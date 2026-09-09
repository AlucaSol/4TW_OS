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
6. Checks approximately 18 GiB of free space on both the native WSL filesystem
   and the Windows output drive before expensive work. Existing retained files
   already count against the reported free space. No user files are deleted.
7. Checks/installs the exact Ubuntu build-host tools. QEMU and OVMF are not
   normal Release-build prerequisites.
8. Uses the existing portable Linux account resolver and copies source from the
   Windows checkout into that account's native WSL filesystem. Rootfs and IMG
   construction never run under `/mnt/c`.
9. Runs the canonical `build/run-wsl.sh all` workflow:

   ```text
   [1/4] prepare-packages.sh
   [2/4] configure-rootfs.sh
   [3/4] build-img.sh
   [4/4] verify-img.sh
   ```

10. Rechecks the IMG against its checksum natively, then copies the final raw
    IMG to a Windows `.partial` file only after stage 4 records successful
    verification. It hashes that Windows copy, requires it to match the
    verified native checksum, and only then publishes the final `.img` name.

The persistent APT download cache and reusable rootfs remain in the resolved
native WSL build directory. Rerunning the launcher does not wipe them. The
package stage still authenticates Ubuntu/Mozilla repositories, indexes and
package hashes; cached files merely avoid unnecessary downloads.

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
    4TW-OS_RELEASE.img
    4TW-OS_RELEASE.img.sha256
    VERIFICATION.txt
```

If the known Downloads folder cannot be resolved, the fallback is `output\`
beside the launcher. A matching verified output is reused without another
16-GiB copy. When a different verified build replaces it, the former Windows
output is moved to `previous\`; at most one previous image is retained. The
Linux orchestrator applies the same bounded policy to previously verified
native output. It refuses to move or overwrite an IMG that lacks verification
evidence.

The checksum file is SHA-256. The launcher checks the native IMG against that
checksum using native WSL I/O, copies it once under a temporary `.partial`
name, then independently hashes the complete Windows file. A mismatch stops
the launcher and is never published under the final `.img` name, so its success
screen is shown only for a verified Windows copy.

## Failures and logs

Each Linux stage streams real output and writes a named log beneath
`artifacts/`. A nonzero stage stops all later stages, reports the failing stage
and log, and preserves the package cache and safe intermediate state. Correct
the reported issue and normally rerun `BUILD-4TW-OS.cmd`; it never opens an
interactive troubleshooting shell.

## Final manual step

The launcher deliberately never flashes disks. After **4TW-OS BUILD COMPLETE**,
open the official Rufus application, select only the intended USB, choose
`4TW-OS_RELEASE.img`, and write it. Rufus erases the selected USB. Leave Secure
Boot enabled on the target laptop.

Microsoft's supported WSL command reference is at
<https://learn.microsoft.com/windows/wsl/basic-commands> and installation
guidance is at <https://learn.microsoft.com/windows/wsl/install>.
