param(
    [string]$FlutterRoot = "",
    [string]$DepsRoot = "",
    [string]$FFmpegRoot = "",
    [string]$CargoTargetDir = "",
    [string]$PubCache = "",
    [string]$BridgeLlvmPath = "",
    [string]$BridgeLlvmCompilerOpts = "",
    [switch]$NoHwCodec,
    [switch]$Clean,
    [switch]$SkipBridgeGen,
    [switch]$ForceBridgeGen,
    [switch]$VerboseBridgeGen
)

$ErrorActionPreference = "Stop"

$RequiredBridgeCodegenVersion = "1.80.1"
$BridgeClassName = "Rustadmin"
$CodecIntegrationReportKind = "rustadmin-codec-integration"
$CodecIntegrationReportVersion = 2
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
if ([string]::IsNullOrWhiteSpace($FFmpegRoot)) {
    $FFmpegRoot = $env:RUSTADMIN_WINDOWS_FFMPEG_ROOT
}
$CodecRoot = if ([string]::IsNullOrWhiteSpace($FFmpegRoot)) { $DepsRoot } else { $FFmpegRoot }
if (!(Test-Path $CodecRoot)) {
    throw "FFmpeg prefix was not found at '$CodecRoot'. Pass -FFmpegRoot or set RUSTADMIN_WINDOWS_FFMPEG_ROOT."
}
$DependencyRoots = @($CodecRoot, $DepsRoot) | Select-Object -Unique

$env:PATH = "$FlutterBin;$env:PATH"
$env:PUB_CACHE = $PubCache
$env:CARGO_TARGET_DIR = $CargoTargetDir
$env:CMAKE_PREFIX_PATH = $DependencyRoots -join ";"
$env:RUSTDESK_WINDOWS_CODEC_ROOT = $CodecRoot

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

