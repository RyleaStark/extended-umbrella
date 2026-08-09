#!/usr/bin/env python3
"""Move state written by interim Umbrel packages back to the RC12 path.

Package revisions umbrel.2 through umbrel.7 mounted the app-data root at
/app/secrets. The established RC12 package mounted app-data/data/secrets there.
This one-shot, network-isolated migration preserves either layout without ever
overwriting divergent state.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import stat
import sys
import tempfile
from pathlib import Path
from typing import NoReturn

ROOT = Path("/app-data")
CANONICAL = ROOT / "secrets"
STAGE = ROOT / ".lnswitchboard-state-stage-v1"
BACKUP = ROOT / ".lnswitchboard-state-backup-v1"
MARKER = ROOT / ".lnswitchboard-state-migration-v1.json"
MARKER_TEMP = ROOT / ".lnswitchboard-state-migration-v1.tmp"
EXCLUDED = {
    "secrets",
    "connectors",
    STAGE.name,
    BACKUP.name,
    MARKER.name,
    MARKER_TEMP.name,
}


def fail(message: str) -> NoReturn:
    print(f"lnSwitchboard state migration refused: {message}", file=sys.stderr)
    raise SystemExit(65)


def validate_tree(path: Path) -> None:
    """Reject links and special files before privileged copying."""
    pending = [path]
    while pending:
        current = pending.pop()
        mode = current.lstat().st_mode
        if stat.S_ISLNK(mode):
            fail(f"symbolic links are not allowed in state ({current.name})")
        if stat.S_ISDIR(mode):
            pending.extend(current.iterdir())
        elif not stat.S_ISREG(mode):
            fail(f"special files are not allowed in state ({current.name})")


def files_equal(left: Path, right: Path) -> bool:
    if left.is_dir() != right.is_dir() or left.is_file() != right.is_file():
        return False
    if left.is_file():
        if left.stat().st_size != right.stat().st_size:
            return False
        with left.open("rb") as a, right.open("rb") as b:
            while True:
                left_chunk = a.read(1024 * 1024)
                right_chunk = b.read(1024 * 1024)
                if left_chunk != right_chunk:
                    return False
                if not left_chunk:
                    return True
    left_names = sorted(item.name for item in left.iterdir())
    right_names = sorted(item.name for item in right.iterdir())
    return left_names == right_names and all(
        files_equal(left / name, right / name) for name in left_names
    )


def preserve_ownership(source: Path, copied: Path) -> None:
    source_stat = source.stat(follow_symlinks=False)
    os.chown(copied, source_stat.st_uid, source_stat.st_gid, follow_symlinks=False)
    os.chmod(copied, stat.S_IMODE(source_stat.st_mode), follow_symlinks=False)
    if source.is_dir():
        for child in source.iterdir():
            preserve_ownership(child, copied / child.name)


def normalize_app_ownership(path: Path) -> None:
    """Make canonical state private and writable by the RC15 app user."""
    mode = 0o700 if path.is_dir() else 0o600
    os.chown(path, 1000, 1000, follow_symlinks=False)
    os.chmod(path, mode, follow_symlinks=False)
    if path.is_dir():
        for child in path.iterdir():
            normalize_app_ownership(child)


def fsync_tree(path: Path) -> None:
    if path.is_file():
        with path.open("rb") as handle:
            os.fsync(handle.fileno())
        return
    for child in path.iterdir():
        fsync_tree(child)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def verify_database(path: Path) -> None:
    if not path.exists():
        return
    verify_directory = Path(tempfile.mkdtemp(prefix=".sqlite-verify-", dir=path.parent))
    verify_path = verify_directory / path.name
    for suffix in ("", "-wal", "-shm"):
        source = Path(f"{path}{suffix}")
        if source.exists():
            shutil.copy2(source, Path(f"{verify_path}{suffix}"))
    result: tuple[str] | None = None
    try:
        with sqlite3.connect(verify_path) as database:
            result = database.execute("PRAGMA integrity_check").fetchone()
    except sqlite3.Error as exc:
        fail(f"the staged database did not open cleanly ({type(exc).__name__})")
    finally:
        shutil.rmtree(verify_directory)
    if result is None or result[0] != "ok":
        fail("the staged database failed SQLite integrity_check")


def database_row_count(path: Path, workspace: Path) -> int:
    verify_directory = Path(tempfile.mkdtemp(prefix=".sqlite-count-", dir=workspace))
    verify_path = verify_directory / path.name
    for suffix in ("", "-wal", "-shm"):
        source = Path(f"{path}{suffix}")
        if source.exists():
            shutil.copy2(source, Path(f"{verify_path}{suffix}"))
    try:
        with sqlite3.connect(verify_path) as database:
            result = database.execute("PRAGMA integrity_check").fetchone()
            if result is None or result[0] != "ok":
                fail("a database candidate failed SQLite integrity_check")
            tables = database.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).fetchall()
            total = 0
            for (name,) in tables:
                quoted = str(name).replace('"', '""')
                total += int(
                    database.execute(f'SELECT COUNT(*) FROM "{quoted}"').fetchone()[0]
                )
            return total
    except sqlite3.Error as exc:
        fail(f"a database candidate did not open cleanly ({type(exc).__name__})")
    finally:
        shutil.rmtree(verify_directory)


def remove_owned_stage() -> None:
    if not STAGE.exists():
        return
    if STAGE.is_symlink() or not STAGE.is_dir():
        fail("the reserved migration staging path has an unexpected type")
    shutil.rmtree(STAGE)


def validate_reserved_paths() -> None:
    for path, label in ((STAGE, "staging"), (BACKUP, "backup")):
        if path.is_symlink():
            fail(f"the reserved {label} path has an unexpected type")
        if path.exists():
            if not path.is_dir():
                fail(f"the reserved {label} path has an unexpected type")
            validate_tree(path)
    for path, label in ((MARKER, "marker"), (MARKER_TEMP, "temporary marker")):
        if path.is_symlink():
            fail(f"the reserved {label} path has an unexpected type")
        if path.exists() and not path.is_file():
            fail(f"the reserved {label} path has an unexpected type")


def archive_source(source: Path) -> None:
    BACKUP.mkdir(mode=0o700, exist_ok=True)
    destination = BACKUP / source.name
    if destination.exists():
        if files_equal(source, destination):
            if source.is_dir():
                shutil.rmtree(source)
            else:
                source.unlink()
            return
        suffix = 2
        while (BACKUP / f"{source.name}.{suffix}").exists():
            suffix += 1
        destination = BACKUP / f"{source.name}.{suffix}"
    os.replace(source, destination)


def write_marker(migrated: list[str]) -> None:
    payload = {"schema": 1, "migrated_entries": sorted(migrated)}
    if MARKER_TEMP.exists():
        MARKER_TEMP.unlink()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(MARKER_TEMP, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(MARKER_TEMP, MARKER)


def main() -> None:
    ROOT.mkdir(mode=0o750, parents=True, exist_ok=True)
    validate_reserved_paths()
    sources = sorted(
        (item for item in ROOT.iterdir() if item.name not in EXCLUDED),
        key=lambda item: item.name,
    )
    if not sources:
        if CANONICAL.exists():
            if CANONICAL.is_symlink() or not CANONICAL.is_dir():
                fail("the canonical secrets path has an unexpected type")
            validate_tree(CANONICAL)
            verify_database(CANONICAL / "lnswitchboard.db")
            normalize_app_ownership(CANONICAL)
            remove_owned_stage()
        elif STAGE.exists():
            fail("staged state exists without canonical or source state")
        if MARKER_TEMP.exists():
            MARKER_TEMP.unlink()
        print("lnSwitchboard state migration: canonical or fresh layout; no migration needed")
        return

    for source in sources:
        validate_tree(source)
    if CANONICAL.exists() and (CANONICAL.is_symlink() or not CANONICAL.is_dir()):
        fail("the canonical secrets path has an unexpected type")
    CANONICAL.mkdir(mode=0o750, exist_ok=True)
    validate_tree(CANONICAL)

    remove_owned_stage()
    STAGE.mkdir(mode=0o700)
    archive_only: set[str] = set()
    interim_database = ROOT / "lnswitchboard.db"
    historical_database = CANONICAL / "lnswitchboard.db"
    if (
        interim_database.exists()
        and historical_database.exists()
        and not files_equal(interim_database, historical_database)
    ):
        interim_rows = database_row_count(interim_database, STAGE)
        database_row_count(historical_database, STAGE)
        if interim_rows == 0:
            # The broken package initialized a new empty state tree beside the
            # historical database. Preserve history and archive the empty tree.
            archive_only.update(source.name for source in sources)

    conflicts = [
        source.name
        for source in sources
        if source.name not in archive_only
        if (CANONICAL / source.name).exists()
        and not files_equal(source, CANONICAL / source.name)
    ]
    if conflicts:
        remove_owned_stage()
        fail(
            "both historical and interim state exist with different contents; "
            "neither copy was changed"
        )

    to_commit: list[Path] = []
    for source in sources:
        if source.name in archive_only:
            continue
        destination = CANONICAL / source.name
        if destination.exists():
            continue
        staged = STAGE / source.name
        if source.is_dir():
            shutil.copytree(source, staged)
        else:
            shutil.copy2(source, staged)
        preserve_ownership(source, staged)
        to_commit.append(source)

    verify_database(STAGE / "lnswitchboard.db")
    fsync_tree(STAGE)

    # Re-check all destinations immediately before the first commit mutation.
    for source in sources:
        if source.name in archive_only:
            continue
        destination = CANONICAL / source.name
        if destination.exists() and not files_equal(source, destination):
            fail("canonical state changed during migration; no source state was removed")

    for source in to_commit:
        staged = STAGE / source.name
        destination = CANONICAL / source.name
        if destination.exists():
            if not files_equal(staged, destination):
                fail("canonical state changed during migration commit")
            continue
        os.replace(staged, destination)
    normalize_app_ownership(CANONICAL)
    fsync_tree(CANONICAL)

    migrated_names = [source.name for source in sources]
    for source in sources:
        archive_source(source)
    remove_owned_stage()
    write_marker(migrated_names)
    print(f"lnSwitchboard state migration: preserved {len(migrated_names)} state entries")


if __name__ == "__main__":
    main()
