param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [string]$InstallPrefix,
    [Parameter(Mandatory = $true)]
    [string]$DependencyPrefix,
    [string]$BuildDir = "",
    [string]$CMakeExe = "cmake.exe",
    [switch]$Clean,
    [switch]$Resume
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = Join-Path $SourceRoot "build\rustadmin-hardware-only"
}
foreach ($Path in @($SourceRoot, $DependencyPrefix)) {
    if (!(Test-Path $Path)) {
        throw "Required path was not found: $Path"
    }
}
if ($Clean -and $Resume) {
    throw "-Clean and -Resume are mutually exclusive."
}
if ($Clean) {
    foreach ($Path in @($BuildDir, $InstallPrefix)) {
        if (Test-Path $Path) {
            Remove-Item -Recurse -Force $Path
        }
    }
} elseif ($Resume) {
    if (!(Test-Path $BuildDir)) {
        throw "Build output was not found for -Resume: $BuildDir"
    }
} elseif ((Test-Path $BuildDir) -or (Test-Path $InstallPrefix)) {
    throw "Build/install output already exists. Use -Clean for a fresh build or -Resume to repeat configure/install/verification without rebuilding."
}

# Distribution policy: H.264/H.265 encoding is hardware/platform-only. Keep
# GPL/nonfree and external codec autodetection disabled so libx264, libx265,
# libopenh264, or another CPU H.26x encoder cannot enter the prefix. Native
# H.264/HEVC decoders and parsers remain enabled for client-side fallback.
# D3D12VA is intentionally omitted from the requested feature set: the native
# backend may still autodetect its decoders, but its encoder sources require
# newer AV1 SDK declarations than Windows SDK 22621. The explicit deny-lists
# below preserve D3D12 decode while RustAdmin uses AMF/NVENC/QSV for encoding.
$HardwareFeatures = @(
    "amf",
    "d3d11va",
    "dxva2",
    "ffnvcodec",
    "libvpl",
    "nvdec",
    "nvenc",
    "qsv"
) -join ";"
$HardwareEncoders = @(
    "av1_amf",
    "h264_amf",
    "hevc_amf",
    "av1_nvenc",
    "h264_nvenc",
    "hevc_nvenc",
    "av1_qsv",
    "h264_qsv",
    "hevc_qsv"
) -join ";"
$DisabledEncoders = @(
    "av1_d3d12va",
    "h264_d3d12va",
    "hevc_d3d12va",
    "libx264",
    "libx265",
    "libopenh264"
) -join ";"
$DisabledFeatures = @(
    "d3d12va_encode",
    "d3d12_encoder_feature",
    "d3d12va_av1_headers",
    "d3d12_intra_refresh",
    "d3d12va_me_precision_eighth_pixel",
    "d3d12_motion_estimator",
    "d3d12_video_process_reference_info"
) -join ";"