function Invoke-BridgeGeneration {
    if ($SkipBridgeGenEffective) {
        Write-Host "Skipping flutter_rust_bridge generation because RUSTDESK_SKIP_BRIDGE_GEN=1 or -SkipBridgeGen was passed."
        return
    }

    $BridgeInput = Join-Path $RepoRoot "src\flutter_ffi.rs"
    $BridgeOutputs = @(
        (Join-Path $FlutterDir "lib\generated_bridge.dart"),
        (Join-Path $FlutterDir "lib\generated_bridge.freezed.dart"),
        (Join-Path $RepoRoot "src\bridge_generated.rs"),
        (Join-Path $RepoRoot "src\bridge_generated.io.rs")
    )
    if (!$ForceBridgeGenEffective -and (Test-BridgeFilesCurrent $BridgeInput $BridgeOutputs)) {
        Write-Host "flutter_rust_bridge files are current."
        return
    }

    $BridgeCodegen = Resolve-BridgeCodegen
    $BridgeCodegenVersion = Assert-BridgeCodegenVersion $BridgeCodegen
    $ResolvedBridgeLlvmPath = Resolve-BridgeLlvmPath $BridgeLlvmPath
    $BridgeArgs = @(
        "--rust-input", $BridgeInput,
        "--dart-output", (Join-Path $FlutterDir "lib\generated_bridge.dart"),
        "--class-name", $BridgeClassName
    )
    if (![string]::IsNullOrWhiteSpace($ResolvedBridgeLlvmPath)) {
        $BridgeArgs += @("--llvm-path", $ResolvedBridgeLlvmPath)
    }
    if (![string]::IsNullOrWhiteSpace($BridgeLlvmCompilerOpts)) {
        $BridgeArgs += "--llvm-compiler-opts=$BridgeLlvmCompilerOpts"
    }

    Write-Host "Generating flutter_rust_bridge files..."
    Write-Host "Using flutter_rust_bridge_codegen: $BridgeCodegen ($BridgeCodegenVersion)"
    $Output = & $BridgeCodegen @BridgeArgs *>&1
    $ExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($VerboseBridgeGenEffective -or $ExitCode -ne 0) {
        $Output | ForEach-Object { Write-Host $_ }
    }
    if ($ExitCode -ne 0) {
        throw "flutter_rust_bridge_codegen failed with exit code $ExitCode."
    }
    foreach ($OutputPath in $BridgeOutputs) {
        if (!(Test-Path $OutputPath)) {
            throw "flutter_rust_bridge generation did not create '$OutputPath'."
        }
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

function Invoke-NativeCommand {
    param(
        [scriptblock]$Command,
        [string]$Description
    )

    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Command
        $ExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw "$Description failed with exit code $ExitCode."
    }
}

function Resolve-BinaryImportTool {
    $Command = Get-Command "llvm-objdump.exe" -ErrorAction SilentlyContinue
    if ($Command) {
        return [PSCustomObject]@{ Kind = "llvm-objdump"; Path = $Command.Source }
    }

    $CandidateRoots = @(
        $env:LLVM_PATH,
        $BridgeLlvmPath,
        (Join-Path $Drive "Program Files\LLVM"),
        "C:\Program Files\LLVM"
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($Root in $CandidateRoots) {
        $Candidate = Join-Path $Root "bin\llvm-objdump.exe"
        if (Test-Path $Candidate) {
            return [PSCustomObject]@{ Kind = "llvm-objdump"; Path = (Resolve-Path $Candidate).Path }
        }
    }

    $Command = Get-Command "dumpbin.exe" -ErrorAction SilentlyContinue
    if ($Command) {
        return [PSCustomObject]@{ Kind = "dumpbin"; Path = $Command.Source }
    }

    $VsRoots = @(
        "C:\Program Files\Microsoft Visual Studio",
        "D:\Program Files\Microsoft Visual Studio"
    ) | Where-Object { Test-Path $_ }
    foreach ($Root in $VsRoots) {
        $Candidate = Get-ChildItem $Root -Recurse -Filter "dumpbin.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\bin\\Hostx64\\x64\\dumpbin\.exe$" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($Candidate) {
            return [PSCustomObject]@{ Kind = "dumpbin"; Path = $Candidate.FullName }
        }
    }

    return $null
}

function Get-ImportedDllNames {
    param(
        [string]$BinaryPath,
        $ImportTool
    )

    $Output = if ($ImportTool.Kind -eq "llvm-objdump") {
        & $ImportTool.Path -p $BinaryPath 2>$null
    } else {
        & $ImportTool.Path /DEPENDENTS $BinaryPath 2>$null
    }
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $Names = [System.Collections.Generic.List[string]]::new()
    foreach ($Line in $Output) {
        if ($Line -match 'DLL Name:\s*([^"]+?\.dll)\s*$') {
            $Names.Add($Matches[1].Trim())
        } elseif ($ImportTool.Kind -eq "dumpbin" -and $Line -match '^\s*([^\s]+\.dll)\s*$') {
            $Names.Add($Matches[1].Trim())
        }
    }
    return $Names | Select-Object -Unique
}

function Copy-WindowsRuntimeDependencies {
    param(
        [string]$BundleDir,
        [string[]]$DependencyRoots
    )

    $ImportTool = Resolve-BinaryImportTool
    if (!$ImportTool) {
        Write-Warning "Could not find llvm-objdump.exe or dumpbin.exe; skipping runtime DLL dependency copy."
        return
    }

    $SearchRoots = @(
        foreach ($Root in $DependencyRoots) {
            (Join-Path $Root "bin")
            (Join-Path $Root "lib")
            $Root
        }
    ) | Where-Object { Test-Path $_ } | Select-Object -Unique

    if ($SearchRoots.Count -eq 0) {
        return
    }

    $Queue = [System.Collections.Generic.Queue[string]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Get-ChildItem $BundleDir -Recurse -File -Include "*.exe", "*.dll" | ForEach-Object {
        $Queue.Enqueue($_.FullName)
    }

    while ($Queue.Count -gt 0) {
        $BinaryPath = $Queue.Dequeue()
        if (!$Seen.Add($BinaryPath)) {
            continue
        }

        foreach ($DllName in Get-ImportedDllNames $BinaryPath $ImportTool) {
            $BundleDll = Join-Path $BundleDir $DllName
            if (Test-Path $BundleDll) {
                continue
            }

            $Source = $null
            foreach ($Root in $SearchRoots) {
                $Candidate = Join-Path $Root $DllName
                if (Test-Path $Candidate) {
                    $Source = (Resolve-Path $Candidate).Path
                    break
                }
            }
            if (!$Source) {
                continue
            }

            Copy-Item -Force $Source $BundleDll
            Write-Host "Copied runtime dependency: $DllName"
            $Queue.Enqueue($BundleDll)
        }
    }
}

function Stop-CodecIntegrationProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds
    )

    if ($null -eq $Process) {
        return
    }
    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            return
        }
        $Process.Kill()
        if (!$Process.WaitForExit($TimeoutMilliseconds)) {
            Write-Warning "Codec integration process did not exit within $($TimeoutMilliseconds / 1000) seconds after termination was requested."
        }
    }
    catch {
        Write-Warning "Could not terminate the codec integration process: $($_.Exception.Message)"
    }
}

