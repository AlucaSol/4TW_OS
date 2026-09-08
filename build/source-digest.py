#!/usr/bin/python3
import hashlib
from pathlib import Path
import sys
project = Path(sys.argv[1])
digest = hashlib.sha256()
for folder in ("config", "rootfs-overlay", "policies", "assets"):
    for path in sorted((project / folder).rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            digest.update(str(path.relative_to(project)).encode())
            digest.update(path.read_bytes())
print(digest.hexdigest())
