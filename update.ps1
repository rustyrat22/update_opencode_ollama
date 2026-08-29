<#
.SYNOPSIS
    Updates Ollama, pulls the latest version of the running model, updates opencode,
    and syncs the opencode.json config to point at the Ollama model.

.DESCRIPTION
    Steps performed:
      1. Update Ollama binary (via winget or fallback installer)
      2. Detect the currently running model (ollama ps)
      3. Pull the latest version of that model (ollama pull)
      3b. Pull the latest version of ALL downloaded models (ollama pull for each)
      3c. Reload the in-use model (ollama stop) so updated weights are picked up
      4. Update opencode (opencode upgrade)
      5. Create or merge ~/.config/opencode/opencode.json with the Ollama model
      6. Verify the update ran (verify-update.ps1)

.PARAMETER Model
    Override the model name instead of auto-detecting from ollama ps.

.PARAMETER SkipOllama
    Skip the Ollama binary update step.

.PARAMETER SkipOpenCode
    Skip the opencode upgrade step.

.PARAMETER SkipVerify
    Skip the post-update verification step.

.PARAMETER DryRun
    Show what would happen without making changes.
#>

param(
    [string]$Model,
    [switch]$SkipOllama,
    [switch]$SkipOpenCode,
    [switch]$SkipVerify,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host ""
    Write-Host "=== Step ${Step}: $Message ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

# Updates every downloaded model by pulling the latest version of each.
# Returns a summary hashtable of updated / already-current / skipped.
function Update-AllModels {
    param([switch]$WhatIf)

    $listOutput = ollama list 2>&1
    $listLines = ($listOutput -split "`n") | Where-Object { $_ -match "\S" }

    if ($listLines.Count -lt 2) {
        Write-Warn "No models downloaded - nothing to update."
        return @{ Updated = @(); Current = @(); Skipped = @() }
    }

    $models = @()
    for ($i = 1; $i -lt $listLines.Count; $i++) {
        $name = ($listLines[$i] -split "\s+")[0]
        if ($name) { $models += $name }
    }

    Write-Host "  Found $($models.Count) downloaded model(s): $($models -join ', ')"

    $summary = @{ Updated = @(); Current = @(); Skipped = @() }

    foreach ($m in $models) {
        if ($WhatIf) {
            Write-Host "  [DRY] would run: ollama pull $m"
            continue
        }

        $beforeId = (ollama list 2>&1 | Select-String "^$m\s") -replace "^$m\s+", "" -replace "\s.*", ""
        Write-Host "  Pulling $m ..."
        ollama pull $m | Out-Null
        $afterId = (ollama list 2>&1 | Select-String "^$m\s") -replace "^$m\s+", "" -replace "\s.*", ""

        if ($beforeId -ne $afterId) {
            Write-Ok "  $m updated: $beforeId -> $afterId"
            $summary.Updated += $m
        }
        else {
            Write-Ok "  $m already at latest version"
            $summary.Current += $m
        }
    }

    return $summary
}

# ===========================================================================
# Step 1: Update Ollama
# ===========================================================================
if (-not $SkipOllama) {
    Write-Step "1" "Updating Ollama"

    $ollamaInstalled = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollamaInstalled) {
        Write-Fail "ollama not found in PATH. Install from https://ollama.com/download"
        exit 1
    }

    $currentVersion = (ollama --version 2>&1) -replace ".*version\s+is\s+", "" -replace "\s.*", ""
    Write-Host "  Current version: $currentVersion"

    if ($DryRun) {
        Write-Warn "Dry run - would update Ollama"
    }
    else {
        $wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetAvailable) {
            Write-Host "  Updating via winget..."
            winget upgrade Ollama.Ollama --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object {
                if ($_ -match "No applicable upgrade") {
                    Write-Ok "Ollama is already up to date"
                }
            }
        }
        else {
            Write-Warn "winget not available - downloading installer directly..."
            $installerUrl = "https://ollama.com/download/OllamaSetup.exe"
            $installerPath = "$env:TEMP\OllamaSetup.exe"
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
            Write-Host "  Running installer (silent)..."
            Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT","/NORESTART" -Wait
            Remove-Item $installerPath -ErrorAction SilentlyContinue
        }

        $newVersion = (ollama --version 2>&1) -replace ".*version\s+is\s+", "" -replace "\s.*", ""
        if ($newVersion -ne $currentVersion) {
            Write-Ok "Updated Ollama: $currentVersion -> $newVersion"
        }
        else {
            Write-Ok "Ollama is already at latest version ($currentVersion)"
        }
    }
}
else {
    Write-Host ""
    Write-Host "=== Step 1: Skipped (SkipOllama) ===" -ForegroundColor DarkGray
}

