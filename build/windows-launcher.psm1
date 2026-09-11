Set-StrictMode -Version Latest

function Remove-4twWslFormatting {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $escape = [regex]::Escape([string][char]27)
    return (($Text -replace "`0", '') -replace ($escape + '\[[0-9;?]*[ -/]*[@-~]'), '')
}

function Get-4twPathFromWslOutput {
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateSet('Unix', 'Windows')][string]$Kind
    )
    $pattern = if ($Kind -eq 'Unix') { '^/' } else { '^(?:[A-Za-z]:\\|\\\\)' }
    $candidates = @(
        foreach ($line in (Remove-4twWslFormatting $Text) -split "`r?`n") {
            $value = $line.Trim()
            if ($value -match $pattern) { $value }
        }
    )
    if ($candidates.Count -ne 1) {
        throw "WSL did not return exactly one valid $Kind path."
    }
    return $candidates[0]
}

function Get-4twUserFromWslOutput {
    param([AllowEmptyString()][string]$Text)
    $candidates = @(
        foreach ($line in (Remove-4twWslFormatting $Text) -split "`r?`n") {
            $value = $line.Trim()
            if ($value -match '^[a-z_][a-z0-9_-]*$') { $value }
        }
    )
    if ($candidates.Count -ne 1) {
        throw 'WSL did not return exactly one valid account name.'
    }
    return $candidates[0]
}

function ConvertFrom-4twWslList {
    param([AllowEmptyString()][string]$Text)
    $items = @()
    foreach ($line in (Remove-4twWslFormatting $Text) -split "`r?`n") {
        # Distro identifiers contain no spaces.  Treat the state column as
        # display text because wsl.exe localizes it on non-English Windows.
        if ($line -match '^\s*\*?\s*(?<Name>\S+)\s+(?<State>.+?)\s+(?<Version>[12])\s*$') {
            $items += [pscustomobject]@{
                Name = $Matches.Name.Trim()
                State = $Matches.State
                Version = [int]$Matches.Version
            }
        }
    }
    return $items
}

function Test-4twOnlineDistroAvailable {
    param([AllowEmptyString()][string]$Text, [string]$Name = 'Ubuntu-26.04')
    foreach ($line in (Remove-4twWslFormatting $Text) -split "`r?`n") {
        if (($line.Trim() -split '\s+')[0] -eq $Name) { return $true }
    }
    return $false
}

function Get-4twWslAction {
    param([bool]$CommandPresent, [int]$VersionExitCode, [int]$StatusExitCode)
    if (-not $CommandPresent -or ($VersionExitCode -ne 0 -and $StatusExitCode -ne 0)) {
        return 'Install'
    }
    if ($VersionExitCode -ne 0) { return 'Update' }
    return 'Ready'
}

function Get-4twWindowsSetupOutcome {
    param(
        [ValidateSet('InstallWsl', 'UpdateWsl')][string]$Step,
        [int]$ExitCode,
        [bool]$CapabilityReady = $false
    )
    if ($Step -eq 'InstallWsl' -and $ExitCode -eq 3010) { return 'RestartRequired' }
    if ($Step -eq 'InstallWsl' -and $ExitCode -eq 0 -and $CapabilityReady) { return 'Ready' }
    if ($Step -eq 'InstallWsl' -and $ExitCode -eq 0) { return 'RestartRequired' }
    if ($Step -eq 'UpdateWsl' -and $ExitCode -eq 0) { return 'Ready' }
    return 'Failed'
}

function Get-4twUbuntuInitializationAction {
    param([int]$ProbeExitCode)
    if ($ProbeExitCode -eq 0) { return 'Ready' }
    if ($ProbeExitCode -eq 10) { return 'SetupRequired' }
    return 'Failed'
}

function Assert-4twRepository {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $required = @('build\run-wsl.sh', 'build\setup-host.sh', 'build\compress-release.sh', 'assets\4TW-OS.png')
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relative) -PathType Leaf)) {
            throw "This is not a complete 4TW-OS source folder; missing $relative"
        }
    }
    return (Resolve-Path -LiteralPath $RepositoryRoot).Path
}

