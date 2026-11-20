# Changelog

## portable-v1.9.1 - 2026-11-20
- Pin: hermes-agent **v0.23.2** (commit ae2a81c - Mac parity, 2026-11-20). Python build, extras and
  playwright pins unchanged from v1.9.0.
- Drive refreshed: skills/memories/SOUL + provider config synced from the live Mac pair; Hermes kit v2
  and the refreshed Brain vault on the drive.

All notable changes to Hermes-USB-Portable. Versions follow the `portable-vMAJOR.MINOR.PATCH` pin in `VERSION`.

## [portable-v1.9.0] — 2026-10-28

### Hermes Agent v0.22.5 pinned, macOS fixed on the exFAT stick, Claude/Grok subscription sign-in, saved models

**Why.** On macOS every chat on the stick died. Causes found, in the order they surfaced:
1. `data/.env` carried `HERMES_HOME=/run/media/...` from a Linux session → `Read-only file system: '/run'`.
   Both launchers now strip `HERMES_HOME=` from `data/.env` and re-point `OBSIDIAN_VAULT_PATH` at this drive.
2. Setup always took upstream **main** once and reused `source.tar.gz` forever, so the drive sat on ~v0.21.0.
   New single pin `hermes_agent_ref: v0.22.5` in `VERSION`, read by all four scripts; the archive name carries
   the ref; `src/hermes-agent/.portable-ref` and a venv stamp trigger setup / a package refresh on mismatch.
3. hermes-agent v0.22.x marks its core deps `python_version >= '3.14'` → on Python 3.13 a chat dies with
   `No module named 'ruamel'`. Portable Python **3.13.14 → 3.14.9** (python-build-standalone 20261021, the build
   the official installer ships); the Python archive name carries the version.
4. A plain `pip install -e .[all]` cannot resolve v0.22.5 (`ResolutionImpossible`: browser-harness pins
   pillow 12.3.0, upstream overrides it to 13.0.0 in `uv.lock`). New `scripts/install-deps.sh` (shared by setup
   and the launcher) installs the **locked set exported from `uv.lock`**, then hermes-agent editable in
   `editable_mode=compat` (v0.22 builds root modules in setup.py; the default finder maps no packages →
   `No module named 'hermes_cli'`), then Playwright 1.64.1; it fails loudly unless `import hermes_cli.main` works,
   and writes `install-stamp.json` so `hermes --version` shows `v0.22.5` instead of `unknown`.
5. **exFAT cannot hold Unix sockets.** v0.22 made the gateway control socket mandatory ("gateway session bootstrap
   control listener unavailable") and binds it at `data/gateway.sock` → `[Errno 45] Operation not supported`.
   New `scripts/apply-patches.py` (idempotent, run by `launch.sh` on every start) applies three small patches:
   `exfat-control-socket` (use Hermes' own temp-dir socket + `gateway.sock.path` pointer when the home cannot hold
   a socket), `exfat-loop-tick` (liveness witness falls back to loopback TCP, as on Windows) and
   `appledouble-tools` (tool discovery skips the binary `._*` twins macOS writes on exFAT — it crashed with
   `UnicodeDecodeError` on `tools/._*.py`).
6. **exFAT has no stable inode numbers**, which Hermes' WAL guard compares → "FATAL: session storage stopped
   writing". The launcher sets `database.journal_mode: delete` (Hermes' documented mode for such filesystems) and
   converts a store that is still WAL on disk with `hermes sessions set-journal-mode delete`.
7. Extraction onto exFAT left ~23,500 AppleDouble `._*` files in the source tree; setup now runs `dot_clean -m`.

**New.** Main menu shows the Claude login; model menu `[C]` Claude Pro/Max subscription
(`hermes auth add anthropic --type oauth`), `[G]` SuperGrok (`hermes auth add xai-oauth`) and `[P]` "My saved
models" (`scripts/my-models.py`: every provider/model in `data/config.yaml`, keys checked by name only).
`Hermes-Mac.command` = Finder double-click launcher. Dashboard moved to **127.0.0.1:9139** (the host's own Hermes
owns 9119). Subscription logins are the drive's **own** OAuth logins — never a copy of a host's token (a copied
refresh token signs the other install out on refresh).

### 🔓 Uncensored model integrations (highlight)
First-class providers in the drive config, listed by `[P]` and documented in the README with a copy-paste
`providers:` block (keys only ever in `data/.env`, which git ignores):
- **Explabs** (`https://api.experientiallabs.ai/v1`, `EXPLABS_API_KEY`, 1M context): `glm-5.3-flash-uncensored`,
  `deepseek-v4.1-flash-uncensored`, `glm-5.3-uncensored:free`.
- **LarpRouter** (`https://larprouter.com/v1`, `LARPROUTER_API_KEY`, 1M context): `deepseek-v4.1-flash-1017-abliterated`.
- **breakout-mini**: your own Ollama `qwen3-vl-8b-agent:64k` (64K) over Tailscale, no key.
- Default model stays **Claude Opus 5.5**; Grok 4.7 via SuperGrok. **No automatic fallback** — the drive never
  swaps the chosen model silently.

### 🐧 Ubuntu dual boot from the same stick (Ventoy)
`setup-live-ubuntu.sh`, `run-hermes.sh` and `README_HERMES.txt` are now tracked (they were gitignored): in an
Ubuntu 26.04 live session booted from the stick they add a desktop shortcut and a `hermes-usb` command and start
Hermes on the same `data/` and `Brain/`. The ISO and `ventoy/` stay out of git, and so does `Hermes-Restore/`
(the private restore-kit images on the same stick). The exFAT fixes above cover Linux as well (`EPERM` instead of
`EOPNOTSUPP`).

### Verification (macOS 26, Apple Silicon, on the exFAT stick)
- `scripts/setup-unix.sh` end to end: Python 3.13.14 → 3.14.9 replaced in place, v0.22.5 source kept (no 1.4 GB
  re-extract), locked package set installed, `import hermes_cli.main` OK → `Setup Complete`. `install-deps.sh` alone
  re-runs in ~6 s.
- `hermes --version` → `Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7`.
- `apply-patches.py`: `--check` lists 3 missing → apply → re-run is a no-op (idempotent); patched modules compile.
- `hermes sessions set-journal-mode delete` on the drive's `state.db`: header byte 18 `2` (WAL) → `1`; the existing
  chat history is intact.
- 12/12 extracted-launcher checks pass (`.env` path scrub, pin check, subscription-login detection);
  `my-models.py --list/--select` works on a copy of the real config.
- One-shot chats from a clean environment through the drive's own gateway (socket in `$TMPDIR` + pointer on the
  drive): **Explabs `glm-5.3-flash-uncensored` replied `PORTABLE OK`** (20 s model time). LarpRouter → HTTP 402
  `insufficient_credit` (account needs credit); `glm-5.3-uncensored:free` → not processed (free tier);
  `deepseek-v4.1-flash-uncensored` not yet run.
