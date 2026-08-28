<#
.SYNOPSIS
    Verifies that the Ollama + opencode update was applied correctly.

.DESCRIPTION
    Checks, in order:
      1. Ollama binary present and version parses
      2. Target model is installed (ollama list)
      3. opencode binary present and version parses
      4. opencode config exists and is valid JSON
      5. Config model + small_model point to "ollama/<model>"
      6. Config model matches an actually-installed Ollama model
      7. Running model (ollama ps) matches the configured model, if any

    Exits 0 if all checks pass, 1 otherwise.

.PARAMETER Model
    Model name to expect (e.g. qwen2.5-coder:7b). If omitted, the model is
    read from the opencode config.

.PARAMETER ConfigPath
    Path to opencode.json to verify. Defaults to discovering the active config
    (local first, then global), same as update.ps1.
#>

param(
    [string]$Model,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

$global:failures = 0

function Test-Report {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    if ($Pass) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:failures++
        Write-Host "  [FAIL] $Name - $Detail" -ForegroundColor Red
    }
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Verifying update ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Ollama present + version parses
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Ollama --" -ForegroundColor White

$ollamaExe = Get-Command ollama -ErrorAction SilentlyContinue
Test-Report "ollama is installed" ([bool]$ollamaExe) "not found in PATH"

$ollamaVersion = $null
if ($ollamaExe) {
    $v = (ollama --version 2>&1)
    $ollamaVersion = ($v -join " ") -replace ".*version\s+is\s+", "" -replace "\s.*", ""
    Test-Report "ollama version parses" ([bool]$ollamaVersion -and $ollamaVersion -match "^\d+\.\d+\.\d+") "got: '$ollamaVersion'"
    Write-Host "  version: $ollamaVersion"
}

# ---------------------------------------------------------------------------
# Resolve expected model
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Config --" -ForegroundColor White

$globalConfigDir = Join-Path (Join-Path $env:USERPROFILE ".config") "opencode"
$globalConfigPath = Join-Path $globalConfigDir "opencode.json"
$localConfigPath = Join-Path (Get-Location) "opencode.json"
$localDotDir = Join-Path (Get-Location) ".opencode"
$localDotConfig = Join-Path $localDotDir "opencode.json"

if (-not $ConfigPath) {
    if (Test-Path $localConfigPath) { $ConfigPath = $localConfigPath }
    elseif (Test-Path $localDotConfig) { $ConfigPath = $localDotConfig }
    elseif (Test-Path $globalConfigPath) { $ConfigPath = $globalConfigPath }
}

$configExists = $false
if ($ConfigPath) {
    $configExists = Test-Path $ConfigPath -PathType Leaf
}
Test-Report "opencode config exists" $configExists "expected: $ConfigPath"

$config = $null
if ($configExists) {
    Write-Host "  config: $ConfigPath"
    try {
        $raw = Get-Content $ConfigPath -Raw
        $stripped = $raw -replace '(?<!:)\/\/[^\r\n]*', '' -replace '/\*[\s\S]*?\*/', ''
        $config = $stripped | ConvertFrom-Json
        Test-Report "config is valid JSON" $true $null
    }
    catch {
        Test-Report "config is valid JSON" $false $_.Exception.Message
    }
}

# Determine the model expected in config
$configModel = $null
$configSmallModel = $null
if ($config) {
    $configModel = $config.model
    $configSmallModel = $config.small_model
    Test-Report "config has 'model'" ([bool]$configModel) "missing 'model' key"
    Test-Report "config has 'small_model'" ([bool]$configSmallModel) "missing 'small_model' key"
}

if (-not $Model) {
    # Prefer the config model; if none, run flag/local override or error
    $Model = $configModel
}

if ($Model) {
    $Model = $Model -replace "^ollama/", ""
}

# ---------------------------------------------------------------------------
# 2. Model installed in Ollama
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Model --" -ForegroundColor White

if ($Model) {
    Write-Host "  expected model: $Model"

    $listOutput = ollama list 2>&1
    $listLines = ($listOutput -split "`n") | Where-Object { $_ -match "\S" }
    $installed = $false
    foreach ($ln in $listLines) {
        $name = ($ln -split "\s+")[0]
        if ($name -eq $Model) {
            $installed = $true
            break
        }
    }
    Test-Report "model '$Model' is installed" $installed "not found in 'ollama list'"

    # Verify config model refs point to an installed model
    if ($configModel) {
        $cfgModelName = $configModel -replace "^ollama/", ""
        $cfgInstalled = $false
        foreach ($ln in $listLines) {
            if (($ln -split "\s+")[0] -eq $cfgModelName) { $cfgInstalled = $true; break }
        }
        Test-Report "config 'model' ('$configModel') maps to installed model" $cfgInstalled "not installed"
    }
}
else {
    # No model to verify against - check what the config points to
    Write-Warn "No model specified and none found in config; skipping model-install checks."
    if ($configModel) {
        Write-Host "  config references model: $configModel"
    }
}

# ---------------------------------------------------------------------------
# 3. Config model + small_model point to ollama/
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Config model refs --" -ForegroundColor White

if ($config) {
    $modelOk = $configModel -match "^ollama/"
    Test-Report "config 'model' uses ollama provider" $modelOk "got: '$configModel'"

    $smallOk = $configSmallModel -match "^ollama/"
    Test-Report "config 'small_model' uses ollama provider" $smallOk "got: '$configSmallModel'"

    # Config model identity should match the resolved expected model
    if ($Model) {
        $cfgModelName = $configModel -replace "^ollama/", ""
        if ($cfgModelName -and $cfgModelName -ne $Model) {
            Test-Report "config model matches expected model" $false "config='$cfgModelName' expected='$Model'"
        }
        else {
            Test-Report "config model matches expected model" $true $null
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Running model matches config (if one is loaded)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- Running model --" -ForegroundColor White

$psOutput = ollama ps 2>&1
$psLines = ($psOutput -split "`n") | Where-Object { $_ -match "\S" }
if ($psLines.Count -ge 2) {
    $runningModel = ($psLines[1] -split "\s+")[0]
    Write-Host "  running model: $runningModel"

    if ($configModel) {
        $cfgModelName = $configModel -replace "^ollama/", ""
        Test-Report "running model matches config" ($runningModel -eq $cfgModelName) "running='$runningModel' config='$cfgModelName'"
    }
}
else {
    Write-Host "  no model currently running" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 5. opencode present + version parses
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "-- opencode --" -ForegroundColor White

$ocExe = Get-Command opencode -ErrorAction SilentlyContinue
Test-Report "opencode is installed" ([bool]$ocExe) "not found in PATH"

$ocVersion = $null
if ($ocExe) {
    $occ = (opencode --version 2>&1 | Out-String).Trim()
    $ocVersion = ($occ -replace "\s", "")
    Test-Report "opencode version parses" ([bool]$ocVersion -and $ocVersion -match "^\d+") "got: '$occ'"
    Write-Host "  version: $ocVersion"
}

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
Write-Host ""
if ($global:failures -gt 0) {
    Write-Host "=== Verification FAILED: $global:failures check(s) failed ===" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "=== Verification passed ===" -ForegroundColor Green
    exit 0
}