function Assert-CodecIntegrationReport {
    [CmdletBinding()]
    param(
        [string]$Json,
        [string]$CodecRoot,
        [bool]$ExpectedHwCodec = $true
    )

    $ExpectedReportKind = if ($null -ne $CodecIntegrationReportKind) {
        $CodecIntegrationReportKind
    } else {
        "rustadmin-codec-integration"
    }
    $ExpectedReportVersion = if ($null -ne $CodecIntegrationReportVersion) {
        $CodecIntegrationReportVersion
    } else {
        2
    }
    $PrefixAdvice = "FFmpeg root '$CodecRoot': check native relink and prefix selection; rebuild FFmpeg only if its inventory or component configuration is missing."
    $CoreAdvice = "Core VP8/VP9/AV1 uses linked libvpx/libaom. Check those baseline libraries and the RustAdmin native relink; this failure is independent of the FFmpeg prefix."
    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "Linked codec integration report was empty. $PrefixAdvice"
    }

    try {
        $Report = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Linked codec integration report was not valid JSON. Check the bundled executable and its native link before changing the FFmpeg prefix. $PrefixAdvice Original error: $($_.Exception.Message)"
    }

    if (!$Json.TrimStart().StartsWith("{") -or $null -eq $Report -or $Report -isnot [pscustomobject]) {
        throw "Linked codec integration report must be one JSON object. Check the bundled executable and its native link. $PrefixAdvice"
    }

    $RequiredProperties = @(
        "report_kind",
        "report_version",
        "hwcodec_enabled",
        "passed",
        "registered_encoders",
        "registered_decoders",
        "core_roundtrips",
        "optional_software_decoders",
        "warnings"
    )
    $ReportProperties = @($Report.PSObject.Properties.Name)
    foreach ($Property in $RequiredProperties) {
        if ($ReportProperties -notcontains $Property) {
            throw "Linked codec integration report is missing required v2 property '$Property'. Check the bundled executable and native link; this is not by itself a reason to rebuild FFmpeg. $PrefixAdvice"
        }
    }

    if ($Report.report_kind -isnot [string] -or [string]::IsNullOrWhiteSpace($Report.report_kind)) {
        throw "Linked codec integration report property 'report_kind' must be a non-empty string. Check the bundled executable and native link. $PrefixAdvice"
    }
    if ($Report.report_kind -ne $ExpectedReportKind) {
        throw "Linked codec integration report marker '$($Report.report_kind)' did not match '$ExpectedReportKind'. Check the bundled executable and native link before changing the FFmpeg prefix. $PrefixAdvice"
    }

    $Version = $Report.PSObject.Properties["report_version"].Value
    if ($null -eq $Version) {
        throw "Linked codec integration report property 'report_version' must be an integer. Check the bundled executable and native link. $PrefixAdvice"
    }
    $IntegerTypes = @("Byte", "Int16", "Int32", "Int64", "SByte", "UInt16", "UInt32", "UInt64")
    if ($IntegerTypes -notcontains $Version.GetType().Name -or $Version -ne $ExpectedReportVersion) {
        throw "Linked codec integration report version '$($Report.report_version)' was not integer schema version $ExpectedReportVersion. Check the bundled executable and native link before changing the FFmpeg prefix. $PrefixAdvice"
    }

    if ($Report.hwcodec_enabled -isnot [bool]) {
        throw "Linked codec integration report property 'hwcodec_enabled' must be boolean. Check the bundled executable and native link. $PrefixAdvice"
    }
    if ($Report.hwcodec_enabled -ne $ExpectedHwCodec) {
        if ($ExpectedHwCodec) {
            throw "Linked codec integration report says hwcodec_enabled=false, but the normal gate expected true. Rebuild RustAdmin without -NoHwCodec; changing the FFmpeg prefix will not enable the RustAdmin hwcodec feature. Selected FFmpeg codec root: $CodecRoot."
        }
        throw "Linked codec integration report says hwcodec_enabled=true, but the -NoHwCodec gate expected false. Check that the bundled executable matches the requested software-only build; changing the FFmpeg prefix will not disable the RustAdmin hwcodec feature. Selected FFmpeg codec root: $CodecRoot."
    }
    if ($Report.passed -isnot [bool]) {
        throw "Linked codec integration report property 'passed' must be boolean. Check the bundled executable and native link. $PrefixAdvice"
    }

    foreach ($Property in @(
        "registered_encoders",
        "registered_decoders",
        "core_roundtrips",
        "optional_software_decoders",
        "warnings"
    )) {
        $Value = $Report.PSObject.Properties[$Property].Value
        if ($Value -isnot [System.Array]) {
            throw "Linked codec integration report property '$Property' must be a JSON array. Check the bundled executable and native link; do not rebuild FFmpeg solely for malformed report data. $PrefixAdvice"
        }
    }

    foreach ($WarningText in @($Report.PSObject.Properties["warnings"].Value)) {
        if ($WarningText -isnot [string] -or [string]::IsNullOrWhiteSpace($WarningText)) {
            throw "Linked codec integration report warning entries must be non-empty strings. Check the bundled executable and native link. $PrefixAdvice"
        }
        Write-Warning $WarningText
    }

    function Assert-CodecInventoryEntry {
        param(
            $Entry,
            [string]$Section
        )

        if ($null -eq $Entry -or $Entry -isnot [pscustomobject]) {
            throw "Linked codec integration report '$Section' entries must be JSON objects. Check the bundled executable and native link. $PrefixAdvice"
        }
        $EntryProperties = @($Entry.PSObject.Properties.Name)
        foreach ($Property in @("name", "format")) {
            if ($EntryProperties -notcontains $Property) {
                throw "Linked codec integration report '$Section' entry is missing '$Property'. Check the bundled executable and native link. $PrefixAdvice"
            }
        }
        if ($Entry.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.name)) {
            throw "Linked codec integration report '$Section' entry name must be a non-empty string. Check the bundled executable and native link. $PrefixAdvice"
        }
        if ($Entry.format -isnot [string] -or @("VP8", "VP9", "AV1", "H264", "H265") -notcontains $Entry.format) {
            throw "Linked codec integration report '$Section' entry format '$($Entry.format)' is invalid. Check the bundled executable and native link. $PrefixAdvice"
        }
    }

    function Assert-CodecCheckEntry {
        param(
            $Entry,
            [string]$Section
        )

        if ($null -eq $Entry -or $Entry -isnot [pscustomobject]) {
            throw "Linked codec integration report '$Section' entries must be JSON objects. Check the bundled executable and native link. $PrefixAdvice"
        }
        $EntryProperties = @($Entry.PSObject.Properties.Name)
        foreach ($Property in @("name", "format", "status", "detail")) {
            if ($EntryProperties -notcontains $Property) {
                throw "Linked codec integration report '$Section' entry is missing '$Property'. Check the bundled executable and native link. $PrefixAdvice"
            }
        }
        if ($Entry.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.name)) {
            throw "Linked codec integration report '$Section' entry name must be a non-empty string. Check the bundled executable and native link. $PrefixAdvice"
        }
        if ($Entry.format -isnot [string] -or @("VP8", "VP9", "AV1", "H264", "H265") -notcontains $Entry.format) {
            throw "Linked codec integration report '$Section' entry format '$($Entry.format)' is invalid. Check the bundled executable and native link. $PrefixAdvice"
        }
        if ($Entry.status -isnot [string] -or @("validated", "not_built", "failed") -notcontains $Entry.status) {
            throw "Linked codec integration report '$Section' entry status '$($Entry.status)' is invalid. Check the bundled executable and native link. $PrefixAdvice"
        }
        if ($null -ne $Entry.PSObject.Properties["detail"].Value -and $Entry.PSObject.Properties["detail"].Value -isnot [string]) {
            throw "Linked codec integration report '$Section' entry detail must be null or a string. Check the bundled executable and native link. $PrefixAdvice"
        }
    }

    foreach ($Entry in @($Report.PSObject.Properties["registered_encoders"].Value)) {
        Assert-CodecInventoryEntry $Entry "registered_encoders"
    }
    foreach ($Entry in @($Report.PSObject.Properties["registered_decoders"].Value)) {
        Assert-CodecInventoryEntry $Entry "registered_decoders"
    }

    $CoreRoundtrips = @($Report.PSObject.Properties["core_roundtrips"].Value)
    if ($CoreRoundtrips.Count -ne 3) {
        throw "Linked codec integration report must contain exactly three core roundtrips for VP8, VP9, and AV1. $CoreAdvice"
    }
    $ExpectedCoreFormats = @("VP8", "VP9", "AV1")
    $SeenCoreFormats = @{}
    foreach ($Check in $CoreRoundtrips) {
        Assert-CodecCheckEntry $Check "core_roundtrips"
        if ($ExpectedCoreFormats -notcontains $Check.format) {
            throw "Linked codec integration report core roundtrip format '$($Check.format)' is not one of VP8, VP9, or AV1. Check the bundled executable and native link. $PrefixAdvice"
        }
        if ($SeenCoreFormats.ContainsKey($Check.format)) {
            throw "Linked codec integration report contains duplicate core roundtrip format '$($Check.format)'. Check the bundled executable and native link. $PrefixAdvice"
        }
        $SeenCoreFormats[$Check.format] = $true
        if ($Check.status -ne "validated") {
            throw "Core codec roundtrip '$($Check.name)' ($($Check.format)) was not validated; status was '$($Check.status)'. $CoreAdvice"
        }
    }
    foreach ($Format in $ExpectedCoreFormats) {
        if (!$SeenCoreFormats.ContainsKey($Format)) {
            throw "Linked codec integration report is missing core roundtrip format '$Format'. $CoreAdvice"
        }
    }

    $OptionalSoftwareDecoders = @($Report.PSObject.Properties["optional_software_decoders"].Value)
    if (!$ExpectedHwCodec) {
        if ($OptionalSoftwareDecoders.Count -ne 0) {
            throw "Linked codec integration report must contain an empty optional_software_decoders array when hwcodec_enabled=false. Check that the bundled executable matches the requested software-only build. $PrefixAdvice"
        }
    } elseif ($OptionalSoftwareDecoders.Count -ne 2) {
        throw "Linked codec integration report must contain exactly the optional h264/H264 and hevc/H265 software decoder checks. Check the bundled executable and native link; do not assume missing optional codecs require an FFmpeg rebuild. $PrefixAdvice"
    }
    $ExpectedOptional = @(
        [PSCustomObject]@{ name = "h264"; format = "H264" },
        [PSCustomObject]@{ name = "hevc"; format = "H265" }
    )
    $SeenOptional = @{}
    foreach ($Check in $OptionalSoftwareDecoders) {
        Assert-CodecCheckEntry $Check "optional_software_decoders"
        $Expected = @($ExpectedOptional | Where-Object { $_.name -eq $Check.name })
        if ($Expected.Count -ne 1 -or $Expected[0].format -ne $Check.format) {
            throw "Linked codec integration report optional software decoder '$($Check.name)' used format '$($Check.format)'; expected h264/H264 and hevc/H265. Check the bundled executable and native link. $PrefixAdvice"
        }
        if ($SeenOptional.ContainsKey($Check.name)) {
            throw "Linked codec integration report contains duplicate optional software decoder '$($Check.name)'. Check the bundled executable and native link. $PrefixAdvice"
        }
        $SeenOptional[$Check.name] = $true
        if ($Check.status -eq "failed") {
            throw "Optional software decoder '$($Check.name)' ($($Check.format)) is present but failed its real-frame probe. Inspect stderr and the selected prefix/native relink; rebuild FFmpeg only if its decoder configuration is wrong. $PrefixAdvice"
        }
        if ($Check.status -ne "validated" -and $Check.status -ne "not_built") {
            throw "Optional software decoder '$($Check.name)' ($($Check.format)) has invalid status '$($Check.status)'. Check the bundled executable and native link. $PrefixAdvice"
        }
    }
    if ($ExpectedHwCodec) {
        foreach ($Expected in $ExpectedOptional) {
            if (!$SeenOptional.ContainsKey($Expected.name)) {
                throw "Linked codec integration report is missing optional software decoder '$($Expected.name)' ($($Expected.format)). Check the bundled executable and native link; this is not by itself a reason to rebuild FFmpeg. $PrefixAdvice"
            }
        }
    }

    if ($Report.passed -ne $true) {
        throw "Linked codec integration report says passed=false after v2 core and optional checks. Check the selected FFmpeg prefix, retained stdout/stderr logs, and RustAdmin native relink; rebuild FFmpeg only if its component configuration is missing. $PrefixAdvice"
    }

    return $Report
}

