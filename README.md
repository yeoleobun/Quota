<p align="center">
  <img src="Assets/AppIcon.png" width="112" height="112" alt="Quota Icon" />
</p>

<h1 align="center">Quota</h1>

<p align="center">
  A lightweight, native macOS menu bar indicator for <b>OpenAI Codex</b> and <b>Google Antigravity</b> subscription usage and reset countdowns.
</p>

<p align="center">
  <img src="Assets/Screenshot.png" width="400" alt="Quota Menu Bar Preview" />
</p>

## Install (Apple Silicon)

### Option 1: Homebrew (Recommended — No Gatekeeper Warning)

```bash
brew tap yeoleobun/tap
brew trust yeoleobun/tap 2>/dev/null || true
brew install --cask yeoleobun/tap/quota
```

### Option 2: One-Line Terminal Installer

```bash
curl -fsSL https://raw.githubusercontent.com/yeoleobun/Quota/main/scripts/install.sh | zsh
```

### Option 3: Manual `.dmg` Download

1. Download **`Quota-macos-arm64.dmg`** from the [latest GitHub Release](https://github.com/yeoleobun/Quota/releases/latest) and drag **`Quota.app`** into `/Applications`.
2. Clear the browser quarantine flag once before first launch:
   ```bash
   xattr -cr /Applications/Quota.app
   open /Applications/Quota.app
   ```

## Features

- **Native macOS Menu (`NSMenu`):** Uses AppKit's genuine system menu (`statusItem.menu`) so backdrop translucency, section headers, badges, checkmarks, and hover highlights match macOS natively.
- **Weekly Watermark Status Dot:** Displays a monochrome menu bar beer mug icon (`isTemplate = true`) with an optional **Green / Yellow / Red** corner dot reflecting the active agent's weekly quota watermark:
  - **Green:** `> 25%` remaining
  - **Yellow:** `11% – 25%` remaining
  - **Red:** `<= 10%` remaining
- **Hover or Click to Reveal:** Hover over the menu bar icon to glance at remaining percentages, ring gauges, and reset timers — move your cursor away to auto-dismiss, or click to keep the menu pinned.
- **Zero Credentials Stored:** Reads live usage directly from your existing local CLI sessions (`codex app-server --stdio` bundled in `ChatGPT.app` and `~/.local/bin/agy` `/usage`) with resilient cached fallback if a refresh fails.

## Prerequisites & CLI Discovery

- **macOS 26.0+** on Apple Silicon (`arm64`)
- At least one supported CLI/runtime installed and signed in locally:
  - **OpenAI Codex:** Standalone `codex` CLI (`brew install --cask codex` or `npm i -g @openai/codex`), **Codex.app**, or **ChatGPT.app**
  - **Google Antigravity:** Antigravity CLI (`curl -fsSL https://antigravity.google/cli/install.sh | bash`, then run `agy` once to sign in)

### Binary Resolution Priority

Because macOS GUI menu bar apps launched from Finder/Spotlight do not inherit interactive terminal `.zshrc` `PATH` additions automatically, **Quota** resolves each binary in the following priority order:

1. **Custom path override** in `~/.config/quota/settings.json` (`customCodexPath` / `customAgyPath`)
2. **`PATH`** — current process `PATH`, followed by your login shell `PATH` (`$SHELL -lc 'printf "%s" "$PATH"'`)
3. **Standard CLI install locations** (when not on `PATH`):
   - **`codex`:** `/opt/homebrew/bin/codex` → `/usr/local/bin/codex` → `~/.local/bin/codex` → `~/.bun/bin/codex` → `~/.volta/bin/codex` → `~/.local/share/mise/shims/codex` → `~/.asdf/shims/codex` → `~/.npm-global/bin/codex` → `~/.nvm/versions/node/<latest>/bin/codex`
   - **`agy`:** `~/.local/bin/agy` → `/opt/homebrew/bin/agy` → `/usr/local/bin/agy` *(IDE window launcher wrappers inside `.app/Contents/Resources/app/bin` are automatically skipped)*
4. **Bundled desktop app runtimes (`codex` fallback):**
   - `/Applications/Codex.app/Contents/Resources/codex` (and `~/Applications/...`)
   - `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (and `~/Applications/...`)

## Build from Source

```bash
./scripts/build-app.sh
open dist/Quota.app
```

## Run Tests

```bash
swift test
```

## Project Structure

- `Assets/` — App bundle icon (`AppIcon.png`, `AppIcon.icns`) and preview screenshot (`Screenshot.png`)
- `Sources/QuotaBarApp/` — Native AppKit menu bar item, hover tracking, and `NSMenu` UI
- `Sources/QuotaBarCore/` — `CodexProvider`, `AntigravityProvider`, models, and polling store
- `Tests/QuotaBarTests/` — Parser and resilient state merge unit tests
- `scripts/` — App bundle packager (`build-app.sh`), 1-line installer (`install.sh`), and `.icns` generator (`generate-icons.swift`)
- `.github/workflows/release.yml` — Automated Apple Silicon (`arm64`) release pipeline on `v*` tags
