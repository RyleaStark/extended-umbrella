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
import hashlib
import json
import os
import secrets
import shutil
import sqlite3
import stat
import sys
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any, NoReturn

ROOT = Path("/app-data")
CANONICAL = ROOT / "secrets"
STAGE = ROOT / ".lnswitchboard-state-stage-v1"
BACKUP = ROOT / ".lnswitchboard-state-backup-v1"
MARKER = ROOT / ".lnswitchboard-state-migration-v1.json"
MARKER_TEMP = ROOT / ".lnswitchboard-state-migration-v1.tmp"
LOCK = ROOT / ".lnswitchboard-state-lock-v1.json"
LOCK_TEMP = ROOT / ".lnswitchboard-state-lock-v1.tmp"
PROXY_CONFIG = ROOT / "proxy-config"
PUBLIC_BACKEND = ROOT / "public-backend"
TRANSIENT_RETIRE = ROOT / ".lnswitchboard-transient-link-retire-v1"
HOST_VIEW = Path("/host-view")
PRIVILEGED_MOUNT_SOURCES = (
    Path("secrets"),
    Path("secrets/tailscale"),
    Path("connectors"),
    Path("connectors/cloudflare-mesh"),
    Path("connectors/cloudflare-mesh-state"),
    Path("connectors/tailscale"),
    Path("secrets/zrok"),
    Path("connectors/zrok"),
)
EXCLUDED = {
    "secrets",
    "connectors",
    "proxy-config",
    "public-backend",
    STAGE.name,
    BACKUP.name,
    MARKER.name,
    MARKER_TEMP.name,
    LOCK.name,
    LOCK_TEMP.name,
    TRANSIENT_RETIRE.name,
}
AT_FDCWD = -100
RENAME_NOREPLACE = 1
TRANSIENT_SQLITE_COMPATIBILITY_NAMES = {
    "lnswitchboard.db-journal",
    "lnswitchboard.db-wal",
    "lnswitchboard.db-shm",
}
CANONICAL_RUNTIME_DIRECTORIES = {"tailscale", "zrok", "cloudflare-mesh"}
APP_PROXY_ENV = b"LOG_LEVEL=silent\nPROXY_AUTH_WHITELIST=\n"
APP_PROXY_TEMP_PREFIX = ".app-proxy.env.tmp."
APP_PROXY_LEGACY_TEMP_NAME = "app-proxy.env.tmp"
APP_PROXY_RETIRE_NAME = ".app-proxy-temp-retire-v1"


def fail(message: str) -> NoReturn:
    print(f"lnSwitchboard state migration refused: {message}", file=sys.stderr)
    raise SystemExit(65)


