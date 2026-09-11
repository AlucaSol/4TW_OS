# Safe build-environment cleanup

`CLEANUP-4TW-OS.cmd` removes only resources attributable to a 4TW-OS source
build. It is not a general WSL, Ubuntu, APT, Windows or Downloads cleaner. It
never accesses a flashed USB, `4TW-CONFIG`, `4TW-WRITING`, Windows EFI,
BitLocker, Secure Boot, TPM or the internal boot configuration.

## Builder audit and generated resources

The Windows launcher detects WSL with `wsl --version` and `wsl --status`. When
needed, its one elevated child invokes `wsl --install --no-distribution`; the
ignored `.4tw-launcher-state.json` lets that setup pause safely for a Windows
restart. It lists distributions with `wsl --list --verbose`, installs only
`Ubuntu-26.04` with `wsl --install --distribution Ubuntu-26.04 --no-launch`,
and lets Ubuntu perform its normal one-time account creation. An existing WSL1
instance of that exact distro is converted with `wsl --set-version`.

`build/resolve-native-build.py` selects one validated non-root login account.
`build/source-copy.sh` copies source into:

```text
<resolved native Linux home>/4tw-ubuntu-sway-build/
```

That tree contains all normal large Linux-side build data:

- `.build-cache/apt/archives/`: persistent build-only package downloads;
- `.work/rootfs/`: debootstrap/package/configuration staging;
- `.work/`: markers, test copies, mounts and VM state;
- `artifacts/`: raw/compressed images, previous image, hashes, reports and logs;
- the synchronized native source copy.

Normal host dependencies are the exact packages in `build/setup-host.sh`.
Optional `run-wsl.sh vm-tools` installs `qemu-system-x86` and `ovmf`; its report
records whether those two direct packages were already installed. They are
host-only and never enter the USB image. Cleanup does not purge packages from a
preserved distro because the builder did not historically record a complete,
dependency-level before-state that could prove exclusive ownership.

Package/configuration stages bind the external cache and mount private `dev`,
`dev/pts`, `proc`, `sys` and `run` trees below `.work/rootfs`. Image and verify
stages attach loop devices backed only by build-tree files and mount their
partitions below `.work`. Existing stages use exit traps and a shared
`.work/build.lock`; the cleanup helper also handles safely attributable remains
from interruption.

The Windows checkout receives small diagnostic artifacts through `rsync`.
Large raw and compressed images are excluded from that normal sync, although
older/manual work may have left generated image copies under the ignored
repository `artifacts` directory. The public builder exports only the verified
release to its resolved Windows output, normally:

```text
%USERPROFILE%\Downloads\4TW-OS\
    4TW-OS_RELEASE.img.zst
    4TW-OS_RELEASE.img.zst.sha256
    VERIFICATION.txt
```

Cleanup also recognizes the former exact `4TW-OS_RELEASE.img` plus checksum,
but does not search Downloads for similarly named files.

## Provenance

Future builds atomically maintain:

```text
%LOCALAPPDATA%\4TW-OS\build-provenance.json
```

This Windows-side record survives restart, WSL termination, native-tree
deletion and Ubuntu unregistration. The first run in a build cycle records:

- whether functional WSL and Ubuntu-26.04 were present;
- installed distro names;
- the repository used to start the cycle;
- whether 4TW invoked/completed WSL or Ubuntu installation;
- before/after WSL and VirtualMachinePlatform feature state when the elevated
  WSL-install child can query it, plus features whose state changed;
- whether 4TW invoked a WSL update or converted Ubuntu from WSL1 to WSL2;
- whether host-dependency installation was invoked/completed;
- selected WSL user and exact resolved native build directory;
- actual Windows output directory, public filename and SHA-256;
- cleanup outcome and optional VM-tools evidence when available.

Resuming after restart or Ubuntu first-run never overwrites the original
before-state. A malformed, reparse-point or contradictory provenance record
fails closed. Cleanup never invents provenance for an older build.

## Cleanup sequence

Before destructive choices, cleanup:

