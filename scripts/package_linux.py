#!/usr/bin/env python3
import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape
from pathlib import Path


DEB_DEPENDS = [
    "libgtk-3-0",
    "libxcb-randr0",
    "libxdo3 | libxdo4",
    "libxfixes3",
    "libxcb-shape0",
    "libxcb-xfixes0",
    "libasound2",
    "libsystemd0",
    "curl",
    "libva2",
    "libva-drm2",
    "libva-x11-2",
    "libgstreamer-plugins-base1.0-0",
    "libpam0g",
    "gstreamer1.0-pipewire",
]


def deb_arch() -> str:
    if os.environ.get("DEB_ARCH"):
        return os.environ["DEB_ARCH"]
    machine = platform.machine().lower()
    return {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "armv7l": "armhf",
        "armv6l": "armhf",
    }.get(machine, machine)


def copy_file(src: Path, dst: Path, mode: int | None = None) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if mode is not None:
        dst.chmod(mode)


def copy_tree_contents(src: Path, dst: Path) -> None:
    if not src.is_dir():
        raise SystemExit(f"Bundle directory was not found: {src}")
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target, symlinks=True)
        else:
            shutil.copy2(item, target, follow_symlinks=False)


def normalize_bundle_executable(bundle_root: Path) -> None:
    rustadmin_bin = bundle_root / "rustadmin"
    rustdesk_bin = bundle_root / "rustdesk"
    if rustadmin_bin.exists():
        rustadmin_bin.chmod(rustadmin_bin.stat().st_mode | 0o111)
        if rustdesk_bin.exists():
            rustdesk_bin.unlink()
        return
    if rustdesk_bin.exists():
        rustdesk_bin.rename(rustadmin_bin)
        rustadmin_bin.chmod(rustadmin_bin.stat().st_mode | 0o111)
        return
    raise SystemExit(f"Linux bundle contains neither {rustadmin_bin.name} nor {rustdesk_bin.name}")


def write_control(path: Path, args: argparse.Namespace, arch: str) -> None:
    depends = list(DEB_DEPENDS)
    if arch == "armhf":
        depends.append("libatomic1")

    control = f"""Package: {args.package_name}
Section: net
Priority: optional
Version: {args.version}
Architecture: {arch}
Maintainer: {args.maintainer}
Homepage: {args.homepage}
Depends: {", ".join(depends)}
Recommends: libayatana-appindicator3-1
Conflicts: rustdesk
Replaces: rustdesk
Description: {args.summary}
 {args.description}
"""
    path.write_text(control, encoding="utf-8")


def write_copyright(path: Path, args: argparse.Namespace) -> None:
    text = f"""Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: RustAdmin
Source: {args.homepage}

Files: *
Copyright: RustAdmin contributors
License: AGPL-3.0-only
 This package is licensed under the GNU Affero General Public License,
 version 3 only.
 .
 On Debian systems, the complete text of the GNU Affero General Public
 License version 3 can be found in /usr/share/common-licenses/AGPL-3.
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_metainfo(path: Path, args: argparse.Namespace) -> None:
    component_id = escape(args.metainfo_id)
    desktop_id = escape(args.desktop_id)
    homepage = escape(args.homepage)
    summary = escape(args.summary.rstrip("."))
    description = escape(args.description)
    name = escape(args.display_name)
    text = f"""<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>{component_id}</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>AGPL-3.0-only</project_license>
  <developer id="io.github.rustadministrator">
    <name>RustAdministrator</name>
  </developer>
  <name>{name}</name>
  <summary>{summary}</summary>
  <description>
    <p>{description}</p>
  </description>
  <launchable type="desktop-id">{desktop_id}</launchable>
  <categories>
    <category>Network</category>
    <category>RemoteAccess</category>
  </categories>
  <url type="homepage">{homepage}</url>
  <content_rating type="oars-1.1"/>
</component>
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_md5sums(package_root: Path) -> None:
    lines: list[str] = []
    for file in sorted(package_root.rglob("*")):
        if not file.is_file() or "DEBIAN" in file.relative_to(package_root).parts:
            continue
        digest = hashlib.md5(file.read_bytes()).hexdigest()
        rel = file.relative_to(package_root).as_posix()
        lines.append(f"{digest}  /{rel}")
    (package_root / "DEBIAN" / "md5sums").write_text("\n".join(lines) + "\n", encoding="utf-8")


