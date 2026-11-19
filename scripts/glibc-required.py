#!/usr/bin/env python3
"""打印目录里所有 ELF 文件要求的最低 GLIBC 版本上限。

发行包里的 `GLIBC_MAX` 以前是写死的 2.31，但实际只用到 2.14～2.28，结果把
Debian 10（2.28）这类完全能跑的机器挡在门外。构建时实测，写进去的才是真的。
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

GLIBC_RE = re.compile(r"Name: GLIBC_([0-9]+(?:\.[0-9]+)+)")


def version_key(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def elf_glibc_requirement(path: Path) -> str | None:
    try:
        result = subprocess.run(
            ["readelf", "--version-info", str(path)],
            capture_output=True, text=True, check=False, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    versions = GLIBC_RE.findall(result.stdout)
    if not versions:
        return None
    return max(versions, key=version_key)


def directory_max(root: Path) -> tuple[str, int]:
    highest = "0.0"
    count = 0
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        needed = elf_glibc_requirement(path)
        if needed is None:
            continue
        count += 1
        if version_key(needed) > version_key(highest):
            highest = needed
    return highest, count


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: glibc-required.py <package-directory>", file=sys.stderr)
        return 64
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 64
    highest, count = directory_max(root)
    if count == 0:
        print("no ELF files found", file=sys.stderr)
        return 1
    print(highest)
    print(f"scanned {count} ELF files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
