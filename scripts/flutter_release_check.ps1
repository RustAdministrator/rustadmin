# Checks the Flutter SDK of a build against the newest release of a Flutter channel, as Flutter
# publishes it for its installers. Dot-sourced by build_windows.ps1.
#
# The newest release is looked up at every build, not pinned: builders that drift apart
# (Flutter 3.44.7 here, 3.50.1 there) resolve pubspec.lock differently and build different
# apps from the same commit.

$FlutterReleaseListUrl = "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"

function Get-LatestFlutterRelease {
    param([string]$Channel)

    $List = Invoke-RestMethod -Uri $FlutterReleaseListUrl -TimeoutSec 20 -UseBasicParsing
    $Hash = $List.current_release.$Channel
    if ([string]::IsNullOrWhiteSpace($Hash)) {
        throw "the release list names no current $Channel release"
    }
    $Release = $List.releases |
        Where-Object { $_.hash -eq $Hash -and $_.channel -eq $Channel } |
        Select-Object -First 1
    if ($null -eq $Release) {
        throw "the release list has no $Channel release with hash $Hash"
    }
    return $Release
}

function Get-InstalledFlutterVersion {
    param([string]$FlutterRoot, [string]$FlutterBat)

    # `flutter --version` writes this file; reading it does not start the tool.
    $VersionFile = Join-Path $FlutterRoot "bin\cache\flutter.version.json"
    if (Test-Path $VersionFile) {
        $Version = (Get-Content -Raw $VersionFile | ConvertFrom-Json).frameworkVersion
        if (![string]::IsNullOrWhiteSpace($Version)) {
            return $Version
        }
    }
    $Output = (& $FlutterBat --version --machine 2>$null | Out-String)
    $Start = $Output.IndexOf("{")
    $End = $Output.LastIndexOf("}")
    if ($Start -lt 0 -or $End -le $Start) {
        throw "'$FlutterBat --version --machine' printed no version"
    }
    return ($Output.Substring($Start, $End - $Start + 1) | ConvertFrom-Json).frameworkVersion
}

function Update-FlutterSdk {
    param([string]$FlutterRoot, [string]$FlutterBat, $Release)

    if (!(Test-Path (Join-Path $FlutterRoot ".git"))) {
        throw "'$FlutterRoot' is not a git checkout of Flutter; install Flutter $($Release.version) there by hand."
    }
    $Version = $Release.version
    $Changes = git -C $FlutterRoot status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed in '$FlutterRoot'."
    }
    if (![string]::IsNullOrWhiteSpace(($Changes | Out-String))) {
        throw "'$FlutterRoot' has local changes; not switching it to $Version."
    }
    git -C $FlutterRoot fetch origin "refs/tags/${Version}:refs/tags/${Version}"
    if ($LASTEXITCODE -ne 0) {
        throw "Fetching Flutter $Version into '$FlutterRoot' failed."
    }
    # The tag must be the commit that the release list names.
    $Commit = (git -C $FlutterRoot rev-parse "${Version}^{commit}" | Out-String).Trim()
    if ($Commit -ne $Release.hash) {
        throw "Flutter tag $Version is $Commit, but the release list names $($Release.hash)."
    }
    git -C $FlutterRoot -c advice.detachedHead=false checkout --detach $Version
    if ($LASTEXITCODE -ne 0) {
        throw "Checking out Flutter $Version in '$FlutterRoot' failed."
    }
    # Downloads the Dart SDK and the engine of the new version.
    & $FlutterBat --version
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter $Version did not start after the update."
    }
}

function Assert-FlutterRelease {
    param(
        [string]$FlutterRoot,
        [string]$FlutterBat,
        [string]$Channel,
        [switch]$Update,
        [switch]$AllowOutdated
    )

    try {
        $Latest = Get-LatestFlutterRelease $Channel
    }
    catch {
        Write-Warning "Could not look up the latest Flutter $Channel release ($($_.Exception.Message)); building with the installed Flutter."
        return
    }
    $Installed = Get-InstalledFlutterVersion $FlutterRoot $FlutterBat
    if ($Installed -eq $Latest.version) {
        Write-Host "Flutter $Installed is the latest $Channel release."
        return
    }
    $Message = "Flutter $Installed is installed at '$FlutterRoot'; the latest $Channel release is $($Latest.version) (released $($Latest.release_date.Substring(0, 10)))."
    if ($Update) {
        Write-Host "$Message Updating the SDK..."
        Update-FlutterSdk $FlutterRoot $FlutterBat $Latest
        $After = Get-InstalledFlutterVersion $FlutterRoot $FlutterBat
        if ($After -ne $Latest.version) {
            throw "After the update Flutter reports $After, not $($Latest.version)."
        }
        Write-Host "Flutter is now $After."
        return
    }
    if ($AllowOutdated) {
        Write-Warning "$Message Building with $Installed (-AllowOutdatedFlutter)."
        return
    }
    throw "$Message Run with -UpdateFlutter to switch the SDK to $($Latest.version), or with -AllowOutdatedFlutter to build with $Installed."
}
