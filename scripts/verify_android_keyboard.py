#!/usr/bin/env python3
"""Run the existing Flutter and Android JVM suites without changing dependencies."""

import argparse
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    flutter = args.flutter.resolve(strict=True)
    commands = [
        ([str(flutter), "test", "--no-pub"], root / "flutter"),
        (
            [str(root / "flutter/android/gradlew"), ":app:testDebugUnitTest",
             "--offline", "--no-daemon", "--console=plain", "--max-workers=2"],
            root / "flutter/android",
        ),
    ]
    for argv, cwd in commands:
        print(f"Running keyboard validation: {Path(argv[0]).name}", flush=True)
        result = subprocess.run(argv, cwd=cwd, check=False)
        if result.returncode != 0:
            return result.returncode if result.returncode > 0 else 1
    print("Android keyboard validation passed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
