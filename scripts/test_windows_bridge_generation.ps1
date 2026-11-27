$ErrorActionPreference = "Stop"

$Tokens = $null
$ParseErrors = $null
$BuildScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "build_windows.ps1"), [ref]$Tokens, [ref]$ParseErrors
)
if ($ParseErrors.Count -ne 0) {
    throw ($ParseErrors -join [Environment]::NewLine)
}
foreach ($Statement in $BuildScriptAst.EndBlock.Statements) {
    if ($Statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $Statement.Name -in "Invoke-BridgeGeneration", "Test-BridgeFilesCurrent", "Invoke-NativeCommand") {
        Invoke-Expression $Statement.Extent.Text
    }
}

$RepoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rustadmin-bridge-$([guid]::NewGuid())"
$FlutterDir = Join-Path $RepoRoot "flutter"
$FlutterBin = Join-Path $RepoRoot "sdk bin"
$BridgeClassName = "Rustadmin"
$VerboseBridgeGenEffective = $true
$script:CodegenCalls = 0

function Resolve-BridgeCodegen { "Invoke-MockBridgeCodegen" }
function Assert-BridgeCodegenVersion { "flutter_rust_bridge_codegen 1.80.1" }
function Resolve-BridgeLlvmPath { "" }

function Invoke-MockBridgeCodegen {
    if ($args -notcontains "--no-build-runner" -or $args -notcontains "--verbose") {
        throw "Codegen must skip its built-in build_runner and receive the verbose flag."
    }
    $script:CodegenCalls++
    Set-Content (Join-Path $FlutterDir "lib\generated_bridge.dart") "class RustadminImpl"
    Set-Content (Join-Path $RepoRoot "src\bridge_generated.rs") "generated"
    Set-Content (Join-Path $RepoRoot "src\bridge_generated.io.rs") "generated"
    $global:LASTEXITCODE = 0
}

try {
    $null = New-Item -ItemType Directory -Path $FlutterBin, "$FlutterDir\lib", "$RepoRoot\src" -Force
    Set-Content "$RepoRoot\src\flutter_ffi.rs" ""
    Set-Content (Join-Path $FlutterBin "dart.bat") -Encoding ASCII @'
@echo off
if "%*"=="run build_runner build --delete-conflicting-outputs --build-filter=lib/generated_bridge.freezed.dart" goto build
if "%~1"=="format" if "%~2"=="--line-length" if "%~3"=="80" if "%~4"=="%CD%\lib\generated_bridge.freezed.dart" goto format
exit /b 20

:build
if exist fail-freezed exit /b 17
if not exist lib\generated_bridge.dart exit /b 18
echo generated>lib\generated_bridge.freezed.dart
exit /b 0

:format
if not exist "%~4" exit /b 19
echo formatted>>"%~4"
exit /b 0
'@

    $OriginalLocation = (Get-Location).Path
    Set-Content "$FlutterDir\fail-freezed" ""
    try {
        Invoke-BridgeGeneration
        throw "Bridge generation accepted a failed Freezed command."
    }
    catch {
        if ($_.Exception.Message -ne "Flutter bridge Freezed generation failed with exit code 17.") {
            throw
        }
    }
    if ((Get-Location).Path -ne $OriginalLocation) {
        throw "Bridge generation did not restore the working directory on failure."
    }
    Remove-Item "$FlutterDir\fail-freezed"

    Invoke-BridgeGeneration
    if ((Get-Content "$FlutterDir\lib\generated_bridge.freezed.dart" -Tail 1) -ne "formatted") {
        throw "Bridge generation did not format the Freezed output."
    }
    Invoke-BridgeGeneration
    if ($script:CodegenCalls -ne 2) {
        throw "Bridge generation did not retry missing output or skip current output."
    }
}
finally {
    Remove-Item -LiteralPath $RepoRoot -Recurse -Force
}

Write-Host "Windows bridge generation checks passed."