- Not verified here: Windows (no Windows machine — `launch.bat` / `setup-windows.ps1` carry the same pin, Python
  3.14.9 and locked install, untested), the Ubuntu live session, and the Claude/Grok OAuth sign-in (needs the owner
  in Terminal). First chat after plug-in takes a few minutes on a USB 3 stick (imports from the drive).

## [portable-v1.8.4] — 2026-06-16

### macOS (Apple Silicon) verification of the v1.8.x stack + hermes-agent re-sync to current main HEAD
Second of three multi-OS passes on the v1.8.x stack (Windows shipped v1.8.2/v1.8.3; **Linux is next**).
v1.8.3's changes were **Windows-only** (A/C in `setup-windows.ps1`) plus shared docs (B), so no Unix code
change was expected on macOS — and none was needed. This release records the macOS confirmation and brings
the bundled hermes-agent up to current upstream main.

**Why a re-sync (and a version bump).** `scripts/setup-unix.sh` fetches hermes-agent from
`…/archive/refs/heads/main.tar.gz` — i.e. **main HEAD**, with no per-commit pin; the `hermes_agent_commit`
in `VERSION` is a *record* of what was last synced, not something setup enforces on Unix. The on-drive
`macos-arm64` cache was still the **v1.8.1** build (hermes-agent `@cc14b747`, 13 Jun), trailing even the
v1.8.3 record pin `@6b76284c`. The step-5 update check found upstream main **+128 commits** ahead of
`@6b76284c`, including **SSL CA-bundle fail-fast guards**, refusal-as-error fixes, and provider/OAuth
account-removal. Rather than verify a stale tree, forced a clean macOS rebuild onto current main HEAD and
re-pinned **`@6b76284c` → `@0bbf325a`**.

**No Unix code change.** `scripts/setup-unix.sh` and `launch.sh` are byte-identical to v1.8.3 (and to the
v1.8.1 macOS-verified versions). Portable runtimes are already newest and unchanged: **Python 3.13.14 ·
Node 24.16.0 LTS · uv 0.11.21 · ripgrep 15.1.0**. The Windows (`windows-x64`) and Linux (`linux-x64`)
caches were **not** rebuilt this round — Linux verifies next and will re-sync its own cache to `@0bbf325a`.

### Verification (macOS, Apple Silicon / arm64) — **macOS only this round; Linux next**
- **Clean rebuild** (cache moved aside, `src/hermes-agent` cleared, fresh `source.tar.gz` = main HEAD):
  `[OK] Source code ready` → `[OK] Virtual environment ready` → `[OK] Dependencies installed` →
  `Setup Complete`. Playwright optional browser install warns (`web tools may be limited`) — non-blocker,
  same as v1.8.1.
