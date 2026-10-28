# Updating Hermes-USB-Portable

This repo is a **portable wrapper** around
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). The agent
source lives in `src/hermes-agent/` which is **gitignored**. Since **portable-v1.9.0**
the launchers download one **pinned release tag** of it, not upstream `main`.

## The pin

`VERSION` holds the one pin every script reads:

| Field | Meaning |
|---|---|
| `portable_version` (`portable-vX.Y.Z`) | The launcher/scripts/docs in **this** repo. Bump on wrapper changes. |
| `hermes_agent_ref` | **The pin.** Release tag of hermes-agent to install (e.g. `v0.22.5`). Read by `setup-unix.sh`, `setup-windows.ps1`, `launch.sh`, `launch.bat`. |
| `hermes_agent_version` / `hermes_agent_commit` | Record of what that tag is (version string + commit), for humans. |

How a pin change reaches a drive:

1. Setup downloads `…/archive/refs/tags/<ref>.tar.gz` (`.zip` on Windows), caches it as
   `source-<ref>.tar.gz` (so an old cached archive is never reused for a new pin), and
   writes the ref to `src/hermes-agent/.portable-ref`. Archives of older pins are deleted.
2. `launch.sh` / `launch.bat` compare `.portable-ref` with the pin on every start. If they
   differ, ready.flag is dropped and setup runs once.
3. The venv carries a stamp of its own (`<venv>/.portable-ref`). If the source on the drive is
   newer than the venv (another machine updated it, or an old local venv survived),
   `launch.sh` refreshes only the Python packages.
4. **Advanced → Update Hermes** = `git pull --ff-only` of this repo (then `dot_clean` of
   `.git` on macOS) + the pin check above. `hermes update` cannot update a tarball install.

Tag releases as `portable-vX.Y.Z`. Bump: **patch** = launcher bugfix; **minor** = new
launcher feature / new hermes-agent release; **major** = breaking layout/flow change.

## Move to a new hermes-agent release

```bash
# 0. From inside the portable folder.
ROOT="$(pwd)"

# 1. Pick the release (stable tags only, never main).
git ls-remote --tags https://github.com/NousResearch/hermes-agent | grep -E 'refs/tags/v[0-9.]+$' | tail -3
#    Check its requires-python still accepts the bundled Python (3.13.x) and note
#    any pinned extras (python-telegram-bot, playwright) that changed.

# 2. Edit VERSION: hermes_agent_ref, hermes_agent_version, hermes_agent_commit,
#    portable_version, synced_on. Keep HERMES_EXTRAS / PLAYWRIGHT_PIN in
#    setup-unix.sh and launch.sh in sync.

# 3. Install it on THIS OS through the real code path, from a normal terminal.
#    Running the launcher does the pin check and setup; running setup alone works too:
bash scripts/setup-unix.sh "$ROOT"          # macOS / Linux
#    (Windows: delete .cache\runtimes\windows-x64\ready.flag, then run launch.bat)

# 4. Verify on this OS (then on the others).
bash launch.sh --version                    # -> the new version, Python 3.13.x
bash launch.sh doctor                       # all green except provider reachability
bash launch.sh chat -q 'Reply with exactly: OK' --provider <p> --model <m>
printf '6\n' | bash launch.sh               # menu renders, brain detected, then exit

# 5. Commit & push (scan first: no data/, .cache/, src/, Brain/, no secrets).
git add VERSION CHANGELOG.md README.md docs/ launch.sh launch.bat scripts/
git commit -m "release: hermes-agent <ref>; portable-vX.Y.Z"
git tag portable-vX.Y.Z
git push origin main --tags
```

## Rules

- **Never commit** `data/`, `.cache/`, `src/`, or `Brain/` (all gitignored: secrets,
  runtimes, agent source, and the personal vault stay off the public repo).
- **`data/.env` never holds `HERMES_HOME`.** Hermes loads `.env` over the environment,
  and the drive mounts at a different path on every machine. Both launchers strip it and
  re-point `OBSIDIAN_VAULT_PATH` at the drive's `Brain/` on every start (a Linux
  `/run/media/...` value crashed macOS before v1.9.0).
- **Test both launchers** before tagging: `launch.sh` (LF endings, macOS/Linux) and
  `launch.bat` (CRLF endings, Windows). Don't let an editor flip line endings. Keep new
  `.bat` / `.ps1` lines ASCII-only (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI).
- **Subscription logins are per drive.** `[C]` Claude and `[G]` Grok write the drive's own
  OAuth login to `data/auth.json`. Never copy a Mac/PC `auth.json` onto the drive:
  refresh tokens are single-use, so a shared token signs one of the two installs out.
- A clean reinstall is always available: delete `.cache/runtimes/<platform>` and
  `src/hermes-agent`, then run the launcher. It re-downloads the pinned release.

## Portable compatibility patches (since portable-v1.9.0)

`scripts/apply-patches.py` applies three small, idempotent patches to the pinned hermes-agent source so it
runs from an exFAT stick (control socket moved to the temp dir via Hermes' own pointer-file fallback; loop-tick
witness on loopback TCP; tool discovery ignores AppleDouble `._*` files). `launch.sh` runs it on every start.

When you change `hermes_agent_ref`, run it once by hand against the new source:

```bash
.cache/runtimes/<os-arch>/venv/bin/python scripts/apply-patches.py --check src/hermes-agent
```

- `[OK] … already applied` or `[INFO] … not applied yet` (with `--check` the latter exits `2`): fine — the
  launcher applies them on the next start.
- `[WARN] … anchor not found` (exit `2`): upstream changed that code. Re-check whether upstream fixed the exFAT
  problem (then delete that patch entry) or refresh the `old`/`new` snippets in `apply-patches.py`.