# ===========================================================================
# Step 2: Detect running model
# ===========================================================================
Write-Step "2" "Detecting running model"

if (-not $Model) {
    $psOutput = ollama ps 2>&1
    $lines = ($psOutput -split "`n") | Where-Object { $_ -match "\S" }

    if ($lines.Count -lt 2) {
        Write-Warn "No models currently running."
        Write-Host "  Listing all installed models:"
        ollama list

        if ($DryRun) {
            # In dry run, pick the first installed model
            $listOutput = ollama list 2>&1
            $listLines = ($listOutput -split "`n") | Where-Object { $_ -match "\S" }
            if ($listLines.Count -ge 2) {
                $Model = ($listLines[1] -split "\s+")[0]
                Write-Warn "Dry run - using first installed model: $Model"
            }
            else {
                Write-Fail "No models installed. Cannot continue."
                exit 1
            }
        }
        else {
            Write-Host ""
            $Model = Read-Host "  Enter model name to use (e.g. qwen2.5-coder:7b)"

            if (-not $Model) {
                Write-Fail "No model specified. Exiting."
                exit 1
            }
        }
    }
    else {
        $firstDataLine = $lines[1]
        $Model = ($firstDataLine -split "\s+")[0]
    }
}

Write-Ok "Using model: $Model"

# ===========================================================================
# Step 3: Update model
# ===========================================================================
Write-Step "3" "Pulling latest version of '$Model'"

if ($DryRun) {
    Write-Warn "Dry run - would run: ollama pull $Model"
}
else {
    $beforeId = (ollama list 2>&1 | Select-String "^$Model\s") -replace "^$Model\s+", "" -replace "\s.*", ""

    Write-Host "  Running: ollama pull $Model"
    ollama pull $Model

    $afterId = (ollama list 2>&1 | Select-String "^$Model\s") -replace "^$Model\s+", "" -replace "\s.*", ""

    if ($beforeId -ne $afterId) {
        Write-Ok "Model updated: $beforeId -> $afterId"
    }
    else {
        Write-Ok "Model '$Model' is already at the latest version"
    }
}

# ===========================================================================
# Step 3b: Update all downloaded models
# ===========================================================================
Write-Step "3b" "Updating all downloaded models"
$allSummary = Update-AllModels -WhatIf:$DryRun
Write-Ok "Models updated: $($allSummary.Updated.Count); already current: $($allSummary.Current.Count)"

# ===========================================================================
# Step 3c: Reload the in-use model so fresh weights are picked up next load
# ===========================================================================
Write-Step "3c" "Reloading in-use model '$Model'"

$psAfter = ollama ps 2>&1
$psLinesAfter = ($psAfter -split "`n") | Where-Object { $_ -match "\S" }
$running = $false
if ($psLinesAfter.Count -ge 2) {
    $running = ($psLinesAfter[1] -split "\s+")[0] -eq $Model
}

if ($DryRun) {
    if ($running) {
        Write-Warn "Dry run - would run: ollama stop $Model"
    }
    else {
        Write-Ok "Model '$Model' is not loaded - nothing to stop"
    }
}
else {
    if ($running) {
        Write-Host "  Running: ollama stop $Model"
        ollama stop $Model
        Write-Ok "Stopped '$Model' - it will reload with updated weights on next use"
    }
    else {
        Write-Ok "Model '$Model' is not loaded - nothing to stop"
    }
}

# ===========================================================================
# Step 4: Update opencode
# ===========================================================================
Write-Step "4" "Updating opencode"

