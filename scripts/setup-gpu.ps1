# Nucleus GPU Setup Script for Windows
# Run as: powershell -ExecutionPolicy Bypass -File setup-gpu.ps1 [cuda|directml|openvino] [-OutputDir <path>] [-TempDir <path>]

param(
    [Parameter(Position=0)]
    [ValidateSet("cuda", "directml", "openvino", "cpu")]
    [string]$Provider = "cpu",

    [Parameter()]
    [string]$OutputDir = "",

    [Parameter()]
    [string]$TempDir = $env:TEMP
)

$ErrorActionPreference = "Stop"
$LibDir = if ($OutputDir) { $OutputDir } else { "$PSScriptRoot\..\target\release" }

# ONNX Runtime version - must match the version used by fastembed/ort crate
# Check NuGet for available versions: https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime.DirectML
$ORT_VERSION = "1.23.0"

function Download-File($url, $output) {
    Write-Host "Downloading $url..."
    Invoke-WebRequest -Uri $url -OutFile $output
}

function Download-NuGetPackage($packageName, $version, $output) {
    # NuGet v3 flat container API
    # Download as .zip since Expand-Archive doesn't recognize .nupkg extension
    $url = "https://api.nuget.org/v3-flatcontainer/$($packageName.ToLower())/$version/$($packageName.ToLower()).$version.nupkg"
    Write-Host "Downloading NuGet package: $packageName v$version..."
    $zipOutput = $output -replace '\.nupkg$', '.zip'
    Invoke-WebRequest -Uri $url -OutFile $zipOutput
    # Return the actual path (with .zip extension)
    return $zipOutput
}

function Get-PyPiWheelUrl($packageName) {
    Write-Host "Searching PyPI for latest $packageName wheel..."
    $json = Invoke-RestMethod -Uri "https://pypi.org/pypi/$packageName/json"
    
    # Check top-level urls first (latest stable release)
    $wheel = $json.urls | Where-Object { $_.filename -like "*win_amd64.whl" } | Select-Object -First 1
    if ($wheel) {
        return $wheel.url
    }
    
    throw "Could not find win_amd64 wheel for $packageName on PyPI"
}

function Setup-CUDA {
    Write-Host "Setting up CUDA provider (NVIDIA GPU)..."

    # Check CUDA installation
    $SystemCuda = Test-Path "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
    if (-not $SystemCuda) {
        Write-Warning "System CUDA Toolkit not found. Attempting to download portable binaries..."
        Setup-CudaRedist
    }

    # CUDA uses NuGet package for ORT provider DLLs
    $zip = "$TempDir\ort-cuda.zip"
    $extractDir = "$TempDir\ort-cuda"

    $zip = Download-NuGetPackage "Microsoft.ML.OnnxRuntime.Gpu.Windows" $ORT_VERSION $zip

    Write-Host "Extracting ONNX Runtime CUDA provider..."
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force

    $srcDir = "$extractDir\runtimes\win-x64\native"
    Copy-Item "$srcDir\onnxruntime.dll" $LibDir -Force
    Copy-Item "$srcDir\onnxruntime_providers_shared.dll" $LibDir -Force
    Copy-Item "$srcDir\onnxruntime_providers_cuda.dll" $LibDir -Force
    Copy-Item "$srcDir\onnxruntime_providers_tensorrt.dll" $LibDir -Force -ErrorAction SilentlyContinue

    # Cleanup temp files
    Write-Host "Cleaning up temporary files..."
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ""
    if ($SystemCuda) {
        Write-Host "CUDA provider installed to $LibDir (using system CUDA)"
    } else {
        Write-Host "CUDA provider installed to $LibDir (with portable redist binaries)"
    }
    Write-Host ""
    Write-Host "Set NUCLEUS_EP=cuda to use CUDA execution provider"
}

