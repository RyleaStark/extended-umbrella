#!/usr/bin/env python3
"""Move state written by interim Umbrel packages back to the RC12 path.

Package revisions umbrel.2 through umbrel.7 mounted the app-data root at
/app/secrets. The established RC12 package mounted app-data/data/secrets there.
This one-shot, network-isolated migration preserves either layout without ever
overwriting divergent state.
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import json
import os
import shutil
import sqlite3
import stat
import sys
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import NoReturn

ROOT = Path("/app-data")
CANONICAL = ROOT / "secrets"
STAGE = ROOT / ".lnswitchboard-state-stage-v1"
BACKUP = ROOT / ".lnswitchboard-state-backup-v1"
MARKER = ROOT / ".lnswitchboard-state-migration-v1.json"
MARKER_TEMP = ROOT / ".lnswitchboard-state-migration-v1.tmp"
LOCK = ROOT / ".lnswitchboard-state-lock-v1.json"
EXCLUDED = {
    "secrets",
    "connectors",
    STAGE.name,
    BACKUP.name,
    MARKER.name,
    MARKER_TEMP.name,
    LOCK.name,
}
AT_FDCWD = -100
RENAME_NOREPLACE = 1


def fail(message: str) -> NoReturn:
    print(f"lnSwitchboard state migration refused: {message}", file=sys.stderr)
    raise SystemExit(65)


@contextmanager
def protected_root() -> Iterator[None]:
    """Temporarily prevent the historical app UID from racing migration paths."""
    root_fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock_fd = -1
    original: dict[str, int] | None = None
    root_locked = False
    try:
        fcntl.flock(root_fd, fcntl.LOCK_EX)
        root_stat = os.fstat(root_fd)
        try:
            lock_fd = os.open(
                LOCK.name,
                os.O_RDWR | os.O_NOFOLLOW,
                dir_fd=root_fd,
            )
            lock_stat = os.fstat(lock_fd)
            if (
                not stat.S_ISREG(lock_stat.st_mode)
                or lock_stat.st_uid != 0
                or lock_stat.st_gid != 0
                or stat.S_IMODE(lock_stat.st_mode) != 0o600
                or lock_stat.st_nlink != 1
            ):
                fail("the migration lock metadata is not trusted")
            payload = os.read(lock_fd, 4096)
            try:
                parsed = json.loads(payload.decode("utf-8"))
                original = {
                    "uid": int(parsed["uid"]),
                    "gid": int(parsed["gid"]),
                    "mode": int(parsed["mode"]),
                }
            except (KeyError, TypeError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
                fail("the migration lock metadata is invalid")
        except FileNotFoundError:
            original = {
                "uid": int(root_stat.st_uid),
                "gid": int(root_stat.st_gid),
                "mode": int(stat.S_IMODE(root_stat.st_mode)),
            }
            lock_fd = os.open(
                LOCK.name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=root_fd,
            )
            payload = (json.dumps(original, sort_keys=True) + "\n").encode("utf-8")
            os.write(lock_fd, payload)
            os.fsync(lock_fd)
            os.fsync(root_fd)

        assert original is not None
        if original["uid"] < 0 or original["gid"] < 0 or not 0 <= original["mode"] <= 0o7777:
            fail("the migration lock metadata is outside allowed ranges")

        lock_stat = os.fstat(lock_fd)
        os.fchown(root_fd, 0, 0)
        os.fchmod(root_fd, 0o700)
        os.fsync(root_fd)
        root_locked = True
        path_stat = os.stat(LOCK.name, dir_fd=root_fd, follow_symlinks=False)
        if (path_stat.st_dev, path_stat.st_ino) != (lock_stat.st_dev, lock_stat.st_ino):
            fail("the migration lock path changed during acquisition")
        yield
    finally:
        if root_locked and original is not None:
            path_stat = os.stat(LOCK.name, dir_fd=root_fd, follow_symlinks=False)
            lock_stat = os.fstat(lock_fd)
            if (path_stat.st_dev, path_stat.st_ino) != (lock_stat.st_dev, lock_stat.st_ino):
                fail("the migration lock path changed while protected")
            os.fchown(root_fd, original["uid"], original["gid"])
            os.fchmod(root_fd, original["mode"])
            os.fsync(root_fd)
            os.unlink(LOCK.name, dir_fd=root_fd)
            os.fsync(root_fd)
        if lock_fd >= 0:
            os.close(lock_fd)
        fcntl.flock(root_fd, fcntl.LOCK_UN)
        os.close(root_fd)


def rename_noreplace(source: Path, destination: Path) -> None:
    """Atomically move within app-data without replacing any destination."""
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameat2 = libc.renameat2
    except AttributeError as exc:  # pragma: no cover - pinned Linux runtime
        raise OSError(errno.ENOSYS, "renameat2 is unavailable") from exc
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        RENAME_NOREPLACE,
    )
    if result == 0:
        return
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise FileExistsError(error, os.strerror(error), destination)
    raise OSError(error, os.strerror(error), destination)


def validate_tree(path: Path) -> None:
    """Reject links and special files before privileged copying."""
    pending = [path]
    while pending:
        current = pending.pop()
        current_stat = current.lstat()
        mode = current_stat.st_mode
        if stat.S_ISLNK(mode):
            fail(f"symbolic links are not allowed in state ({current.name})")
        if stat.S_ISDIR(mode):
            pending.extend(current.iterdir())
        elif stat.S_ISREG(mode):
            if current_stat.st_nlink != 1:
                fail(f"hard-linked state entry is not safe to migrate: {current.name}")
        else:
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
    if (source_stat.st_uid, source_stat.st_gid) != (1000, 1000):
        fail("application state has unexpected ownership")
    os.chown(copied, 1000, 1000, follow_symlinks=False)
    os.chmod(copied, stat.S_IMODE(source_stat.st_mode), follow_symlinks=False)
    if source.is_dir():
        for child in source.iterdir():
            preserve_ownership(child, copied / child.name)


def normalize_app_ownership(path: Path) -> None:
    """Make canonical state private and writable by the application user."""
    path_stat = path.stat(follow_symlinks=False)
    if (path_stat.st_uid, path_stat.st_gid) not in {(0, 0), (1000, 1000)}:
        fail("canonical application state has unexpected ownership")
    mode = 0o700 if path.is_dir() else 0o600
    os.chown(path, 1000, 1000, follow_symlinks=False)
    os.chmod(path, mode, follow_symlinks=False)
    if path.is_dir():
        for child in path.iterdir():
            normalize_app_ownership(child)


def tree_is_subset(subset: Path, superset: Path) -> bool:
    if subset.is_dir() != superset.is_dir():
        return False
    if subset.is_file():
        return files_equal(subset, superset)
    subset_entries = {entry.name: entry for entry in subset.iterdir()}
    superset_entries = {entry.name: entry for entry in superset.iterdir()}
    return set(subset_entries).issubset(superset_entries) and all(
        tree_is_subset(entry, superset_entries[name])
        for name, entry in subset_entries.items()
    )


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
    stage_stat = STAGE.lstat()
    if (
        not stat.S_ISDIR(stage_stat.st_mode)
        or stage_stat.st_uid != 0
        or stage_stat.st_gid != 0
        or stat.S_IMODE(stage_stat.st_mode) != 0o700
    ):
        fail("refusing to remove an untrusted migration staging path")
    validate_tree(STAGE)
    shutil.rmtree(STAGE)

def is_trusted_partial_migration(
    sources: dict[str, Path], canonical: dict[str, Path]
) -> bool:
    """Recognize only the root-owned stage shape left by our own commit loop."""
    if not STAGE.exists() or STAGE.is_symlink() or not STAGE.is_dir():
        return False
    stage_stat = STAGE.stat(follow_symlinks=False)
    if (stage_stat.st_uid, stage_stat.st_gid) != (0, 0):
        return False
    if stat.S_IMODE(stage_stat.st_mode) != 0o700:
        return False
    staged = {entry.name: entry for entry in STAGE.iterdir()}
    if not canonical or not staged:
        return False
    if canonical.keys() & staged.keys():
        return False
    if canonical.keys() | staged.keys() != sources.keys():
        return False
    return all(
        files_equal(entry, sources[name])
        for entries in (canonical, staged)
        for name, entry in entries.items()
    )


def validate_reserved_paths() -> None:
    for path, label in ((STAGE, "staging"), (BACKUP, "backup")):
        if path.is_symlink():
            fail(f"the reserved {label} path has an unexpected type")
        if path.exists():
            path_stat = path.lstat()
            if not stat.S_ISDIR(path_stat.st_mode):
                fail(f"the reserved {label} path has an unexpected type")
            if path_stat.st_uid != 0 or path_stat.st_gid != 0:
                fail(f"the reserved {label} path must be owned by root")
            if stat.S_IMODE(path_stat.st_mode) != 0o700:
                fail(f"the reserved {label} path has unsafe permissions")
            validate_tree(path)
    for path, label in (
        (MARKER, "marker"),
        (MARKER_TEMP, "temporary marker"),
        (LOCK, "lock metadata"),
    ):
        if path.is_symlink():
            fail(f"the reserved {label} path has an unexpected type")
        if path.exists():
            path_stat = path.lstat()
            if not stat.S_ISREG(path_stat.st_mode):
                fail(f"the reserved {label} path has an unexpected type")
            if path_stat.st_uid != 0 or path_stat.st_gid != 0:
                fail(f"the reserved {label} path must be owned by root")
            if stat.S_IMODE(path_stat.st_mode) != 0o600 or path_stat.st_nlink != 1:
                fail(f"the reserved {label} path has unsafe permissions")


def is_compatibility_link(path: Path) -> bool:
    if not path.is_symlink():
        return False
    return Path(os.readlink(path)) == Path("secrets") / path.name


def ensure_compatibility_links() -> None:
    """Keep interim root mounts pointed at the canonical live state."""
    for canonical_entry in CANONICAL.iterdir():
        link = ROOT / canonical_entry.name
        if link.is_symlink():
            if not is_compatibility_link(link):
                fail("an interim compatibility link has an unexpected target")
            continue
        if link.exists():
            fail("interim state still exists while creating rollback compatibility")
        os.symlink(
            Path("secrets") / canonical_entry.name,
            link,
            target_is_directory=canonical_entry.is_dir(),
        )
    descriptor = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_backup_directory(*, create: bool) -> bool:
    validate_reserved_paths()
    if BACKUP.is_symlink():
        fail("the reserved backup path changed during migration")
    if not BACKUP.exists():
        if not create:
            return False
        BACKUP.mkdir(mode=0o700)
    backup_stat = BACKUP.lstat()
    if (
        not stat.S_ISDIR(backup_stat.st_mode)
        or backup_stat.st_uid != 0
        or backup_stat.st_gid != 0
        or stat.S_IMODE(backup_stat.st_mode) != 0o700
    ):
        fail("the reserved backup path is not trusted")
    return True


def archive_source(source: Path, *, allow_subset_cleanup: bool = False) -> None:
    ensure_backup_directory(create=True)
    suffix = 1
    while True:
        name = source.name if suffix == 1 else f"{source.name}.{suffix}"
        destination = BACKUP / name
        try:
            rename_noreplace(source, destination)
            return
        except FileExistsError:
            if files_equal(source, destination) or (
                allow_subset_cleanup
                and source.is_dir()
                and destination.is_dir()
                and tree_is_subset(source, destination)
            ):
                if source.is_dir():
                    shutil.rmtree(source)
                else:
                    source.unlink()
                return
            suffix += 1


def read_marker() -> list[str] | None:
    if not MARKER.exists():
        return None
    try:
        payload = json.loads(MARKER.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        fail("the migration marker is invalid")
    if payload.get("schema") != 1 or not isinstance(payload.get("migrated_entries"), list):
        fail("the migration marker has an unsupported schema")
    names: list[str] = []
    for value in payload["migrated_entries"]:
        name = str(value)
        if not name or name in EXCLUDED or Path(name).name != name:
            fail("the migration marker contains an unsafe state name")
        names.append(name)
    if len(names) != len(set(names)):
        fail("the migration marker contains duplicate state names")
    return sorted(names)


def backup_candidate(name: str) -> Path | None:
    if not ensure_backup_directory(create=False):
        return None
    candidates: list[tuple[int, Path]] = []
    for candidate in BACKUP.iterdir():
        if candidate.name == name:
            candidates.append((1, candidate))
            continue
        prefix = f"{name}."
        if candidate.name.startswith(prefix):
            suffix = candidate.name[len(prefix) :]
            if suffix.isdigit() and int(suffix) >= 2:
                candidates.append((int(suffix), candidate))
    if not candidates:
        return None
    selected = max(candidates, key=lambda item: item[0])[1]
    validate_tree(selected)
    return selected


def recover_archived_transaction(marker_names: list[str]) -> bool:
    canonical_entries: dict[str, Path] = {}
    if CANONICAL.exists():
        if CANONICAL.is_symlink() or not CANONICAL.is_dir():
            fail("the canonical secrets path has an unexpected type")
        validate_tree(CANONICAL)
        canonical_entries = {entry.name: entry for entry in CANONICAL.iterdir()}
    if set(marker_names).issubset(canonical_entries) and (
        not STAGE.exists() or not any(STAGE.iterdir())
    ):
        return False

    selected: dict[str, Path] = {}
    for name in marker_names:
        candidate = backup_candidate(name)
        if candidate is None:
            fail("migration metadata exists but archived state is incomplete")
        selected[name] = candidate
    if not selected:
        fail("migration metadata exists without recoverable archived state")

    for name in set(marker_names) & canonical_entries.keys():
        if not files_equal(canonical_entries[name], selected[name]):
            fail("canonical state diverged during archived transaction recovery")

    if STAGE.exists():
        staged_entries = {entry.name: entry for entry in STAGE.iterdir()}
        for name, staged in list(staged_entries.items()):
            if name not in selected or name in canonical_entries:
                fail("staged archived recovery state is not coherent")
            if not files_equal(staged, selected[name]):
                if staged.is_dir():
                    shutil.rmtree(staged)
                else:
                    staged.unlink()
                staged_entries.pop(name)
    else:
        STAGE.mkdir(mode=0o700)
        staged_entries = {}

    for name, source in selected.items():
        if name in canonical_entries or name in staged_entries:
            continue
        staged = STAGE / name
        if source.is_dir():
            shutil.copytree(source, staged)
        else:
            shutil.copy2(source, staged)
        preserve_ownership(source, staged)
        staged_entries[name] = staged
    verify_database(STAGE / "lnswitchboard.db")
    fsync_tree(STAGE)

    if not CANONICAL.exists():
        CANONICAL.mkdir(mode=0o750)
    for name in marker_names:
        destination = CANONICAL / name
        if destination.exists():
            continue
        rename_noreplace(STAGE / name, destination)
    normalize_app_ownership(CANONICAL)
    fsync_tree(CANONICAL)
    remove_owned_stage()
    ensure_compatibility_links()
    write_marker(marker_names)
    print(
        "lnSwitchboard state migration: recovered "
        f"{len(marker_names)} archived state entries"
    )
    return True


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


def _main_locked() -> None:
    validate_reserved_paths()
    marker_names = read_marker()
    sources: list[Path] = []
    for item in sorted(ROOT.iterdir(), key=lambda candidate: candidate.name):
        if item.name in EXCLUDED:
            continue
        if item.is_symlink():
            if not is_compatibility_link(item) or not (CANONICAL / item.name).exists():
                fail("an unexpected symbolic link exists in interim state")
            continue
        sources.append(item)
    if not sources:
        if marker_names is not None and recover_archived_transaction(marker_names):
            return
        if CANONICAL.exists():
            if CANONICAL.is_symlink() or not CANONICAL.is_dir():
                fail("the canonical secrets path has an unexpected type")
            validate_tree(CANONICAL)
            verify_database(CANONICAL / "lnswitchboard.db")
            normalize_app_ownership(CANONICAL)
            remove_owned_stage()
            ensure_compatibility_links()
            if marker_names is not None:
                write_marker([entry.name for entry in CANONICAL.iterdir()])
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

    canonical_entries_before = {
        entry.name: entry for entry in CANONICAL.iterdir()
    }
    source_entries_before = {entry.name: entry for entry in sources}
    partial_recovery = is_trusted_partial_migration(
        source_entries_before,
        canonical_entries_before,
    )
    remove_owned_stage()
    STAGE.mkdir(mode=0o700)
    archive_only: set[str] = set()
    subset_archive_cleanup: set[str] = set()
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
    archived_interim_database = backup_candidate("lnswitchboard.db")
    if (
        not interim_database.exists()
        and archived_interim_database is not None
        and historical_database.exists()
        and not files_equal(archived_interim_database, historical_database)
        and database_row_count(archived_interim_database, STAGE) == 0
    ):
        # Resume cleanup if power was lost after the empty interim database was
        # archived but before the rest of that non-authoritative tree.
        archive_only.update(source.name for source in sources)

    canonical_entries = {
        entry.name: entry for entry in CANONICAL.iterdir()
    }
    source_entries = {entry.name: entry for entry in sources}
    if canonical_entries and not archive_only:
        bundles_match = canonical_entries.keys() == source_entries.keys() and all(
            files_equal(source_entries[name], canonical_entries[name])
            for name in source_entries
        )
        sources_are_identical_subset = source_entries.keys() < canonical_entries.keys() and all(
            files_equal(source_entries[name], canonical_entries[name])
            for name in source_entries
        )
        rollback_extension = (
            marker_names is not None
            and set(marker_names).issubset(canonical_entries)
            and all(
                name not in canonical_entries
                or files_equal(source_entries[name], canonical_entries[name])
                for name in source_entries
            )
        )
        torn_archive_cleanup = (
            set(source_entries).issubset(canonical_entries)
            and any(
                not files_equal(source_entries[name], canonical_entries[name])
                for name in source_entries
            )
            and all(
                tree_is_subset(source_entries[name], canonical_entries[name])
                for name in source_entries
            )
            and all(
                files_equal(candidate, canonical_entries[name])
                if (candidate := backup_candidate(name)) is not None
                else False
                for name in source_entries
                if not files_equal(source_entries[name], canonical_entries[name])
            )
        )
        if bundles_match or sources_are_identical_subset or torn_archive_cleanup:
            # An identical strict subset is the durable shape left if power is
            # lost after some source entries were archived but before rollback
            # compatibility links were created.
            archive_only.update(source_entries)
            if torn_archive_cleanup:
                subset_archive_cleanup.update(
                    name
                    for name in source_entries
                    if not files_equal(source_entries[name], canonical_entries[name])
                )
        elif rollback_extension:
            # A completed prior migration proves the root-layout application was
            # a rollback. Preserve newly created root entries alongside the
            # canonical bundle while still refusing divergent replacements.
            pass
        elif not partial_recovery:
            remove_owned_stage()
            fail(
                "both historical and interim state exist as different bundles; "
                "neither copy was changed"
            )

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
        try:
            rename_noreplace(staged, destination)
        except FileExistsError:
            if not files_equal(staged, destination):
                fail("canonical state changed during migration commit")
    normalize_app_ownership(CANONICAL)
    fsync_tree(CANONICAL)

    migrated_names = sorted(set(marker_names or []) | {source.name for source in sources})
    for source in sources:
        archive_source(
            source,
            allow_subset_cleanup=source.name in subset_archive_cleanup,
        )
    ensure_compatibility_links()
    remove_owned_stage()
    write_marker(migrated_names)
    print(f"lnSwitchboard state migration: preserved {len(migrated_names)} state entries")


def main() -> None:
    if ROOT.is_symlink():
        fail("the app-data root cannot be a symbolic link")
    ROOT.mkdir(mode=0o750, parents=True, exist_ok=True)
    with protected_root():
        _main_locked()


if __name__ == "__main__":
    main()
