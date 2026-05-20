param(
    [string]$FlutterRoot = "",
    [string]$PubCache = "",
    [string]$CargoTargetDir = "",
    [string]$Features = "flutter,use_dasp",
    [switch]$SkipFullClient,
    [switch]$SkipHbbCommon,
    [switch]$SkipFlutter,
    [switch]$StopOnFailure
)

$ErrorActionPreference = "Stop"

$ClientRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WorkspaceRoot = Split-Path $ClientRoot -Parent
$HbbCommonRoot = Join-Path $WorkspaceRoot "hbb_common"
$FlutterDir = Join-Path $ClientRoot "flutter"
$Drive = Split-Path -Qualifier $ClientRoot

if ([string]::IsNullOrWhiteSpace($PubCache)) {
    $PubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $Drive "GH\flutter-pub-cache-win" }
}
if ([string]::IsNullOrWhiteSpace($CargoTargetDir)) {
    $CargoTargetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Drive "GH\rustdesk-target-win" }
}
if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $DefaultFlutterRoot = Join-Path $Drive "GH\flutter-win"
    $FlutterRoot = if ($env:RUSTDESK_FLUTTER_ROOT) { $env:RUSTDESK_FLUTTER_ROOT } elseif (Test-Path (Join-Path $DefaultFlutterRoot "bin\flutter.bat")) { $DefaultFlutterRoot } else { "" }
}

$env:PUB_CACHE = $PubCache
$env:CARGO_TARGET_DIR = $CargoTargetDir
New-Item -ItemType Directory -Force -Path $PubCache, $CargoTargetDir | Out-Null

function Resolve-FlutterCommand {
    if (![string]::IsNullOrWhiteSpace($FlutterRoot)) {
        $flutterBat = Join-Path $FlutterRoot "bin\flutter.bat"
        if (!(Test-Path $flutterBat)) {
            throw "Flutter was not found at '$flutterBat'. Pass -FlutterRoot or set RUSTDESK_FLUTTER_ROOT."
        }
        $env:PATH = "$(Join-Path $FlutterRoot "bin");$env:PATH"
        return $flutterBat
    }

    $cmd = Get-Command "flutter.bat" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $cmd = Get-Command "flutter" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    throw "Flutter was not found on PATH. Pass -FlutterRoot or set RUSTDESK_FLUTTER_ROOT."
}

$Results = New-Object System.Collections.Generic.List[object]

function Invoke-TestStep {
    param(
        [string]$Name,
        [string]$WorkingDirectory,
        [string]$Command,
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan
    Write-Host "    $Command $($Arguments -join ' ')" -ForegroundColor DarkGray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $exitCode = 1
    }
    finally {
        Pop-Location
        $sw.Stop()
    }

    $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
    $Results.Add([PSCustomObject]@{
        Step = $Name
        Status = $status
        ExitCode = $exitCode
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    })

    if ($exitCode -ne 0 -and $StopOnFailure) {
        throw "Stopping after failed step: $Name"
    }
}

$LogDir = Join-Path $ClientRoot "target\windows-test-logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$TranscriptPath = Join-Path $LogDir ("windows-tests-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$TranscriptStarted = $false
try {
    Start-Transcript -Path $TranscriptPath | Out-Null
    $TranscriptStarted = $true
}
catch {
    Write-Host "Warning: could not start transcript: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    Write-Host "RustAdmin Windows validation"
    Write-Host "Client:      $ClientRoot"
    Write-Host "hbb_common:  $HbbCommonRoot"
    Write-Host "Flutter dir: $FlutterDir"
    Write-Host "Features:    $Features"
    Write-Host "Pub cache:   $env:PUB_CACHE"
    Write-Host "Target dir:  $env:CARGO_TARGET_DIR"

    Invoke-TestStep "rustdesk-client cargo check" $ClientRoot "cargo" @(
        "check", "--no-default-features", "--features", $Features
    )
    Invoke-TestStep "privacy mode policy tests" $ClientRoot "cargo" @(
        "test", "--no-default-features", "--features", $Features, "privacy_mode_policy"
    )
    Invoke-TestStep "RustAdmin GUI block policy tests" $ClientRoot "cargo" @(
        "test", "--no-default-features", "--features", $Features, "rustadmin_gui_block_policy"
    )
    Invoke-TestStep "low-permission support policy tests" $ClientRoot "cargo" @(
        "test", "--no-default-features", "--features", $Features, "low_permission"
    )
    Invoke-TestStep "elevation permission policy tests" $ClientRoot "cargo" @(
        "test", "--no-default-features", "--features", $Features, "elevation_policy_requires_unattended_access"
    )
    Invoke-TestStep "IPC enum size contract" $ClientRoot "cargo" @(
        "test", "--no-default-features", "--features", $Features, "ipc::test::verify_ffi_enum_data_size"
    )

    if (!$SkipFullClient) {
        Invoke-TestStep "rustdesk-client full serial tests" $ClientRoot "cargo" @(
            "test", "--no-default-features", "--features", $Features, "--", "--test-threads=1"
        )
    }

    if (!$SkipHbbCommon) {
        Invoke-TestStep "hbb_common permanent password tests" $HbbCommonRoot "cargo" @(
            "test", "permanent_password"
        )
        Invoke-TestStep "hbb_common full tests" $HbbCommonRoot "cargo" @(
            "test"
        )
    }

    if (!$SkipFlutter) {
        $FlutterCommand = Resolve-FlutterCommand
        # `.dart_tool/package_config.json` is platform/cache specific. Regenerate
        # it here so WSL/Linux Flutter runs cannot leave Windows tests pointing
        # at `/mnt/...` package paths.
        Invoke-TestStep "Flutter pub get" $FlutterDir $FlutterCommand @("pub", "get")
        Invoke-TestStep "Flutter tests" $FlutterDir $FlutterCommand @("test", "-r", "expanded")
    }
}
finally {
    Write-Host ""
    Write-Host "Windows validation summary" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Log: $TranscriptPath"
    }
}

$Failed = @($Results | Where-Object { $_.Status -ne "PASS" })
if ($Failed.Count -gt 0) {
    exit 1
}
exit 0