$ConfigureArgs = @(
    "-S", $SourceRoot,
    "-B", $BuildDir,
    "-G", "Visual Studio 17 2022",
    "-A", "x64",
    "-DCMAKE_INSTALL_PREFIX=$InstallPrefix",
    "-DCMAKE_PREFIX_PATH=$DependencyPrefix",
    "-DFFMPEG_INSTALL_PREFIX=$InstallPrefix",
    "-DFFMPEG_BUILD_BACKEND=NATIVE_CMAKE",
    "-DFFMPEG_BUILD_STATIC=ON",
    "-DFFMPEG_BUILD_SHARED=OFF",
    "-DFFMPEG_ENABLE_GPL=OFF",
    "-DFFMPEG_ENABLE_VERSION3=OFF",
    "-DFFMPEG_ENABLE_NONFREE=OFF",
    "-DFFMPEG_NATIVE_AUTODETECT_EXTERNAL_LIBRARIES=OFF",
    # FFmpeg's QSV dependency graph names the oneVPL compatibility surface
    # libmfx while also recording the concrete libvpl backend. Enable both;
    # neither adds a software H.26x encoder.
    "-DFFMPEG_ENABLE_EXTERNAL_LIBRARIES=libmfx;libvpl",
    "-DFFMPEG_ENABLE_FEATURES=$HardwareFeatures",
    "-DFFMPEG_DISABLE_FEATURES=$DisabledFeatures",
    "-DFFMPEG_ENABLE_ENCODERS=$HardwareEncoders",
    "-DFFMPEG_DISABLE_ENCODERS=$DisabledEncoders",
    "-DFFMPEG_ENABLE_DECODERS=h264;hevc;av1",
    "-DFFMPEG_ENABLE_PARSERS=h264;hevc;av1",
    "-DFFMPEG_NATIVE_DEFAULT_COMPONENT_SET=COMMON",
    "-DFFMPEG_NATIVE_REQUIRE_STATIC_EXTERNAL_DEPENDENCIES=OFF",
    # Static RustAdmin linkage does not need CMake to redistribute transitive
    # Windows system DLLs for the diagnostic ffmpeg.exe. Runtime scanning can
    # fail on protected inbox DLLs even when all FFmpeg libraries built cleanly.
    "-DFFMPEG_NATIVE_INSTALL_RUNTIME_DEPENDENCIES=OFF",
    "-DFFMPEG_SOURCE_GIT_CLONE=ON",
    "-DFFMPEG_NV_CODEC_HEADERS_GIT_CLONE=ON",
    "-DFFMPEG_AMF_HEADERS_GIT_CLONE=ON",
    "-DFFMPEG_BUILD_DOC=OFF",
    "-DFFMPEG_NATIVE_ENABLE_SMOKE_TESTS=ON",
    "-DFFMPEG_NATIVE_ENABLE_HARDWARE_SMOKE_TESTS=OFF"
)

& $CMakeExe @ConfigureArgs
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg configure failed with exit code $LASTEXITCODE"
}
if (!$Resume) {
    & $CMakeExe --build $BuildDir --config Release --parallel
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg build failed with exit code $LASTEXITCODE"
    }
}
& $CMakeExe --install $BuildDir --config Release
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg install failed with exit code $LASTEXITCODE"
}

$FFmpegExe = Join-Path $InstallPrefix "bin\ffmpeg.exe"
if (!(Test-Path $FFmpegExe)) {
    throw "Installed ffmpeg.exe was not found at $FFmpegExe"
}

$Encoders = (& $FFmpegExe -hide_banner -encoders 2>&1 | Out-String)
$Decoders = (& $FFmpegExe -hide_banner -decoders 2>&1 | Out-String)
$BuildConfig = (& $FFmpegExe -hide_banner -buildconf 2>&1 | Out-String)
$ConfigComponentsPath = Join-Path $BuildDir "ffmpeg-native\config_components.h"
if (!(Test-Path $ConfigComponentsPath)) {
    throw "Generated FFmpeg component configuration was not found: $ConfigComponentsPath"
}
$ConfigComponents = Get-Content -Raw $ConfigComponentsPath

foreach ($Forbidden in @("libx264", "libx265", "libopenh264")) {
    if ($Encoders -match [regex]::Escape($Forbidden)) {
        throw "Forbidden software H.26x encoder is present: $Forbidden"
    }
}
foreach ($Required in @("h264", "hevc")) {
    if ($Decoders -notmatch "(?m)^\s*[A-Z\.]{6}\s+$Required\s") {
        throw "Required software decoder is missing: $Required"
    }
    $ParserMacro = "CONFIG_$($Required.ToUpperInvariant())_PARSER"
    if ($ConfigComponents -notmatch "(?m)^\s*#\s*define\s+$ParserMacro\s+1\b") {
        throw "Required parser is missing: $Required"
    }
}
foreach ($RequiredHardware in @("h264_(nvenc|amf|qsv)", "hevc_(nvenc|amf|qsv)")) {
    if ($Encoders -notmatch $RequiredHardware) {
        throw "No reviewed hardware encoder matched: $RequiredHardware"
    }
}
if ($BuildConfig -match "(?i)(^|[,; ]+)gpl([,; ]+|$)" -or
    $BuildConfig -match "(?i)(^|[,; ]+)nonfree([,; ]+|$)") {
    throw "FFmpeg build unexpectedly enabled GPL or nonfree components"
}

Write-Host "Hardware-only FFmpeg verification passed."
Write-Host "Prefix: $InstallPrefix"