- `bash ./launch.sh --version` → **`Hermes Agent v0.16.0` on Python 3.13.14**.
- `bash ./launch.sh doctor` → **exit 0**. `NVIDIA NIM` connectivity ✓ green; SSL CA certificate bundle
  valid ✓ (exercises the new `@0bbf325a` SSL guard); Python env / venv / version files all ✓. Advisories
  (non-fatal): dead `KIMI_API_KEY`, config version `v0 → v29` migration available, portable
  venv-entry-point false-positive (`hermes` runs fine via the launcher's PATH — `--version` proves it),
  and unconfigured optional integration keys.
- Main menu + `[M]` model menu render; `[M] → [1] NVIDIA` (key already present) kept `NVIDIA_API_KEY`
  unchanged (`sha256[0:16] = f179184aa935e782` before **and** after) and set
  `model.provider = nvidia` / `model.default = deepseek-ai/deepseek-v4-flash`; `[11] Back` returns to the
  main menu; `[6] Exit` = 0. The experimental `providers.kimchi-dev` block in `data/config.yaml` was
  preserved (switch-model.py is idempotent).
- **Live:** `bash ./launch.sh -z "Reply with exactly: MAC OK"` → **`MAC OK`** (exit 0).
- A **new `@0bbf325a` advisory** flags `deepseek-ai/deepseek-v4-flash` as a vendor-prefixed slug under
  `provider: nvidia` (it assumes vendor/model slugs belong to aggregators). NVIDIA NIM legitimately uses
  vendor/model IDs, so this is **cosmetic** — the green connectivity check and the live `MAC OK` confirm
  the model works as configured.
- **Re-audited — clean.** 21 files tracked (launchers/docs/scripts only). No API keys/tokens/private keys
  in tracked files or in full git history; `data/`, `Brain/`, `data/config.yaml`, `chrome-profile/`,
  `data/auth/`, `src/`, `.cache/` all gitignored.

## [portable-v1.8.3] — 2026-06-14

### Windows installer hardening + storage docs (two fixes adopted from upstream `techjarves`, one found here)
Brought this fork up to parity with two improvements that upstream **`techjarves/main`** already had and
we were missing — both harden the Windows first-run/re-run path and shrink the eventual upstream-merge
conflict surface — plus a third re-run bug uncovered while verifying them on Windows.

**A — Lock-tolerant source refresh** (`scripts/setup-windows.ps1`). Replacing `src\hermes-agent` used a
plain `Remove-Item -Recurse -Force` + `Move-Item`, which **throws and aborts setup** if any file under
`src\` is locked on a re-run (antivirus scan, Windows Search indexer, or a still-running hermes during
the `launch.bat` self-heal). Now done through a `Copy-DirectoryContents` helper that falls back to
per-child delete + copy when the destination can't be fully removed. *Adapted from upstream commit
`b2904ba` ("fix locked source refresh during setup").*

**C — `uv venv --clear`** (`scripts/setup-windows.ps1`). uv 0.11.x **aborts** with *"A virtual
environment already exists … use the `--clear` flag"* when the venv is present, so **every re-run — and
the `launch.bat` self-heal that re-runs setup when `hermes.exe` is missing — failed at venv creation.**
The v1.8.0 uv bump (0.6.8 → 0.11.21) introduced this behaviour; clean installs never hit it, so it went
unnoticed until this round's re-run testing. Added `--clear` (matches `setup-unix.sh`, which `rm -rf`s
the venv first). *Found during this v1.8.3 Windows verification.*

**B — Storage free-space guidance** (`README.md`). The "Cache & Runtime Footprint" section gains a
recommended-free-space table (one platform → 2 GB min / 4 GB rec; all three OSes → 8 GB+). *Adapted from
upstream commit `3c639d7` ("docs: clarify portable storage requirements").*

All three are **Windows-only code changes** — `scripts/setup-unix.sh` and `launch.sh` are untouched
(on Unix `rm -rf` already removes open files, and the unix venv path pre-clears). The bundled
hermes-agent pin is unchanged (`0.16.0 @6b76284c`); runtimes already newest.

### Verification (Windows 11, 10.0.26200, exFAT USB — `LEGION`) — **Windows only this round**
- `Copy-DirectoryContents` unit-tested: normal replace ✓; **locked-file fallback ✓** (does not throw,
  and the new files land even with a file held open in the destination).
- The re-run that previously aborted at venv now completes end-to-end:
  `[OK] Source code ready` (A) → `[OK] Virtual environment ready` (C) → `[OK] Dependencies installed`
  → `Setup Complete`.

```
> launch.bat --version
Hermes Agent v0.16.0 (2026.6.5)   Python: 3.13.14        # exit 0

> launch.bat doctor   (exit 0)
... Python 3.13.14 OK; venv active; versions consistent (0.16.0); NVIDIA NIM connectivity OK
... 4 advisory items only (vendor-prefix note on the model slug, config migration, optional keys)

> launch.bat -z "Reply with exactly: WIN OK"
WIN OK            # free NVIDIA NIM deepseek-v4-flash one-shot, exit 0
```

- The live one-shot's **first** attempt returned no final response (a transient NVIDIA free-tier
  hiccup); the immediate retry returned `WIN OK`. doctor's NVIDIA NIM connectivity check was green
  throughout.
- **Not re-run on macOS or Linux this round.** A/C are Windows-only and B is shared docs, so no Unix
  change is expected — the owner verifies macOS first, then Linux (handoff prompts prepared), and each
  will append its evidence here.

### Security
- Re-audited — clean. 21 files tracked (launchers/docs/scripts only); no API keys/tokens/private keys
  in tracked content or in the full commit history. `data/`, `Brain/`, `config.yaml`, `chrome-profile/`,
  `chrome-downloads/`, `data/auth/`, `.cache/` and `src/` are all gitignored.

## [portable-v1.8.2] — 2026-06-14

### Verified — first Windows (x64) run of the v1.8.x stack (and the v1.7.0 NVIDIA menu)
The Windows launcher (`launch.bat`) and Windows setup (`scripts/setup-windows.ps1`) had been bumped
in v1.7.0/v1.8.0 (Python 3.13.14, Node 24.16.0, uv 0.11.21, ripgrep 15.1.0, Python source repointed
from the abandoned `indygreg` org to `astral-sh`, and the new `[M] → [1] NVIDIA — DeepSeek V4` model
option) but had **never been run on Windows**. This release closes that gap — and fixes a real
exFAT-only setup bug it exposed.

**Root cause #1 — stale runtime cache (same trap as macOS v1.8.1).** The on-drive
`.cache/runtimes/windows-x64/` was still the **pre-v1.8.0 stack** — Python **3.11.10**, uv **0.6.8**,
Node **22.14.0**, ripgrep **14.1.1**, built 2026-06-06 — with `ready.flag` present. So `launch.bat`
would have happily run the *old* 3.11 stack, and `setup-windows.ps1`'s `Download-File` reuses any
same-named archive already on disk, so deleting `ready.flag` alone would **not** refetch. Fix: moved
the stale cache aside and forced a clean rebuild.

**Root cause #2 — `tar` extraction fails on exFAT (the real bug).** The forced clean rebuild
**aborted at the Node step**. `setup-windows.ps1` extracts archives with the Windows built-in
`tar.exe` (bsdtar). On the **exFAT** USB, bsdtar's post-extract modification-time restore fails on
every entry with `Can't restore time: Invalid argument` and makes `tar.exe` exit **non-zero** — even
though the files extracted fine. `Extract-Zip` treated that as failure and fell through to
`Expand-Archive`, which then **threw** on the half-populated destination and aborted the whole script
(no Node/uv/venv/deps ever installed).

**Fix:** pass `-m` (do not restore modification times) to every `tar.exe` call in both `Extract-TarGz`
and `Extract-Zip`. With `-m`, bsdtar never attempts the failing `utime()`, so it exits 0 on exFAT and
the fast path succeeds (the `Expand-Archive` fallback is kept as a safety net but is no longer
triggered). This is Windows-specific — `setup-unix.sh` extracts on a native FS / local-disk stage and
never hits it, so it is unchanged; runtime version pins stay in lock-step.

```
# Proof the fix is real (same node.zip, same exFAT drive):
TEST A (no -m):   exit=1  time-errors=1942  node.exe=True   # false failure -> aborts setup
TEST B (with -m): exit=0  time-errors=0     node.exe=True   # clean
```

### Changed — hermes-agent source refreshed to upstream main HEAD
| Component | Was (v1.8.1) | Now |
|---|---|---|
| bundled **hermes-agent** | `0.16.0 @cc14b747` | `0.16.0 @6b76284c` (upstream `main` HEAD, **+26 commits**) |

- The 26 new commits include `fix(update): stop Windows gateways before mutating install` (directly
  Windows-relevant), three security/approval hardening commits (`fix(security): gate cp/mv/install
  into ~/.ssh, credential, and shell-rc files`, `fix(approval): detect absolute home shell rc writes`,
  `fix(approval): gate in-place edits to sensitive user files`), and `feat(read): extract notebook and
  office documents`, plus gateway/telegram/gemini/desktop/codex fixes.
- **Runtimes were checked and left unchanged** — Python 3.13.14 (build 20260610), Node 24.16.0 LTS,
  uv 0.11.21 and ripgrep 15.1.0 are each still the newest upstream release (Node v26 exists but is not
  LTS; `requires-python` is still `>=3.11,<3.14`, so 3.13.14 remains the ceiling). All six setup asset
  URLs reconfirmed HTTP 200. Nothing to bump.

### Verification (Windows 11, 10.0.26200, exFAT USB — `LEGION`)
Clean rebuild from an empty `windows-x64` cache with the fixed script (every step `[OK]`, no
`restore time` / `zip extraction failed`), then:

```
> launch.bat --version
Hermes Agent v0.16.0 (2026.6.5)
Project: D:\Hermes-USB-Portable\src\hermes-agent
Python: 3.13.14
OpenAI SDK: 2.24.0                       # exit 0

> launch.bat doctor   (exit 0)
... Python 3.13.14 OK; venv active; versions consistent (0.16.0); NVIDIA NIM connectivity OK
... 3 advisory items only: config v0->v29 migration hint, dead KIMI_API_KEY, optional API keys

# Main menu + [M] model menu render (driven via redirected stdin):
#   [M] -> model menu shows "[1] NVIDIA - DeepSeek V4  free credits (cloud, NIM)" ... "[11] Back"
#   [11] -> returns to the main menu  (Back works)
#   [5] -> "Goodbye"  (exit 0)

# [M] -> [1] NVIDIA (key already present -> findstr check errorlevel 0, no re-prompt):
config model block: provider kimi-coding/kimi-for-coding  ->  provider nvidia / deepseek-ai/deepseek-v4-flash
NVIDIA_API_KEY: unchanged (len=70, sha256[0:16]=F179184AA935E782 before and after)   # key preserved

> launch.bat -z "Reply with exactly: WIN OK"
WIN OK                                   # live NVIDIA deepseek-v4-flash one-shot, exit 0
```

- `doctor` exits **0**; the 3 listed items are advisory (a config-migration hint, the long-dead
  `kimi-for-coding` key — `Kimi / Moonshot (invalid API key)`, which is exactly why the default is
  NVIDIA — and optional provider keys). NVIDIA NIM connectivity is green and the live one-shot proves
  the `nvidia` / `deepseek-ai/deepseek-v4-flash` pairing works end-to-end.
- **Default model set to NVIDIA on this drive:** the drive had been left on the quota-dead
  `kimi-coding`; the `[M] → [1]` test switched it to the intended free default
  `nvidia` / `deepseek-ai/deepseek-v4-flash` (matches macOS/Linux). `config.yaml` is gitignored
  (drive state, not a tracked change).
- Unlike macOS (where Playwright's chromium download failed), Playwright installed cleanly on Windows.

### Security
- **Re-audited — clean.** 21 files tracked (launchers/docs/scripts only). No API keys/tokens/private
  keys in tracked content or in the **full 29-commit history** (the only `sk-…` matches are the
  `sk-…-xxxxxxxxxxxxxxxx` placeholder examples in `README.md`). `data/.env`, `Brain/`, `config.yaml`,
  `chrome-profile/`, `chrome-downloads/`, `data/auth/`, `.cache/` and `src/` are all confirmed
  gitignored and were never committed.

## [portable-v1.8.1] — 2026-06-13

### Verified — first clean macOS (Apple Silicon) rebuild of the v1.8.0 stack
v1.8.0 shipped the whole-stack runtime bump but, as its own changelog noted, was **only re-run and
verified on Linux** — the macOS/Windows setup scripts were updated "in lock-step (URLs verified to
resolve) but not re-run on those OSes this session." This release closes that gap on macOS.

**Root cause found on first macOS plug-in:** the on-drive macOS runtime cache
(`.cache/runtimes/macos-arm64/`) was still the **pre-v1.8.0 stack** — Python **3.11.15**, uv 0.7.8,
ripgrep 14.1.1 — built 2026-06-06, before v1.8.0's runtime bump landed (2026-06-13). The launcher's
`ready.flag` was present, so `launch.sh` would have happily run the *old* 3.11 stack, and
`setup-unix.sh`'s `download()` reuses any same-named archive already on disk (the cached
`python.tar.gz` is a valid gzip), so simply deleting `ready.flag` would **not** have refetched 3.13.

