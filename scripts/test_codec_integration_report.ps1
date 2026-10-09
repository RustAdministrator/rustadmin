$ErrorActionPreference = "Stop"

$BuildScriptPath = Join-Path $PSScriptRoot "build_windows.ps1"
$Tokens = $null
$ParseErrors = $null
$BuildScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $BuildScriptPath,
    [ref]$Tokens,
    [ref]$ParseErrors
)
if ($ParseErrors.Count -ne 0) {
    throw "build_windows.ps1 could not be parsed: $($ParseErrors -join '; ')"
}

function Import-BuildFunction {
    param([string]$Name)

    $FunctionAsts = @(
        $BuildScriptAst.FindAll(
            {
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        ) | Where-Object { $_.Name -eq $Name }
    )
    if ($FunctionAsts.Count -ne 1) {
        throw "Expected exactly one $Name function in build_windows.ps1, found $($FunctionAsts.Count)."
    }
    return $FunctionAsts[0].Extent.Text
}

# Extract only the pure report validator and policy writer. The build script's
# top-level dependency discovery, Cargo, Flutter, CMake, and process launcher
# code is never executed by this contract test.
Invoke-Expression (Import-BuildFunction "Assert-CodecIntegrationReport")
Invoke-Expression (Import-BuildFunction "Write-CodecPolicyFile")

function New-CodecCheck {
    param(
        [string]$Name,
        [string]$Format,
        [string]$Status = "validated"
    )

    return [pscustomobject][ordered]@{
        name = $Name
        format = $Format
        status = $Status
        detail = $null
    }
}

function New-CodecReport {
    param([bool]$HwCodec = $true)

    $Optional = @()
    if ($HwCodec) {
        $Optional = @(
            (New-CodecCheck "h264" "H264" "not_built"),
            (New-CodecCheck "hevc" "H265" "not_built")
        )
    }
    return [pscustomobject][ordered]@{
        report_kind = "rustadmin-codec-integration"
        report_version = 2
        hwcodec_enabled = $HwCodec
        passed = $true
        registered_encoders = @()
        registered_decoders = @()
        core_roundtrips = @(
            (New-CodecCheck "libvpx-vp8" "VP8"),
            (New-CodecCheck "libvpx-vp9" "VP9"),
            (New-CodecCheck "libaom-av1" "AV1")
        )
        optional_software_decoders = $Optional
        warnings = @()
    }
}

function Invoke-ReportValidator {
    param(
        $Report,
        [bool]$ExpectedHwCodec = $true
    )

    $CapturedWarnings = @()
    $Validated = Assert-CodecIntegrationReport `
        -Json ($Report | ConvertTo-Json -Depth 10) `
        -CodecRoot "C:\\rustadmin\\FFmpeg" `
        -ExpectedHwCodec $ExpectedHwCodec `
        -WarningAction SilentlyContinue `
        -WarningVariable CapturedWarnings
    return [pscustomobject]@{
        Report = $Validated
        Warnings = @($CapturedWarnings)
    }
}

function Assert-ReportFails {
    param(
        $Report,
        [string]$ExpectedMessage,
        [bool]$ExpectedHwCodec = $true
    )

    $CaughtMessage = $null
    try {
        $null = Invoke-ReportValidator $Report $ExpectedHwCodec
    }
    catch {
        $CaughtMessage = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($CaughtMessage)) {
        throw "Expected report validation to fail."
    }
    if ($CaughtMessage -notmatch $ExpectedMessage) {
        throw "Expected report failure to contain '$ExpectedMessage', got '$CaughtMessage'."
    }
}

$HardwareOnly = New-CodecReport
$HardwareResult = Invoke-ReportValidator $HardwareOnly
if ($HardwareResult.Report.passed -ne $true -or $HardwareResult.Warnings.Count -ne 0) {
    throw "Hardware-only v2 report did not validate with empty codec inventories and not_built optional decoders."
}

$SoftwareOnly = New-CodecReport $false
$SoftwareResult = Invoke-ReportValidator $SoftwareOnly $false
if ($SoftwareResult.Report.passed -ne $true -or $SoftwareOnly.optional_software_decoders.Count -ne 0) {
    throw "Software-only v2 report did not validate with hwcodec_enabled=false and empty optional decoders."
}

$SoftwareWarning = New-CodecReport
$SoftwareWarning.registered_encoders = @(
    [pscustomobject][ordered]@{ name = "libx264"; format = "H264" }
)
$SoftwareWarning.optional_software_decoders[0].status = "validated"
$SoftwareWarning.warnings = @(
    "This build includes optional software H.264/H.265 implementations. Under RustAdmin's distribution policy it is intended for private/custom use and is not approved for public distribution."
)
$WarningResult = Invoke-ReportValidator $SoftwareWarning
if ($WarningResult.Warnings.Count -ne 1 -or "$($WarningResult.Warnings[0])" -notmatch "private/custom") {
    throw "A valid software-codec report did not emit its warning through the warning stream."
}

$CoreFailure = New-CodecReport
$CoreFailure.core_roundtrips[1].status = "failed"
$CoreFailure.core_roundtrips[1].detail = "VP9 roundtrip failed"
$CoreFailure.passed = $false
Assert-ReportFails $CoreFailure "libvpx/libaom"

$OptionalFailure = New-CodecReport
$OptionalFailure.optional_software_decoders[1].status = "failed"
$OptionalFailure.optional_software_decoders[1].detail = "HEVC probe failed"
$OptionalFailure.passed = $false
Assert-ReportFails $OptionalFailure "present but failed"

$StaleV1 = New-CodecReport
$StaleV1.report_version = 1
Assert-ReportFails $StaleV1 "schema version 2"

$Malformed = New-CodecReport
$Malformed.hwcodec_enabled = "true"
Assert-ReportFails $Malformed "hwcodec_enabled.*boolean"

$MalformedArray = New-CodecReport
$MalformedArray.warnings = $null
Assert-ReportFails $MalformedArray "warnings.*JSON array"

# ConvertFrom-Json enumerates singleton root arrays in Windows PowerShell;
# the validator must still require a JSON object at the root.
$RejectedRootArray = $false
try {
    $null = Assert-CodecIntegrationReport -Json ('[' + ((New-CodecReport) | ConvertTo-Json -Depth 10) + ']') -CodecRoot "C:\FFmpeg"
} catch {
    $RejectedRootArray = $_.Exception.Message -match "one JSON object"
}
if (!$RejectedRootArray) {
    throw "Singleton root array was accepted as a codec report object."
}

$PolicyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rustadmin-codec-policy-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $PolicyRoot | Out-Null
try {
    $PolicyWarningReport = New-CodecReport
    $PolicyWarningReport.warnings = @("private/custom policy warning")
    Write-CodecPolicyFile $PolicyRoot "C:\\rustadmin\\FFmpeg" $PolicyWarningReport
    $PolicyPath = Join-Path $PolicyRoot "CODEC-POLICY.txt"
    if (!(Test-Path $PolicyPath) -or (Get-Content -Raw $PolicyPath) -notmatch "private/custom policy warning") {
        throw "Warning-bearing report did not preserve its warning in CODEC-POLICY.txt."
    }

    $PolicyCleanReport = New-CodecReport $false
    Write-CodecPolicyFile $PolicyRoot "C:\\rustadmin\\FFmpeg" $PolicyCleanReport
    if (Test-Path $PolicyPath) {
        throw "A zero-warning report did not remove stale CODEC-POLICY.txt."
    }
}
finally {
    Remove-Item -Recurse -Force $PolicyRoot -ErrorAction SilentlyContinue
}

Write-Host "codec integration report contract tests passed (10/10)"
