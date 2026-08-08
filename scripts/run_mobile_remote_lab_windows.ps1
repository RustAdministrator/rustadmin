param(
    [string]$FlutterRoot = "",
    [string]$DepsRoot = "",
    [string]$CargoTargetDir = "",
    [string]$PubCache = "",
    [string]$Device = "windows",
    [switch]$HwCodec,
    [switch]$SkipCargo,
    [switch]$Clean,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArgs
)

$ErrorActionPreference = "Stop"

$Runner = Join-Path $PSScriptRoot "run_toolbar_lab_windows.ps1"
$Target = "lib\prototyping\main_mobile_remote_lab.dart"

$RunnerParams = @{
    FlutterRoot = $FlutterRoot
    DepsRoot = $DepsRoot
    CargoTargetDir = $CargoTargetDir
    PubCache = $PubCache
    Device = $Device
    Target = $Target
    HwCodec = $HwCodec.IsPresent
    SkipCargo = $SkipCargo.IsPresent
    Clean = $Clean.IsPresent
    FlutterArgs = $FlutterArgs
}

& $Runner @RunnerParams
