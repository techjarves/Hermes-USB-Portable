#!/usr/bin/env python3
"""Hermes Portable - compatibility patches for the pinned hermes-agent source.

Why: the portable drive is exFAT so one stick works on macOS, Linux and
Windows. exFAT cannot hold Unix-domain socket nodes - bind() fails with
EOPNOTSUPP ("[Errno 45] Operation not supported" on macOS) or EPERM (Linux).
Hermes Agent v0.22 made the gateway's control socket mandatory ("gateway
session bootstrap control listener unavailable") and binds it at
$HERMES_HOME/gateway.sock - on the drive - so every chat died before a single
message was sent. Hermes already knows how to put that socket in the temp dir
behind a private $HERMES_HOME/gateway.sock.path pointer (it does so when the
home path is too long for sun_path); these patches take the same, already
supported route when the home directory cannot hold a socket.

Patches (each carries a "hermes-portable patch:" marker in the patched file):
  exfat-control-socket  gateway/control_socket.py   resolve_server_socket_path()
  exfat-loop-tick       gateway/shutdown_watchdog.py loop-tick witness falls back
                                                     to loopback TCP (as on Windows)
  appledouble-tools     tools/registry.py           tool discovery skips the binary
                                                     "._<name>" twins macOS writes on
                                                     exFAT (UnicodeDecodeError otherwise)

Idempotent: a patch whose marker is already present is skipped, so launch.sh
runs this on every start (two small file reads). Windows uses named pipes and
never reaches these code paths, so the patched tree is safe there too.

Usage: apply-patches.py [--quiet] [--check] <src/hermes-agent>
Exit:  0 all patches present - 1 usage/IO error - 2 an anchor was not found
       (the pinned release changed: refresh the patch, or drop it if upstream
       fixed the issue).
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

PATCHES = [
    {
        "id": "exfat-control-socket",
        "file": "gateway/control_socket.py",
        "old": '''def resolve_server_socket_path(home: Path) -> tuple[Path, Optional[Path]]:
    """Return ``(bind_path, pointer_file)``; pointer_file is set only for the temp-dir fallback."""
    direct = Path(home) / _SOCKET_FILENAME
    return (direct, None) if _fits_sun_path(direct) else (_fallback_socket_path(home), Path(home) / _POINTER_FILENAME)
''',
        "new": '''def _dir_holds_unix_sockets(directory: Path) -> bool:  # hermes-portable patch: exfat-control-socket
    """False when ``directory`` sits on a filesystem that cannot create socket nodes (exFAT/FAT USB
    drives: bind() fails with EOPNOTSUPP on macOS, EPERM on Linux). Probes with a PID-named socket
    no longer than ``gateway.sock`` (so it fits wherever the direct path fits) and removes it."""
    probe = Path(directory) / f".gwp{os.getpid()}"
    if not _fits_sun_path(probe):
        return True  # the caller's own sun_path check decides
    with contextlib.suppress(OSError):
        probe.unlink()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(probe))
    except OSError:
        return False
    finally:
        with contextlib.suppress(OSError):
            probe.unlink()
    return True


def resolve_server_socket_path(home: Path) -> tuple[Path, Optional[Path]]:
    """Return ``(bind_path, pointer_file)``; pointer_file is set only for the temp-dir fallback
    (home path too long for sun_path, or home on a filesystem without socket nodes)."""
    direct = Path(home) / _SOCKET_FILENAME
    if _fits_sun_path(direct) and _dir_holds_unix_sockets(Path(home)):
        return (direct, None)
    return (_fallback_socket_path(home), Path(home) / _POINTER_FILENAME)
''',
    },
    {
        "id": "exfat-loop-tick",
        "file": "gateway/shutdown_watchdog.py",
        "old": '''            _sweep_stale_tick_sockets(tick_socket_path)
            tick_server = await asyncio.start_unix_server(_tick_socket_handler,
                                                          path=str(tick_socket_path))
        else:
            tick_server = await asyncio.start_server(_tick_socket_handler, host="127.0.0.1", port=0)
''',
        "new": '''            _sweep_stale_tick_sockets(tick_socket_path)
            try:  # hermes-portable patch: exfat-loop-tick
                tick_server = await asyncio.start_unix_server(_tick_socket_handler,
                                                              path=str(tick_socket_path))
            except OSError:  # HERMES_HOME on exFAT/FAT (no socket nodes): use loopback below
                tick_server = tick_socket_path = None
        if tick_server is None:
            tick_server = await asyncio.start_server(_tick_socket_handler, host="127.0.0.1", port=0)
''',
    },
    {
        "id": "appledouble-tools",
        "file": "tools/registry.py",
        "old": '''    candidates = list(tools_path.glob("*.py")) + list(tools_path.glob("*/tool.py"))
    return sorted(candidates)
''',
        "new": '''    candidates = list(tools_path.glob("*.py")) + list(tools_path.glob("*/tool.py"))
    # hermes-portable patch: appledouble-tools - macOS keeps extended attributes on exFAT/FAT
    # drives in binary "._<name>" twins; reading tools/._foo.py as source crashed tool discovery.
    return sorted(p for p in candidates if not p.name.startswith("._"))
''',
    },
]

MARKER = "hermes-portable patch: "


def _write_atomic(path: Path, text: str) -> None:
    mode = path.stat().st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply Hermes Portable compatibility patches (idempotent).")
    parser.add_argument("src", help="path to src/hermes-agent")
    parser.add_argument("--quiet", action="store_true", help="print only changes and problems")
    parser.add_argument("--check", action="store_true", help="report only; change nothing (exit 2 if any patch is missing)")
    args = parser.parse_args()

    src = Path(args.src)
    if not (src / "pyproject.toml").is_file():
        print(f"[ERROR] Not a hermes-agent source tree: {src}")
        return 1

    status = 0
    for patch in PATCHES:
        target = src / patch["file"]
        tag = MARKER + patch["id"]
        try:
            text = target.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"[ERROR] {patch['id']}: cannot read {patch['file']}: {exc}")
            return 1
        if tag in text:
            if not args.quiet:
                print(f"[OK]    {patch['id']}: already applied")
            continue
        if text.count(patch["old"]) != 1:
            print(f"[WARN]  {patch['id']}: anchor not found in {patch['file']} - this Hermes release "
                  f"changed that code; refresh scripts/apply-patches.py (or drop the patch if upstream fixed it).")
            status = 2
            continue
        if args.check:
            print(f"[INFO]  {patch['id']}: not applied yet")
            status = 2
            continue
        _write_atomic(target, text.replace(patch["old"], patch["new"], 1))
        # macOS writes an AppleDouble "._<name>" twin next to files it creates on exFAT; drop it.
        try:
            (target.parent / ("._" + target.name)).unlink()
        except OSError:
            pass
        print(f"[OK]    {patch['id']}: applied to {patch['file']}")
    return status


if __name__ == "__main__":
    sys.exit(main())
