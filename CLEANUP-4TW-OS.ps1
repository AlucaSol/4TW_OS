[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$LaunchedFromCmd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Distro = 'Ubuntu-26.04'
$ModulePath = Join-Path $PSScriptRoot 'build\windows-launcher.psm1'
Import-Module $ModulePath -Force
$Messages = [Collections.Generic.List[string]]::new()

function Write-4twCleanup {
    param([string]$Message = '')
    Write-Host $Message
    $script:Messages.Add($Message)
}

function Wait-4twCleanupUser {
    if ($LaunchedFromCmd -and -not $NonInteractive) {
        Read-Host 'Press Enter to close this window' | Out-Null
    }
}

function Invoke-4twCleanupCapture {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ ExitCode = [int]$code; Text = ($output -join "`n") }
}

function Invoke-4twCleanupLive {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-4twCleanup "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    return [int]$code
}

function Get-4twCleanupDownloadsFolder {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace('shell:Downloads')
        if ($null -ne $folder -and $folder.Self.Path) { return [string]$folder.Self.Path }
    } catch { }
    return ''
}

function Confirm-4twCleanup {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($NonInteractive) { return $false }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^(?i:y|yes)$')
}

function Save-4twCleanupLog {
    param([string]$Path)
    if ($DryRun -or -not $Path) { return }
    try {
        $directory = Split-Path -Parent $Path
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllLines($Path, $Messages, [Text.UTF8Encoding]::new($false))
    } catch { Write-Warning 'The concise cleanup log could not be written.' }
}

function Format-4twSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KiB' -f ($Bytes / 1KB))
}

