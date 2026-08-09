#!/usr/bin/env python3
"""Bind-source identity guard for lnSwitchboard's privileged state initializer."""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path
from typing import NoReturn

HOST_VIEW = Path("/host-view")
INITIALIZER = "/usr/local/bin/lnswitchboard-prepare-state"
PROXY_ENV = b"LOG_LEVEL=silent\nPROXY_AUTH_WHITELIST=\n"

MOUNTS = (
    (Path("secrets"), Path("/app-secrets")),
    (Path("connectors/cloudflare-mesh"), Path("/app-secrets/cloudflare-mesh")),
    (Path("secrets/tailscale"), Path("/tailscale-control")),
    (Path("connectors/tailscale"), Path("/tailscale-state")),
    (Path("public-backend"), Path("/public-socket")),
    (Path("proxy-config"), Path("/proxy-config")),
    (Path("connectors/cloudflare-mesh-state"), Path("/cloudflare-mesh-state")),
)


def fail(message: str) -> "NoReturn":
    print(f"lnSwitchboard state initialization refused: {message}", file=sys.stderr)
    raise SystemExit(65)


def open_directory(path: str | Path, *, dir_fd: int | None = None) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        return os.open(path, flags, dir_fd=dir_fd)
    except OSError:
        fail("a required state directory is unavailable or unsafe")


def open_host_relative(root_fd: int, relative: Path) -> int:
    current = os.dup(root_fd)
    try:
        for component in relative.parts:
            child = open_directory(component, dir_fd=current)
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


def require_same_directory(host_fd: int, direct_fd: int) -> None:
    host_stat = os.fstat(host_fd)
    direct_stat = os.fstat(direct_fd)
    if not stat.S_ISDIR(host_stat.st_mode) or not stat.S_ISDIR(direct_stat.st_mode):
        fail("a writable state mount is not a directory")
    if (host_stat.st_dev, host_stat.st_ino) != (direct_stat.st_dev, direct_stat.st_ino):
        fail("a writable state mount does not match its validated host source")


def write_proxy_config(directory_fd: int) -> None:
    os.fchown(directory_fd, 0, 0)
    os.fchmod(directory_fd, 0o755)
    temporary = f".app-proxy.env.tmp.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        output_fd = os.open(temporary, flags, 0o444, dir_fd=directory_fd)
        try:
            os.fchown(output_fd, 0, 0)
            os.fchmod(output_fd, 0o444)
            view = memoryview(PROXY_ENV)
            while view:
                written = os.write(output_fd, view)
                if written <= 0:
                    fail("the App Proxy configuration could not be written")
                view = view[written:]
            os.fsync(output_fd)
        finally:
            os.close(output_fd)
        try:
            existing = os.stat(
                "app-proxy.env", dir_fd=directory_fd, follow_symlinks=False
            )
        except FileNotFoundError:
            existing = None
        if existing is not None and not stat.S_ISREG(existing.st_mode):
            fail("the App Proxy configuration path has an unexpected type")
        os.replace(
            temporary,
            "app-proxy.env",
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        os.fsync(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    host_root_fd = open_directory(HOST_VIEW)
    direct_fds: dict[Path, int] = {}
    try:
        for relative, direct in MOUNTS:
            host_fd = open_host_relative(host_root_fd, relative)
            direct_fd = open_directory(direct)
            try:
                require_same_directory(host_fd, direct_fd)
            finally:
                os.close(host_fd)
            direct_fds[direct] = direct_fd
        mesh_state_fd = direct_fds[Path("/cloudflare-mesh-state")]
        os.fchown(mesh_state_fd, 0, 0)
        os.fchmod(mesh_state_fd, 0o700)
        write_proxy_config(direct_fds[Path("/proxy-config")])
    finally:
        os.close(host_root_fd)
        for descriptor in direct_fds.values():
            os.close(descriptor)
    os.execv(INITIALIZER, [INITIALIZER])


if __name__ == "__main__":
    main()