$opencodeInstalled = Get-Command opencode -ErrorAction SilentlyContinue
if (-not $opencodeInstalled) {
    Write-Warn "opencode not found in PATH. Skipping upgrade."
}
elseif ($SkipOpenCode) {
    Write-Host "  Skipped (SkipOpenCode)" -ForegroundColor DarkGray
}
else {
    $ocVersion = (opencode --version 2>&1) -replace "\s", ""
    Write-Host "  Current version: $ocVersion"

    if ($DryRun) {
        Write-Warn "Dry run - would run: opencode upgrade"
    }
    else {
        opencode upgrade 2>&1 | ForEach-Object { Write-Host "  $_" }
        $newOcVersion = (opencode --version 2>&1) -replace "\s", ""
        if ($newOcVersion -ne $ocVersion) {
            Write-Ok "Updated opencode: $ocVersion -> $newOcVersion"
        }
        else {
            Write-Ok "opencode is already at the latest version ($ocVersion)"
        }
    }
}

# ===========================================================================
# Step 5: Update opencode.json
# ===========================================================================
Write-Step "5" "Updating opencode config"

$globalConfigDir = Join-Path (Join-Path $env:USERPROFILE ".config") "opencode"
$globalConfigPath = Join-Path $globalConfigDir "opencode.json"
$localConfigPath = Join-Path (Get-Location) "opencode.json"
$localDotDir = Join-Path (Get-Location) ".opencode"
$localDotConfig = Join-Path $localDotDir "opencode.json"

# Pick the first existing config, or default to global path for creation
$configPath = $null
if (Test-Path $localConfigPath) { $configPath = $localConfigPath }
elseif (Test-Path $localDotConfig) { $configPath = $localDotConfig }
elseif (Test-Path $globalConfigPath) { $configPath = $globalConfigPath }

$ollamaModelRef = "ollama/$Model"
$config = $null

if ($configPath) {
    Write-Host "  Found existing config: $configPath"
    $rawJson = Get-Content $configPath -Raw
    # Strip single-line and block comments for JSONC parsing (avoid breaking URLs)
    $stripped = $rawJson -replace '(?<!:)\/\/[^\r\n]*', '' -replace '/\*[\s\S]*?\*/', ''
    $config = $stripped | ConvertFrom-Json
}
else {
    Write-Host "  No existing config found. Creating global config."
    $configPath = $globalConfigPath
    $config = [PSCustomObject]@{
        '$schema' = "https://opencode.ai/config.json"
    }
}

# Update model fields
$config | Add-Member -NotePropertyName "model" -NotePropertyValue $ollamaModelRef -Force
$config | Add-Member -NotePropertyName "small_model" -NotePropertyValue $ollamaModelRef -Force

# Ensure $schema is present
if (-not ($config.PSObject.Properties.Name -contains '$schema')) {
    $config | Add-Member -NotePropertyName '$schema' -NotePropertyValue "https://opencode.ai/config.json" -Force
}

if ($DryRun) {
    Write-Warn "Dry run - would write to: $configPath"
    Write-Host ($config | ConvertTo-Json -Depth 10)
}
else {
    # Ensure directory exists
    $configDir = Split-Path $configPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    # Back up any existing config before overwriting
    if (Test-Path $configPath -PathType Leaf) {
        $backupPath = "$configPath.bak"
        Copy-Item -Path $configPath -Destination $backupPath -Force
        Write-Host "  Backed up existing config to: $backupPath"
    }

    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
    Write-Ok "Wrote config to: $configPath"
    Write-Host "  model:       $ollamaModelRef" -ForegroundColor White
    Write-Host "  small_model: $ollamaModelRef" -ForegroundColor White
}

# ===========================================================================
# Step 6: Verify update
# ===========================================================================
Write-Step "6" "Verifying update"

$verifyScript = Join-Path $PSScriptRoot "verify-update.ps1"

if ($SkipVerify) {
    Write-Host "  Skipped (SkipVerify)" -ForegroundColor DarkGray
}
elseif (-not (Test-Path $verifyScript -PathType Leaf)) {
    Write-Warn "verify-update.ps1 not found next to update.ps1. Skipping verification."
}
elseif ($DryRun) {
    Write-Warn "Dry run - would run: $verifyScript -Model '$Model'"
}
else {
    Write-Host "  Running: $verifyScript -Model '$Model'"
    & $verifyScript -Model $Model
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Fail "Verification failed (exit code $LASTEXITCODE)."
        exit 1
    }
    Write-Ok "Verification passed"
}

# ===========================================================================
# Done
# ===========================================================================
Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Restart opencode for config changes to take effect."
Write-Host ""