function Write-CodecPolicyFile {
    param(
        [string]$BundleDir,
        [string]$CodecRoot,
        $Report
    )

    $PolicyPath = Join-Path $BundleDir "CODEC-POLICY.txt"
    $Warnings = @($Report.PSObject.Properties["warnings"].Value)
    if ($Warnings.Count -eq 0) {
        if (Test-Path $PolicyPath) {
            Remove-Item -Force $PolicyPath
        }
        return
    }
    $Lines = @(
        "RustAdmin codec integration policy",
        "report_kind: $($Report.report_kind)",
        "report_version: $($Report.report_version)",
        "hwcodec_enabled: $($Report.hwcodec_enabled)",
        "selected_ffmpeg_codec_root: $CodecRoot",
        "",
        "Core roundtrips: VP8, VP9, and AV1 must be validated.",
        "Optional software H.264/H.265 decoders may be validated or not_built when hwcodec is enabled; software-only reports leave this list empty.",
        "Registered encoder/decoder lists are inventories and make no GPU claim.",
        "",
        "Warnings:"
    )
    foreach ($WarningText in $Warnings) {
        $Lines += "- $WarningText"
    }
    Set-Content -Path $PolicyPath -Value $Lines -Encoding UTF8
    Write-Host "Codec policy report: $PolicyPath"
}

