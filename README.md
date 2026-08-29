# update_opencode_ollama

Automates keeping Ollama and OpenCode up to date, syncing the in-use Ollama model
into the OpenCode configuration, and verifying everything after the update.

## Files

| File               | Purpose                                                        |
| ------------------ | -------------------------------------------------------------- |
| `update.ps1`       | Runs the full update pipeline (Ollama, models, opencode, config) |
| `verify-update.ps1`| Posts-update verification checks; run automatically by `update.ps1` |

## Requirements

- Windows with PowerShell 5.1+
- [Ollama](https://ollama.com/download) (`ollama` on `PATH`)
- [OpenCode](https://opencode.ai) (`opencode` on `PATH`)
- Optional: `winget` (used to update the Ollama binary; falls back to downloading
  the installer directly if `winget` is unavailable)

## Usage

```powershell
# Full update: Ollama -> model(s) -> config -> verify
.\update.ps1

# Preview what would happen without changing anything
.\update.ps1 -DryRun

# Specify the model instead of auto-detecting the running one
.\update.ps1 -Model "qwen2.5-coder:7b"

# Skip parts of the pipeline
.\update.ps1 -SkipOllama        # don't update the Ollama binary
.\update.ps1 -SkipOpenCode      # don't upgrade opencode
.\update.ps1 -SkipVerify        # don't run the verification step

# Run only the verification checks
.\verify-update.ps1
.\verify-update.ps1 -Model "qwen2.5-coder:7b"
.\verify-update.ps1 -ConfigPath "C:\path\to\opencode.json"
```

## What `update.ps1` does

| Step | Action                                                        |
| ---- | ------------------------------------------------------------- |
| 1    | Update the Ollama binary (`winget upgrade Ollama.Ollama`, or installer fallback) |
| 2    | Detect the model currently in use (`ollama ps`)                |
| 3    | Pull the latest version of the in-use model (`ollama pull`)    |
| 3b   | Update ALL downloaded models (`ollama pull` for each in `ollama list`) |
| 4    | Update opencode (`opencode upgrade`)                           |
| 5    | Create or merge `~/.config/opencode/opencode.json` to point at the Ollama model |
| 6    | Run `verify-update.ps1` and stop if any check fails            |

### Config (Step 5)

- Writes both `model` and `small_model` to `ollama/<model>`.
- Before overwriting, copies any existing `opencode.json` to `opencode.json.bak`.
- If the config already exists, it is parsed and only `model` / `small_model`
  are updated; every other field is preserved.
- Discovery order (first match wins): `./opencode.json`, `./.opencode/opencode.json`,
  then `~/.config/opencode/opencode.json`.

## What `verify-update.ps1` checks

- Ollama is installed and its version parses.
- The expected model is installed (`ollama list`).
- The opencode config exists, is valid JSON, and has `model` + `small_model`.
- Both config refs use the `ollama/` provider and map to installed models.
- The running model (`ollama ps`), if any, matches the configured model.
- opencode is installed and its version parses.

Exits `0` on success, `1` if any check fails.

> After running an update, restart opencode for the config changes to take effect.