**Fix:** moved the stale cache aside and forced a clean rebuild, which fetched the correct v1.8.0
pins (Python 3.13.14 / Node 24.16.0 / uv 0.11.21 / ripgrep 15.1.0) and re-synced the bundled
hermes-agent source from upstream `main`.

### Changed — hermes-agent source refreshed to upstream main HEAD
| Component | Was | Now |
|---|---|---|
| bundled **hermes-agent** | `0.16.0 @4b646bc2` | `0.16.0 @cc14b747` (upstream `main` HEAD, **+27 commits**) |

- The 27 new commits are upstream fixes, including **three `fix(security)`** commits
  (`fail closed when an own-policy gateway adapter has no allowlist`, `stop /api/status leaking host
  paths and PID on gated binds`, plus a WeCom sender-allowlist fix) — directly in line with v1.8.0's
  vuln-surface-reduction goal.
- **Runtimes were checked and left unchanged** — Python 3.13.14 (build 20260610), Node 24.16.0 LTS,
  uv 0.11.21 and ripgrep 15.1.0 are each already the newest upstream release (`requires-python` is
  still `>=3.11,<3.14`, so 3.13.14 remains the ceiling). Nothing to bump.

### Verification (macOS 27.0, Apple Silicon, exFAT USB — `achupradeeps-MacBook-Air`)
Clean rebuild from an empty `macos-arm64` cache, then:

