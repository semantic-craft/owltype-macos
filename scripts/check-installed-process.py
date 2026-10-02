#!/usr/bin/env python3
"""Read-only installed-update regression: the live IME must map the installed inode."""
import os
from pathlib import Path
import subprocess
import sys

EXECUTABLE = Path("/Library/Input Methods/Owltype.app/Contents/MacOS/Owltype")


def mapped_executable_matches(snapshot, expected_inode, expected_path):
    records = snapshot.split("ftxt\n")[1:]
    for record in records:
        fields = record.splitlines()
        names = [field[1:] for field in fields if field.startswith("n")]
        inodes = [field[1:] for field in fields if field.startswith("i")]
        if str(expected_path) in names and str(expected_inode) in inodes:
            return True
    return False


def main():
    if sys.argv[1:] == ["--self-test"]:
        path = str(EXECUTABLE)
        current = f"p16843\nftxt\ni16875381\nn{path}\n"
        stale = "p11991\nftxt\ni16843063\nn/Library/Input Methods/.Owltype.app.old.owl-test/Contents/MacOS/Owltype\n"
        assert mapped_executable_matches(current, 16875381, path)
        assert not mapped_executable_matches(stale, 16875381, path)
        assert not mapped_executable_matches(current, 16843063, path)
        print("PASS: current mapping accepted; captured stale mapping and same-path old inode rejected")
        return
    if sys.argv[1:]:
        raise SystemExit("usage: check-installed-process.py [--self-test]")
    result = subprocess.run(["/usr/bin/pgrep", "-U", str(os.getuid()), "-x", "Owltype"],
                            capture_output=True, text=True, check=False)
    pids = result.stdout.split()
    if result.returncode != 0 or not pids:
        raise SystemExit("FAIL: no running Owltype process")
    expected_inode = EXECUTABLE.stat().st_ino
    for pid in pids:
        snapshot = subprocess.run(["/usr/sbin/lsof", "-a", "-p", pid, "-d", "txt", "-F", "fin"],
                                  capture_output=True, text=True, check=True).stdout
        if not mapped_executable_matches(snapshot, expected_inode, EXECUTABLE):
            raise SystemExit(f"FAIL: PID {pid} does not map the currently installed executable")
        print(f"PASS: PID {pid} maps installed Owltype executable inode {expected_inode}")


if __name__ == "__main__":
    main()
