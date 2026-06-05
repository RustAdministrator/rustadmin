param(
    [string]$FlutterRoot = "",
    [string]$DepsRoot = "",
    [string]$PubCache = "",
    [string]$CargoTargetDir = "",
    [string]$Features = "flutter,use_dasp",
    [string]$BridgeLlvmPath = "",
    [string]$BridgeLlvmCompilerOpts = "",
    [switch]$SkipFullClient,
    [switch]$SkipHbbCommon,
    [switch]$SkipFlutter,
    [switch]$SkipBridgeGen,
    [switch]$ForceBridgeGen,
    [switch]$VerboseBridgeGen,
    [switch]$ClipboardIntegration,
    [switch]$StopOnFailure
)

$ErrorActionPreference = "Stop"

$RequiredBridgeCodegenVersion = "1.80.1"
$BridgeClassName = "Rustdesk"
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
if ([string]::IsNullOrWhiteSpace($DepsRoot)) {
    $DepsRoot = if ($env:RUSTDESK_WINDOWS_CODEC_ROOT) { $env:RUSTDESK_WINDOWS_CODEC_ROOT } else { Join-Path $Drive "DVS" }
}
if (!(Test-Path $DepsRoot)) {
    throw "Dependency prefix was not found at '$DepsRoot'. Pass -DepsRoot or set RUSTDESK_WINDOWS_CODEC_ROOT."
}

$env:PUB_CACHE = $PubCache
$env:CARGO_TARGET_DIR = $CargoTargetDir
$env:CMAKE_PREFIX_PATH = $DepsRoot
$env:RUSTDESK_WINDOWS_CODEC_ROOT = $DepsRoot
New-Item -ItemType Directory -Force -Path $PubCache, $CargoTargetDir | Out-Null

$SkipBridgeGenEffective = $SkipBridgeGen -or ($env:RUSTDESK_SKIP_BRIDGE_GEN -eq "1")
$ForceBridgeGenEffective = $ForceBridgeGen -or ($env:RUSTDESK_FORCE_BRIDGE_GEN -eq "1")
$VerboseBridgeGenEffective = $VerboseBridgeGen -or ($env:RUSTDESK_VERBOSE_BRIDGE_GEN -eq "1")
if ([string]::IsNullOrWhiteSpace($BridgeLlvmPath)) {
    $BridgeLlvmPath = $env:RUSTDESK_BRIDGE_LLVM_PATH
}
if ([string]::IsNullOrWhiteSpace($BridgeLlvmCompilerOpts)) {
    $BridgeLlvmCompilerOpts = $env:RUSTDESK_BRIDGE_LLVM_COMPILER_OPTS
}

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

function ConvertTo-StepLogName {
    param(
        [string]$Name
    )

    $safeName = $Name -replace '[^A-Za-z0-9._-]+', '-'
    $safeName = $safeName.Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return "step"
    }
    return $safeName
}

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
    $stepNumber = $Results.Count + 1
    $stepLogName = "{0:00}-{1}.log" -f $stepNumber, (ConvertTo-StepLogName $Name)
    $stepLogPath = Join-Path $StepLogDir $stepLogName
    Write-Host "    Step log: $stepLogPath" -ForegroundColor DarkGray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $WorkingDirectory
    New-Item -ItemType File -Force -Path $stepLogPath | Out-Null
    $oldErrorActionPreference = $ErrorActionPreference
    $hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        & $Command @Arguments *>&1 | Tee-Object -FilePath $stepLogPath
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    catch {
        $_.ToString() | Add-Content -Encoding UTF8 -Path $stepLogPath
        Write-Host $_.ToString() -ForegroundColor Red
        $exitCode = 1
    }
    finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
        $ErrorActionPreference = $oldErrorActionPreference
        Pop-Location
        $sw.Stop()
    }

    $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
    $Results.Add([PSCustomObject]@{
        Step = $Name
        Status = $status
        ExitCode = $exitCode
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Log = $stepLogPath
    })

    if ($exitCode -ne 0) {
        Write-Host "    Failed step log tail:" -ForegroundColor Red
        Get-Content -Path $stepLogPath -Tail 80 | ForEach-Object {
            Write-Host "    $_" -ForegroundColor Red
        }
    }

    if ($exitCode -ne 0 -and $StopOnFailure) {
        throw "Stopping after failed step: $Name"
    }
}

function Test-BridgeLlvmRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return Test-Path (Join-Path $Path "bin\libclang.dll")
}

function Add-BridgeLlvmCandidate {
    param(
        [System.Collections.Generic.List[string]]$Candidates,
        [string]$Path
    )

    if (![string]::IsNullOrWhiteSpace($Path) -and !$Candidates.Contains($Path)) {
        $Candidates.Add($Path)
    }
}