```
$ ./launch.sh --version
Hermes Agent v0.16.0 (2026.6.5)
Project: /Volumes/New Volume/Hermes-USB-Portable/src/hermes-agent
Python: 3.13.14
OpenAI SDK: 2.24.0

$ ./launch.sh doctor ; echo $?
...core toolsets ✓ (todo, web, kanban); optional ones ⚠ (missing keys / system deps)
0                       # exits 0

$ printf '6\n' | ./launch.sh      # interactive menu
... banner renders: provider "nvidia", model "deepseek-ai/deepseek-v4-flash", Brain 72 pages, v0.16.0
Goodbye!                # option [6] exits cleanly (exit 0)

$ ./launch.sh -z "Reply with exactly: MAC OK"
MAC OK                  # live NVIDIA deepseek-v4-flash one-shot, exit 0
```

- `doctor` exits **0**; its 5 listed items are advisory (optional API keys for discord/x_search/moa,
  a config-migration hint, and a vendor-prefix note on `deepseek-ai/deepseek-v4-flash` + provider
  `nvidia`). The live one-shot proves that exact provider/model pairing works end-to-end, so the
  vendor-prefix note is cosmetic for this drive.
- **Known non-blocker:** Playwright's chromium download failed during setup (`[WARN] Playwright
  browser install failed`) — browser-driven web automation is unavailable until
  `python -m playwright install chromium` succeeds; everything else (incl. the `web` toolset) works.

### Security
- **Re-audited — clean.** 21 files tracked (launchers/docs/scripts only). No API keys/tokens/private
  keys in tracked content or in the **full commit history**; `data/.env`, `Brain/`, `config.yaml`,
  `chrome-profile/`, `data/auth/` and `.cache/unix-home/.git-credentials` are all confirmed gitignored
  and were never committed.

## [portable-v1.8.0] — 2026-06-13

### Changed — whole-stack update to latest (CVE / vuln-surface reduction)
Updated **everything** the portable drive ships, to shrink the vulnerability surface of the bundled
stack:

| Component | Was | Now |
|---|---|---|
| bundled **hermes-agent** | `0.16.0 @56236b16` | `0.16.0 @4b646bc2` (upstream `main` HEAD — newer commits/fixes) |
| **Python** | 3.11.15 (build 20260510) | **3.13.14** (build 20260610) |
| **Node.js** | 22.14.0 | **24.16.0** (LTS "Krypton") |
| **uv** | 0.7.8 | **0.11.21** |
| **ripgrep** | 14.1.1 | **15.1.0** |

- Python stays within hermes-agent's `requires-python = ">=3.11,<3.14"` — 3.13.14 is the newest
  allowed. All Python deps (`hermes-agent[all]` + `anthropic` + `python-telegram-bot`) build and
  install cleanly on 3.13.
- **Fixed a stale/abandoned Windows pin:** `scripts/setup-windows.ps1` was downloading Python from
  the **deprecated `indygreg/python-build-standalone`** org at **3.11.10 (20241016)**. Repointed to
  `astral-sh` 3.13.14 (20260610), matching `setup-unix.sh`. uv on Windows was also far behind (0.6.8).
- Version pins are now single-sourced as variables (`PY_VER`/`NODE_VER`/`UV_VER`/`RG_VER`) at the top
  of `setup-unix.sh`; `VERSION` records the exact runtime versions alongside the hermes-agent commit.

### Security
- **Re-audited the git repo for secrets — clean.** Only 21 files are tracked (launchers/docs/scripts);
  every sensitive path (`data/`, `Brain/`, `config.yaml`, `chrome-profile/`, `data/auth/`, the on-drive
  `.cache/unix-home/.git-credentials`) is gitignored. No API keys/tokens/passwords in tracked files or
  in the full commit history; no `.env`/key file was ever committed. The only matches are the owner's
  own public git-config email and download URLs.

### Notes
- **Verified on Linux (AST-WKS-571, Ubuntu 26.04, exFAT USB):** full clean rebuild — Python 3.13.14,
  Node v24.16.0, uv 0.11.21, ripgrep 15.1.0 all install via the exFAT-safe path; `ready.flag` written;
  `launch.sh --version` → Hermes v0.16.0 on **Python 3.13.14**; live NVIDIA `deepseek-v4-flash`
  one-shot through `launch.sh -z` returns a real reply. macOS/Windows setup scripts updated in lock-step
  (URLs verified to resolve) but not re-run on those OSes this session.
- Playwright browser binaries still don't unpack on exFAT-Linux (symlink-based) — non-fatal, unchanged.

## [portable-v1.7.0] — 2026-06-13

### Added
- **"NVIDIA — DeepSeek V4" model option** in the model switcher — `launch.sh` `[M]` menu **`[1]`** (and `launch.bat` parity). It wires hermes-agent's **native `nvidia` NIM provider**, which reads `NVIDIA_API_KEY` and has the endpoint (`https://integrate.api.nvidia.com/v1`) built in, so no base-url/key juggling is needed. Picking it prompts for a model (default below) and, if `NVIDIA_API_KEY` isn't already in `data/.env`, for the key (free at <https://build.nvidia.com/>).
- This gives the drive a **free, working model out of the box** — which matters because the prior default `kimi-for-coding` is **quota-exhausted (HTTP 403)** and the OpenRouter/Nous fallbacks are out of credit, so live chat was effectively dead until now.

