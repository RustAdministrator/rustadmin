param(
    [string]$FlutterRoot = "",
    [string]$DepsRoot = "",
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
        [string]$DepsRoot
    )

    $ImportTool = Resolve-BinaryImportTool
    if (!$ImportTool) {
        Write-Warning "Could not find llvm-objdump.exe or dumpbin.exe; skipping runtime DLL dependency copy."
        return
    }

    $SearchRoots = @(
        (Join-Path $DepsRoot "bin"),
        (Join-Path $DepsRoot "lib"),
        $DepsRoot
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

$VersionInfo = Get-RustAdminVersionInfo
Write-VersionFile $VersionInfo

Push-Location $FlutterDir
try {
    if ($Clean -or (Test-StaleFlutterMetadata)) {
        Write-Host "Refreshing Windows Flutter metadata..."
        Remove-Item -Recurse -Force ".dart_tool", ".flutter-plugins-dependencies", "build\windows" -ErrorAction SilentlyContinue
    }
    & $FlutterBat pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Invoke-BridgeGeneration

$Features = if ($NoHwCodec) { "flutter" } else { "flutter,hwcodec" }

Push-Location $RepoRoot
try {
    cargo build --features $Features --lib --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Push-Location $FlutterDir
try {
    & $FlutterBat build windows
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$StaleRuntimeIcon = Join-Path $FlutterDir "build\windows\x64\runner\Release\data\flutter_assets\assets\icon.ico"
Remove-Item -Force $StaleRuntimeIcon -ErrorAction SilentlyContinue

Write-Host "Windows bundle:"
$BundleDir = Join-Path $FlutterDir "build\windows\x64\runner\Release"
Write-Host $BundleDir
Copy-WindowsRuntimeDependencies $BundleDir $DepsRoot
New-ReleaseZip $VersionInfo