function Resolve-4twOutputDirectory {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [AllowEmptyString()][string]$DownloadsPath,
        [AllowEmptyString()][string]$UserProfile
    )
    if ($DownloadsPath -and [IO.Path]::IsPathRooted($DownloadsPath)) {
        return (Join-Path $DownloadsPath '4TW-OS')
    }
    if ($UserProfile -and [IO.Path]::IsPathRooted($UserProfile)) {
        return (Join-Path (Join-Path $UserProfile 'Downloads') '4TW-OS')
    }
    return (Join-Path $RepositoryRoot 'output')
}

function Test-4twFreeSpace {
    param([long]$AvailableBytes, [long]$RequiredBytes)
    return ($AvailableBytes -ge $RequiredBytes)
}

function ConvertFrom-4twDfAvailable {
    param([AllowEmptyString()][string]$Text)
    $available = $null
    foreach ($line in (Remove-4twWslFormatting $Text) -split "`r?`n") {
        if ($line -match '^\S+\s+\d+\s+\d+\s+(?<Available>\d+)\s+\d+%\s+.+$') {
            $available = [long]$Matches.Available * 1KB
        }
    }
    if ($null -eq $available) { throw 'Could not read native WSL free space.' }
    return $available
}

function Read-4twChecksum {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('4TW-OS_RELEASE.img', '4TW-OS_RELEASE.img.zst')]
        [string]$ExpectedFileName
    )
    $line = (Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop).Trim()
    $escapedName = [regex]::Escape($ExpectedFileName)
    if ($line -notmatch "^(?<Hash>[0-9a-fA-F]{64})\s+[ *]?$escapedName$") {
        throw 'The verified WSL checksum file has an unexpected format.'
    }
    return $Matches.Hash.ToLowerInvariant()
}

function Test-4twChecksumMatch {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedHash)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq
        $ExpectedHash.ToLowerInvariant())
}

function Get-4twProvenancePath {
    param([AllowEmptyString()][string]$LocalAppData = $env:LOCALAPPDATA)
    if (-not $LocalAppData -or -not [IO.Path]::IsPathRooted($LocalAppData)) {
        throw 'The Windows Local AppData directory could not be resolved safely.'
    }
    return (Join-Path (Join-Path $LocalAppData '4TW-OS') 'build-provenance.json')
}

function Write-4twProvenance {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Path)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $directoryItem = Get-Item -LiteralPath $directory -Force
    if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The 4TW-OS provenance directory is a reparse point; refusing to write it.'
    }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -and
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The 4TW-OS provenance file is a reparse point; refusing to replace it.'
        }
    }
    $State.updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = "$Path.$PID.partial"
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    $json = $State | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($temporary, $json + "`r`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-4twProvenance {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The 4TW-OS provenance file is a reparse point.'
    }
    try { $state = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { throw 'The 4TW-OS provenance file is not valid JSON.' }
    if ($state.schema_version -ne 1 -or $state.distro_name -ne 'Ubuntu-26.04') {
        throw 'The 4TW-OS provenance file has an unsupported or unsafe identity.'
    }
    return $state
}

function Initialize-4twProvenance {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Present', 'Absent', 'Unknown')][string]$WslBefore,
        [Parameter(Mandatory)][ValidateSet('Present', 'Absent', 'Unknown')][string]$UbuntuBefore,
        [string[]]$DistrosBefore = @(),
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $existing = Read-4twProvenance $Path
    if ($null -ne $existing -and $existing.cleanup_completed -ne $true) { return $existing }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $state = [pscustomobject][ordered]@{
        schema_version = 1
        cycle_id = [guid]::NewGuid().ToString('D')
        created_utc = $now
        updated_utc = $now
        distro_name = 'Ubuntu-26.04'
        wsl_before = $WslBefore
        ubuntu_before = $UbuntuBefore
        distros_before = @($DistrosBefore)
        repository_root_at_start = $RepositoryRoot
        wsl_install_invoked_by_4tw = $false
        wsl_install_completed = $false
        wsl_update_invoked_by_4tw = $false
        ubuntu_install_invoked_by_4tw = $false
        ubuntu_installed_by_4tw = $false
        ubuntu_version_before = $null
        ubuntu_converted_to_wsl2_by_4tw = $false
        windows_features_before = [pscustomobject]@{
            MicrosoftWindowsSubsystemLinux = 'NotQueried'
            VirtualMachinePlatform = 'NotQueried'
        }
        windows_features_after = [pscustomobject]@{
            MicrosoftWindowsSubsystemLinux = 'NotQueried'
            VirtualMachinePlatform = 'NotQueried'
        }
        windows_features_changed_by_4tw = @()
        host_dependencies_install_invoked = $false
        host_dependencies_install_completed = $false
        vm_tools_stage = 'not-recorded'
        selected_wsl_user = $null
        native_build_directory = $null
        output_directory = $null
        release_file = $null
        release_sha256 = $null
        cleanup_completed = $false
        cleanup_last_run_utc = $null
        cleanup_native_tree_removed = $false
        cleanup_ubuntu_unregistered = $false
    }
    Write-4twProvenance $state $Path
    return $state
}

