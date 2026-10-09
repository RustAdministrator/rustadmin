#!/usr/bin/env python3
"""Check whether release binaries contain software H.264/H.265 encoders.

RustAdmin distributes hardware-only H.264/H.265 encoding. hwcodec accepts
libx264/libx265 whenever the linked FFmpeg provides them, so release
packaging must show that no such encoder was linked. The markers are
encoder-only: FFmpeg's H.264 decoder also mentions "x264 - core" while
parsing SEI data, so that string is deliberately not used.

Public usage is strict and fails on a detected software encoder:

    verify_hardware_only_h26x.py PATH...

Private/custom usage explicitly accepts detected encoders with a strong
distribution warning:

    verify_hardware_only_h26x.py --private-build PATH...

Self-test:

    verify_hardware_only_h26x.py --self-test

PATH may be a binary (.a, .so, .dll, .exe, .dylib) or a .zip/.apk/.aar archive.
"""

import sys
import tempfile
import zipfile
from pathlib import Path

MARKERS = {
    b"ff_libx264_encoder": "FFmpeg libx264 encoder symbol",
    b"ff_libx264rgb_encoder": "FFmpeg libx264rgb encoder symbol",
    b"ff_libx265_encoder": "FFmpeg libx265 encoder symbol",
    b"ff_libopenh264_encoder": "FFmpeg OpenH264 encoder symbol",
    b"ff_libkvazaar_encoder": "FFmpeg Kvazaar encoder symbol",
    b"libx264 H.264 / AVC": "FFmpeg libx264 encoder name",
    b"libx265 H.265 / HEVC": "FFmpeg libx265 encoder name",
    b"H.264/MPEG-4 AVC codec - Copy": "x264 library banner",
    b"H.265/HEVC codec - Copyright": "x265 library banner",
}
BINARY_SUFFIXES = {".a", ".so", ".dll", ".exe", ".dylib", ".lib"}
ARCHIVE_SUFFIXES = {".zip", ".apk", ".aar"}


def scan_bytes(data: bytes) -> list:
    return [description for marker, description in MARKERS.items() if marker in data]


def scan_path(path: Path) -> list:
    """Returns (location, description) findings and the number of scanned binaries."""
    findings = []
    scanned = 0
    if path.suffix.lower() in ARCHIVE_SUFFIXES:
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if Path(member.filename).suffix.lower() not in BINARY_SUFFIXES:
                    continue
                scanned += 1
                for description in scan_bytes(archive.read(member)):
                    findings.append((f"{path}!{member.filename}", description))
    else:
        scanned += 1
        for description in scan_bytes(path.read_bytes()):
            findings.append((str(path), description))
    return findings, scanned


def verify(paths: list, private_build: bool = False) -> int:
    all_findings = []
    total = 0
    for path in paths:
        if not path.is_file():
            print(f"error: not a file: {path}", file=sys.stderr)
            return 2
        try:
            findings, scanned = scan_path(path)
        except (OSError, KeyError, RuntimeError, zipfile.BadZipFile) as error:
            print(f"error: could not scan {path}: {error}", file=sys.stderr)
            return 2
        total += scanned
        all_findings.extend(findings)
    if total == 0:
        print("error: no binaries were scanned", file=sys.stderr)
        return 2
    for location, description in all_findings:
        print(f"software H.26x encoder found: {location}: {description}")
    if all_findings:
        if private_build:
            print(
                "WARNING: software H.264/H.265 encoders were detected. "
                "This is a private/custom build only and is not approved for "
                "public distribution. Review applicable implementation "
                "licenses and patent obligations before sharing it.",
                file=sys.stderr,
            )
            return 0
        return 1
    print(f"hardware-only H.26x encoding verified in {total} binaries")
    return 0


def self_test() -> int:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        clean = root / "clean.so"
        clean.write_bytes(b"\0ff_h264_mediacodec_encoder\0x264 - core %d\0")
        dirty = root / "dirty.dll"
        dirty.write_bytes(b"\0libx265 H.265 / HEVC\0")
        package = root / "package.zip"
        with zipfile.ZipFile(package, "w") as archive:
            archive.writestr("lib/arm64-v8a/librustdesk.so", b"clean")
            archive.writestr("lib/arm64-v8a/libavcodec.so", b"..ff_libx264_encoder..")
            archive.writestr("assets/readme.txt", b"ff_libx264_encoder")
        invalid_package = root / "invalid.zip"
        invalid_package.write_bytes(b"not a zip archive")
        assert verify([clean]) == 0
        assert verify([dirty]) == 1
        assert verify([dirty], private_build=True) == 0
        assert verify([invalid_package], private_build=True) == 2
        findings, scanned = scan_path(package)
        assert scanned == 2, scanned
        assert findings == [(f"{package}!lib/arm64-v8a/libavcodec.so",
                             "FFmpeg libx264 encoder symbol")], findings
    print("self-test passed")
    return 0


def main() -> int:
    arguments = sys.argv[1:]
    if arguments == ["--self-test"]:
        return self_test()
    private_build = False
    if arguments and arguments[0] == "--private-build":
        private_build = True
        arguments = arguments[1:]
    if not arguments or any(argument.startswith("-") for argument in arguments):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return verify([Path(argument) for argument in arguments], private_build=private_build)


if __name__ == "__main__":
    sys.exit(main())