function Invoke-CodecIntegrationGate {
    param(
        [string]$BundleDir,
        [string]$CodecRoot,
        [bool]$ExpectedHwCodec = $true
    )

    $AppExe = Join-Path $BundleDir "rustadmin.exe"
    Write-Host "Selected FFmpeg codec root: $CodecRoot"
    Write-Host "Expected hwcodec_enabled: $ExpectedHwCodec"
    if (!(Test-Path $AppExe)) {
        throw "Codec integration gate could not find the bundled executable '$AppExe'. Check the Windows bundle and RustAdmin build output; this is not an FFmpeg-prefix validation failure."
    }

    $LogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rustadmin-codec-integration-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $StdoutPath = Join-Path $LogDir "stdout.log"
    $StderrPath = Join-Path $LogDir "stderr.log"
    $Process = $null
    $Passed = $false
    $TimeoutMilliseconds = 30 * 1000
    $CleanupTimeoutMilliseconds = 5 * 1000

    Write-Host "Running linked codec integration verification: $AppExe --verify-codec-integration"
    try {
        $StartInfo = @{
            FilePath = $AppExe
            ArgumentList = @("--verify-codec-integration")
            WorkingDirectory = $BundleDir
            WindowStyle = "Hidden"
            RedirectStandardOutput = $StdoutPath
            RedirectStandardError = $StderrPath
            PassThru = $true
        }
        $Process = Start-Process @StartInfo
        if (!$Process.WaitForExit($TimeoutMilliseconds)) {
            Stop-CodecIntegrationProcess $Process $CleanupTimeoutMilliseconds
            throw "Linked codec integration verification timed out after $($TimeoutMilliseconds / 1000) seconds. Check the kept stdout/stderr logs, executable, and prefix selection; rebuild FFmpeg only if its inventory/configuration is missing, otherwise relink RustAdmin or repair the bundle. Selected FFmpeg codec root: $CodecRoot."
        }

        $Process.Refresh()
        $ExitCode = $Process.ExitCode
        $Stdout = if (Test-Path $StdoutPath) { Get-Content -Raw $StdoutPath } else { "" }
        $Stderr = if (Test-Path $StderrPath) { Get-Content -Raw $StderrPath } else { "" }
        if (![string]::IsNullOrWhiteSpace($Stdout)) {
            Write-Host $Stdout.TrimEnd()
        }
        if (![string]::IsNullOrWhiteSpace($Stderr)) {
            Write-Host $Stderr.TrimEnd()
        }
        try {
            $Report = Assert-CodecIntegrationReport -Json $Stdout -CodecRoot $CodecRoot -ExpectedHwCodec $ExpectedHwCodec
        }
        catch {
            throw "Linked codec integration report validation failed. $($_.Exception.Message)"
        }
        Write-CodecPolicyFile $BundleDir $CodecRoot $Report
        if ($ExitCode -ne 0) {
            throw @"
Linked codec integration verification failed with exit code $ExitCode.
The bundled executable returned failure after the v2 codec report was parsed.
Selected FFmpeg codec root: $CodecRoot
Inspect the kept stdout.log and stderr.log, verify the selected prefix and RustAdmin native relink, and rebuild FFmpeg only if its component inventory/configuration is missing.
"@
        }

        Write-Host "Linked codec integration verification passed."
        $Passed = $true
    }
    catch {
        $Message = $_.Exception.Message
        $NormalizedMessage = $Message.TrimStart()
        if ($NormalizedMessage.StartsWith("Linked codec integration report validation failed") -or
            $NormalizedMessage.StartsWith("Linked codec integration verification failed") -or
            $NormalizedMessage.StartsWith("Linked codec integration verification timed out")) {
            throw
        }
        throw "Could not start or complete linked codec integration verification. Selected FFmpeg codec root: $CodecRoot. Check the bundled executable, selected prefix, and RustAdmin native relink; rebuild FFmpeg only if the prefix inventory/configuration is missing. Original error: $Message"
    }
    finally {
        if ($null -ne $Process) {
            Stop-CodecIntegrationProcess $Process $CleanupTimeoutMilliseconds
        }
        if ($Passed) {
            Remove-Item -Recurse -Force $LogDir -ErrorAction SilentlyContinue
        } else {
            Write-Host "Codec integration logs were kept at: $LogDir"
        }
    }
}