function Set-4twProvenanceFields {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $state = Read-4twProvenance $Path
    if ($null -eq $state) { throw 'The 4TW-OS provenance file does not exist.' }
    foreach ($key in $Values.Keys) {
        if ($state.PSObject.Properties.Name -contains $key) { $state.$key = $Values[$key] }
        else { $state | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] }
    }
    Write-4twProvenance $state $Path
    return $state
}

function Get-4twOptionalFeatureStates {
    $result = [ordered]@{}
    foreach ($entry in @(
        [pscustomobject]@{ Key = 'MicrosoftWindowsSubsystemLinux'; Name = 'Microsoft-Windows-Subsystem-Linux' }
        [pscustomobject]@{ Key = 'VirtualMachinePlatform'; Name = 'VirtualMachinePlatform' }
    )) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $entry.Name -ErrorAction Stop
            $result[$entry.Key] = [string]$feature.State
        } catch {
            $result[$entry.Key] = 'Unknown'
        }
    }
    return [pscustomobject]$result
}

function Get-4twDistroOwnership {
    param([AllowNull()]$Provenance)
    if ($null -eq $Provenance) { return 'Unknown' }
    if ($Provenance.distro_name -ne 'Ubuntu-26.04') { return 'Conflict' }
    if ($Provenance.ubuntu_before -eq 'Present') {
        if ($Provenance.ubuntu_installed_by_4tw -eq $true) { return 'Conflict' }
        return 'PreExisting'
    }
    if ($Provenance.ubuntu_before -eq 'Absent' -and
            $Provenance.ubuntu_install_invoked_by_4tw -eq $true -and
            $Provenance.ubuntu_installed_by_4tw -eq $true) {
        return 'CreatedBy4tw'
    }
    return 'Unknown'
}

function Test-4twNativeBuildPathFormat {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path -or -not $Path.StartsWith('/') -or
            $Path -match '[\x00-\x1f]' -or $Path -match '^/(?:mnt|root)(?:/|$)') { return $false }
    $parts = @($Path -split '/' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2 -or $parts[-1] -ne '4tw-ubuntu-sway-build') { return $false }
    return -not (@($parts | Where-Object { $_ -in @('.', '..') }).Count)
}

function Get-4twVerifiedReleaseAtDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    foreach ($name in @('4TW-OS_RELEASE.img.zst', '4TW-OS_RELEASE.img')) {
        $release = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $release -PathType Leaf)) { continue }
        $checksum = "$release.sha256"
        if (-not (Test-Path -LiteralPath $checksum -PathType Leaf)) {
            throw "The finished release exists without its checksum: $release"
        }
        foreach ($path in @($release, $checksum)) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A finished release or checksum is a reparse point; verification stopped.'
            }
        }
        $expected = Read-4twChecksum $checksum $name
        if (-not (Test-4twChecksumMatch $release $expected)) {
            throw "The finished Windows release failed SHA-256 verification: $release"
        }
        return [pscustomobject]@{
            Directory = $Directory
            Release = $release
            Checksum = $checksum
            Report = (Join-Path $Directory 'VERIFICATION.txt')
            FileName = $name
            Hash = $expected
            Bytes = (Get-Item -LiteralPath $release).Length
        }
    }
    return $null
}