function Resolve-BridgeLlvmPath {
    param([string]$RequestedPath)

    if (![string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (!(Test-BridgeLlvmRoot $RequestedPath)) {
            throw "libclang.dll was not found under '$RequestedPath\bin'. Pass -BridgeLlvmPath to an LLVM root that contains bin\libclang.dll."
        }
        return (Resolve-Path $RequestedPath).Path
    }

    $Candidates = [System.Collections.Generic.List[string]]::new()
    Add-BridgeLlvmCandidate $Candidates $env:LLVM_PATH
    if (![string]::IsNullOrWhiteSpace($env:LIBCLANG_PATH)) {
        Add-BridgeLlvmCandidate $Candidates $env:LIBCLANG_PATH
        if (Test-Path (Join-Path $env:LIBCLANG_PATH "libclang.dll")) {
            Add-BridgeLlvmCandidate $Candidates (Split-Path $env:LIBCLANG_PATH -Parent)
        }
    }

    $KnownDrives = @("C:", "D:", $Drive) | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($RootDrive in $KnownDrives) {
        Add-BridgeLlvmCandidate $Candidates (Join-Path $RootDrive "Program Files\LLVM")
        Add-BridgeLlvmCandidate $Candidates (Join-Path $RootDrive "msys64\mingw64")
        foreach ($VsVersion in @("18", "17")) {
            foreach ($VsEdition in @("Community", "Professional", "Enterprise", "BuildTools")) {
                Add-BridgeLlvmCandidate $Candidates (Join-Path $RootDrive "Program Files\Microsoft Visual Studio\$VsVersion\$VsEdition\VC\Tools\Llvm\x64")
            }
        }
    }

    foreach ($Candidate in $Candidates) {
        if (Test-BridgeLlvmRoot $Candidate) {
            return (Resolve-Path $Candidate).Path
        }
    }

    return ""
}

function Resolve-BridgeCodegen {
    $Command = Get-Command "flutter_rust_bridge_codegen.exe" -ErrorAction SilentlyContinue
    if (!$Command) {
        $Command = Get-Command "flutter_rust_bridge_codegen" -ErrorAction SilentlyContinue
    }
    if ($Command) {
        return $Command.Source
    }

    $CandidateRoots = @($env:USERPROFILE, $env:HOME) | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($CandidateRoot in $CandidateRoots) {
        foreach ($Name in @("flutter_rust_bridge_codegen.exe", "flutter_rust_bridge_codegen")) {
            $Candidate = Join-Path $CandidateRoot ".cargo\bin\$Name"
            if (Test-Path $Candidate) {
                return $Candidate
            }
        }
    }

    throw @"
flutter_rust_bridge_codegen was not found.
Install it with:
  cargo install flutter_rust_bridge_codegen --version $RequiredBridgeCodegenVersion --features uuid --locked --force
or pass -SkipBridgeGen if the generated files are already current.
"@
}

function Assert-BridgeCodegenVersion {
    param([string]$BridgeCodegen)

    $VersionOutput = & $BridgeCodegen --version 2>&1
    $ExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    $VersionText = ($VersionOutput | Out-String).Trim()
    if ($ExitCode -ne 0) {
        throw "Failed to run '$BridgeCodegen --version' with exit code $ExitCode. Output: $VersionText"
    }
    if ($VersionText -notmatch "\b$([regex]::Escape($RequiredBridgeCodegenVersion))\b") {
        throw @"
flutter_rust_bridge_codegen version mismatch.
Found:    $VersionText
Expected: $RequiredBridgeCodegenVersion
Binary:   $BridgeCodegen
Install the pinned generator with:
  cargo install flutter_rust_bridge_codegen --version $RequiredBridgeCodegenVersion --features uuid --locked --force
or pass -SkipBridgeGen if the generated files are already current.
"@
    }
    return $VersionText
}

function Get-BridgeInput {
    return (Join-Path $ClientRoot "src\flutter_ffi.rs")
}

function Get-BridgeOutputs {
    return @(
        (Join-Path $FlutterDir "lib\generated_bridge.dart"),
        (Join-Path $FlutterDir "lib\generated_bridge.freezed.dart"),
        (Join-Path $ClientRoot "src\bridge_generated.rs"),
        (Join-Path $ClientRoot "src\bridge_generated.io.rs")
    )
}

function Test-BridgeFilesCurrent {
    param(
        [string]$BridgeInput,
        [string[]]$BridgeOutputs
    )

    if (!(Test-Path $BridgeInput)) {
        throw "Bridge Rust input was not found at '$BridgeInput'."
    }

    $InputTimestamp = (Get-Item $BridgeInput).LastWriteTimeUtc
    foreach ($Output in $BridgeOutputs) {
        if (!(Test-Path $Output)) {
            return $false
        }
        if ((Get-Item $Output).LastWriteTimeUtc -lt $InputTimestamp) {
            return $false
        }
    }
    $GeneratedDart = $BridgeOutputs[0]
    if (!((Get-Content $GeneratedDart -Raw).Contains("class $($BridgeClassName)Impl"))) {
        return $false
    }
    return $true
}

function Test-BridgeGenerationRequired {
    if ($SkipBridgeGenEffective) {
        return $false
    }
    if ($ForceBridgeGenEffective) {
        return $true
    }
    return !(Test-BridgeFilesCurrent (Get-BridgeInput) (Get-BridgeOutputs))
}

function Invoke-BridgeGenerationStep {
    $BridgeCodegen = Resolve-BridgeCodegen
    $BridgeCodegenVersion = Assert-BridgeCodegenVersion $BridgeCodegen
    $ResolvedBridgeLlvmPath = Resolve-BridgeLlvmPath $BridgeLlvmPath
    $BridgeArgs = @(
        "--rust-input", (Get-BridgeInput),
        "--dart-output", (Join-Path $FlutterDir "lib\generated_bridge.dart"),
        "--class-name", $BridgeClassName
    )
    if (![string]::IsNullOrWhiteSpace($ResolvedBridgeLlvmPath)) {
        $BridgeArgs += @("--llvm-path", $ResolvedBridgeLlvmPath)
    }
    if (![string]::IsNullOrWhiteSpace($BridgeLlvmCompilerOpts)) {
        $BridgeArgs += "--llvm-compiler-opts=$BridgeLlvmCompilerOpts"
    }

    Write-Host "Using flutter_rust_bridge_codegen: $BridgeCodegen ($BridgeCodegenVersion)"
    if ($VerboseBridgeGenEffective) {
        Write-Host "Bridge LLVM path: $ResolvedBridgeLlvmPath"
    }
    Invoke-TestStep "Flutter bridge generation" $ClientRoot $BridgeCodegen $BridgeArgs
    if ($Results[$Results.Count - 1].Status -ne "PASS") {
        throw "flutter_rust_bridge generation failed."
    }
    foreach ($OutputPath in (Get-BridgeOutputs)) {
        if (!(Test-Path $OutputPath)) {
            throw "flutter_rust_bridge generation did not create '$OutputPath'."
        }
    }
}

$LogDir = Join-Path $ClientRoot "target\windows-test-logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$TranscriptPath = Join-Path $LogDir ("windows-tests-{0}.log" -f $RunStamp)
$StepLogDir = Join-Path $LogDir ("windows-tests-{0}-steps" -f $RunStamp)
New-Item -ItemType Directory -Force -Path $StepLogDir | Out-Null
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
    Write-Host "Codec root:  $env:RUSTDESK_WINDOWS_CODEC_ROOT"
    Write-Host "Clipboard integration: $ClipboardIntegration"

    $FlutterCommand = $null
    $FlutterPubGetAlreadyRun = $false
    if ($SkipBridgeGenEffective) {
        Write-Host "Bridge gen:  skipped"
    } elseif (Test-BridgeGenerationRequired) {
        $FlutterCommand = Resolve-FlutterCommand
        Invoke-TestStep "Flutter pub get" $FlutterDir $FlutterCommand @("pub", "get")
        if ($Results[$Results.Count - 1].Status -ne "PASS") {
            throw "Flutter pub get failed before bridge generation."
        }
        $FlutterPubGetAlreadyRun = $true
        Invoke-BridgeGenerationStep
    } else {
        Write-Host "Bridge gen:  generated files are current"
    }

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

    if ($ClipboardIntegration) {
        $oldClipboardIntegration = $env:RUSTDESK_CLIPBOARD_INTEGRATION_TESTS
        try {
            $env:RUSTDESK_CLIPBOARD_INTEGRATION_TESTS = "1"
            Invoke-TestStep "Windows clipboard integration tests" $ClientRoot "cargo" @(
                "test", "--no-default-features", "--features", $Features,
                "clipboard_windows_integration_tests", "--", "--ignored", "--test-threads=1"
            )
        }
        finally {
            $env:RUSTDESK_CLIPBOARD_INTEGRATION_TESTS = $oldClipboardIntegration
        }
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
        if (!$FlutterCommand) {
            $FlutterCommand = Resolve-FlutterCommand
        }
        # `.dart_tool/package_config.json` is platform/cache specific. Regenerate
        # it here so WSL/Linux Flutter runs cannot leave Windows tests pointing
        # at `/mnt/...` package paths.
        if (!$FlutterPubGetAlreadyRun) {
            Invoke-TestStep "Flutter pub get" $FlutterDir $FlutterCommand @("pub", "get")
        }
        Invoke-TestStep "Flutter tests" $FlutterDir $FlutterCommand @("test", "-r", "expanded")
    }
}
finally {
    Write-Host ""
    Write-Host "Windows validation summary" -ForegroundColor Cyan
    $Results | Select-Object Step, Status, ExitCode, Seconds | Format-Table -AutoSize
    $FailedInFinally = @($Results | Where-Object { $_.Status -ne "PASS" })
    if ($FailedInFinally.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed step logs:" -ForegroundColor Red
        foreach ($item in $FailedInFinally) {
            Write-Host (" - {0}: {1}" -f $item.Step, $item.Log) -ForegroundColor Red
        }
    }
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Log: $TranscriptPath"
    }
    Write-Host "Step logs: $StepLogDir"
}

$Failed = @($Results | Where-Object { $_.Status -ne "PASS" })
if ($Failed.Count -gt 0) {
    exit 1
}
exit 0