### Changed
- **Default NVIDIA model is `deepseek-ai/deepseek-v4-flash`**, not `-v4-pro`. Reason — verified on Linux:
  - `deepseek-ai/deepseek-v4-flash` → hermes one-shot returns a real answer (`"NVIDIA OK"`, exit 0); fast first token. ✅
  - `deepseek-ai/deepseek-v4-pro` → **stalls**. hermes logs: `Stream stale for 180s — no chunks received. model=deepseek-ai/deepseek-v4-pro context=~33,607 tokens. Killing connection.` → `APIConnectionError`, all 3 retries fail. v4-pro runs in full **thinking mode**, and with Hermes' large system+tools+Brain context it doesn't emit a first token before the 180s stream-stale watchdog fires. It's still **typeable** in the menu (type `deepseek-ai/deepseek-v4-pro`) for short-context use, just not the default.
- The `[M]` menu was renumbered to put NVIDIA first: `[1]` NVIDIA, `[2]` Kimi, `[3]` Ollama, `[4]` LM Studio, `[5]`/`[6]` Gemini (OAuth / API key), `[7]` OpenRouter, `[8]` Anthropic, `[9]` Custom, `[10]` Full picker, `[11]` Back. `launch.bat` mirrors this.

### Notes
- The live default on the master drive was switched to `provider: nvidia` / `deepseek-ai/deepseek-v4-flash` and **verified end-to-end** (`launch.sh -z "…"` returns a real model reply on Ubuntu 26.04, exFAT). `NVIDIA_API_KEY` was already present in `data/.env`.
- To enable v4-pro properly one would need to pass NVIDIA's `extra_body={"chat_template_kwargs":{"thinking":false}}` (disables the reasoning trace) through the provider — not currently exposed by the launcher; flash sidesteps it entirely.
- `launch.bat` parity was added by mirroring the `launch.sh` flow (new `:mdl_nvidia` label, `findstr` check for an existing `NVIDIA_API_KEY`); it was **not re-run on Windows in this session** (no Windows host available) — macOS/Linux `launch.sh` is the verified path.

## [portable-v1.6.0] — 2026-06-13