$VersionInfo = Get-RustAdminVersionInfo
Write-VersionFile $VersionInfo

Push-Location $FlutterDir
try {
    if ($Clean -or (Test-StaleFlutterMetadata)) {
        Write-Host "Refreshing Windows Flutter metadata and generated assets..."
        Remove-Item -Recurse -Force `
            ".dart_tool", `
            ".flutter-plugins-dependencies", `
            "build\windows", `
            "build\flutter_assets", `
            "build\native_assets\windows" `
            -ErrorAction SilentlyContinue
    }
    Invoke-NativeCommand { & $FlutterBat pub get } "flutter pub get"
}
finally {
    Pop-Location
}

Invoke-BridgeGeneration

$Features = if ($NoHwCodec) { "flutter" } else { "flutter,hwcodec" }
$RustHostLine = rustc -vV | Select-String '^host:' | Select-Object -First 1
if ($null -eq $RustHostLine) {
    throw "Unable to determine the Rust host target."
}
$RustHost = $RustHostLine.Line -replace '^host:\s*', ''
Invoke-NativeCommand {
    python (Join-Path $RepoRoot "scripts\platform_profiles.py") check `
        --profile windows-x86_64-release `
        --wrapper scripts/build_windows.ps1 `
        --target $RustHost `
        --features $Features
} "platform profile validation"

Push-Location $RepoRoot
try {
    Invoke-NativeCommand { cargo build --features $Features --lib --release } "cargo build"
}
finally {
    Pop-Location
}

Push-Location $FlutterDir
try {
    Invoke-NativeCommand { & $FlutterBat build windows } "flutter build windows"
}
finally {
    Pop-Location
}

$BundleDir = Join-Path $FlutterDir "build\windows\x64\runner\Release"
$UnexpectedKernelBlob = Join-Path $BundleDir "data\flutter_assets\kernel_blob.bin"
if (Test-Path $UnexpectedKernelBlob) {
    throw "Release bundle contains debug-only Flutter asset '$UnexpectedKernelBlob'. Rebuild with -Clean."
}

$StaleRuntimeIcon = Join-Path $FlutterDir "build\windows\x64\runner\Release\data\flutter_assets\assets\icon.ico"
Remove-Item -Force $StaleRuntimeIcon -ErrorAction SilentlyContinue

Write-Host "Windows bundle:"
Write-Host $BundleDir
Copy-WindowsRuntimeDependencies $BundleDir $DependencyRoots
Invoke-CodecIntegrationGate $BundleDir $CodecRoot (-not $NoHwCodec)
New-ReleaseZip $VersionInfo
