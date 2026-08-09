#!/usr/bin/env python3
"""Prove a final replacement is restored rather than path-unlinked."""

import importlib.util
import os
from pathlib import Path
import shutil
import tempfile

SOURCE = Path("/opt/state-migrate.py")
spec = importlib.util.spec_from_file_location("state_migrate_probe", SOURCE)
assert spec and spec.loader
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)

name = "lnswitchboard.db-journal"
root = Path(tempfile.mkdtemp(prefix="transient-retire-race-", dir="/fixture"))
try:
    (root / "secrets").mkdir()
    (root / ".lnswitchboard-state-backup-v1").mkdir()
    setattr(migration, "ROOT", root)
    setattr(migration, "CANONICAL", root / "secrets")
    setattr(migration, "BACKUP", root / ".lnswitchboard-state-backup-v1")
    setattr(migration, "TRANSIENT_RETIRE", root / ".lnswitchboard-transient-link-retire-v1")

    os.symlink(Path("secrets") / name, root / name)
    archive = migration.BACKUP / "journal.authority"
    archive.write_bytes(b"authority-generation")
    transaction_id = "a" * 32
    marker = migration.validate_transaction_marker(
        {
            "schema": 2,
            "transaction_id": transaction_id,
            "phase": "complete",
            "managed_entries": [name],
            "authorities": {
                name: {
                    "archive_name": archive.name,
                    "sha256": migration.state_digest(archive),
                    "temp_name": f".txn-{transaction_id}-0.tmp",
                }
            },
            "archives": {},
        }
    )

    real_rename = getattr(migration, "rename_noreplace")
    swapped = [False]

    def replace_then_rename(source: Path, destination: Path) -> None:
        if source == root / name and not swapped[0]:
            swapped[0] = True
            os.unlink(source)
            source.write_bytes(b"attacker-replacement-must-survive")
        real_rename(source, destination)

    setattr(migration, "rename_noreplace", replace_then_rename)
    try:
        migration.remove_transient_compatibility_links(marker)
    except SystemExit as error:
        assert error.code == 65
    else:
        raise AssertionError("replacement race was not rejected")

    assert swapped[0]
    assert (root / name).read_bytes() == b"attacker-replacement-must-survive"
    assert not getattr(migration, "TRANSIENT_RETIRE").exists()
    print("GREEN transient_retirement_final_replacement_survives")
finally:
    shutil.rmtree(root)
