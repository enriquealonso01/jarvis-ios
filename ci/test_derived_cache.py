"""Tests for ci/derived_cache.py. Run: python3 -m unittest discover -s ci -p 'test_*.py'"""

from __future__ import annotations

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import derived_cache  # noqa: E402

OLD = 1_700_000_000_123_456_700  # a recorded time, finer than a second (100 ns steps suit every file system)
FRESH = 1_800_000_000_000_000_000  # what a fresh checkout gives every file


def git(root: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
        cwd=root, check=True, capture_output=True,
    )


class DerivedCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.derived = self.root / "DerivedData"
        git(self.root, "init", "-q")
        (self.root / ".gitignore").write_text("DerivedData/\n")
        for path, text in (("App/Same.swift", "let a = 1\n"), ("App/Edited.swift", "let b = 1\n"),
                           ("App/Assets/icon.txt", "icon\n"), ("Other/Keep.swift", "let c = 1\n")):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "first")
        (self.derived / "Build").mkdir(parents=True)
        (self.derived / "Build" / "App.o").write_text("object")
        self.stamp_everything(OLD)
        self.addCleanup(self.tmp.cleanup)

    def stamp_everything(self, when: int) -> None:
        for folder, dirs, names in os.walk(self.root):
            if ".git" in dirs:
                dirs.remove(".git")
            for name in [*names, "."]:
                os.utime(os.path.join(folder, name), ns=(when, when))

    def run_tool(self, command: str) -> str:
        out = io.StringIO()
        cwd = os.getcwd()
        os.chdir(self.root)
        try:
            with contextlib.redirect_stdout(out):
                code = derived_cache.main(["derived_cache.py", command, "DerivedData"])
        finally:
            os.chdir(cwd)
        self.assertEqual(code, 0)
        return out.getvalue()

    def mtime(self, path: str) -> int:
        return os.stat(self.root / path).st_mtime_ns

    def fresh_checkout(self) -> None:
        """Every source file and directory gets a new time; the build's files lose their nanoseconds."""
        record = (self.derived / derived_cache.RECORD_NAME).read_text()
        self.stamp_everything(FRESH)
        rounded = OLD // 1_000_000_000 * 1_000_000_000
        for folder, _, names in os.walk(self.derived):
            for name in [*names, "."]:
                os.utime(os.path.join(folder, name), ns=(rounded, rounded))
        (self.derived / derived_cache.RECORD_NAME).write_text(record)

    def test_unchanged_files_get_their_times_back_and_changed_ones_do_not(self) -> None:
        self.assertIn("recorded 5 source files", self.run_tool("record"))
        self.fresh_checkout()
        (self.root / "App/Edited.swift").write_text("let b = 2\n")
        (self.root / "App/New.swift").write_text("let n = 1\n")
        git(self.root, "add", "-A")
        os.utime(self.root / "App/Edited.swift", ns=(FRESH, FRESH))
        os.utime(self.root / "App/New.swift", ns=(FRESH, FRESH))

        out = self.run_tool("restore")

        self.assertEqual(self.mtime("App/Same.swift"), OLD)
        self.assertEqual(self.mtime("Other/Keep.swift"), OLD)
        self.assertEqual(self.mtime("App/Assets/icon.txt"), OLD)
        self.assertEqual(self.mtime("App/Edited.swift"), FRESH)   # changed: Xcode must see it
        self.assertEqual(self.mtime("App/New.swift"), FRESH)      # new: Xcode must see it
        self.assertIn("1 changed or removed and 1 new", out)

    def test_a_directory_keeps_its_time_only_when_what_it_holds_is_unchanged(self) -> None:
        self.run_tool("record")
        self.fresh_checkout()
        (self.root / "App/New.swift").write_text("let n = 1\n")
        git(self.root, "add", "-A")
        os.utime(self.root / "App", ns=(FRESH, FRESH))

        self.run_tool("restore")

        self.assertEqual(self.mtime("Other"), OLD)        # same files as recorded
        self.assertEqual(self.mtime("App/Assets"), OLD)   # same files as recorded
        self.assertEqual(self.mtime("App"), FRESH)        # gained a file

    def test_build_files_get_their_exact_times_back(self) -> None:
        self.run_tool("record")
        self.fresh_checkout()
        self.assertNotEqual(self.mtime("DerivedData/Build/App.o"), OLD)

        self.run_tool("restore")

        self.assertEqual(self.mtime("DerivedData/Build/App.o"), OLD)
        self.assertEqual(self.mtime("DerivedData/Build"), OLD)

    def test_restore_without_a_record_changes_nothing(self) -> None:
        out = self.run_tool("restore")
        self.assertIn("nothing restored", out)
        self.assertEqual(self.mtime("App/Same.swift"), OLD)


if __name__ == "__main__":
    unittest.main()
