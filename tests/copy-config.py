#!/usr/bin/python3
"""Copy partition three using GPT coordinates, never a physical disk path."""
from pathlib import Path
import struct
import sys
source, destination = map(Path, sys.argv[1:])
assert source.is_file() and source.suffix == ".img"
assert destination.name == "config-write-test.fat" and destination.parent.name == ".work"
with source.open("rb") as handle:
    handle.seek(512)
    header = handle.read(512)
    assert header[:8] == b"EFI PART"
    table_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    handle.seek(table_lba * 512 + entry_size * 2)
    entry = handle.read(entry_size)
    first, last = struct.unpack_from("<QQ", entry, 32)
    assert 0 < first < last < source.stat().st_size // 512
    handle.seek(first * 512)
    remaining = (last - first + 1) * 512
    with destination.open("wb") as output:
        while remaining:
            data = handle.read(min(1024 * 1024, remaining))
            if not data:
                raise RuntimeError("Truncated image")
            output.write(data)
            remaining -= len(data)
