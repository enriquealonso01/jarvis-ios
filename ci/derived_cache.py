#!/usr/bin/env python3
"""Lets a build restored from the cache be reused by a fresh checkout.

Xcode decides what to rebuild from file times. A fresh checkout gives every source file a new
time, and a cache archive can round the times of the build's own files, so a restored
DerivedData would be rebuilt from scratch. This script closes both gaps:

  record   after a build: write, inside DerivedData, the git blob id and time of every tracked
           source file and directory, and the exact time of every file the build produced.
  restore  after the cache is restored: give every source file whose content is unchanged its
           recorded time back, and every build file its exact time. A file that changed, or is
           new, keeps its checkout time, so Xcode sees exactly the files that really changed.

  python3 ci/derived_cache.py record  DerivedData
  python3 ci/derived_cache.py restore DerivedData

Neither command fails the build: with no record to read, `restore` says so and the build is a
clean one.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

RECORD_NAME = "source-times.json"
VERSION = 1
# A link's own time, where the platform can set it (macOS and Linux can).
NO_FOLLOW = os.utime in os.supports_follow_symlinks


def tracked_files(root: Path) -> dict[str, str]:
    """Path -> git blob id for every tracked regular file (the index of a fresh checkout)."""
    out = subprocess.run(
        ["git", "ls-files", "-s", "-z"], cwd=root, check=True, capture_output=True
    ).stdout.decode("utf-8", "surrogateescape")
    files: dict[str, str] = {}
    for entry in out.split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        mode, blob, stage = meta.split(" ")
        if stage == "0" and mode.startswith("100"):  # regular files only: no links, no submodules
            files[path] = blob
    return files


def directory_shapes(files: dict[str, str]) -> dict[str, str]:
    """Directory -> a stamp of what it directly holds, so an unchanged directory is recognisable."""
    children: dict[str, list[str]] = {}
    for path, blob in files.items():
        parent = os.path.dirname(path)
        children.setdefault(parent, []).append(f"{os.path.basename(path)}={blob}")
        # every ancestor lists the child directory it holds
        while parent:
            grand = os.path.dirname(parent)
            marker = f"{os.path.basename(parent)}/"
            held = children.setdefault(grand, [])
            if marker not in held:
                held.append(marker)
            parent = grand
    return {d: "|".join(sorted(names)) for d, names in children.items() if d}


def record(root: Path, derived: Path) -> int:
    files = tracked_files(root)
    source = {}
    for path, blob in files.items():
        try:
            source[path] = [blob, os.stat(root / path).st_mtime_ns]
        except OSError:
            continue
    dirs = {}
    for path, shape in directory_shapes(files).items():
        try:
            dirs[path] = [shape, os.stat(root / path).st_mtime_ns]
        except OSError:
            continue
    built = {}
    for folder, _, names in os.walk(derived):
        for name in [*names, "."]:
            full = os.path.join(folder, name)
            try:
                built[os.path.relpath(full, derived)] = os.lstat(full).st_mtime_ns
            except OSError:
                continue
    derived.mkdir(parents=True, exist_ok=True)
    (derived / RECORD_NAME).write_text(
        json.dumps({"version": VERSION, "source": source, "dirs": dirs, "built": built})
    )
    print(f"recorded {len(source)} source files, {len(dirs)} directories, {len(built)} build files")
    return 0


def restore(root: Path, derived: Path) -> int:
    try:
        data = json.loads((derived / RECORD_NAME).read_text())
        if data.get("version") != VERSION:
            raise ValueError("unknown record version")
    except (OSError, ValueError) as error:
        print(f"no usable record in {derived} ({error}): nothing restored, this is a clean build")
        return 0

    # The build's own files first: exact times, in case the archive rounded them.
    exact = 0
    for rel, mtime in data.get("built", {}).items():
        full = derived / rel
        try:
            if os.lstat(full).st_mtime_ns != mtime:
                os.utime(full, ns=(mtime, mtime), follow_symlinks=not NO_FOLLOW)
                exact += 1
        except OSError:
            continue

    files = tracked_files(root)
    kept = changed = 0
    for path, (blob, mtime) in data.get("source", {}).items():
        if files.get(path) != blob:
            changed += 1
            continue
        try:
            os.utime(root / path, ns=(mtime, mtime))
            kept += 1
        except OSError:
            changed += 1
    new = len(set(files) - set(data.get("source", {})))

    # Directories last: writing a file's time does not touch its directory, and a directory keeps
    # its recorded time only when what it directly holds is unchanged.
    shapes = directory_shapes(files)
    same_dirs = 0
    for path, (shape, mtime) in data.get("dirs", {}).items():
        if shapes.get(path) != shape:
            continue
        try:
            os.utime(root / path, ns=(mtime, mtime))
            same_dirs += 1
        except OSError:
            continue

    print(
        f"restored the times of {kept} unchanged source files and {same_dirs} directories; "
        f"{changed} changed or removed and {new} new files keep their checkout time; "
        f"{exact} build files had their exact time put back"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("record", "restore"):
        print(__doc__, file=sys.stderr)
        return 2
    root = Path.cwd()
    derived = Path(argv[2])
    return record(root, derived) if argv[1] == "record" else restore(root, derived)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
