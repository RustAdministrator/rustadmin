param(
    [string]$FlutterRoot = "",
    [string]$DepsRoot = "",
    [string]$CargoTargetDir = "",
    [string]$PubCache = "",
    [string]$Device = "windows",
    [string]$Target = "lib\prototyping\main_toolbar_lab.dart",
    [switch]$HwCodec,
    [switch]$SkipCargo,
    [switch]$Clean,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArgs
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$FlutterDir = Join-Path $RepoRoot "flutter"
$Drive = Split-Path -Qualifier $RepoRoot

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

$Features = if ($HwCodec) { "flutter,hwcodec" } else { "flutter" }

if (-not $SkipCargo) {
    Push-Location $RepoRoot
    try {
        cargo build --features $Features --lib
    }
    finally {
        Pop-Location
    }
}

Push-Location $FlutterDir
try {
    & $FlutterBat run -d $Device -t $Target @FlutterArgs
}
finally {
    Pop-Location
}
