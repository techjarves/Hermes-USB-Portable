# Hermes Dashboard (web UI)

A browser dashboard for managing Hermes — model/provider config, API keys,
sessions, and an in-browser chat — served locally by hermes-agent (FastAPI
backend + a pre-built Vite/React single-page app).

## How to open it

1. Launch Hermes (`./launch.sh`).
2. Press **`D`** → **Open Dashboard**.
3. The launcher starts the server in the background and **waits until it's
   actually listening** before opening your browser at
   **http://127.0.0.1:9139**. The **first launch can take ~60-90s** (plugin
   discovery loads off the USB); later launches are faster, and if it's already
   running the browser re-opens instantly.
4. The server keeps running in the background. Stop it any time with
   **`hermes dashboard --stop`**.

> The wait-for-ready step matters: earlier versions opened the browser
> immediately, so it landed on a "connection refused" page during the slow cold
> start and looked broken. The browser now only opens once the server responds.

Equivalent CLI: `hermes dashboard --skip-build` (start), `hermes dashboard --stop`
(stop), `hermes dashboard --status` (list running).

## What runs, and where it lives on the drive

| Piece | Location | Persisted on USB? |
|-------|----------|-------------------|
| Frontend (built SPA) | `src/hermes-agent/hermes_cli/web_dist/` | ✅ yes (gitignored, physical) |
| Frontend deps (build only) | `src/hermes-agent/web/node_modules/` (~14 MB) | ✅ yes |
| Backend (`fastapi`/`uvicorn`) | the venv, via `hermes-agent[all]` | ✅ reinstalled on every venv rebuild |

The launcher serves the pre-built SPA with **`--skip-build`**, so no Node/npm is
needed at runtime — startup is instant. If the build is ever missing (e.g. a
brand-new drive), the launcher falls back to a one-time `hermes dashboard`
auto-build using the bundled Node.

### Rebuilding the frontend (after a hermes-agent sync)

```sh
cd src/hermes-agent/web
npm install          # only if node_modules was cleared
npm run build        # outputs to ../hermes_cli/web_dist
```

## Security

- Bound to **`127.0.0.1` only** — never reachable from the network by default.
- On loopback, the SPA carries an **ephemeral session token** injected into the
  served HTML at start; every `/api/*` call requires it (a couple of read-only
  endpoints like `/api/status` are public). A request without the token gets
  `401`.
- Do **not** pass `--insecure` (binds to non-loopback) on an untrusted network —
  it would expose your API keys.

## Port

Default **9139** on the drive (Hermes itself defaults to 9119; the portable stays off it so it never collides with a Hermes installed on the host). Set `HERMES_PORTABLE_DASHBOARD_PORT` to change it. Override with `hermes dashboard --port <n>` (and update the
launcher call in `menu_dashboard()` in `launch.sh` if you want a different
default).

## Troubleshooting

- **Blank page / 404s** — the dist is missing; rebuild (see above) or run
  `hermes dashboard` once without `--skip-build`.
- **Port already in use** — `hermes dashboard --stop` to kill a stale instance,
  or start on another port with `--port`.
- **Logs** — dashboard/GUI logs land in `data/logs/` (`gui.log`).