function Find-4twVerifiedRelease {
    param([Parameter(Mandatory)][string[]]$Directories)
    $results = @()
    foreach ($directory in @($Directories | Select-Object -Unique)) {
        if (-not $directory -or -not [IO.Path]::IsPathRooted($directory)) { continue }
        $result = Get-4twVerifiedReleaseAtDirectory $directory
        if ($null -ne $result) { $results += $result }
    }
    if ($results.Count -eq 0) { throw 'No verified finished Windows release was found. Cleanup stopped before deleting build data.' }
    if ($results.Count -ne 1) { throw 'More than one possible verified Windows output was found. Cleanup stopped rather than guessing.' }
    return $results[0]
}

function Get-4twRepositoryGeneratedArtifacts {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $artifactRoot = Join-Path $RepositoryRoot 'artifacts'
    if (-not (Test-Path -LiteralPath $artifactRoot -PathType Container)) { return @() }
    if (((Get-Item -LiteralPath $artifactRoot -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The repository artifacts directory is a reparse point; cleanup stopped.'
    }
    $found = @()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($artifactRoot)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            if ($item.Name -match '^4TW-OS.*\.img(?:\.zst)?(?:\.partial)?$' -or
                    $item.Name -match '^4TW-OS.*\.img(?:\.zst)?(?:\.source)?\.sha256$') {
                $found += $item
            }
        }
    }
    return @($found)
}

function ConvertFrom-4twCleanupStatus {
    param([AllowEmptyString()][string]$Text)
    $allowed = @('status', 'path', 'selected_user', 'size_bytes', 'mount_count', 'loop_count', 'vm_tools')
    $values = @{}
    foreach ($line in (Remove-4twWslFormatting $Text) -split "`r?`n") {
        if (-not $line.Trim()) { continue }
        if ($line -notmatch '^(?<Key>[a-z_]+)=(?<Value>[^\r\n]*)$' -or
                $Matches.Key -notin $allowed -or $values.ContainsKey($Matches.Key)) {
            throw 'The native cleanup helper returned ambiguous diagnostic data.'
        }
        $values[$Matches.Key] = $Matches.Value
    }
    foreach ($required in @('status', 'path', 'selected_user', 'size_bytes', 'mount_count', 'loop_count', 'vm_tools')) {
        if (-not $values.ContainsKey($required)) { throw 'The native cleanup helper omitted required diagnostic data.' }
    }
    foreach ($numeric in @('size_bytes', 'mount_count', 'loop_count')) {
        if ($values[$numeric] -notmatch '^\d+$') { throw 'The native cleanup helper returned an invalid count.' }
    }
    if ($values.status -notin @('present', 'absent', 'removed')) {
        throw 'The native cleanup helper returned an invalid status.'
    }
    if ($values.path -and -not (Test-4twNativeBuildPathFormat $values.path)) {
        throw 'The native cleanup helper returned an unsafe build path.'
    }
    if ($values.selected_user -and $values.selected_user -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw 'The native cleanup helper returned an unsafe account name.'
    }
    if ($values.status -in @('present', 'removed') -and
            (-not $values.path -or -not $values.selected_user)) {
        throw 'The native cleanup helper returned an incomplete build identity.'
    }
    return [pscustomobject]@{
        Status = $values.status
        Path = $values.path
        SelectedUser = $values.selected_user
        SizeBytes = [long]$values.size_bytes
        MountCount = [int]$values.mount_count
        LoopCount = [int]$values.loop_count
        VmTools = $values.vm_tools
    }
}

function Get-4twGitHubReleaseSize {
    param([long]$Bytes, [long]$LimitBytes = 2147483648)
    return [pscustomobject]@{
        Pass = ($Bytes -lt $LimitBytes)
        Bytes = $Bytes
        GiB = ($Bytes / 1GB)
        HeadroomMiB = (($LimitBytes - $Bytes) / 1MB)
    }
}

