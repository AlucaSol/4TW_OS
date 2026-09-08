#!/usr/bin/python3
import json
from pathlib import Path
import sys

project, root = map(Path, sys.argv[1:])
sys.path.insert(0, str(project / "rootfs-overlay/usr/local/lib/4tw"))
from appliance import DEFAULT_URL, permitted_url
patterns = json.loads((project / "config/allowed-sites.json").read_text())
assert patterns and len(patterns) <= 1000
for pattern in patterns:
    # Validate every pattern, including entries after the first match.
    permitted_url("https://invalid.example/", [pattern])
assert permitted_url(DEFAULT_URL, patterns)
policy = json.loads((project / "policies/policies.json").read_text())
policy["policies"]["WebsiteFilter"]["Exceptions"] = patterns
destination = root / "etc/firefox/policies/policies.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(policy, indent=2) + "\n")
# Mozilla Linux supports /etc/firefox/policies; distribution is a single link
# to the same policy file, not a second independently maintained policy set.
link = root / "usr/lib/firefox/distribution/policies.json"
if link.is_symlink():
    link.unlink()
elif link.exists():
    raise SystemExit("Unexpected package distribution policy: inspect before replacing")
link.symlink_to("/etc/firefox/policies/policies.json")