def write_all(descriptor: int, payload: bytes) -> None:
    """Write every byte or fail without treating a short write as durable."""
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError(errno.EIO, "write returned no progress")
        remaining = remaining[written:]


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject duplicate authority keys instead of silently keeping the last."""
    parsed: dict[str, Any] = {}
    for key, value in pairs:
        if key in parsed:
            raise ValueError("duplicate JSON object key")
        parsed[key] = value
    return parsed


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
                parsed = json.loads(
                    payload.decode("utf-8"), object_pairs_hook=unique_json_object
                )
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
            try:
                temporary_stat = os.stat(
                    LOCK_TEMP.name,
                    dir_fd=root_fd,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                temporary_stat = None
            if temporary_stat is not None:
                if (
                    not stat.S_ISREG(temporary_stat.st_mode)
                    or temporary_stat.st_uid != 0
                    or temporary_stat.st_gid != 0
                    or stat.S_IMODE(temporary_stat.st_mode) != 0o600
                    or temporary_stat.st_nlink != 1
                ):
                    fail("the temporary migration lock metadata is not trusted")
                os.unlink(LOCK_TEMP.name, dir_fd=root_fd)
                os.fsync(root_fd)
            lock_fd = os.open(
                LOCK_TEMP.name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=root_fd,
            )
            payload = (json.dumps(original, sort_keys=True) + "\n").encode("utf-8")
            write_all(lock_fd, payload)
            os.fsync(lock_fd)
            try:
                rename_noreplace(LOCK_TEMP, LOCK)
            except FileExistsError:
                os.unlink(LOCK_TEMP.name, dir_fd=root_fd)
                os.fsync(root_fd)
                fail("the migration lock appeared during publication")
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


def unlink_private(directory_fd: int, name: str) -> None:
    """Unlink inside a root-private directory without mutable path dispatch."""
    libc = ctypes.CDLL(None, use_errno=True)
    unlinkat = libc.unlinkat
    unlinkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    unlinkat.restype = ctypes.c_int
    if unlinkat(directory_fd, os.fsencode(name), 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), name)


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


def validate_canonical_tree() -> None:
    """Validate application state without traversing live connector protocols."""
    canonical_stat = CANONICAL.lstat()
    if CANONICAL.is_symlink() or not stat.S_ISDIR(canonical_stat.st_mode):
        fail("the canonical secrets path has an unexpected type")
    for child in CANONICAL.iterdir():
        if child.name in CANONICAL_RUNTIME_DIRECTORIES:
            child_stat = child.lstat()
            if child.is_symlink() or not stat.S_ISDIR(child_stat.st_mode):
                fail(f"the reserved connector path {child.name} has an unexpected type")
            continue
        validate_tree(child)


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


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def state_digest(path: Path) -> str:
    digest = hashlib.sha256()

    def visit(current: Path, relative: str) -> None:
        current_stat = current.lstat()
        if stat.S_ISREG(current_stat.st_mode):
            digest.update(b"file\0")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            with current.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            return
        if not stat.S_ISDIR(current_stat.st_mode):
            fail("transaction state contains an unexpected filesystem object")
        digest.update(b"dir\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        for child in sorted(current.iterdir(), key=lambda item: item.name):
            child_relative = f"{relative}/{child.name}" if relative else child.name
            visit(child, child_relative)

    visit(path, "")
    return digest.hexdigest()


def verify_state_digest(path: Path, expected: str, label: str) -> None:
    validate_tree(path)
    if state_digest(path) != expected:
        fail(f"{label} does not match the durable transaction manifest")


def verify_credential_bundle(directory: Path) -> None:
    database_path = directory / "lnswitchboard.db"
    key_path = directory / "connection-secrets.key"
    if not database_path.exists():
        return
    verify_directory = Path(tempfile.mkdtemp(prefix=".credential-verify-", dir=directory))
    verify_path = verify_directory / database_path.name
    for suffix in ("", "-wal", "-shm"):
        source = Path(f"{database_path}{suffix}")
        if source.exists():
            shutil.copy2(source, Path(f"{verify_path}{suffix}"))
    try:
        with sqlite3.connect(verify_path) as database:
            exists = database.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='connection_secrets'"
            ).fetchone()
            ciphertexts = (
                [row[0] for row in database.execute("SELECT ciphertext FROM connection_secrets")]
                if exists
                else []
            )
        if not ciphertexts:
            return
        if not key_path.exists():
            fail("encrypted connection credentials exist without their key")
        try:
            from cryptography.fernet import Fernet, InvalidToken
        except ImportError:
            fail("credential bundle verification is unavailable")
        try:
            cipher = Fernet(key_path.read_bytes().strip())
            for ciphertext in ciphertexts:
                cipher.decrypt(bytes(ciphertext))
        except (OSError, ValueError, InvalidToken, TypeError):
            fail("the database and connection credential key are not one coherent bundle")
    except sqlite3.Error as exc:
        fail(f"the credential database did not open cleanly ({type(exc).__name__})")
    finally:
        shutil.rmtree(verify_directory)


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


def verify_combined_bundle(canonical: Path, stage: Path) -> None:
    validation = stage / ".bundle-validation"
    if validation.exists():
        if validation.is_dir():
            shutil.rmtree(validation)
        else:
            validation.unlink()
    validation.mkdir(mode=0o700)
    try:
        for directory in (canonical, stage):
            if not directory.exists():
                continue
            for source in directory.iterdir():
                if source == validation:
                    continue
                destination = validation / source.name
                if destination.exists():
                    continue
                if source.is_dir():
                    shutil.copytree(source, destination)
                else:
                    shutil.copy2(source, destination)
        verify_database(validation / "lnswitchboard.db")
        verify_credential_bundle(validation)
    finally:
        shutil.rmtree(validation)
        fsync_directory(stage)


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


def remove_owned_proxy_temporaries() -> None:
    """Retire bounded guard temporaries without unlinking mutable live paths."""
    directory_fd = os.open(
        PROXY_CONFIG,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    retire_fd = -1
    held: dict[str, tuple[str, int, os.stat_result]] = {}

    def expected_modes(name: str) -> set[int] | None:
        if name == APP_PROXY_LEGACY_TEMP_NAME:
            return {0o600}
        if not name.startswith(APP_PROXY_TEMP_PREFIX):
            return None
        suffix = name[len(APP_PROXY_TEMP_PREFIX) :]
        if not suffix.isdigit() or int(suffix) <= 0 or str(int(suffix)) != suffix:
            return None
        return {0o600, 0o444}

    def same_entry(expected: os.stat_result, current: os.stat_result) -> bool:
        return (
            expected.st_dev,
            expected.st_ino,
            expected.st_mode,
            expected.st_uid,
            expected.st_gid,
            expected.st_nlink,
            expected.st_size,
            expected.st_mtime_ns,
        ) == (
            current.st_dev,
            current.st_ino,
            current.st_mode,
            current.st_uid,
            current.st_gid,
            current.st_nlink,
            current.st_size,
            current.st_mtime_ns,
        )

    def open_validated(directory: int, name: str) -> tuple[int, os.stat_result]:
        modes = expected_modes(name)
        if modes is None:
            fail("the App Proxy retirement path contains an unexpected entry")
        try:
            initial = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            fail("an App Proxy publication temporary changed during validation")
        if (
            not stat.S_ISREG(initial.st_mode)
            or (initial.st_uid, initial.st_gid) != (0, 0)
            or initial.st_nlink != 1
            or stat.S_IMODE(initial.st_mode) not in modes
            or initial.st_size > len(APP_PROXY_ENV)
        ):
            fail("an App Proxy publication temporary has unsafe metadata")
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        opened = os.fstat(descriptor)
        if not same_entry(initial, opened):
            os.close(descriptor)
            fail("an App Proxy publication temporary changed during validation")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                os.close(descriptor)
                fail("an App Proxy publication temporary changed during validation")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            os.close(descriptor)
            fail("an App Proxy publication temporary changed during validation")
        payload = b"".join(chunks)
        after_read = os.fstat(descriptor)
        if not same_entry(opened, after_read):
            os.close(descriptor)
            fail("an App Proxy publication temporary changed during validation")
        if not APP_PROXY_ENV.startswith(payload):
            os.close(descriptor)
            fail("an App Proxy publication temporary has unexpected content")
        return descriptor, after_read

    try:
        try:
            retirement = os.stat(
                APP_PROXY_RETIRE_NAME,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            retirement = None
        if retirement is not None:
            if (
                not stat.S_ISDIR(retirement.st_mode)
                or (retirement.st_uid, retirement.st_gid) != (0, 0)
                or stat.S_IMODE(retirement.st_mode) != 0o700
            ):
                fail("the App Proxy retirement path is not trusted")
            retire_fd = os.open(
                APP_PROXY_RETIRE_NAME,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )

        for name in sorted(os.listdir(directory_fd)):
            if name == APP_PROXY_RETIRE_NAME or expected_modes(name) is None:
                continue
            descriptor, opened = open_validated(directory_fd, name)
            held[name] = ("live", descriptor, opened)
        if retire_fd >= 0:
            for name in sorted(os.listdir(retire_fd)):
                descriptor, opened = open_validated(retire_fd, name)
                if name in held:
                    os.close(descriptor)
                    fail("an App Proxy temporary exists in two retirement locations")
                held[name] = ("retired", descriptor, opened)

        if any(location == "live" for location, _fd, _entry in held.values()):
            if retire_fd < 0:
                os.mkdir(APP_PROXY_RETIRE_NAME, mode=0o700, dir_fd=directory_fd)
                os.fsync(directory_fd)
                retire_fd = os.open(
                    APP_PROXY_RETIRE_NAME,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
            for name, (location, descriptor, opened) in list(held.items()):
                if location != "live":
                    continue
                rename_noreplace(
                    PROXY_CONFIG / name,
                    PROXY_CONFIG / APP_PROXY_RETIRE_NAME / name,
                )
                moved = os.stat(name, dir_fd=retire_fd, follow_symlinks=False)
                current = os.fstat(descriptor)
                if not same_entry(current, moved):
                    rename_noreplace(
                        PROXY_CONFIG / APP_PROXY_RETIRE_NAME / name,
                        PROXY_CONFIG / name,
                    )
                    os.fsync(directory_fd)
                    os.fsync(retire_fd)
                    if not os.listdir(retire_fd):
                        os.close(retire_fd)
                        retire_fd = -1
                        os.rmdir(APP_PROXY_RETIRE_NAME, dir_fd=directory_fd)
                        os.fsync(directory_fd)
                    fail("an App Proxy publication temporary changed during retirement")
                held[name] = ("retired", descriptor, moved)
            os.fsync(directory_fd)
            os.fsync(retire_fd)

        for name, (location, descriptor, moved) in held.items():
            if location != "retired" or retire_fd < 0:
                fail("an App Proxy publication temporary was not safely retired")
            if not same_entry(os.fstat(descriptor), moved):
                fail("an App Proxy publication temporary changed during retirement")
            current = os.stat(name, dir_fd=retire_fd, follow_symlinks=False)
            if not same_entry(moved, current):
                fail("an App Proxy publication temporary changed during retirement")
        for name in sorted(held):
            unlink_private(retire_fd, name)
        if retire_fd >= 0:
            os.fsync(retire_fd)
            os.close(retire_fd)
            retire_fd = -1
            os.rmdir(APP_PROXY_RETIRE_NAME, dir_fd=directory_fd)
            os.fsync(directory_fd)
    finally:
        for _location, descriptor, _entry in held.values():
            os.close(descriptor)
        if retire_fd >= 0:
            os.close(retire_fd)
        os.close(directory_fd)


def validate_reserved_paths() -> None:
    if HOST_VIEW.exists():
        host_root_stat = HOST_VIEW.stat()
        migration_root_stat = ROOT.stat()
        if (host_root_stat.st_dev, host_root_stat.st_ino) != (
            migration_root_stat.st_dev,
            migration_root_stat.st_ino,
        ):
            fail("the read-only host view does not match the migration root")
        for relative in PRIVILEGED_MOUNT_SOURCES:
            source = HOST_VIEW / relative
            if source.is_symlink():
                fail(f"the reserved writable mount source {relative} is a symlink")
            if not source.exists():
                continue
            source_stat = source.lstat()
            if not stat.S_ISDIR(source_stat.st_mode):
                fail(f"the reserved writable mount source {relative} is not a directory")
            # The state migrator itself validates and normalizes the canonical
            # secrets root.  Only its alias/type is checked here so historical
            # layouts can be repaired before the privileged initializer runs.
            if relative == Path("secrets"):
                continue
            ownership = (source_stat.st_uid, source_stat.st_gid)
            mode = stat.S_IMODE(source_stat.st_mode)
            if (
                ownership not in {(0, 0), (1000, 1000)}
                or mode & 0o002
                or (ownership == (0, 0) and mode & 0o020)
            ):
                fail(f"the reserved writable mount source {relative} is not trusted")
    if PUBLIC_BACKEND.is_symlink():
        fail("the reserved public backend path has an unexpected type")
    if PUBLIC_BACKEND.exists():
        backend_stat = PUBLIC_BACKEND.lstat()
        if not stat.S_ISDIR(backend_stat.st_mode) or (
            backend_stat.st_uid,
            backend_stat.st_gid,
            stat.S_IMODE(backend_stat.st_mode),
        ) not in {(0, 0, 0o755), (1000, 1000, 0o700)}:
            fail("the reserved public backend path is not trusted")
        entries = list(PUBLIC_BACKEND.iterdir())
        if entries:
            if len(entries) != 1 or entries[0].name != "public.sock":
                fail("the reserved public backend path contains an unexpected entry")
            socket_stat = entries[0].lstat()
            if (
                not stat.S_ISSOCK(socket_stat.st_mode)
                or socket_stat.st_uid != 1000
                or socket_stat.st_gid != 1000
            ):
                fail("the reserved public backend socket is not trusted")
    if PROXY_CONFIG.is_symlink():
        fail("the reserved App Proxy configuration path has an unexpected type")
    if PROXY_CONFIG.exists():
        config_stat = PROXY_CONFIG.lstat()
        if (
            not stat.S_ISDIR(config_stat.st_mode)
            or config_stat.st_uid != 0
            or config_stat.st_gid != 0
            or stat.S_IMODE(config_stat.st_mode) != 0o755
        ):
            fail("the reserved App Proxy configuration path is not trusted")
        remove_owned_proxy_temporaries()
        for child in PROXY_CONFIG.iterdir():
            if child.name != "app-proxy.env" or child.is_symlink():
                fail("the reserved App Proxy configuration contains an unexpected entry")
            child_stat = child.lstat()
            if (
                not stat.S_ISREG(child_stat.st_mode)
                or child_stat.st_uid != 0
                or child_stat.st_gid != 0
                or child_stat.st_nlink != 1
                or stat.S_IMODE(child_stat.st_mode) != 0o444
            ):
                fail("the reserved App Proxy configuration entry is not trusted")
        configured = PROXY_CONFIG / "app-proxy.env"
        if configured.exists() and configured.read_text(encoding="utf-8") != (
            "LOG_LEVEL=silent\n"
            "PROXY_AUTH_WHITELIST=\n"
        ):
            fail("the reserved App Proxy privacy configuration is invalid")
    if TRANSIENT_RETIRE.is_symlink():
        fail("the transient compatibility retirement path has an unexpected type")
    if TRANSIENT_RETIRE.exists():
        retire_stat = TRANSIENT_RETIRE.lstat()
        if (
            not stat.S_ISDIR(retire_stat.st_mode)
            or (retire_stat.st_uid, retire_stat.st_gid) != (0, 0)
            or stat.S_IMODE(retire_stat.st_mode) != 0o700
        ):
            fail("the transient compatibility retirement path is not trusted")
        for child in TRANSIENT_RETIRE.iterdir():
            child_stat = child.lstat()
            if (
                child.name not in TRANSIENT_SQLITE_COMPATIBILITY_NAMES
                or not stat.S_ISLNK(child_stat.st_mode)
                or (child_stat.st_uid, child_stat.st_gid) != (0, 0)
                or child_stat.st_nlink != 1
                or Path(os.readlink(child)) != Path("secrets") / child.name
            ):
                fail("the transient compatibility retirement path contains an unexpected entry")
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
        (LOCK_TEMP, "temporary lock metadata"),
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


def remove_transient_compatibility_links(marker: dict[str, Any] | None) -> None:
    """Retire authority-bound transient links through a recoverable private dir."""
    root_fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    retire_fd = -1
    validated: dict[str, tuple[str, os.stat_result]] = {}
    held_root_entries: dict[str, int] = {}

    def matches(initial: os.stat_result, current: os.stat_result) -> bool:
        return (
            initial.st_dev,
            initial.st_ino,
            initial.st_mode,
            initial.st_uid,
            initial.st_gid,
            initial.st_nlink,
        ) == (
            current.st_dev,
            current.st_ino,
            current.st_mode,
            current.st_uid,
            current.st_gid,
            current.st_nlink,
        )

    def validate_candidate(directory_fd: int, name: str) -> os.stat_result:
        try:
            initial = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            raise
        if not stat.S_ISLNK(initial.st_mode):
            fail("a transient compatibility link has an unexpected type")
        if (initial.st_uid, initial.st_gid) != (0, 0) or initial.st_nlink != 1:
            fail("a transient compatibility link has unsafe metadata")
        try:
            target = Path(os.readlink(name, dir_fd=directory_fd))
        except OSError:
            fail("a transient compatibility link changed during validation")
        if target != Path("secrets") / name:
            fail("a transient compatibility link has an unexpected target")
        if marker is None or marker.get("schema") != 2:
            fail("a transient compatibility link lacks durable migration authority")
        authority = marker.get("authorities", {}).get(name)
        if not isinstance(authority, dict):
            fail("a transient compatibility link lacks durable migration authority")
        archived = BACKUP / authority["archive_name"]
        if not archived.exists() or archived.is_symlink():
            fail("a transient compatibility link lacks its bound archive authority")
        verify_state_digest(
            archived,
            authority["sha256"],
            "transient compatibility archive authority",
        )
        return initial

    try:
        if TRANSIENT_RETIRE.exists():
            retire_fd = os.open(
                TRANSIENT_RETIRE,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
        for name in sorted(TRANSIENT_SQLITE_COMPATIBILITY_NAMES):
            root_entry: os.stat_result | None = None
            retired_entry: os.stat_result | None = None
            try:
                candidate = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                candidate = None
            if candidate is not None and stat.S_ISLNK(candidate.st_mode):
                root_entry = validate_candidate(root_fd, name)
                held_fd = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=root_fd)
                held_entry = os.fstat(held_fd)
                if not matches(root_entry, held_entry):
                    os.close(held_fd)
                    fail("a transient compatibility link changed during validation")
                held_root_entries[name] = held_fd
                root_entry = held_entry
            if retire_fd >= 0:
                try:
                    retired_entry = validate_candidate(retire_fd, name)
                except FileNotFoundError:
                    retired_entry = None
            if root_entry is not None and retired_entry is not None:
                fail("a transient compatibility link exists in two retirement locations")
            if root_entry is not None:
                validated[name] = ("root", root_entry)
            elif retired_entry is not None:
                validated[name] = ("retired", retired_entry)
        if any(location == "root" for location, _entry in validated.values()):
            if retire_fd < 0:
                TRANSIENT_RETIRE.mkdir(mode=0o700)
                os.fsync(root_fd)
                retire_fd = os.open(
                    TRANSIENT_RETIRE,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                )
            for name, (location, initial) in validated.items():
                if location != "root":
                    continue
                rename_noreplace(ROOT / name, TRANSIENT_RETIRE / name)
                moved = os.stat(name, dir_fd=retire_fd, follow_symlinks=False)
                if not matches(initial, moved):
                    rename_noreplace(TRANSIENT_RETIRE / name, ROOT / name)
                    os.fsync(root_fd)
                    os.fsync(retire_fd)
                    if not os.listdir(retire_fd):
                        os.close(retire_fd)
                        retire_fd = -1
                        TRANSIENT_RETIRE.rmdir()
                        os.fsync(root_fd)
                    fail("a transient compatibility link changed during retirement")
                validated[name] = ("retired", moved)
            os.fsync(root_fd)
            os.fsync(retire_fd)
        for name, (location, initial) in validated.items():
            if location != "retired" or retire_fd < 0:
                fail("a transient compatibility link was not safely retired")
            current = os.stat(name, dir_fd=retire_fd, follow_symlinks=False)
            if not matches(initial, current):
                fail("a transient compatibility link changed during retirement")
        for name in sorted(validated):
            unlink_private(retire_fd, name)
        if retire_fd >= 0:
            os.fsync(retire_fd)
            os.close(retire_fd)
            retire_fd = -1
            TRANSIENT_RETIRE.rmdir()
            os.fsync(root_fd)
    finally:
        for held_fd in held_root_entries.values():
            os.close(held_fd)
        if retire_fd >= 0:
            os.close(retire_fd)
        os.close(root_fd)


def ensure_compatibility_links(marker: dict[str, Any] | None) -> None:
    """Keep interim root mounts pointed at the canonical live state."""
    remove_transient_compatibility_links(marker)
    for canonical_entry in CANONICAL.iterdir():
        if canonical_entry.name in TRANSIENT_SQLITE_COMPATIBILITY_NAMES:
            continue
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
        fsync_directory(ROOT)
    backup_stat = BACKUP.lstat()
    if (
        not stat.S_ISDIR(backup_stat.st_mode)
        or backup_stat.st_uid != 0
        or backup_stat.st_gid != 0
        or stat.S_IMODE(backup_stat.st_mode) != 0o700
    ):
        fail("the reserved backup path is not trusted")
    return True


def validate_state_name(value: Any) -> str:
    name = str(value)
    if not name or name in {".", ".."} or name in EXCLUDED or Path(name).name != name:
        fail("the migration marker contains an unsafe state name")
    return name


def validate_transaction_marker(payload: dict[str, Any]) -> dict[str, Any]:
    if payload.get("schema") == 1:
        values = payload.get("migrated_entries")
        if not isinstance(values, list):
            fail("the migration marker is invalid")
        names = [validate_state_name(value) for value in values]
        if len(names) != len(set(names)):
            fail("the migration marker contains duplicate state names")
        return {"schema": 1, "migrated_entries": sorted(names)}
    if payload.get("schema") != 2:
        fail("the migration marker has an unsupported schema")
    transaction_id = str(payload.get("transaction_id") or "")
    if len(transaction_id) != 32 or any(character not in "0123456789abcdef" for character in transaction_id):
        fail("the migration marker has an invalid transaction identifier")
    phase = payload.get("phase")
    if phase not in {"prepared", "complete"}:
        fail("the migration marker has an invalid phase")
    authorities = payload.get("authorities")
    archives = payload.get("archives")
    managed_entries = payload.get("managed_entries")
    if not isinstance(authorities, dict) or not isinstance(archives, dict) or not isinstance(managed_entries, list):
        fail("the migration marker has an invalid transaction manifest")
    managed = [validate_state_name(value) for value in managed_entries]
    if len(managed) != len(set(managed)) or set(managed) != set(authorities):
        fail("the migration marker does not bind every managed state entry")

    def validate_records(records: dict[str, Any], *, authority: bool) -> dict[str, dict[str, str]]:
        validated: dict[str, dict[str, str]] = {}
        for raw_name, raw_record in records.items():
            name = validate_state_name(raw_name)
            if not isinstance(raw_record, dict):
                fail("the migration marker contains an invalid archive record")
            archive_name = str(raw_record.get("archive_name") or "")
            if (
                not archive_name
                or archive_name in {".", ".."}
                or Path(archive_name).name != archive_name
            ):
                fail("the migration marker contains an unsafe archive name")
            expected = str(raw_record.get("sha256") or "")
            if len(expected) != 64 or any(character not in "0123456789abcdef" for character in expected):
                fail("the migration marker contains an invalid state digest")
            record = {"archive_name": archive_name, "sha256": expected}
            if authority:
                temp_name = str(raw_record.get("temp_name") or "")
                if (
                    not temp_name
                    or temp_name in {".", ".."}
                    or Path(temp_name).name != temp_name
                ):
                    fail("the migration marker contains an unsafe snapshot name")
                record["temp_name"] = temp_name
            validated[name] = record
        return validated

    validated_authorities = validate_records(authorities, authority=True)
    validated_archives = validate_records(archives, authority=False)
    claimed_archives: dict[str, tuple[str, str]] = {}
    claimed_temporaries: set[str] = set()
    for index, name in enumerate(sorted(validated_authorities)):
        record = validated_authorities[name]
        archive_name = record["archive_name"]
        if archive_name in claimed_archives:
            fail("the migration marker reuses an archive destination")
        claimed_archives[archive_name] = (name, record["sha256"])
        temporary_name = record["temp_name"]
        expected_temporary = f".txn-{transaction_id}-{index}.tmp"
        if temporary_name != expected_temporary:
            fail("the migration marker contains an unbound snapshot name")
        if temporary_name in claimed_temporaries:
            fail("the migration marker reuses a snapshot name")
        claimed_temporaries.add(temporary_name)
    for name, record in validated_archives.items():
        claim = (name, record["sha256"])
        existing = claimed_archives.get(record["archive_name"])
        if existing is not None and existing != claim:
            fail("the migration marker reuses an archive destination")
        claimed_archives[record["archive_name"]] = claim
    if claimed_temporaries & claimed_archives.keys():
        fail("the migration marker overlaps archive and snapshot names")
    return {
        "schema": 2,
        "transaction_id": transaction_id,
        "phase": phase,
        "managed_entries": sorted(managed),
        "migrated_entries": sorted(managed),
        "authorities": validated_authorities,
        "archives": validated_archives,
    }


def read_marker() -> dict[str, Any] | None:
    if not MARKER.exists():
        return None
    try:
        payload = json.loads(
            MARKER.read_text(encoding="utf-8"),
            object_pairs_hook=unique_json_object,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        fail("the migration marker is invalid")
    if not isinstance(payload, dict):
        fail("the migration marker is invalid")
    return validate_transaction_marker(payload)


def write_marker_payload(payload: dict[str, Any]) -> None:
    validated = validate_transaction_marker(payload)
    if MARKER_TEMP.exists():
        MARKER_TEMP.unlink()
        fsync_directory(ROOT)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(MARKER_TEMP, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(validated, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(MARKER_TEMP, MARKER)
    fsync_directory(ROOT)


def backup_candidate(name: str, *, require_unique: bool = False) -> Path | None:
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
    if require_unique and len(candidates) != 1:
        fail(
            "legacy migration metadata does not bind a unique archived "
            f"generation for {name}"
        )
    selected = max(candidates, key=lambda item: item[0])[1]
    validate_tree(selected)
    return selected


def allocate_archive_name(name: str, reserved: set[str]) -> str:
    ensure_backup_directory(create=True)
    suffix = 1
    while True:
        candidate = name if suffix == 1 else f"{name}.{suffix}"
        if candidate not in reserved and not (BACKUP / candidate).exists():
            reserved.add(candidate)
            return candidate
        suffix += 1


def copy_state(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)
    preserve_ownership(source, destination)


def build_transaction_manifest(
    sources: list[Path], archive_only: set[str]
) -> dict[str, Any]:
    transaction_id = secrets.token_hex(16)
    reserved: set[str] = set()
    source_entries = {source.name: source for source in sources}
    authorities: dict[str, dict[str, str]] = {}
    archives: dict[str, dict[str, str]] = {}
    projected_authorities = {
        entry.name: entry for entry in CANONICAL.iterdir()
    }
    for source in sources:
        if source.name in archive_only or source.name in projected_authorities:
            continue
        staged = STAGE / source.name
        if not staged.exists():
            fail("the prepared transaction is missing projected canonical state")
        projected_authorities[source.name] = staged
    for name, authority in sorted(projected_authorities.items()):
        expected = state_digest(authority)
        source = source_entries.get(name)
        if (
            source is not None
            and name not in archive_only
            and files_equal(source, authority)
        ):
            archive_name = allocate_archive_name(name, reserved)
            archives[name] = {"archive_name": archive_name, "sha256": expected}
        else:
            archive_name = allocate_archive_name(name, reserved)
        authorities[name] = {
            "archive_name": archive_name,
            "sha256": expected,
            "temp_name": f".txn-{transaction_id}-{len(authorities)}.tmp",
        }
    for source in sources:
        if source.name in archives:
            continue
        archives[source.name] = {
            "archive_name": allocate_archive_name(source.name, reserved),
            "sha256": state_digest(source),
        }
    return validate_transaction_marker(
        {
            "schema": 2,
            "transaction_id": transaction_id,
            "phase": "prepared",
            "managed_entries": sorted(authorities),
            "migrated_entries": sorted(authorities),
            "authorities": authorities,
            "archives": archives,
        }
    )


def copy_snapshot(source: Path, record: dict[str, str]) -> None:
    ensure_backup_directory(create=True)
    destination = BACKUP / record["archive_name"]
    if destination.exists():
        verify_state_digest(destination, record["sha256"], "archived authority")
        return
    temporary = BACKUP / record["temp_name"]
    if temporary.exists():
        validate_tree(temporary)
        if temporary.is_dir():
            shutil.rmtree(temporary)
        else:
            temporary.unlink()
        fsync_directory(BACKUP)
    copy_state(source, temporary)
    fsync_tree(temporary)
    verify_state_digest(temporary, record["sha256"], "transaction snapshot")
    try:
        rename_noreplace(temporary, destination)
    except FileExistsError:
        verify_state_digest(destination, record["sha256"], "archived authority")
        if temporary.is_dir():
            shutil.rmtree(temporary)
        else:
            temporary.unlink()
    fsync_directory(BACKUP)


def archive_exact(source: Path, record: dict[str, str]) -> None:
    ensure_backup_directory(create=True)
    destination = BACKUP / record["archive_name"]
    if destination.exists():
        verify_state_digest(destination, record["sha256"], "interim archive destination")
        if source.is_dir() and destination.is_dir():
            validate_tree(source)
            if state_digest(source) != record["sha256"] and not tree_is_subset(source, destination):
                fail("the remaining interim directory is not a safe archive subset")
        else:
            verify_state_digest(source, record["sha256"], "interim archive source")
        if source.is_dir():
            shutil.rmtree(source)
        else:
            source.unlink()
        fsync_directory(ROOT)
        return
    verify_state_digest(source, record["sha256"], "interim archive source")
    try:
        rename_noreplace(source, destination)
    except FileExistsError:
        verify_state_digest(destination, record["sha256"], "interim archive destination")
        if source.is_dir():
            shutil.rmtree(source)
        else:
            source.unlink()
    fsync_directory(BACKUP)
    fsync_directory(ROOT)


def recover_canonical_entry(name: str, record: dict[str, str]) -> None:
    destination = CANONICAL / name
    if destination.exists():
        verify_state_digest(destination, record["sha256"], "canonical authority")
        return
    candidates = (STAGE / name, ROOT / name, BACKUP / record["archive_name"])
    source = next(
        (candidate for candidate in candidates if candidate.exists() and not candidate.is_symlink()),
        None,
    )
    if source is None:
        fail("the durable transaction has no remaining authority for canonical state")
    verify_state_digest(source, record["sha256"], "transaction recovery authority")
    staged = STAGE / name
    if source != staged:
        if staged.exists():
            if staged.is_dir():
                shutil.rmtree(staged)
            else:
                staged.unlink()
        copy_state(source, staged)
        fsync_tree(staged)
    try:
        rename_noreplace(staged, destination)
    except FileExistsError:
        verify_state_digest(destination, record["sha256"], "canonical authority")
    fsync_directory(CANONICAL)


def execute_prepared_transaction(payload: dict[str, Any]) -> None:
    payload = validate_transaction_marker(payload)
    if payload["schema"] != 2:
        fail("cannot execute a legacy transaction marker")
    prepared = dict(payload)
    prepared["phase"] = "prepared"
    if read_marker() != prepared:
        write_marker_payload(prepared)
    ensure_backup_directory(create=True)
    if not CANONICAL.exists():
        CANONICAL.mkdir(mode=0o750)
        fsync_directory(ROOT)
    if not STAGE.exists():
        STAGE.mkdir(mode=0o700)
        fsync_directory(ROOT)
    for name, record in prepared["authorities"].items():
        recover_canonical_entry(name, record)
    verify_database(CANONICAL / "lnswitchboard.db")
    verify_credential_bundle(CANONICAL)
    normalize_app_ownership(CANONICAL)
    fsync_tree(CANONICAL)

    source_archives = prepared["archives"]
    for name, record in prepared["authorities"].items():
        source_record = source_archives.get(name)
        if source_record is not None and source_record["archive_name"] == record["archive_name"]:
            continue
        copy_snapshot(CANONICAL / name, record)
    for name, record in source_archives.items():
        source = ROOT / name
        destination = BACKUP / record["archive_name"]
        if source.exists() and not source.is_symlink():
            archive_exact(source, record)
        elif destination.exists():
            verify_state_digest(destination, record["sha256"], "completed interim archive")
        else:
            fail("the durable transaction is missing an interim archive")
    for record in prepared["authorities"].values():
        authority = BACKUP / record["archive_name"]
        if not authority.exists():
            fail("the durable transaction is missing a canonical authority")
        verify_state_digest(authority, record["sha256"], "canonical archive authority")
    ensure_compatibility_links(prepared)
    remove_owned_stage()
    fsync_directory(ROOT)
    completed = dict(prepared)
    completed["phase"] = "complete"
    write_marker_payload(completed)


def verify_legacy_archived_bundle(selected: dict[str, Path]) -> None:
    validation = Path(tempfile.mkdtemp(prefix=".legacy-bundle-", dir=ROOT))
    try:
        for name, source in selected.items():
            copy_state(source, validation / name)
        verify_database(validation / "lnswitchboard.db")
        verify_credential_bundle(validation)
    finally:
        shutil.rmtree(validation)
        fsync_directory(ROOT)


def record_complete_canonical_snapshot() -> None:
    manifest = build_transaction_manifest([], set())
    write_marker_payload(manifest)
    execute_prepared_transaction(manifest)


def complete_marker_matches_canonical(marker: dict[str, Any]) -> bool:
    if marker["schema"] != 2 or marker["phase"] != "complete":
        return False
    canonical_entries = {entry.name: entry for entry in CANONICAL.iterdir()}
    authorities = marker["authorities"]
    if set(authorities) != set(canonical_entries):
        return False
    if not ensure_backup_directory(create=False):
        return False
    for name, record in authorities.items():
        canonical = canonical_entries[name]
        if state_digest(canonical) != record["sha256"]:
            return False
        archived = BACKUP / record["archive_name"]
        if not archived.exists() or archived.is_symlink():
            return False
        if state_digest(archived) != record["sha256"]:
            return False
    return True


def build_legacy_recovery_manifest(selected: dict[str, Path]) -> dict[str, Any]:
    transaction_id = secrets.token_hex(16)
    canonical_entries = (
        {entry.name: entry for entry in CANONICAL.iterdir()}
        if CANONICAL.exists()
        else {}
    )
    staged_entries = {entry.name: entry for entry in STAGE.iterdir()}
    projected = dict(canonical_entries)
    projected.update(staged_entries)
    authorities: dict[str, dict[str, str]] = {}
    reserved = {path.name for path in selected.values()}
    for name, authority in sorted(projected.items()):
        archive_name = (
            selected[name].name
            if name in selected
            else allocate_archive_name(name, reserved)
        )
        authorities[name] = {
            "archive_name": archive_name,
            "sha256": state_digest(authority),
            "temp_name": f".txn-{transaction_id}-{len(authorities)}.tmp",
        }
    return validate_transaction_marker(
        {
            "schema": 2,
            "transaction_id": transaction_id,
            "phase": "prepared",
            "managed_entries": sorted(authorities),
            "migrated_entries": sorted(authorities),
            "authorities": authorities,
            "archives": {},
        }
    )


def recover_legacy_archived_transaction(marker_names: list[str]) -> bool:
    canonical_entries: dict[str, Path] = {}
    if CANONICAL.exists():
        if CANONICAL.is_symlink() or not CANONICAL.is_dir():
            fail("the canonical secrets path has an unexpected type")
        validate_canonical_tree()
        canonical_entries = {entry.name: entry for entry in CANONICAL.iterdir()}
    if set(marker_names).issubset(canonical_entries) and (
        not STAGE.exists() or not any(STAGE.iterdir())
    ):
        return False
    selected: dict[str, Path] = {}
    for name in marker_names:
        candidate = backup_candidate(name, require_unique=True)
        if candidate is None:
            fail("migration metadata exists but archived state is incomplete")
        selected[name] = candidate
    if not selected:
        fail("migration metadata exists without recoverable archived state")
    verify_legacy_archived_bundle(selected)
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
        fsync_directory(ROOT)
        staged_entries = {}
    for name, source in selected.items():
        if name in canonical_entries or name in staged_entries:
            continue
        staged = STAGE / name
        copy_state(source, staged)
        staged_entries[name] = staged
    verify_combined_bundle(CANONICAL, STAGE)
    fsync_tree(STAGE)
    prepared = build_legacy_recovery_manifest(selected)
    write_marker_payload(prepared)
    execute_prepared_transaction(prepared)
    print(
        "lnSwitchboard state migration: recovered "
        f"{len(marker_names)} legacy archived state entries"
    )
    return True


def _main_locked() -> None:
    validate_reserved_paths()
    marker = read_marker()
    if marker is not None and marker["schema"] == 2 and marker["phase"] == "prepared":
        execute_prepared_transaction(marker)
        print("lnSwitchboard state migration: resumed durable prepared transaction")
        return
    remove_transient_compatibility_links(marker)
    marker_names = (
        list(marker.get("managed_entries") or marker.get("migrated_entries") or [])
        if marker is not None
        else []
    )
    sources: list[Path] = []
    for item in sorted(ROOT.iterdir(), key=lambda candidate: candidate.name):
        if item.name in EXCLUDED:
            continue
        if item.is_symlink():
            if not is_compatibility_link(item) or not (CANONICAL / item.name).exists():
                fail("an unexpected symbolic link exists in interim state")
            continue
        sources.append(item)
    if MARKER_TEMP.exists() and marker is None:
        if not sources:
            fail("a temporary migration marker exists without recoverable source state")
        MARKER_TEMP.unlink()
        fsync_directory(ROOT)
    if not sources:
        if marker is not None and marker["schema"] == 2 and not CANONICAL.exists():
            recoverable = dict(marker)
            recoverable["phase"] = "prepared"
            write_marker_payload(recoverable)
            execute_prepared_transaction(recoverable)
            print("lnSwitchboard state migration: recovered the bound archived transaction")
            return
        if (
            marker is not None
            and marker["schema"] == 1
            and recover_legacy_archived_transaction(marker_names)
        ):
            return
        if CANONICAL.exists():
            if CANONICAL.is_symlink() or not CANONICAL.is_dir():
                fail("the canonical secrets path has an unexpected type")
            validate_canonical_tree()
            verify_database(CANONICAL / "lnswitchboard.db")
            verify_credential_bundle(CANONICAL)
            if (
                marker is not None
                and marker["schema"] == 2
                and not complete_marker_matches_canonical(marker)
            ):
                # A rollback can update the compatibility-linked canonical DB
                # without adding a top-level source entry. Supersede the old
                # recovery authority before it can later restore stale bytes.
                record_complete_canonical_snapshot()
            normalize_app_ownership(CANONICAL)
            remove_owned_stage()
            ensure_compatibility_links(read_marker())
            if marker is not None and marker["schema"] == 1:
                record_complete_canonical_snapshot()
        elif STAGE.exists():
            fail("staged state exists without canonical or source state")
        elif BACKUP.exists() and any(BACKUP.iterdir()) and marker is None:
            fail("archived state exists without an authenticated transaction marker")
        if MARKER_TEMP.exists():
            MARKER_TEMP.unlink()
            fsync_directory(ROOT)
        print("lnSwitchboard state migration: canonical or fresh layout; no migration needed")
        return

    for source in sources:
        validate_tree(source)
    if CANONICAL.exists() and (CANONICAL.is_symlink() or not CANONICAL.is_dir()):
        fail("the canonical secrets path has an unexpected type")
    CANONICAL.mkdir(mode=0o750, exist_ok=True)
    validate_canonical_tree()

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
            marker is not None
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

    verify_database(STAGE / "lnswitchboard.db")
    verify_combined_bundle(CANONICAL, STAGE)
    fsync_tree(STAGE)

    # Re-check all destinations immediately before the first commit mutation.
    for source in sources:
        if source.name in archive_only:
            continue
        destination = CANONICAL / source.name
        if destination.exists() and not files_equal(source, destination):
            fail("canonical state changed during migration; no source state was removed")

    manifest = build_transaction_manifest(sources, archive_only)
    write_marker_payload(manifest)
    execute_prepared_transaction(manifest)
    print(
        "lnSwitchboard state migration: preserved "
        f"{len(manifest['managed_entries'])} bound state entries"
    )


def main() -> None:
    if ROOT.is_symlink():
        fail("the app-data root cannot be a symbolic link")
    ROOT.mkdir(mode=0o750, parents=True, exist_ok=True)
    with protected_root():
        _main_locked()


if __name__ == "__main__":
    main()