1. resolves the recorded output, or conservatively checks only the builder's
   normal Downloads/fallback locations for an old build;
2. hashes the exact `.img.zst` (or legacy exact `.img`) against its adjacent
   checksum;
3. stops if the release is missing, invalid, ambiguous or contradicts its
   recorded build hash;
4. lists WSL distributions and explicitly leaves other distros alone;
5. discovers all normal users' exact `4tw-ubuntu-sway-build` locations and
   stops if more than one exists;
6. validates the selected account, resolved native home, directory name and
   4TW-OS source/generated-data sentinels;
7. calculates physical Linux disk use with `du` and inventories only mounts
   below that exact tree and loops backed by files inside it.

Removal acquires the normal build lock. A validated project QEMU process is
stopped; another live process using files/cwd/root below the tree stops cleanup.
Mounts are unmounted child-first only below the tree. Loop devices are detached
only when their backing file is inside the tree and none of their partitions is
mounted elsewhere. Generic `umount -a`, `losetup -D`, global process killing and
generic APT-cache deletion are not used. Only after all these checks does the
helper remove that one complete build directory.

Repository cleanup separately selects only generated `4TW-OS*.img`, direct
`.img.zst` counterparts/partials, and their checksum/source-hash sidecars below
the real, non-reparse `artifacts` directory. It leaves source, configuration,
assets, documentation and small logs in place. The verified output directory
and everything inside it are outside every deletion target.

Every destructive choice defaults to No. Run this to see the same inventory
without prompts, logs, provenance updates, unmounts or deletions:

```bat
CLEANUP-4TW-OS.cmd --dry-run
```

## Ubuntu and shared WSL behavior

- **Ubuntu pre-existed:** it is never unregistered. Cleanup may remove only the
  exact project tree after confirmation.
- **Ownership is unknown/old build:** same conservative project-tree-only
  behavior. The distro name is never treated as proof of ownership.
- **Provenance proves 4TW installed Ubuntu:** cleanup displays a permanent-data
  loss warning and offers exact-distro termination/unregistration only after
  the user types `REMOVE`. Declining falls back to the optional tree cleanup.
- **Distro already absent/tree already gone:** reported as already clean; this
  is not a fatal error unless it contradicts pre-existing ownership state.

The utility deliberately does not disable WSL, VirtualMachinePlatform or a
Windows optional feature, uninstall Store/AppX packages, edit the registry, or
touch another distro. Modern `wsl --install` manages shared Windows/Store state,
and the builder does not record enough package identity and dependency evidence
to prove safe automatic reversal on every supported Windows 11 configuration.
If a project-created distro is unregistered, any small Ubuntu launcher entry
that remains can be removed manually through Windows Installed Apps.

Unregistering a project-created distro removes its WSL virtual disk naturally.
When a pre-existing distro is kept, deleting the project tree frees Linux
filesystem space but its dynamically expanding VHD may not immediately become
smaller on the Windows filesystem. Cleanup reports this and does not run
DiskPart, manipulate an AppData VHDX, stop other distros for compaction, or
attempt an undocumented shortcut.

## Test matrix

Automated tests cover provenance persistence/new cycles, fresh versus
pre-existing versus unknown ownership, contradictory state, compressed and
legacy release verification, corrupt/missing/ambiguous output, paths containing
spaces, strict native diagnostics, unsafe `/mnt` targets, generated-artifact
selection, unregister confirmation gates, and the absence of shared-feature,
package-purge and VHD manipulation commands. Native tests cover unsafe-path
rejection, exact mount filtering, build locking and prohibited generic cleanup.

The real current machine has additionally been exercised only with
`--dry-run`: its Windows `.img.zst` checksum passed; exactly one 19.1 GiB
native build tree was found with zero project mounts/loops; Ubuntu provenance
was absent and therefore classified unknown/preserve; and approximately 18.0
GiB of repository image duplicates were listed. Nothing was deleted or changed.

Fresh installation, project-created Ubuntu unregistration, a deliberately live
interrupted loop/mount and physical host package histories remain simulated or
statically reasoned rather than destructively exercised on the user's machine.
