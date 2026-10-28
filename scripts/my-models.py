#!/usr/bin/env python3
"""List every model this drive can use, show which are ready, switch to one.

Launcher entry point: launch.sh -> [M] Switch Model -> [P] My saved models.

Sources (all inside the portable HERMES_HOME, i.e. data/ on the drive):
  config.yaml  `providers:` (named OpenAI-compatible endpoints, e.g. a key_env
               provider or a LAN Ollama box), legacy `custom_providers:`, and
               `model_aliases:`
  auth.json    subscription logins (Claude Pro/Max, SuperGrok) from
               `hermes auth add anthropic --type oauth` / `hermes auth add xai-oauth`
  .env         API keys, checked by NAME only. A key value is never printed.

The switch itself is written by switch-model.py (comment-preserving YAML).

Usage:
  my-models.py --home DATA_DIR --switcher scripts/switch-model.py [--list] [--select N]
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# Subscription models offered when the drive holds the matching OAuth login.
# (label, provider id, model id, credential-pool key in auth.json)
SUBSCRIPTION_MODELS = [
    ("Claude Opus 5.5 (Pro/Max subscription)", "anthropic", "claude-opus-5-5", "anthropic"),
    ("Claude Opus 4.8 (Pro/Max subscription)", "anthropic", "claude-opus-4-8", "anthropic"),
    ("Grok 4.7 (SuperGrok subscription)", "xai-oauth", "grok-4.7", "xai-oauth"),
]
SIGN_IN_HINT = {"anthropic": "[M] then [C] to sign in", "xai-oauth": "[M] then [G] to sign in"}


def load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    text = path.read_text()
    try:
        import yaml  # PyYAML ships with hermes-agent
        return yaml.safe_load(text) or {}
    except ImportError:
        from ruamel.yaml import YAML
        return YAML(typ="safe").load(text) or {}


def load_env_names(path: Path) -> set:
    """Names of keys that have a non-empty value in .env (values are discarded)."""
    names = set()
    if not path.exists():
        return names
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        if val.strip().strip("'\""):
            names.add(key.strip())
    return names


def oauth_pools(path: Path) -> set:
    """Credential-pool keys that hold at least one OAuth login."""
    try:
        data = json.loads(path.read_text())
    except Exception:
        return set()
    pools = data.get("credential_pool") or {}
    return {
        name for name, entries in pools.items()
        if isinstance(entries, list)
        and any(isinstance(e, dict) and e.get("auth_type") == "oauth" for e in entries)
    }


def key_status(entry: dict, env_names: set) -> tuple:
    """(ready, text) for an endpoint entry: key_env / inline api_key / none."""
    key_env = (entry.get("key_env") or "").strip()
    if entry.get("api_key"):
        return True, "key in config"
    if key_env:
        if key_env in env_names or os.environ.get(key_env):
            return True, f"key {key_env} set"
        return False, f"needs {key_env} in data/.env"
    return True, "no key needed (local / LAN endpoint)"


def build_entries(cfg: dict, env_names: set, signed_in: set) -> list:
    entries = []
    for label, provider, model, pool in SUBSCRIPTION_MODELS:
        ready = pool in signed_in
        entries.append({
            "label": label, "provider": provider, "model": model, "base_url": "",
            "ready": ready, "status": "signed in" if ready else SIGN_IN_HINT[provider],
        })

    seen = set()
    providers = cfg.get("providers") or {}
    if isinstance(providers, dict):
        for name, p in providers.items():
            if not isinstance(p, dict):
                continue
            models = [m for m in (p.get("models") or []) if m] or [p.get("model")]
            ready, status = key_status(p, env_names)
            for model in [m for m in models if m]:
                entries.append({
                    "label": f"{name}: {model}", "provider": f"custom:{name}", "model": model,
                    "base_url": "", "ready": ready, "status": status,
                })
                seen.add((str(p.get("base_url") or "").rstrip("/"), model))

    legacy = cfg.get("custom_providers") or []
    if isinstance(legacy, list):
        for p in legacy:
            if not isinstance(p, dict) or not p.get("name"):
                continue
            name = str(p["name"]).strip().lower().replace(" ", "-")
            model = p.get("model") or p.get("default_model")
            if not model or (str(p.get("base_url") or "").rstrip("/"), model) in seen:
                continue
            ready, status = key_status(p, env_names)
            entries.append({
                "label": f"{name}: {model}", "provider": f"custom:{name}", "model": model,
                "base_url": "", "ready": ready, "status": status,
            })
            seen.add((str(p.get("base_url") or "").rstrip("/"), model))

    aliases = cfg.get("model_aliases") or {}
    if isinstance(aliases, dict):
        for alias, a in aliases.items():
            if not isinstance(a, dict) or not a.get("model"):
                continue
            base = str(a.get("base_url") or "").rstrip("/")
            if (base, a["model"]) in seen:
                continue  # same endpoint + model already listed via providers:
            ready, status = key_status(a, env_names)
            entries.append({
                "label": f"alias '{alias}': {a['model']}", "provider": a.get("provider") or "custom",
                "model": a["model"], "base_url": a.get("base_url") or "", "ready": ready,
                "status": status,
            })
    return entries


def print_table(entries: list, cur_provider: str, cur_model: str) -> None:
    print("")
    print("  My saved models (data/config.yaml + subscription logins on this drive)")
    print("  " + "-" * 72)
    for i, e in enumerate(entries, 1):
        mark = "OK" if e["ready"] else "  "
        current = "   <- current" if (e["provider"] == cur_provider and e["model"] == cur_model) else ""
        print(f"  [{i:>2}] [{mark}] {e['label']}")
        print(f"            {e['status']}{current}")
    print("  " + "-" * 72)


def main() -> int:
    ap = argparse.ArgumentParser(description="List every model this drive can use and switch to one.")
    ap.add_argument("--home", required=True, help="portable HERMES_HOME (data/)")
    ap.add_argument("--switcher", required=True, help="path to switch-model.py")
    ap.add_argument("--list", action="store_true", help="print the table and exit")
    ap.add_argument("--select", type=int, default=None, help="pick entry N without prompting")
    a = ap.parse_args()

    home = Path(a.home)
    cfg = load_yaml(home / "config.yaml")
    model_cfg = cfg.get("model")
    if not isinstance(model_cfg, dict):
        model_cfg = {}
    cur_provider = str(model_cfg.get("provider") or "")
    cur_model = str(model_cfg.get("default") or model_cfg.get("model") or "")

    entries = build_entries(cfg, load_env_names(home / ".env"), oauth_pools(home / "auth.json"))
    if not entries:
        print("No saved models yet. Use [C]/[G] to sign in, or add providers to data/config.yaml.")
        return 1
    print_table(entries, cur_provider, cur_model)
    if a.list:
        return 0

    choice = a.select
    if choice is None:
        try:
            raw = input("  Switch to number (Enter = cancel): ").strip()
        except EOFError:
            raw = ""
        if not raw:
            print("  Unchanged.")
            return 0
        if not raw.isdigit():
            print("  Not a number — unchanged.")
            return 1
        choice = int(raw)
    if not 1 <= choice <= len(entries):
        print(f"  {choice} is not on the list — unchanged.")
        return 1

    e = entries[choice - 1]
    if not e["ready"]:
        print(f"  Not ready: {e['label']} — {e['status']}. Unchanged.")
        return 1
    cmd = [sys.executable, a.switcher, "--config", str(home / "config.yaml"), "--env",
           str(home / ".env"), "--provider", e["provider"], "--model", e["model"],
           "--base-url", e["base_url"]]
    rc = subprocess.call(cmd)
    if rc == 0:
        print(f"  Switched to {e['label']}.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