def normalize_permissions(package_root: Path) -> None:
    package_root.chmod(0o755)
    for path in package_root.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir():
            path.chmod(0o755)
        elif path.is_file():
            mode = path.stat().st_mode
            if mode & 0o111:
                path.chmod(0o755)
            else:
                path.chmod(0o644)


def build_deb(args: argparse.Namespace) -> Path:
    repo_root = args.repo_root.resolve()
    bundle_dir = args.bundle.resolve()
    output_dir = args.output.resolve()
    res_dir = repo_root / "res"
    arch = deb_arch()
    output_name = args.output_name or f"{args.package_name}_{args.version}_{arch}.deb"
    output_path = output_dir / output_name

    with tempfile.TemporaryDirectory(prefix="rustadmin-deb-") as tmp:
        root = Path(tmp) / "pkg"
        debian_dir = root / "DEBIAN"
        debian_dir.mkdir(parents=True)

        copy_tree_contents(bundle_dir, root / "usr/share/rustadmin")
        normalize_bundle_executable(root / "usr/share/rustadmin")
        copy_file(res_dir / "rustadmin.service", root / "usr/share/rustadmin/files/systemd/rustadmin.service")
        copy_file(res_dir / "128x128@2x.png", root / "usr/share/icons/hicolor/256x256/apps/rustadmin.png")
        copy_file(res_dir / "scalable.svg", root / "usr/share/icons/hicolor/scalable/apps/rustadmin.svg")
        copy_file(res_dir / "rustadmin.desktop", root / "usr/share/applications/rustadmin.desktop")
        copy_file(res_dir / "rustadmin-link.desktop", root / "usr/share/applications/rustadmin-link.desktop")
        copy_file(res_dir / "startwm.sh", root / "etc/rustadmin/startwm.sh")
        copy_file(res_dir / "xorg.conf", root / "etc/rustadmin/xorg.conf")
        copy_file(res_dir / "pam.d/rustadmin.debian", root / "etc/pam.d/rustadmin")
        write_copyright(root / f"usr/share/doc/{args.package_name}/copyright", args)
        write_metainfo(root / f"usr/share/metainfo/{args.metainfo_id}.metainfo.xml", args)

        polkit = root / "usr/share/rustadmin/files/polkit"
        polkit.parent.mkdir(parents=True, exist_ok=True)
        polkit.write_text("#!/bin/sh\n", encoding="utf-8")
        polkit.chmod(0o755)

        for script in ["preinst", "prerm", "postinst", "postrm"]:
            copy_file(res_dir / "DEBIAN" / script, debian_dir / script, 0o755)
        write_control(debian_dir / "control", args, arch)
        normalize_permissions(root)
        write_md5sums(root)

        output_dir.mkdir(parents=True, exist_ok=True)
        if output_path.exists():
            output_path.unlink()
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(root), str(output_path)], check=True)

    return output_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package RustAdmin Linux build outputs.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    deb = subparsers.add_parser("deb", help="Build a Debian package from a Flutter Linux bundle.")
    deb.add_argument("--repo-root", type=Path, required=True)
    deb.add_argument("--bundle", type=Path, required=True)
    deb.add_argument("--output", type=Path, required=True)
    deb.add_argument("--version", required=True)
    deb.add_argument("--package-name", default="rustadmin")
    deb.add_argument("--output-name")
    deb.add_argument("--maintainer", default="rustadmin <info@rustadmin.local>")
    deb.add_argument("--homepage", default="https://github.com/RustAdministrator/rustadmin")
    deb.add_argument("--summary", default="RustAdmin remote desktop client.")
    deb.add_argument(
        "--description",
        default=(
            "RustAdmin is a remote desktop administration client based on RustDesk, "
            "with attended access, file transfer, and Linux background service support."
        ),
    )
    deb.add_argument("--display-name", default="RustAdmin")
    deb.add_argument("--metainfo-id", default="io.github.rustadministrator.rustadmin")
    deb.add_argument("--desktop-id", default="rustadmin.desktop")

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "deb":
        path = build_deb(args)
        print("Debian package:")
        print(path)
        return 0
    raise SystemExit(f"Unknown command: {args.command}")


if __name__ == "__main__":
    sys.exit(main())
