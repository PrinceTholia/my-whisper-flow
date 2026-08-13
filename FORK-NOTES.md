# Whisper fork — session notes (Princetholia)

## Answers (this session)

### 1) Dictionary — what you meant vs what existed
| # | Kind | Status |
|---|------|--------|
| 1a | Manual Dictionary window | Already in installed app (menu → Dictionary…) |
| 1b | **Auto-add when you edit a word after paste** | **Newly coded in this fork** — was NOT in upstream |

After paste we watch the focused text field (~20s). If you change a word, we add `old -> new` to `~/.whisperapp/dictionary.txt`. Toggle in Settings: **Auto-add edits to Dictionary** (default ON). Needs Accessibility (same as paste).

### 2) Backtrack — already there or new?
**I coded it in this fork.** Upstream WhisperApp did **not** have Backtrack.  
Toggle default **OFF**. Lives in menu + Settings. Needs AI Correction on. **Requires rebuild** to use.

### 3) Soft sound — what is it?
- **Not** Wispr Flow’s sound (we don’t copy their assets; that would be a copyright risk).
- Wispr docs only describe a generic “ping / interaction sound” — they don’t publish the file for reuse.
- Ours: **custom soft sine pips** generated as tiny WAVs in `~/.whisperapp/`:
  - Start ≈ **880 Hz**, ~70 ms
  - Stop ≈ **660 Hz**, ~60 ms
- Preview was played once via `afplay` this session. Toggle in Settings.

### 4) Redesign — what changed (in fork, needs rebuild)
| Before | After |
|--------|--------|
| Wide ~300×76 rounded box + tall cyan bars | Compact **capsule pill** ~220×56 |
| Big waveform only | Small **red mic dot** + short neutral waveform |
| Heavy bottom placement | Lower, Flow-like bar near bottom center |
| Panel shadow on | Softer material + light stroke + soft drop shadow on pill |

Aesthetic goal: quieter, smaller, less “dashboard widget,” closer to a status chip.

### 5) Build blocker — options & disk/RAM

This Mac has **Command Line Tools only**, not full **Xcode** → can’t assemble `Whisper.app` here yet.

| Option | What you do | Disk / RAM |
|--------|-------------|------------|
| **A. Install Xcode (recommended)** | App Store → Xcode → `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` → `cd Real/WhisperApp && ./run.sh` | **~12–25 GB** disk for Xcode alone; **16 GB RAM** comfortable (8 GB minimum, slow) |
| **B. Another Mac with Xcode** | Clone/copy `Real/WhisperApp`, `./run.sh`, copy `Whisper.app` back | Same as A on that machine |
| **C. GitHub Actions CI** | Push fork, build DMG in cloud, download artifact | ~0 local Xcode; needs GitHub + workflow |
| **D. Stay on stock 1.2.5** | Manual Dictionary works today; #1b/#2/#3/#4 wait for A–C | 0 |

App itself once built: small (a few MB + Sparkle). The heavy cost is **the toolchain**, not Whisper.

## Backlog (numbered)

| # | Feature | Status |
|---|---------|--------|
| 1a | Manual dictionary | Live in installed app |
| 1b | Auto-add from post-paste edits | Coded in fork · needs rebuild |
| 2 | Backtrack (default off) | Coded in fork · needs rebuild |
| 3 | Compact pill UI | Coded in fork · needs rebuild |
| 4 | Soft custom chimes | Coded in fork · needs rebuild |
| 5+ | Other Wispr gaps | Parked |

## Rebuild (after Xcode)

```bash
cd /Users/princetholia/Desktop/Projects/Real/WhisperApp
./run.sh
# open Whisper.app or copy to /Applications
```

## Known conflict: macOS Dictation vs Fn

If music pauses and “live” text appears then vanishes on Fn double-tap, macOS **Keyboard → Dictation → Shortcut** is still set to Press Fn twice. Whisper auto-disables `AppleFnUsageType` / `AppleDictationAutoEnable`, but users may need to set Shortcut → Off manually once.

## Auto-paste after rebuilds

Ad-hoc builds change code signature. Accessibility grants often stop applying → clipboard works but ⌘V is required. Fix: remove/re-add Whisper in Accessibility, enable Automation → System Events, Quit & reopen. Do not rely on `typeTextDirectly` as a success signal (events can be dropped).
