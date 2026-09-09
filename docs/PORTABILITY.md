# Build-host portability and Windows launcher notes

The portable stage architecture is now wrapped by the low-click Windows
launcher. The wrapper orchestrates the same Linux implementation; it does not
create a second build pipeline.

## Native WSL path strategy

`build/run-wsl.sh` discovers the checkout from its own location and asks
`build/resolve-native-build.py` for the native build directory. Because stages
run as root, the resolver never uses root's `HOME` and never infers a user from
a hard-coded UID. It selects the first applicable source:

1. explicit `FOURTW_WSL_USER`;
2. a non-root `SUDO_USER`;
3. `[user] default=` in `/etc/wsl.conf`;
4. the sole eligible normal login account, using `UID_MIN`/`UID_MAX` from
   `/etc/login.defs`.

The selected account must exist, be non-root, and have an existing native home
outside `/mnt`. Ambiguous or unsafe results stop with a clear error. The
canonical directory is:

```text
<selected account home>/4tw-ubuntu-sway-build
```

The source checkout may remain on Windows and may contain spaces. The wrapper
quotes every source/destination use, copies source to the native directory, and
copies only non-IMG artifacts back automatically. `.git`, `.work`,
`.build-cache`, `artifacts`, `prompts` and `__pycache__` are excluded from source
copying and preserved in an existing native build tree, while stale ordinary
source files are removed so a deleted overlay file cannot survive a later sync.
`.gitattributes` preserves LF endings for Linux build/runtime scripts
when Git checks the repository out on Windows; generated Python bytecode is not
source-controlled.
The large IMG remains native until the launcher's single post-verification
Windows copy documented in `README.md` and `docs/WINDOWS-BUILDER.md`.

## Self-containment and path audit

Tracked source previously contained these machine-layout assumptions, all of
which were removed:

- an original-developer-specific native build directory in `run-wsl.sh`;
- an original-developer-specific earlier BCLD cache in `prepare-packages.sh`;
- original Windows checkout, WSL checkout, IMG export and artifact paths in
  `README.md`;
- an original native build path in the historical build notes;
- a sibling-repository notation that could imply an external BCLD checkout.

The current wrapper uses only `assets/4TW-OS.png` from this repository and
rejects a missing or externally linked logo before copying source. There is no
build dependency on a sibling repository, an old artifact, an external logo or
an earlier BCLD tree.

Remaining absolute paths are intentional and not build-host identity:

- `/home/kiosk` and `/run/user/1000` belong to the fixed target appliance
  account, not the person building it;
- `/mnt` appears in safety checks that prevent building on Windows filesystems;
- `/etc`, `/usr`, `/var`, `/run`, `/boot`, `/config` and `/writing` are target
  OS or standard WSL system paths;
- historical mentions of BCLD in build/verification notes describe provenance
  and explicitly state that it is not a dependency.

Five ignored local artifact logs retained the old absolute path as historical
build evidence: `build-img.log`, `configure-rootfs.log`,
`prepare-vm-tools.log`, `verify-img.log` and `vm-command.json`. They are under
the Git-ignored `artifacts/` directory, are not source inputs, and will not
exist in a fresh clone. They were retained so the already verified IMG and its
audit trail remained untouched. The local Git-ignored `prompts/` directory also
contains copies of request text with the old example paths; it is excluded from
native source synchronization and is likewise absent from a fresh clone.

No tracked source contains a real SSID, Wi-Fi password or encoded credential.
The committed `config/4tw.cfg` credential values remain empty.

## Cache behavior and migration result

The canonical cache is always:

```text
<native build directory>/.build-cache/apt/archives
```

It is automatically created, build-time only, Git-ignored, excluded from the
IMG and safe to delete. An optional existing cache can be supplied through the
absolute native-Linux path `FOURTW_OLD_APT_CACHE`. Only absent `.deb` files are
copied with `rsync --ignore-existing`; the old cache is never moved, deleted,
mounted or modified. An unset or nonexistent optional path is silent and
normal.