### Fixed
- **`launch.sh` failed on the very first run on Linux — Hermes never started.** First-run setup aborted while unpacking the portable runtime with a flood of:
  ```
  tar: bin/python: Cannot create symlink to 'python3.11': Operation not permitted
  tar: lib/libpython3.11.so: Cannot create symlink to 'libpython3.11.so.1.0': Operation not permitted
  ...
  ```
  **Root cause:** the master USB is formatted **exFAT** (the only filesystem Windows + macOS + Linux can all read/write), and on **Linux the exFAT driver cannot store POSIX symlinks** — `ln -s` returns `EPERM`, and so does `tar -x` on any archive that contains symlinks. The portable Python (python-build-standalone) and Node tarballs are both symlink-heavy (`bin/python → python3.11`, `lib/libpython3.11.so → …so.1.0`, npm/npx/corepack, hundreds of terminfo entries). So `extract_tgz`/`extract_txz` died mid-unpack, `setup-unix.sh` exited non-zero, **`ready.flag` was never written**, and every subsequent `./launch.sh` re-entered the same broken setup. (macOS's exFAT implementation *does* support symlinks, which is why the existing macOS runtime — all real files — worked and Linux never had.)
- **Fix — materialise symlinks as real files on no-symlink drives.** `scripts/setup-unix.sh` now:
  - **Detects** whether the runtime drive can hold symlinks (a one-shot `ln -s` probe). On exFAT/NTFS it prints a clear `[WARN]` and switches strategy.
  - **Extracts on the host's local disk** (`/tmp`, where symlinks work) and copies the result onto the drive with **`cp -RL`** (dereference) so every symlink becomes a **real file** exFAT can store. Native filesystems (macOS/HFS, ext4) keep the original fast direct-extract path. This is applied to **Python, Node, uv, ripgrep, and the Hermes source tarball**.
  - **Builds the venv on local disk** for no-symlink drives (a venv is built out of symlinks to the base interpreter) and records the location in **`venv.path`** — the exact pointer `launch.sh` already reads and rebuilds from after a reboot purges `/tmp`. On native filesystems the venv stays on the drive.
  - Hardened incidental bugs surfaced along the way: ripgrep extraction no longer aborts the whole script under `set -e` on a man-page symlink; `uv`/`uvx` are dereferenced too; a `warn` call that ran before the function was defined was removed.

### Notes
- **macOS `launch.sh` / `setup-unix.sh` behaviour is unchanged** — the new branches only trigger when the drive can't store symlinks. Windows (`launch.bat`) is untouched.
- **Playwright browser binaries** still can't install onto exFAT-Linux (they unpack with symlinks); this is non-fatal and already wrapped in a warning — browser/web-automation tools are limited there, everything else works.
- **Verified on `AST-WKS-571` (Ubuntu 26.04 LTS, x86_64, exFAT USB):** clean `bash -n`; full first-run setup completes (Python/Node/uv/ripgrep/source all extract, venv built at `/tmp/hermes-portable-venv-<id>`, deps installed, `ready.flag` written); `bash launch.sh --version` → `Hermes Agent v0.16.0`, Python 3.11.15; `bash launch.sh doctor` runs (exit 0); the interactive menu renders and exits cleanly; device memory recorded to `Brain/devices/ast-wks-571-linux-x64.md`; plugin discovery reports **38 found, 32 enabled**. The agent loop reaches the model provider and fails only at the billing layer (`kimi-for-coding` → **HTTP 403 quota exhausted**, fallbacks out of credit) — an account/quota matter identical across OSes, not a launcher bug. Refill the Kimi quota or point `[M] → Model` at a funded provider for live chat.

## [portable-v1.5.0] — 2026-06-10

### Changed
- **README overhaul** — front-page completely rewritten to document every portable-specific feature shipped since v1.0.0. New sections added:
  - **Obsidian Brain Setup** — how to open `Brain/` as an Obsidian vault on any machine, vault structure, and the `.hermes-safe-eject.json` marker.
  - **Portable Chrome Launcher** — import profile from host, launch with `chrome-launcher/chrome.bat`, carry logins/bookmarks across PCs.
  - **Dashboard** — `[D] Open Dashboard` shortcut, cold-start wait logic, pre-built SPA, and security notes.
  - **Safe Eject** — `[5] Eject USB Safely` workflow, `--dry-run` / `--yes` flags, and eject-blocked troubleshooting.
  - **Model Switcher & OAuth Gemini** — `[M]` menu and `[4] Google Gemini — login with Google` with credential location.
  - **Versioning & Releases** — how `VERSION` pairs the wrapper with the upstream hermes-agent commit, plus tag history.
  - Updated mermaid diagram to include Brain, Dashboard, and Chrome Launcher nodes.
  - Updated directory structure YAML to include `Brain/`, `chrome-launcher/`, `docs/`, `chrome-profile/`, `chrome-downloads/`, `data/auth/`, and `scripts/safe-eject.sh`.
  - New troubleshooting entries for dashboard blank page, Chrome profile import, and USB eject blocked.
- No launcher or script code changes in this release — purely documentation and repo hygiene.

## [portable-v1.4.1] — 2026-06-07

### Fixed
- **`launch.bat -z "<multi-word prompt>"` (and any quoted passthrough args) crashed** with `is was unexpected at this time` before Hermes ever ran. Root cause: the direct-run path used `if not "%ARGS%"=="" ( hermes %ARGS% )`, which expands `%ARGS%` at *parse* time — so quotes/commas/parens inside the prompt got re-parsed as batch syntax and broke the `if`-block. Now it detects passthrough args via `%~1` and runs `hermes !ARGS!` on a bare line with **delayed expansion**, so the prompt reaches Hermes verbatim. Verified on LEGION: `launch.bat -z "In 8 words: your name, owner, and brain folder (no tools)."` runs clean and Herme replies. (Caveat: a literal `!` in the prompt is consumed by delayed expansion.) macOS `launch.sh` already handled this correctly via `bash`.

## [portable-v1.4.0] — 2026-06-07

### Fixed
- **Windows launcher had no OAuth Gemini option — "Login with Google" only worked on macOS.** The `[4] Google Gemini` entry in `launch.bat` ran the **API-key** path (`switch-model.py --provider gemini --set-env GEMINI_API_KEY=…`), even though the `google-gemini-cli` **OAuth** flow shipped in `launch.sh` back at v1.2.0. Result on Windows: users who had logged in with Google (creds at `data/auth/google_oauth.json`) and selected `[M] → Gemini` got `provider: gemini` with an empty `GEMINI_API_KEY` → **"model provider failed."** `launch.bat` is now at parity with `launch.sh`.

### Added (Windows parity with `launch.sh`)
- **`[4] Google Gemini — login with Google (OAuth, no API key)`** in `launch.bat`: runs `hermes auth add google-gemini-cli` (browser PKCE sign-in; creds → `data/auth/google_oauth.json` on the USB), then points `config.yaml` at `provider: google-gemini-cli` via `switch-model.py` (no API key). Default model `gemini-3-flash-preview` (high RPM, snappy for an always-on agent; switch to `gemini-3-pro-preview` for heavy reasoning).
- The existing **API-key** Gemini path is preserved at **`[5] Google Gemini — cloud (API key)`**; OpenRouter/Anthropic/Custom/Full-picker/Back renumbered to `[6]…[10]`.
- The model menu now reads input with `set /p` instead of `choice` so the two-digit **`[10] Back`** is selectable.

### Notes
- macOS `launch.sh` is unchanged (it already had both Gemini options).
- Verified on `LEGION` (Windows 11): switched `config.yaml` to `google-gemini-cli` / `gemini-3-flash-preview`; `hermes doctor` shows Gemini OAuth logged in; live one-shots on both `gemini-3-pro-preview` and `gemini-3-flash-preview` returned correct answers (identity + injected memory); gateway reconnects to Telegram on Gemini. `gemini-3-pro-preview` is RPM-throttled on the standard tier (HTTP 429 with short reset windows) under rapid multi-step calls — flash avoids this.

## [portable-v1.3.1] — 2026-06-06

### Fixed
- **Dashboard opened a blank / "connection refused" page.** Root cause: the launcher ran `hermes dashboard` which auto-opened the browser *immediately*, but the server's cold start (plugin discovery off the USB) takes **~60-90s to bind** — so the browser loaded before the server existed and looked broken. The backend was always fine (verified: SPA + assets 200, token injected, `/api/config`·`/api/model/info`·`/api/sessions`·`/api/system/stats` all 200 + JSON).
- `menu_dashboard()` now starts the server **detached with `--no-open`**, polls `http://127.0.0.1:9119/api/status` until it actually responds (up to 120s, with progress dots), and **only then opens the browser**. Added an **"already running" fast-path** (re-opens the tab instead of spawning a second server) and clear stop guidance (`hermes dashboard --stop`).
- New helpers `_http_ok` (curl → bundled-python fallback) and `_open_url` (macOS `open` / Linux `xdg-open`) so readiness-polling and browser-open work on any host.

### Notes
- First launch is slow (~60-90s) because plugin discovery loads off the USB; subsequent launches are faster (OS cache) and the fast-path is instant. Verified end-to-end: ready after 62-74s, browser opens only when live, `/api/config → 200`.

## [portable-v1.3.0] — 2026-06-06

### Added
- **Hermes Dashboard** — new main-menu shortcut **`[D] Open Dashboard`**. Launches hermes-agent's web UI (config, API keys, sessions, in-browser chat) at **`http://127.0.0.1:9119`**, bound to localhost only. Runs `hermes dashboard --skip-build` so startup is instant and needs no Node/npm at runtime; Ctrl-C stops it and returns to the menu.
- **Frontend pre-built onto the drive** — the Vite/React SPA is built once into `src/hermes-agent/hermes_cli/web_dist/` (vite `outDir`), so the dashboard serves a static bundle. `web/node_modules` is kept on the drive too, so a future rebuild works offline. The launcher auto-builds on first run if the dist is missing.
- Backend deps (`fastapi`/`uvicorn`/`starlette`) already ship via `hermes-agent[all]`, which the launcher installs on every venv (re)build — so the dashboard survives temp-venv rebuilds.

### Notes
- **Security:** the dashboard binds to `127.0.0.1` only; on loopback the SPA carries an ephemeral session token injected at serve time, so `/api/*` writes require it (verified: `/api/config` 200 with token, 401 without). Never expose it with `--insecure` on an untrusted network.
- Verified end-to-end: `bash -n` clean; `npm run build` → `web_dist` (index.html + assets); live server returns `GET / → 200`, `/api/status → 200` (public), `/api/config` & `/api/sessions → 200` (authenticated), `401` without token; `--skip-build`, `--stop`, `--status` all work.
- Gemini (v1.2.0) confirmed on the **subscription / standard-tier** via Cloud Code Assist (not API-key credits): `loadCodeAssist` reports `current_tier_id=standard-tier`, quota ~97% on the pro models, live inference OK.

## [portable-v1.2.0] — 2026-06-06

### Added
- **Google Gemini — Login with Google** — new model-menu entry **`[4] Google Gemini · login with Google (no API key)`**. Picks Gemini using a Google account instead of an API key, by wiring hermes-agent's native **`google-gemini-cli`** provider into the portable launcher:
  1. Runs `hermes auth add google-gemini-cli` — a browser **OAuth (PKCE)** sign-in to Google.
  2. Talks to Google's **Cloud Code Assist** backend (`cloudcode-pa.googleapis.com`) — the same backend behind Google's own gemini-cli free/subscription tiers. No API key, no `gemini-cli` install required (the public OAuth client ships with hermes-agent).
  3. Prompts for the model (default `gemini-3-pro-preview`; also `gemini-3.1-pro-preview`, `gemini-3-flash-preview`, `gemini-3.5-flash`) and points `data/config.yaml` at the provider.
- **Portable by design** — the OAuth credential is stored at `data/auth/google_oauth.json` (chmod 0600, on the USB and gitignored), so the login travels with the drive across machines.
- The existing **API-key** Gemini path is preserved, now at **`[5] Google Gemini · cloud (API key)`**; subsequent menu items renumbered (`[10] Back`).
- `docs/GEMINI-LOGIN.md` — setup, model notes, credential location, and the Google ToS caveat.

### Notes
- **Google policy:** using the gemini-cli OAuth client with third-party software is a ToS gray-area; hermes-agent shows an upfront warning before sign-in. Use with your own account at your discretion.
- Verified: `bash -n` syntax-clean; live Google sign-in completed end-to-end (`auth status google-gemini-cli: logged in`, credential saved on USB); model applied to `config.yaml`.

## [portable-v1.1.0] — 2026-06-06

### Added
- **Safe Eject** — new launcher menu option **`[5] Eject USB Safely`** (alias `e`) and a standalone engine `scripts/safe-eject.sh`. One action runs the full safe-removal workflow so the drive is never pulled with unsaved state:
  1. **Stop gateway** — releases live file handles (`hermes gateway stop`).
  2. **Save sessions** — counts/flushes `data/sessions/*` and appends a timestamped close-out entry to `Brain/log.md`.
  3. **Organise & verify the Brain** — scans all notes, runs a `[[wikilink]]` integrity check, and writes a machine-readable `Brain/.hermes-safe-eject.json` marker for the next AI session.
  4. **Sync** — double `sync` to flush all writes to the USB.
  5. **Eject** — detects the drive's volume (`df`) and ejects via a *detached* helper (macOS `diskutil eject`; Linux `udisksctl`/`umount`) so the volume isn't yanked out from under the running launcher.
- **Flags** on `scripts/safe-eject.sh`: `--dry-run` (save/organise/sync but skip eject) and `--yes` (no confirm prompt).
- `docs/SAFE-EJECT.md` — detailed workflow + troubleshooting.
- `.gitignore` now excludes macOS AppleDouble files (`._*`, `.DS_Store`).

### Notes
- A confirm prompt guards the action (cancel returns to the menu, exit code 10).
- Nothing is ever deleted; the workflow only saves, organises, and unmounts.
- Verified: `bash -n` syntax-clean; `--dry-run` exercised end-to-end (gateway stop, log close-out, 39-note Brain integrity scan, sync, volume detection).

## [portable-v1.0.0] — 2026-06-06
- Initial portable release: cross-platform launchers (`launch.sh`/`launch.bat`), fast model switcher, gateway + Telegram wiring, Obsidian "Brain", device recording, versioning + `docs/UPDATING.md`.
