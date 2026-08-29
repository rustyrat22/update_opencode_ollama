# update_opencode_ollama

Keeps **Ollama** and **OpenCode** up to date and wired together. It updates the
Ollama binary, refreshes every downloaded model, reloads the in-use model, upgrades
OpenCode, points the OpenCode config at the Ollama model, and verifies the result.

## Purpose

Ollama serves local models (e.g. `qwen2.5-coder:7b`) that OpenCode uses as its
provider. Keeping all of this in sync by hand means remembering several distinct
updates. This build automates the whole workflow in one command.

---

## Files

| File                | Purpose                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `update.ps1`        | The main update pipeline (steps 1-6)                               |
| `verify-update.ps1` | Post-update verification checks (step 6, run automatically)        |

---

## Requirements

- **Windows** with PowerShell 5.1+
- **Ollama** installed, with `ollama` on `PATH` (https://ollama.com/download)
- **OpenCode** installed, with `opencode` on `PATH` (https://opencode.ai)
- **Optional:** `winget` (used to update the Ollama binary; if absent, the script
  downloads the official installer directly)

---

## Quick start

```powershell
# Run the full workflow
.\update.ps1
```

That single command:

1. Updates the Ollama binary
2. Detects the local model currently in use
3. Pulls the latest version of that model
4. Pulls the latest version of **every** downloaded model
5. Reloads the in-use model
6. Upgrades OpenCode
7. Updates the OpenCode config to use the Ollama model
8. Verifies everything

---

## The 6-step workflow in detail

### Step 1 — Update the Ollama binary

Tries `winget upgrade Ollama.Ollama` first. If `winget` is unavailable, downloads
`OllamaSetup.exe` from https://ollama.com/download and runs it silently in place.
Your downloaded models and settings are preserved.

### Step 2 — Detect the model in use

Reads `ollama ps` to find which model is currently loaded. If none is running, it
lists your installed models and asks you to pick one (or uses the first installed
model when running with `-DryRun`). You can also bypass detection with `-Model`.

### Step 3 — Update the in-use model

Runs `ollama pull <model>` to fetch the latest version of the model you're using.
Only changed layers are downloaded, so this is fast when the model is already current.

### Step 3b — Update all downloaded models

Enumerates `ollama list` and runs `ollama pull` on **every** model, so your whole
local library stays current — not just the one in use. Prints a summary of how many
were updated vs. already current.

### Step 3c — Reload the in-use model

If your model was loaded in memory, runs `ollama stop <model>` so it unloads and
reloads with the freshly-updated weights on next use.

### Step 4 — Update OpenCode

Runs `opencode upgrade` to update OpenCode to the latest version. Skipped if
OpenCode is not installed or if you pass `-SkipOpenCode`.

### Step 5 — Update the OpenCode config

Creates or merges `~/.config/opencode/opencode.json` (unless a project-level config
already exists — see *Config location* below). Specifically:

- Sets both `model` and `small_model` to `ollama/<model>`.
- **Carries over the model's runtime settings** (`num_ctx`, and `temperature` /
  `top_p` / `top_k` when set on the model) into
  `provider.ollama.models.<model>.options`, so OpenCode requests use the same
  generation parameters as the installed model.
- **Backs up** any existing config to `opencode.json.bak` before overwriting.
- Preserves every other field you already had in the config (only `model` and
  `small_model` are updated).

### Step 6 — Verify the update

Runs `verify-update.ps1` and stops with a non-zero exit code if any check fails.

---

## Config location

Discovery order (first match wins):

1. `./opencode.json`
2. `./.opencode/opencode.json`
3. `~/.config/opencode/opencode.json` (default target when none exists)

The script only modifies `model`, `small_model`, and the Ollama provider options;
everything else in the file is left intact.

---

## Usage reference

```powershell
# Full workflow
.\update.ps1

# Preview everything without changing anything
.\update.ps1 -DryRun

# Use a specific model instead of auto-detecting
.\update.ps1 -Model "qwen2.5-coder:7b"

# Skip the Ollama binary update
.\update.ps1 -SkipOllama

# Skip the OpenCode upgrade
.\update.ps1 -SkipOpenCode

# Skip the post-update verification
.\update.ps1 -SkipVerify

# Run only the verification checks
.\verify-update.ps1
.\verify-update.ps1 -Model "qwen2.5-coder:7b"
.\verify-update.ps1 -ConfigPath "C:\path\to\opencode.json"
```

### Flags for `update.ps1`

| Flag            | Description                                              |
| --------------- | -------------------------------------------------------- |
| `-Model <name>` | Model to use instead of the auto-detected running model  |
| `-SkipOllama`   | Do not update the Ollama binary                          |
| `-SkipOpenCode` | Do not upgrade OpenCode                                  |
| `-SkipVerify`   | Do not run the verification step                         |
| `-DryRun`       | Show what would happen without making any changes        |

---

## Verification checks (`verify-update.ps1`)

- Ollama is installed and its version parses.
- The expected model is installed (`ollama list`).
- The OpenCode config exists, is valid JSON, and has both `model` and `small_model`.
- Both config refs use the `ollama/` provider.
- The config models map to actually-installed Ollama models.
- The running model (`ollama ps`), if any, matches the configured model.
- OpenCode is installed and its version parses.

Exits `0` on success, `1` if any check fails.

---

## Example config produced

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/qwen2.5-coder:7b",
  "small_model": "ollama/qwen2.5-coder:7b",
  "provider": {
    "ollama": {
      "models": {
        "qwen2.5-coder:7b": {
          "options": {
            "num_ctx": 32768
          }
        }
      }
    }
  }
}
```

---

## Notes

- After running an update, **restart OpenCode** for the config changes to take
  effect.
- `ollama pull` is how Ollama updates models; there is no separate `ollama update`.
- The `opencode.json.bak` file is kept next to your config for recovery.

---

## Development workflow

Each improvement to this repo is developed on its own branch and merged via a pull
request:

```powershell
git checkout master
git pull origin master
git checkout -b feature/<name>
# ... make changes, test ...
git add -A
git commit -m "<description>"
git push -u origin feature/<name>
# open a pull request into main
```
