# Low-click Windows builder

`BUILD-4TW-OS.cmd` is the public entry point. It starts
`BUILD-4TW-OS.ps1` with a process-only PowerShell execution-policy bypass; it
does not change the user's configured policy. Keep both files in the extracted
repository and double-click the CMD file.

## What the launcher does

1. Finds the repository from its own path. Git metadata is optional and paths
   containing spaces are supported.
2. Detects WSL using `wsl --version` and `wsl --status`. If necessary it asks
   for one UAC approval to install official WSL components or update WSL. The
   rest of the launcher is not elevated.
3. If Windows reports first-time WSL setup, it stops with a restart message.
   Restart Windows and run `BUILD-4TW-OS.cmd` again. A small ignored state file
   improves this message, but capability detection remains authoritative.
4. Detects `Ubuntu-26.04` with `wsl --list --verbose`. If absent, it confirms
   the identifier with `wsl --list --online`, installs it without changing
   unrelated distributions or the default distribution, then opens its normal
   first run. Create a Linux username and password, close Ubuntu, and run the
   same CMD again. The password is neither invented nor stored by 4TW-OS.
5. Confirms the selected distribution uses WSL2. Only `Ubuntu-26.04` is
   converted if it was installed as WSL1.
6. Checks approximately 18 GiB on native WSL for image construction and 4 GiB
   on the Windows output drive for the compressed release and safe temporary
   copy. Existing retained files count against free space. No user files are
   deleted.
7. Checks/installs the exact Ubuntu build-host tools. QEMU and OVMF are not
   normal Release-build prerequisites.
8. Uses the existing portable Linux account resolver and copies source from the
   Windows checkout into that account's native WSL filesystem. Rootfs and IMG
   construction never run under `/mnt/c`.
9. Runs the canonical `build/run-wsl.sh all` workflow:

   ```text
   [1/6] prepare-packages.sh
   [2/6] configure-rootfs.sh
   [3/6] build-img.sh
   [4/6] verify-img.sh
   [5/6] compress-release.sh
   ```

10. Stage 5 rechecks the exact raw IMG against `verify-img`'s checksum/marker,
    compresses it directly with `zstd -T0 -10`, runs `zstd --test`, records the
    raw source hash, hashes the `.img.zst`, and requires it to be below
    2,147,483,648 bytes.
11. `[6/6]` copies only the compressed release to a Windows `.partial` file,
    hashes that Windows copy, requires it to match the native compressed-file
    checksum, and only then publishes the final `.img.zst` name. The raw IMG
    remains inside native WSL.

The persistent APT download cache and reusable rootfs remain in the resolved
native WSL build directory. Rerunning the launcher does not wipe them. The
package stage still authenticates Ubuntu/Mozilla repositories, indexes and
package hashes; cached files merely avoid unnecessary downloads.

Before making any host change, the launcher creates one build-cycle provenance
record under `%LOCALAPPDATA%\4TW-OS\build-provenance.json`. Resumed runs retain
the original before-build state rather than replacing it. The record includes
WSL/Ubuntu presence, the installed distro list, any 4TW-initiated WSL install
or update, elevated before/after optional-feature states when 4TW installs WSL,
Ubuntu installation or WSL1-to-WSL2 conversion, host-dependency invocation,
the selected Linux account/native directory, final output directory and final
release hash. A completed cleanup permits a new build cycle to take a new
before-state snapshot. No Wi-Fi credential or USB content is recorded.

## Pauses and resume

Two one-time actions cannot safely be unattended:

- A new WSL installation may require a Windows restart.
- A new Ubuntu distribution requires the user to create its standard Linux
  account and password.

At either pause, follow the displayed instructions. The resume action is always
the same: double-click `BUILD-4TW-OS.cmd` again. No scheduled task, saved
credential or hidden startup action is created.

## Output and safe replacement

The default Windows output is the current user's known Downloads folder:

```text
Downloads\4TW-OS\
    4TW-OS_RELEASE.img.zst
    4TW-OS_RELEASE.img.zst.sha256
    VERIFICATION.txt
```

If the known Downloads folder cannot be resolved, the fallback is `output\`
beside the launcher. A matching verified output is reused without another
compressed-file copy. When a different verified build replaces it, the former
Windows output is moved to `previous\`; at most one previous release is retained. The
Linux orchestrator applies the same bounded policy to previously verified
native output. It refuses to move or overwrite an IMG that lacks verification
evidence.

The public checksum is SHA-256 over the actual `.img.zst` download. Native WSL
first verifies the raw and compressed artifacts, then Windows copies the
compressed bytes once under a temporary `.partial` name and independently
hashes the complete copy. A mismatch stops the launcher and is never published
under the final `.img.zst` name, so the success screen is shown only for a
verified Windows copy.

Compression and export are independently resumable. If raw verification has
passed but compression failed, rerunning skips the valid raw build and retries
stage 5. If the compressed artifact is intact but Windows export failed,
rerunning validates and reuses it before retrying only stage 6. A recorded raw
SHA-256 prevents an older `.zst` from being reused after the IMG changes.

The builder never deletes either the verified raw IMG or the persistent APT
cache. An advanced developer who later needs the native-WSL disk space may
remove the raw IMG together with its adjacent raw checksum and `.work`
verification markers; the next normal source build will recreate and verify a
new raw IMG before it can produce another public `.zst`. This is optional
maintenance, not part of the normal launcher workflow.

## Failures and logs

Each Linux stage streams real output and writes a named log beneath
`artifacts/`. A nonzero stage stops all later stages, reports the failing stage
and log, and preserves the package cache and safe intermediate state. Correct
the reported issue and normally rerun `BUILD-4TW-OS.cmd`; it never opens an
interactive troubleshooting shell. Compression failure preserves the verified
raw IMG. An otherwise valid compressed file at or above GitHub's 2 GiB
per-file limit is retained for diagnosis but is not exported as Release-ready.

Some WSL installations print unrelated Windows-PATH translation diagnostics
while successfully returning a Linux or Windows path. The launcher validates
and extracts exactly one path of the expected kind, so diagnostic text cannot
become part of `wsl --cd` or an artifact filename. Missing or ambiguous path
output still fails closed.

## Final manual step

The launcher deliberately never flashes disks. After **4TW-OS BUILD COMPLETE**,
open the official Rufus application, select only the intended USB, choose
`4TW-OS_RELEASE.img.zst` directly, and write it. Do not extract it first. Rufus
4.7 or newer decompresses Zstandard disk images while flashing. Rufus erases
the selected USB. Leave Secure Boot enabled on the target laptop.

Microsoft's supported WSL command reference is at
<https://learn.microsoft.com/windows/wsl/basic-commands> and installation
guidance is at <https://learn.microsoft.com/windows/wsl/install>.

## Removing the build environment

`CLEANUP-4TW-OS.cmd` is the matching low-click cleanup entry point. It hashes
the finished Windows release before inspecting or removing build data. It can
remove the complete validated native build tree and generated IMG duplicates
under this repository's ignored `artifacts` directory while retaining small
diagnostic logs. Ubuntu unregistration is offered only when provenance proves
that this build cycle started without Ubuntu-26.04 and the launcher then
successfully installed that exact distro; it additionally requires the user to
type `REMOVE`. Shared WSL features and other distributions are always retained.

Use `CLEANUP-4TW-OS.cmd --dry-run` for a non-destructive inventory. Detailed
provenance, mount/loop safety, legacy-build handling and disk-space behavior are
documented in `CLEANUP.md`.
