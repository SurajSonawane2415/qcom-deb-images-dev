#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Load boards/<name>.yaml and prepare debos -t options / generated overlay."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    sys.stderr.write(
        "ERROR: PyYAML is required (apt install python3-yaml)\n"
    )
    raise SystemExit(1) from exc

REPO_ROOT = Path(__file__).resolve().parents[1]
BOARDS_DIR = REPO_ROOT / "boards"
GENERATED_OVERLAY = REPO_ROOT / "debos-recipes" / "overlays" / "generated"
LOCAL_DEB_DST = REPO_ROOT / "debos-recipes" / "local-debs"


def load_board(name: str) -> dict:
    path = BOARDS_DIR / f"{name}.yaml"
    if not path.is_file():
        sys.stderr.write(f"ERROR: board profile not found: {path}\n")
        sys.stderr.write("Available boards:\n")
        for p in sorted(BOARDS_DIR.glob("*.yaml")):
            sys.stderr.write(f"  - {p.stem}\n")
        raise SystemExit(1)
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: {path} must be a mapping")
    for key in ("name", "hostname", "username", "password"):
        if key not in data:
            raise SystemExit(f"ERROR: {path} missing required key: {key}")
    return data


def bool_str(value: bool) -> str:
    return "true" if value else "false"


def debos_opts(board: dict) -> list[str]:
    overlays = list(board.get("overlays") or ["qsc-deb-releases"])
    if "generated" not in overlays:
        overlays.append("generated")

    kernel = board.get("kernel") or {}
    image = board.get("image") or {}
    vnc = board.get("vnc") or {}
    packages = board.get("packages") or []

    opts = [
        f"-t hostname:{board['hostname']}",
        f"-t username:{board['username']}",
        f"-t password:{board['password']}",
        f"-t rootpassword:{board.get('root_password', 'root')}",
        f"-t forcepasswordchange:{bool_str(bool(board.get('force_password_change', False)))}",
        f"-t overlays:{','.join(overlays)}",
        f"-t xfcedesktop:{bool_str(bool(board.get('xfcedesktop', False)))}",
        f"-t gnomedesktop:{bool_str(bool(board.get('gnomedesktop', False)))}",
        f"-t vnc:{bool_str(bool(vnc.get('enabled', False)))}",
        f"-t vncpassword:{vnc.get('password', board['password'])}",
        f"-t vncgeometry:{vnc.get('geometry', '1280x800')}",
        f"-t vncdisplay:{vnc.get('display', 1)}",
        f"-t vnclocalhost:{bool_str(bool(vnc.get('localhost', False)))}",
        f"-t localdebs:{kernel.get('localdebs', 'none')}",
        f"-t kernelpackage:{kernel.get('package', 'linux-image-arm64')}",
        f"-t requireddtb:{kernel.get('required_dtb', 'none')}",
        f"-t dtb:{image.get('dtb', 'firmware')}",
    ]
    if packages:
        opts.append(f"-t extrapackages:{','.join(packages)}")
    else:
        opts.append("-t extrapackages:none")
    return opts


def write_generated_overlay(board: dict) -> None:
    if GENERATED_OVERLAY.exists():
        try:
            shutil.rmtree(GENERATED_OVERLAY)
        except PermissionError as exc:
            raise SystemExit(
                f"ERROR: cannot remove {GENERATED_OVERLAY} ({exc}).\n"
                "A previous 'sudo make' likely created root-owned files.\n"
                f"Fix with: sudo chown -R \"$USER:$USER\" {GENERATED_OVERLAY}"
            ) from exc
    sudoers = GENERATED_OVERLAY / "etc" / "sudoers.d"
    sudoers.mkdir(parents=True, exist_ok=True)
    user = board["username"]
    (sudoers / "user").write_text(f"{user} ALL=(ALL) ALL\n", encoding="utf-8")
    os.chmod(sudoers / "user", 0o440)

    meta = GENERATED_OVERLAY / "etc" / "vicharak"
    meta.mkdir(parents=True, exist_ok=True)
    (meta / "board").write_text(f"{board['name']}\n", encoding="utf-8")
    (meta / "hostname").write_text(f"{board['hostname']}\n", encoding="utf-8")


def sync_local_debs(board: dict) -> None:
    kernel = board.get("kernel") or {}
    localdebs = kernel.get("localdebs", "none")
    src = kernel.get("localdeb_src")
    if localdebs in (None, "none") or not src:
        return
    src_path = (REPO_ROOT / src).resolve()
    if not src_path.is_dir():
        raise SystemExit(f"ERROR: localdeb_src not found: {src_path}")
    LOCAL_DEB_DST.mkdir(parents=True, exist_ok=True)
    debs = sorted(src_path.glob("*.deb"))
    if not debs:
        raise SystemExit(f"ERROR: no .deb files in {src_path}")
    for deb in debs:
        shutil.copy2(deb, LOCAL_DEB_DST / deb.name)
    images = list(LOCAL_DEB_DST.glob("linux-image-*.deb"))
    if not images:
        raise SystemExit(f"ERROR: no linux-image-*.deb synced from {src_path}")
    if len(images) != 1:
        names = ", ".join(p.name for p in images)
        raise SystemExit(
            f"ERROR: expected exactly one linux-image-*.deb, found {len(images)}: {names}"
        )
    print(f"Synced {len(debs)} deb(s) from {src_path} → {LOCAL_DEB_DST}")


def cmd_debos_opts(name: str) -> None:
    print(" ".join(debos_opts(load_board(name))))


def cmd_prepare(name: str) -> None:
    board = load_board(name)
    write_generated_overlay(board)
    sync_local_debs(board)
    print(f"Prepared board profile: {name}")


def cmd_ci_env(name: str) -> None:
    board = load_board(name)
    ci = board.get("ci") or {}
    hostname = ci.get("hostname", board["hostname"])
    user = ci.get("login_user", board["username"])
    password = ci.get("login_password", board["password"])
    force = "1" if board.get("force_password_change", False) else "0"
    print(f"export BOARD_HOSTNAME={hostname}")
    print(f"export BOARD_USERNAME={user}")
    print(f"export BOARD_PASSWORD={password}")
    print(f"export BOARD_FORCE_PASSWORD_CHANGE={force}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("debos-opts", "prepare", "ci-env", "list"),
    )
    parser.add_argument("board", nargs="?", help="board profile name")
    args = parser.parse_args()

    if args.command == "list":
        for p in sorted(BOARDS_DIR.glob("*.yaml")):
            print(p.stem)
        return

    if not args.board:
        parser.error("board name required")

    if args.command == "debos-opts":
        cmd_debos_opts(args.board)
    elif args.command == "prepare":
        cmd_prepare(args.board)
    elif args.command == "ci-env":
        cmd_ci_env(args.board)


if __name__ == "__main__":
    main()