On the portability-test machine, the pre-pass current-build cache was detected
with **1,062 `.deb` files occupying 1.9 GiB**. The dynamic resolver selected the
same native directory, so no migration copy was necessary and all 1,062 files
remain available in the new canonical cache. On a machine where a desired old
cache is elsewhere, set `FOURTW_OLD_APT_CACHE` for the next `packages` stage.

APT/debootstrap signature, repository and package-hash verification are
unchanged. An imported archive is merely a candidate and is accepted only
through the existing authenticated package workflow.

## Stage order and resume behavior

The launcher calls the existing stages, as WSL root, in this exact order:

```text
prepare-packages.sh
    -> configure-rootfs.sh
    -> build-img.sh
    -> verify-img.sh
```

`run-wsl.sh` exposes these as `packages`, `configure`, `image` and `verify`.
Its diagnostic/support stages remain `vm-tools`, `boot-test`, `notifications`,
`fix-timeout` and `fix-wifi-retry`; they are not an alternative build pipeline.

- `packages` preserves a successful `bootstrap.ok`, invalidates `packages.ok`
  and `configured.ok` before package work, and is safe to rerun after a later
  APT failure. If debootstrap was interrupted before `bootstrap.ok`, it retains
  the partial rootfs and deliberately stops for inspection instead of deleting
  it silently.
- `configure` requires `packages.ok`, clears `configured.ok` before work, tracks
  its chroot mounts, and is safe to rerun after the cause of a failure is fixed.
- `image` requires `configured.ok` and a matching source digest. It refuses to
  overwrite any complete or partial IMG. After an image-stage failure, inspect
  and explicitly move the partial file before retrying.
- `verify` mounts the deliverable read-only, uses copies for FAT write tests,
  and is safe to rerun. A failed verification should leave the IMG available
  for diagnosis rather than trigger automatic cleanup.

The native `.work`, `.build-cache` and `artifacts` directories survive closing
PowerShell, stopping WSL and restarting Windows. After an ordinary later-stage
failure, rerun that stage. If a process was forcibly interrupted while WSL
remains running, inspect lingering chroot/loop mounts before retrying; a Windows
restart naturally stops WSL mounts but does not erase native files.

## Beginner launcher flow

First run on a Windows PC without WSL:

```text
launcher enables/installs official WSL2 components if needed
launcher installs Ubuntu 26.04 if needed
Windows may request a restart
user restarts Windows and runs the same launcher again
```

Second/resumed run:

```text
launcher detects WSL2 and Ubuntu 26.04
resolves the checkout and non-root WSL home
prepares packages
configures and tests the rootfs
creates exactly one IMG
verifies that IMG
copies and rehashes the verified IMG in Windows Downloads
tells the user to flash it with Rufus
```

`BUILD-4TW-OS.cmd` is the stable double-click entry point and
`BUILD-4TW-OS.ps1` implements detection, resumable setup, preflights and final
export. `build/run-wsl.sh all` delegates to `build/build-all.sh`, which runs the
four established scripts in order. A small optional ignored state file improves
the post-restart explanation, but every run redetects actual capabilities.

## Remaining portability limitations

- Windows 11 with WSL2 and the intended `Ubuntu-26.04` distribution is required.
  A first-time WSL installation may require a Windows restart.
- The WSL host needs enough native free space for the rootfs, cache and 16 GiB
  sparse IMG. The launcher installs the documented Linux build tools.
- A fresh cache requires internet access to authenticated Ubuntu and Mozilla
  repositories.
- All stages require WSL root. Hosts with multiple eligible WSL accounts and no
  configured default must supply `FOURTW_WSL_USER`.
- After exact verification, the large IMG is copied once to the current user's
  known Downloads folder and rehashed there. Rufus flashing remains manual.