function Setup-CudaRedist {
    Write-Host "Downloading CUDA 12 and cuDNN 9 redistributable binaries..."

    # CUDA 12 components from PyPI (they contain the full DLLs unlike NuGet placeholders)
    $CudaPackages = @("nvidia-cuda-runtime-cu12", "nvidia-cublas-cu12")

    foreach ($pkg in $CudaPackages) {
        $url = Get-PyPiWheelUrl $pkg
        $zipFile = "$TempDir\$pkg.zip"
        $extractPath = "$TempDir\$pkg"
        
        Download-File $url $zipFile
        
        Write-Host "Extracting $pkg..."
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        # Rename .whl to .zip for extraction if needed, but Expand-Archive often works on .whl
        Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force
        
        # Discover DLLs recursively and copy to LibDir
        Get-ChildItem -Path $extractPath -Filter "*.dll" -Recurse | ForEach-Object {
            Copy-Item $_.FullName $LibDir -Force
        }

        # Cleanup
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # cuDNN 9.x from NVIDIA redist server
    # Note: Using a fixed version known to be stable with ORT 1.23.0
    $CudnnVersion = "9.19.0.56"
    $CudnnZip = "$TempDir\cudnn.zip"
    $CudnnExtract = "$TempDir\cudnn"
    $CudnnUrl = "https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-${CudnnVersion}_cuda12-archive.zip"

    Download-File $CudnnUrl $CudnnZip
    
    Write-Host "Extracting cuDNN $CudnnVersion..."
    if (Test-Path $CudnnExtract) { Remove-Item $CudnnExtract -Recurse -Force }
    Expand-Archive -Path $CudnnZip -DestinationPath $CudnnExtract -Force
    
    # cuDNN zip has a subfolder in the archive
    $CudnnBinDir = Get-ChildItem -Path $CudnnExtract -Directory | Select-Object -First 1 | ForEach-Object { "$($_.FullName)\bin" }
    if (Test-Path $CudnnBinDir) {
        Copy-Item "$CudnnBinDir\*.dll" $LibDir -Force
    }

    # Cleanup cuDNN
    Remove-Item $CudnnZip -Force -ErrorAction SilentlyContinue
    Remove-Item $CudnnExtract -Recurse -Force -ErrorAction SilentlyContinue

    # ZLib is often a dependency for cuDNN
    Write-Host "Adding ZLib dependency..."
    $ZLibUrl = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib131.zip"
    $ZLibZip = "$TempDir\zlib.zip"
    $ZLibExtract = "$TempDir\zlib"
    Download-File $ZLibUrl $ZLibZip
    Expand-Archive -Path $ZLibZip -DestinationPath $ZLibExtract -Force
    Copy-Item "$ZLibExtract\zlib1.dll" $LibDir -Force -ErrorAction SilentlyContinue

    # Cleanup ZLib
    Remove-Item $ZLibZip -Force -ErrorAction SilentlyContinue
    Remove-Item $ZLibExtract -Recurse -Force -ErrorAction SilentlyContinue
}

function Setup-DirectML {
    Write-Host "Setting up DirectML provider (works with any Windows GPU)..."

    # DirectML is distributed via NuGet, not GitHub releases
    $zip = "$TempDir\ort-directml.zip"
    $extractDir = "$TempDir\ort-directml"

    $zip = Download-NuGetPackage "Microsoft.ML.OnnxRuntime.DirectML" $ORT_VERSION $zip

    Write-Host "Extracting..."
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force

    $srcDir = "$extractDir\runtimes\win-x64\native"

    # Copy ONNX Runtime with DirectML support (DirectML is built into onnxruntime.dll)
    Copy-Item "$srcDir\onnxruntime.dll" $LibDir -Force
    Copy-Item "$srcDir\onnxruntime_providers_shared.dll" $LibDir -Force

    # Cleanup temp files
    Write-Host "Cleaning up temporary files..."
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "DirectML provider installed to $LibDir"
    Write-Host ""
    Write-Host "Set NUCLEUS_EP=directml to use DirectML execution provider"
    Write-Host "Works with NVIDIA, AMD, and Intel GPUs on Windows 10/11"
}

function Setup-OpenVINO {
    Write-Host "Setting up OpenVINO provider (Intel CPU/GPU/NPU)..."

    # OpenVINO uses Intel's NuGet package (not Microsoft's)
    # See: https://www.nuget.org/packages/Intel.ML.OnnxRuntime.OpenVino
    $zip = "$TempDir\ort-openvino.zip"
    $extractDir = "$TempDir\ort-openvino"

    $zip = Download-NuGetPackage "Intel.ML.OnnxRuntime.OpenVino" $ORT_VERSION $zip

    Write-Host "Extracting..."
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force

    $srcDir = "$extractDir\runtimes\win-x64\native"

    # Copy ONNX Runtime with OpenVINO support
    Copy-Item "$srcDir\*.dll" $LibDir -Force

    # Cleanup temp files
    Write-Host "Cleaning up temporary files..."
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "OpenVINO provider installed to $LibDir"
    Write-Host ""
    Write-Host "Set NUCLEUS_EP=openvino to use OpenVINO execution provider"
    Write-Host "Supported devices: CPU, GPU (Intel Arc), NPU (Intel AI Boost)"
}

# Create lib directory
if (-not (Test-Path $LibDir)) {
    New-Item -ItemType Directory -Path $LibDir -Force | Out-Null
}

switch ($Provider) {
    "cuda" { Setup-CUDA }
    "directml" { Setup-DirectML }
    "openvino" { Setup-OpenVINO }
    "cpu" {
        Write-Host "CPU-only mode (default). No additional setup needed."
        Write-Host "The ONNX Runtime CPU version is bundled with the binary."
    }
}

Write-Host ""
Write-Host "Done! Provider: $Provider"
Write-Host ""
Write-Host "Model cache: $env:LOCALAPPDATA\fastembed"
Write-Host "The BGE-M3 model (~550MB) downloads automatically on first run."
Write-Host ""
Write-Host "Usage:"
Write-Host "  `$env:NUCLEUS_EP = `"$Provider`""
Write-Host "  nucleus-server.exe"
