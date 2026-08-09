#!/usr/bin/env python3
"""Prove App Proxy temporary retirement is replacement-safe and recoverable."""

import importlib.util
import os
from pathlib import Path
import shutil
import tempfile

SOURCE = Path("/opt/state-migrate.py")
spec = importlib.util.spec_from_file_location("state_migrate_proxy_probe", SOURCE)
assert spec and spec.loader
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)

root = Path(tempfile.mkdtemp(prefix="proxy-retire-race-", dir="/fixture"))
proxy = root / "proxy-config"
proxy.mkdir(mode=0o755)
setattr(migration, "PROXY_CONFIG", proxy)
name = ".app-proxy.env.tmp.321"
replacement = b"LOG_LEVEL=silent\nPROXY_AUTH_WHITELIST=\n"

try:
    temporary = proxy / name
    temporary.write_bytes(replacement)
    temporary.chmod(0o444)

    real_rename = getattr(migration, "rename_noreplace")
    swapped = [False]

    def replace_then_rename(source: Path, destination: Path) -> None:
        if source == temporary and not swapped[0]:
            swapped[0] = True
            source.unlink()
            source.write_bytes(replacement)
            source.chmod(0o444)
        real_rename(source, destination)

    setattr(migration, "rename_noreplace", replace_then_rename)
    try:
        migration.remove_owned_proxy_temporaries()
    except SystemExit as error:
        assert error.code == 65
    else:
        raise AssertionError("proxy replacement race was not rejected")

    assert swapped[0]
    assert temporary.read_bytes() == replacement
    assert not (proxy / migration.APP_PROXY_RETIRE_NAME).exists()
    print("GREEN proxy_retirement_final_replacement_survives")

    setattr(migration, "rename_noreplace", real_rename)
    temporary.unlink()
    retirement = proxy / migration.APP_PROXY_RETIRE_NAME
    retirement.mkdir(mode=0o700)
    interrupted = retirement / ".app-proxy.env.tmp.322"
    interrupted.write_bytes(replacement)
    interrupted.chmod(0o444)
    migration.remove_owned_proxy_temporaries()
    assert not retirement.exists()
    print("GREEN proxy_retirement_interruption_recovers")
finally:
    shutil.rmtree(root)
