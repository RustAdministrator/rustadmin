param(
    [string]$FlutterRoot = "",
    [string]$DepsRoot = "",
    [string]$CargoTargetDir = "",
    [string]$PubCache = "",
    [switch]$NoHwCodec,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$FlutterDir = Join-Path $RepoRoot "flutter"
$Drive = Split-Path -Qualifier $RepoRoot
$DistDir = Join-Path $RepoRoot "dist\windows"

if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $FlutterRoot = if ($env:RUSTDESK_FLUTTER_ROOT) { $env:RUSTDESK_FLUTTER_ROOT } else { Join-Path $Drive "GH\flutter-win" }
}
if ([string]::IsNullOrWhiteSpace($DepsRoot)) {
    $DepsRoot = if ($env:RUSTDESK_WINDOWS_CODEC_ROOT) { $env:RUSTDESK_WINDOWS_CODEC_ROOT } else { Join-Path $Drive "DVS" }
}
if ([string]::IsNullOrWhiteSpace($CargoTargetDir)) {
    $CargoTargetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Drive "GH\rustdesk-target-win" }
}
if ([string]::IsNullOrWhiteSpace($PubCache)) {
    $PubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $Drive "GH\flutter-pub-cache-win" }
}

$FlutterBin = Join-Path $FlutterRoot "bin"
$FlutterBat = Join-Path $FlutterBin "flutter.bat"
if (!(Test-Path $FlutterBat)) {
    throw "Flutter was not found at '$FlutterBat'. Pass -FlutterRoot or set RUSTDESK_FLUTTER_ROOT."
}
if (!(Test-Path $DepsRoot)) {
    throw "Dependency prefix was not found at '$DepsRoot'. Pass -DepsRoot or set RUSTDESK_WINDOWS_CODEC_ROOT."
}

$env:PATH = "$FlutterBin;$env:PATH"
$env:PUB_CACHE = $PubCache
$env:CARGO_TARGET_DIR = $CargoTargetDir
$env:CMAKE_PREFIX_PATH = $DepsRoot
$env:RUSTDESK_WINDOWS_CODEC_ROOT = $DepsRoot

New-Item -ItemType Directory -Force -Path $PubCache, $CargoTargetDir | Out-Null

function Test-StaleFlutterMetadata {
    $PackageConfig = Join-Path $FlutterDir ".dart_tool\package_config.json"
    if (!(Test-Path $PackageConfig)) {
        return $true
    }
    $Content = Get-Content $PackageConfig -Raw
    return $Content.Contains("/home/") -or
        $Content.Contains("/mnt/") -or
        $Content.Contains("/Users/") -or
        $Content.Contains("file:///mnt/") -or
        $Content.Contains("file:///home/") -or
        $Content.Contains("file:///Users/")
}

function Get-RustAdminVersionInfo {
    $CargoToml = Join-Path $RepoRoot "Cargo.toml"
    $RevisionFile = Join-Path $RepoRoot "rustadmin_revision.txt"

    $Version = $null
    foreach ($Line in Get-Content $CargoToml) {
        if ($Line -match '^\s*version\s*=\s*"([^"]+)"') {
            $Version = $Matches[1]
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "Could not read package version from '$CargoToml'."
    }
    if (!(Test-Path $RevisionFile)) {
        throw "Missing RustAdmin revision file: '$RevisionFile'."
    }

    $Revision = (Get-Content $RevisionFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($Revision)) {
        throw "RustAdmin revision file is empty: '$RevisionFile'."
    }

    [PSCustomObject]@{
        Version = $Version
        Revision = $Revision
        ArchiveName = "RustAdmin_Release_$Version.$Revision.zip"
    }
}

function Write-VersionFile {
    param($VersionInfo)

    $VersionFile = Join-Path $RepoRoot "src\version.rs"
    $BuildDate = Get-Date -Format "yyyy-MM-dd HH:mm"
    Set-Content -Path $VersionFile -Encoding ASCII -Value @(
        "#[allow(dead_code)]"
        "pub const VERSION: &str = `"$($VersionInfo.Version)`";"
        "#[allow(dead_code)]"
        "pub const RUSTADMIN_REVISION: &str = `"$($VersionInfo.Revision)`";"
        "#[allow(dead_code)]"
        "pub const FULL_VERSION: &str = `"$($VersionInfo.Version) rev $($VersionInfo.Revision)`";"
        "#[allow(dead_code)]"
        "pub const BUILD_DATE: &str = `"$BuildDate`";"
    )
}

function New-ReleaseZip {
    param($VersionInfo)

    $BundleDir = Join-Path $FlutterDir "build\windows\x64\runner\Release"
    if (!(Test-Path $BundleDir)) {
        throw "Windows bundle was not found at '$BundleDir'."
    }

    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    $ArchivePath = Join-Path $DistDir $VersionInfo.ArchiveName
    Remove-Item -Force $ArchivePath -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $BundleDir "*") -DestinationPath $ArchivePath -CompressionLevel Optimal
    Write-Host "Windows archive:"
    Write-Host $ArchivePath
}

$VersionInfo = Get-RustAdminVersionInfo
Write-VersionFile $VersionInfo

Push-Location $FlutterDir
try {
    if ($Clean -or (Test-StaleFlutterMetadata)) {
        Write-Host "Refreshing Windows Flutter metadata..."
        Remove-Item -Recurse -Force ".dart_tool", ".flutter-plugins-dependencies", "build\windows" -ErrorAction SilentlyContinue
    }
    & $FlutterBat pub get
}
finally {
    Pop-Location
}

$Features = if ($NoHwCodec) { "flutter" } else { "flutter,hwcodec" }

Push-Location $RepoRoot
try {
    cargo build --features $Features --lib --release
}
finally {
    Pop-Location
}

Push-Location $FlutterDir
try {
    & $FlutterBat build windows
}
finally {
    Pop-Location
}

$StaleRuntimeIcon = Join-Path $FlutterDir "build\windows\x64\runner\Release\data\flutter_assets\assets\icon.ico"
Remove-Item -Force $StaleRuntimeIcon -ErrorAction SilentlyContinue

Write-Host "Windows bundle:"
$BundleDir = Join-Path $FlutterDir "build\windows\x64\runner\Release"
Write-Host $BundleDir
New-ReleaseZip $VersionInfo