$ProvenancePath = $null
$LogPath = $null
try {
    Write-4twCleanup ''
    Write-4twCleanup '=================================================='
    Write-4twCleanup '                 4TW-OS CLEANUP'
    Write-4twCleanup '=================================================='
    if ($DryRun) { Write-4twCleanup 'DRY RUN: nothing will be changed.' }
    Write-4twCleanup ''

    $RepositoryRoot = Assert-4twRepository $PSScriptRoot
    $nativeHelper = Join-Path $RepositoryRoot 'build\cleanup-native.sh'
    if (-not (Test-Path -LiteralPath $nativeHelper -PathType Leaf)) {
        throw 'This source folder is missing build\cleanup-native.sh.'
    }
    $ProvenancePath = Get-4twProvenancePath
    $LogPath = Join-Path (Split-Path -Parent $ProvenancePath) 'cleanup-last.log'
    $provenance = Read-4twProvenance $ProvenancePath
    $ownership = Get-4twDistroOwnership $provenance
    if ($ownership -eq 'Conflict') {
        throw 'Recorded Ubuntu ownership contradicts itself. Cleanup stopped rather than guessing.'
    }

    Write-4twCleanup 'Checking finished image...'
    if ($null -ne $provenance -and $provenance.output_directory) {
        $outputCandidates = @([string]$provenance.output_directory)
    } else {
        $downloads = Get-4twCleanupDownloadsFolder
        $outputCandidates = @()
        if ($downloads) { $outputCandidates += (Join-Path $downloads '4TW-OS') }
        elseif ($env:USERPROFILE) { $outputCandidates += (Join-Path $env:USERPROFILE 'Downloads\4TW-OS') }
        $outputCandidates += (Join-Path $RepositoryRoot 'output')
    }
    $release = Find-4twVerifiedRelease $outputCandidates
    if ($null -ne $provenance -and $provenance.release_sha256 -and
            $release.Hash -ne ([string]$provenance.release_sha256).ToLowerInvariant()) {
        throw 'The verified Windows release does not match the hash recorded for this build cycle.'
    }
    Write-4twCleanup 'Finished image verified.'
    Write-4twCleanup ("Kept: {0}" -f $release.Release)
    Write-4twCleanup ("SHA-256: {0}" -f $release.Hash)
    Write-4twCleanup ''

    $wslCommand = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
    $installed = @()
    $ubuntuPresent = $false
    $native = $null
    $nativeHelperWsl = $null
    if ($null -ne $wslCommand) {
        $list = Invoke-4twCleanupCapture $wslCommand.Source @('--list', '--verbose')
        if ($list.ExitCode -eq 0) {
            $installed = @(ConvertFrom-4twWslList $list.Text)
            $ubuntuPresent = $null -ne ($installed | Where-Object Name -eq $Distro | Select-Object -First 1)
        } else {
            throw 'WSL is installed but its distribution list could not be read safely.'
        }
    }

    $otherDistros = @($installed | Where-Object Name -ne $Distro | ForEach-Object { $_.Name })
    if ($otherDistros.Count -gt 0) {
        Write-4twCleanup ("Other WSL distributions found and kept: {0}" -f ($otherDistros -join ', '))
    } else {
        Write-4twCleanup 'No other WSL distributions were detected.'
    }

    if ($ubuntuPresent) {
        $helperPath = Invoke-4twCleanupCapture $wslCommand.Source @('-d', $Distro, '-u', 'root', '--',
            'wslpath', '-a', '-u', $nativeHelper)
        if ($helperPath.ExitCode -ne 0) { throw 'The native cleanup helper path could not be translated into WSL.' }
        $nativeHelperWsl = Get-4twPathFromWslOutput $helperPath.Text Unix
        $inspection = Invoke-4twCleanupCapture $wslCommand.Source @('-d', $Distro, '-u', 'root', '--',
            'bash', $nativeHelperWsl, '--discover')
        if ($inspection.ExitCode -ne 0) {
            throw ("The native build environment could not be identified safely. " + $inspection.Text.Trim())
        }
        $native = ConvertFrom-4twCleanupStatus $inspection.Text
        if ($null -ne $provenance -and $provenance.native_build_directory) {
            if ($native.Status -eq 'present' -and
                    ($native.Path -ne [string]$provenance.native_build_directory -or
                     $native.SelectedUser -ne [string]$provenance.selected_wsl_user)) {
                throw 'The detected native build identity contradicts recorded provenance.'
            }
            if ($native.Status -eq 'absent') {
                $recordedPath = [string]$provenance.native_build_directory
                $recordedUser = [string]$provenance.selected_wsl_user
                if (-not (Test-4twNativeBuildPathFormat $recordedPath) -or
                        $recordedUser -notmatch '^[a-z_][a-z0-9_-]*$') {
                    throw 'Recorded native build provenance is incomplete or unsafe.'
                }
                $recordedInspection = Invoke-4twCleanupCapture $wslCommand.Source @('-d', $Distro,
                    '-u', 'root', '--', 'bash', $nativeHelperWsl, '--inspect', $recordedPath, $recordedUser)
                if ($recordedInspection.ExitCode -ne 0) { throw $recordedInspection.Text.Trim() }
                $native = ConvertFrom-4twCleanupStatus $recordedInspection.Text
            }
        }
    } else {
        $native = ConvertFrom-4twCleanupStatus "status=absent`npath=`nselected_user=`nsize_bytes=0`nmount_count=0`nloop_count=0`nvm_tools=not-recorded"
        if ($null -ne $provenance -and $provenance.ubuntu_before -eq 'Present' -and
                $provenance.cleanup_completed -ne $true) {
            throw 'Provenance says Ubuntu pre-existed, but it is now absent. Cleanup stopped before changing Windows files.'
        }
    }

    Write-4twCleanup ''
    Write-4twCleanup 'Checking build environment...'
    Write-4twCleanup ("Ubuntu-26.04: {0}" -f $(if ($ubuntuPresent) { 'found' } else { 'not installed' }))
    switch ($ownership) {
        'CreatedBy4tw' { Write-4twCleanup 'Ubuntu ownership: created by 4TW-OS (recorded provenance).' }
        'PreExisting' { Write-4twCleanup 'Ubuntu ownership: already present before this build. It will be kept.' }
        default { Write-4twCleanup 'Ubuntu ownership: unknown. Safe cleanup only; Ubuntu will be kept.' }
    }
    if ($native.Status -eq 'present') {
        Write-4twCleanup ("4TW-OS build files: {0}" -f (Format-4twSize $native.SizeBytes))
        Write-4twCleanup ("Build path: {0}" -f $native.Path)
        Write-4twCleanup ("Project mounts: {0}; project loop devices: {1}" -f $native.MountCount, $native.LoopCount)
    } else { Write-4twCleanup '4TW-OS native build files: not present.' }
    if ($native.VmTools -eq 'completed') {
        Write-4twCleanup 'Optional VM/QEMU tools stage: recorded as completed.'
    } elseif (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'artifacts\vm-tools-host-state.txt') -PathType Leaf) {
        $native.VmTools = 'completed'
        Write-4twCleanup 'Optional VM/QEMU tools stage: recorded as completed.'
    } else { Write-4twCleanup 'Optional VM/QEMU tools stage: not recorded.' }

    $repositoryArtifacts = @(Get-4twRepositoryGeneratedArtifacts $RepositoryRoot)
    $repositoryBytes = [long](($repositoryArtifacts | Measure-Object -Property Length -Sum).Sum)
    Write-4twCleanup ("Duplicate generated repository images: {0} file(s), {1}" -f
        $repositoryArtifacts.Count, (Format-4twSize $repositoryBytes))
    Write-4twCleanup 'Small diagnostic logs are kept.'
    Write-4twCleanup 'Host packages are not purged from an Ubuntu environment that is kept.'
    Write-4twCleanup 'Shared WSL and Windows features are always kept by this utility.'

    if ($DryRun) {
        Write-4twCleanup ''
        if ($ownership -eq 'CreatedBy4tw' -and $ubuntuPresent) {
            Write-4twCleanup 'WOULD OFFER: permanently unregister the project-created Ubuntu-26.04 distribution.'
        } elseif ($native.Status -eq 'present') {
            Write-4twCleanup 'WOULD OFFER: remove only the validated 4TW-OS native build tree.'
        }
        if ($repositoryArtifacts.Count -gt 0) {
            Write-4twCleanup 'WOULD OFFER: remove the listed generated IMG/Zstandard duplicates from repository artifacts.'
            foreach ($artifact in $repositoryArtifacts) { Write-4twCleanup ("  {0}" -f $artifact.FullName) }
        }
        Write-4twCleanup 'WOULD KEEP: the verified release, its checksum/report, source, Ubuntu unless proven project-created, other distributions, WSL, Windows features and flashed USB.'
        Write-4twCleanup ''
        Write-4twCleanup 'Dry run complete. Nothing was changed.'
        Wait-4twCleanupUser
        exit 0
    }

    $ubuntuUnregistered = $false
    $nativeRemoved = ($native.Status -eq 'absent')
    $repositoryRemovedBytes = 0L
    if ($ownership -eq 'CreatedBy4tw' -and $ubuntuPresent) {
        Write-4twCleanup ''
        Write-4twCleanup 'WARNING: This can permanently delete the Ubuntu-26.04 environment installed for this build.'
        Write-4twCleanup 'All files, packages, settings and caches inside that distribution would be lost.'
        $answer = if ($NonInteractive) { '' } else {
            Read-Host 'Type REMOVE to unregister Ubuntu-26.04, or press Enter to keep it'
        }
        if ($answer -ceq 'REMOVE') {
            if ((Invoke-4twCleanupLive $wslCommand.Source @('--terminate', $Distro)) -ne 0) {
                throw 'Ubuntu-26.04 could not be terminated; it was not unregistered.'
            }
            if ((Invoke-4twCleanupLive $wslCommand.Source @('--unregister', $Distro)) -ne 0) {
                throw 'Ubuntu-26.04 could not be unregistered.'
            }
            $afterList = Invoke-4twCleanupCapture $wslCommand.Source @('--list', '--verbose')
            if ($afterList.ExitCode -ne 0 -or
                    (@(ConvertFrom-4twWslList $afterList.Text).Name -contains $Distro)) {
                throw 'Windows did not confirm removal of Ubuntu-26.04.'
            }
            $ubuntuUnregistered = $true
            $nativeRemoved = $true
            Write-4twCleanup 'Ubuntu-26.04 was unregistered.'
        }
    }

    if (-not $ubuntuUnregistered -and $native.Status -eq 'present') {
        Write-4twCleanup ''
        if (Confirm-4twCleanup ("Remove the temporary 4TW-OS build files ({0})" -f
                (Format-4twSize $native.SizeBytes))) {
            $removal = Invoke-4twCleanupCapture $wslCommand.Source @('-d', $Distro, '-u', 'root', '--',
                'bash', $nativeHelperWsl, '--remove', $native.Path, $native.SelectedUser)
            if ($removal.ExitCode -ne 0) { throw $removal.Text.Trim() }
            $removed = ConvertFrom-4twCleanupStatus $removal.Text
            if ($removed.Status -notin @('removed', 'absent')) {
                throw 'Native cleanup did not confirm removal.'
            }
            $nativeRemoved = $true
            Write-4twCleanup ("Removed the 4TW-OS native build tree ({0})." -f
                (Format-4twSize $removed.SizeBytes))
        } else { Write-4twCleanup 'The native build tree was kept.' }
    }

    if ($repositoryArtifacts.Count -gt 0) {
        Write-4twCleanup ''
        if (Confirm-4twCleanup ("Remove duplicate generated repository images ({0})" -f
                (Format-4twSize $repositoryBytes))) {
            $artifactRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'artifacts'))
            $prefix = $artifactRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            foreach ($artifact in $repositoryArtifacts) {
                $full = [IO.Path]::GetFullPath($artifact.FullName)
                if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'A repository artifact changed identity during cleanup; deletion stopped.'
                }
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $currentArtifact = Get-Item -LiteralPath $full -Force
                    if (($currentArtifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw 'A repository artifact became a reparse point; deletion stopped.'
                    }
                    Remove-Item -LiteralPath $full -Force
                    $repositoryRemovedBytes += [long]$currentArtifact.Length
                }
            }
            Write-4twCleanup ("Removed generated repository image duplicates ({0})." -f
                (Format-4twSize $repositoryRemovedBytes))
        } else { Write-4twCleanup 'Duplicate repository images were kept.' }
    }

    if ($nativeRemoved -or $ubuntuUnregistered) {
        $launcherState = Join-Path $RepositoryRoot '.4tw-launcher-state.json'
        if (Test-Path -LiteralPath $launcherState -PathType Leaf) {
            Remove-Item -LiteralPath $launcherState -Force
        }
    }
    if ($null -ne $provenance) {
        Set-4twProvenanceFields $ProvenancePath @{
            cleanup_last_run_utc = (Get-Date).ToUniversalTime().ToString('o')
            cleanup_native_tree_removed = $nativeRemoved
            cleanup_ubuntu_unregistered = $ubuntuUnregistered
            cleanup_completed = $nativeRemoved
            vm_tools_stage = $native.VmTools
        } | Out-Null
    }

    Write-4twCleanup ''
    Write-4twCleanup 'Cleanup complete.'
    Write-4twCleanup ("Final image preserved: {0}" -f $release.Release)
    Write-4twCleanup ("Linux build tree: {0}" -f $(if ($nativeRemoved) { 'removed or already absent' } else { 'kept' }))
    Write-4twCleanup ("Ubuntu-26.04: {0}" -f $(if ($ubuntuUnregistered) { 'unregistered' } else { 'preserved' }))
    Write-4twCleanup 'Other WSL distributions: preserved.'
    Write-4twCleanup 'WSL/shared Windows features: preserved; no Windows restart is required.'
    if ($nativeRemoved -and -not $ubuntuUnregistered) {
        Write-4twCleanup 'Linux filesystem space was freed, but the existing WSL virtual disk may not immediately shrink on Windows.'
    }
    Write-4twCleanup 'Build-host packages were left installed when Ubuntu was preserved because package ownership is not proven precisely enough for safe removal.'
    Write-4twCleanup 'The flashed USB, 4TW-CONFIG, 4TW-WRITING and all release-folder files were untouched.'
    Write-4twCleanup 'You may manually delete this extracted source folder later if you no longer need it.'
    Save-4twCleanupLog $LogPath
    Wait-4twCleanupUser
    exit 0
} catch {
    Write-4twCleanup ''
    Write-4twCleanup '4TW-OS CLEANUP STOPPED'
    Write-4twCleanup $_.Exception.Message
    Write-4twCleanup 'No further cleanup action was taken.'
    Save-4twCleanupLog $LogPath
    Wait-4twCleanupUser
    exit 1
}
