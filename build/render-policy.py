#!/usr/bin/python3
from pathlib import Path
import shutil
import sys

project, root = map(Path, sys.argv[1:])
sys.path.insert(0, str(project / "rootfs-overlay/usr/local/lib/4tw"))
from appliance import parse_config, write_firefox_policy

template = root / "etc/4tw/firefox-policies.base.json"
template.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(project / "policies/policies.json", template)
config = parse_config((project / "config/4tw.cfg").read_text(encoding="utf-8-sig"))
write_firefox_policy(config.start_url, config.site_lock, config.allowed_extra_domains,
                     template, root / "etc/firefox/policies/policies.json")
# Mozilla Linux supports /etc/firefox/policies; distribution is a single link
# to the same policy file, not a second independently maintained policy set.
link = root / "usr/lib/firefox/distribution/policies.json"
if link.is_symlink():
    link.unlink()
elif link.exists():
    raise SystemExit("Unexpected package distribution policy: inspect before replacing")
link.symlink_to("/etc/firefox/policies/policies.json")