function Export-4twVerifiedRelease {
    param(
        [Parameter(Mandatory)][string]$SourceRelease,
        [Parameter(Mandatory)][string]$SourceChecksum,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
    )
    $expected = Read-4twChecksum $SourceChecksum '4TW-OS_RELEASE.img.zst'
    $sourceSize = (Get-Item -LiteralPath $SourceRelease -ErrorAction Stop).Length
    $sizeStatus = Get-4twGitHubReleaseSize $sourceSize
    if (-not $sizeStatus.Pass) {
        throw 'GitHub Release size check failed: the compressed artifact is not below 2 GiB.'
    }
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $destinationRelease = Join-Path $OutputDirectory '4TW-OS_RELEASE.img.zst'
    $partialRelease = Join-Path $OutputDirectory '4TW-OS_RELEASE.img.zst.partial'
    $destinationChecksum = Join-Path $OutputDirectory '4TW-OS_RELEASE.img.zst.sha256'
    $destinationReport = Join-Path $OutputDirectory 'VERIFICATION.txt'
    $destinationVerified = $false
    if (Test-Path -LiteralPath $destinationRelease -PathType Leaf) {
        if (Test-4twChecksumMatch $destinationRelease $expected) {
            $destinationVerified = $true
        } else {
            $previous = Join-Path $OutputDirectory 'previous'
            [IO.Directory]::CreateDirectory($previous) | Out-Null
            Get-ChildItem -LiteralPath $previous -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '4TW-OS_RELEASE-*.img.zst*' -or
                    $_.Name -like '4TW-OS_RELEASE-*-VERIFICATION.txt' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
            $previousRelease = Join-Path $previous "4TW-OS_RELEASE-$Timestamp.img.zst"
            Move-Item -LiteralPath $destinationRelease -Destination $previousRelease
            foreach ($old in @($destinationChecksum, $destinationReport)) {
                if (Test-Path -LiteralPath $old -PathType Leaf) {
                    $previousMetadata = Join-Path $previous `
                        ("4TW-OS_RELEASE-$Timestamp-" + [IO.Path]::GetFileName($old))
                    Move-Item -LiteralPath $old -Destination $previousMetadata
                }
            }
        }
    }
    if (-not (Test-Path -LiteralPath $destinationRelease -PathType Leaf)) {
        if (Test-Path -LiteralPath $partialRelease) {
            Remove-Item -LiteralPath $partialRelease -Force
        }
        Copy-Item -LiteralPath $SourceRelease -Destination $partialRelease -ErrorAction Stop
        if (-not (Test-4twChecksumMatch $partialRelease $expected)) {
            throw 'The copied Windows release differs from the verified WSL checksum and remains unpublished as a .partial file.'
        }
        Move-Item -LiteralPath $partialRelease -Destination $destinationRelease
        $destinationVerified = $true
    }
    if (-not $destinationVerified) {
        throw 'The Windows release checksum differs from the verified WSL artifact.'
    }
    [IO.File]::WriteAllText($destinationChecksum, "$expected  4TW-OS_RELEASE.img.zst`r`n",
        [Text.Encoding]::ASCII)
    $report = @(
        '4TW-OS compressed Release verification PASSED',
        "Exported UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "Compressed bytes: $sourceSize",
        'Zstandard integrity test: PASS (native WSL artifact)',
        'GitHub Release size check: PASS (under 2147483648 bytes)',
        "SHA-256: $expected",
        'The Windows .img.zst copy was hashed after export and matches the verified WSL artifact.',
        'Flash 4TW-OS_RELEASE.img.zst directly with Rufus 4.7 or newer; do not extract it first.',
        'Rufus will erase the selected USB. This workflow does not export the raw IMG; its verified source remains in native WSL storage.'
    )
    [IO.File]::WriteAllLines($destinationReport, $report, [Text.Encoding]::UTF8)
    return [pscustomobject]@{
        Release = $destinationRelease
        Checksum = $destinationChecksum
        Report = $destinationReport
        Hash = $expected
        SizeBytes = $sourceSize
        SizeGiB = $sizeStatus.GiB
        HeadroomMiB = $sizeStatus.HeadroomMiB
    }
}

function Invoke-4twBuildRunner {
    param([Parameter(Mandatory)][scriptblock]$Runner)
    $exitCode = & $Runner
    if ([int]$exitCode -ne 0) {
        throw "The Linux Release workflow failed with exit code $exitCode."
    }
    return $true
}

Export-ModuleMember -Function *-4tw*
