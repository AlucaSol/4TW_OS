Set-StrictMode -Version Latest

function Remove-4twWslFormatting {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $escape = [regex]::Escape([string][char]27)
    return (($Text -replace "`0", '') -replace ($escape + '\[[0-9;?]*[ -/]*[@-~]'), '')
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
    $required = @('build\run-wsl.sh', 'build\setup-host.sh', 'assets\4TW-OS.png')
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
    param([Parameter(Mandatory)][string]$Path)
    $line = (Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop).Trim()
    if ($line -notmatch '^(?<Hash>[0-9a-fA-F]{64})\s+[ *]?4TW-OS_RELEASE\.img$') {
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

function Export-4twVerifiedOutput {
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [Parameter(Mandatory)][string]$SourceChecksum,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
    )
    $expected = Read-4twChecksum $SourceChecksum
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $destinationImage = Join-Path $OutputDirectory '4TW-OS_RELEASE.img'
    $partialImage = Join-Path $OutputDirectory '4TW-OS_RELEASE.img.partial'
    $destinationChecksum = Join-Path $OutputDirectory '4TW-OS_RELEASE.img.sha256'
    $destinationReport = Join-Path $OutputDirectory 'VERIFICATION.txt'
    if (Test-Path -LiteralPath $destinationImage -PathType Leaf) {
        if (-not (Test-4twChecksumMatch $destinationImage $expected)) {
            $previous = Join-Path $OutputDirectory 'previous'
            [IO.Directory]::CreateDirectory($previous) | Out-Null
            Get-ChildItem -LiteralPath $previous -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '4TW-OS_RELEASE-*' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
            $previousImage = Join-Path $previous "4TW-OS_RELEASE-$Timestamp.img"
            Move-Item -LiteralPath $destinationImage -Destination $previousImage
            foreach ($old in @($destinationChecksum, $destinationReport)) {
                if (Test-Path -LiteralPath $old -PathType Leaf) {
                    $previousMetadata = Join-Path $previous `
                        ("4TW-OS_RELEASE-$Timestamp-" + [IO.Path]::GetFileName($old))
                    Move-Item -LiteralPath $old -Destination $previousMetadata
                }
            }
        }
    }
    if (-not (Test-Path -LiteralPath $destinationImage -PathType Leaf)) {
        if (Test-Path -LiteralPath $partialImage) {
            Remove-Item -LiteralPath $partialImage -Force
        }
        Copy-Item -LiteralPath $SourceImage -Destination $partialImage -ErrorAction Stop
        if (-not (Test-4twChecksumMatch $partialImage $expected)) {
            throw 'The copied Windows IMG differs from the verified WSL checksum and remains unpublished as a .partial file.'
        }
        Move-Item -LiteralPath $partialImage -Destination $destinationImage
    }
    if (-not (Test-4twChecksumMatch $destinationImage $expected)) {
        throw 'The Windows IMG checksum differs from the verified WSL artifact.'
    }
    [IO.File]::WriteAllText($destinationChecksum, "$expected  4TW-OS_RELEASE.img`r`n",
        [Text.Encoding]::ASCII)
    $report = @(
        '4TW-OS Release verification PASSED',
        "Exported UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "SHA-256: $expected",
        'The Windows copy was hashed after export and matches the verified WSL artifact.',
        'Flash 4TW-OS_RELEASE.img with Rufus. Rufus will erase the selected USB.'
    )
    [IO.File]::WriteAllLines($destinationReport, $report, [Text.Encoding]::UTF8)
    return [pscustomobject]@{
        Image = $destinationImage
        Checksum = $destinationChecksum
        Report = $destinationReport
        Hash = $expected
    }
}

function Invoke-4twBuildRunner {
    param([Parameter(Mandatory)][scriptblock]$Runner)
    $exitCode = & $Runner
    if ([int]$exitCode -ne 0) {
        throw "The Linux build-all workflow failed with exit code $exitCode."
    }
    return $true
}

Export-ModuleMember -Function *-4tw*
