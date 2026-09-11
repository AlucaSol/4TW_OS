[CmdletBinding()]
param(
    [ValidateSet('', 'InstallWsl', 'UpdateWsl')]
    [string]$WindowsSetup = '',
    [switch]$NonInteractive,
    [switch]$LaunchedFromCmd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Distro = 'Ubuntu-26.04'
$StatePath = Join-Path $PSScriptRoot '.4tw-launcher-state.json'
$ModulePath = Join-Path $PSScriptRoot 'build\windows-launcher.psm1'
Import-Module $ModulePath -Force

function Write-4twBanner {
    param([string[]]$Lines)
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Cyan
    foreach ($line in $Lines) { Write-Host $line -ForegroundColor Cyan }
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Wait-4twUser {
    param([string]$Message = 'Press Enter to close this window')
    if (-not $NonInteractive) { Read-Host $Message | Out-Null }
}

function Test-4twAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-4twCapture {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    return [pscustomobject]@{ ExitCode = [int]$code; Text = ($output -join "`n") }
}

function Invoke-4twLive {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    return [int]$code
}

function Save-4twState {
    param([string]$Phase)
    try {
        @{ phase = $Phase; updated_utc = (Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding ASCII
    } catch {
        Write-Warning 'Could not save optional launcher state; capability detection will still resume safely.'
    }
}

function Invoke-4twElevatedStep {
    param([ValidateSet('InstallWsl', 'UpdateWsl')][string]$Step)
    $scriptArgument = '"' + $PSCommandPath.Replace('"', '""') + '"'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $scriptArgument -WindowsSetup $Step -NonInteractive"
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    return [int]$process.ExitCode
}

function Show-4twRestartRequired {
    Write-4twBanner @(
        '4TW-OS SETUP - WINDOWS RESTART REQUIRED',
        '',
        'WSL has been installed/enabled successfully.',
        '',
        '1. Restart Windows.',
        '2. Return to this 4TW-OS folder.',
        '3. Double-click BUILD-4TW-OS.cmd again.',
        '',
        'Your progress is safe.'
    )
    Wait-4twUser
}

function Show-4twUbuntuSetup {
    param([string]$WslPath)
    Save-4twState 'ubuntu-first-run'
    Write-4twBanner @(
        'ONE-TIME UBUNTU SETUP',
        '',
        'Ubuntu will now ask you to create:',
        '- a Linux username',
        '- a Linux password',
        '',
        'These do not need to match Windows.',
        'No password characters or dots will appear while typing; this is normal.',
        '',
        'Complete setup and close Ubuntu. Then double-click',
        'BUILD-4TW-OS.cmd again.'
    )
    if (-not $NonInteractive) {
        Start-Process -FilePath $WslPath -ArgumentList @('-d', $Distro) -Wait
        Wait-4twUser 'After Ubuntu setup is complete, press Enter to close this launcher'
    }
}

function Test-4twWindowsEndpoint {
    try {
        Invoke-WebRequest -Uri 'https://archive.ubuntu.com/ubuntu/dists/resolute/InRelease' `
            -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null
        return $true
    } catch { return $false }
}

function Get-4twDownloadsFolder {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace('shell:Downloads')
        if ($null -ne $folder -and $folder.Self.Path) { return [string]$folder.Self.Path }
    } catch { }
    return ''
}

function Get-4twWindowsFreeBytes {
    param([string]$Path)
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    if (-not $root) { throw 'Could not determine the Windows output drive.' }
    return [IO.DriveInfo]::new($root).AvailableFreeSpace
}

try {
    $RepositoryRoot = Assert-4twRepository $PSScriptRoot
    $wslCommand = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue

    if ($WindowsSetup) {
        if (-not (Test-4twAdministrator)) { throw 'The requested Windows setup step requires Administrator approval.' }
        if ($null -eq $wslCommand) { $wslPath = Join-Path $env:SystemRoot 'System32\wsl.exe' }
        else { $wslPath = $wslCommand.Source }
        if ($WindowsSetup -eq 'InstallWsl') {
            Write-Host 'Installing the official Windows Subsystem for Linux components...'
            $code = Invoke-4twLive $wslPath @('--install', '--no-distribution')
            if ($code -eq 0) {
                $childVersion = Invoke-4twCapture $wslPath @('--version')
                $childStatus = Invoke-4twCapture $wslPath @('--status')
                $ready = (Get-4twWslAction $true $childVersion.ExitCode $childStatus.ExitCode) -eq 'Ready'
            } else { $ready = $false }
            $outcome = Get-4twWindowsSetupOutcome InstallWsl $code $ready
            if ($outcome -eq 'RestartRequired') {
                Save-4twState 'windows-restart-required'
                exit 10
            }
            if ($outcome -eq 'Ready') { exit 0 }
            exit 1
        }
        Write-Host 'Updating the official Windows Subsystem for Linux components...'
        $code = Invoke-4twLive $wslPath @('--update')
        if ((Get-4twWindowsSetupOutcome UpdateWsl $code) -eq 'Ready') { exit 0 }
        exit 1
    }

    $version = if ($null -eq $wslCommand) { [pscustomobject]@{ ExitCode = 1; Text = '' } }
        else { Invoke-4twCapture $wslCommand.Source @('--version') }
    $status = if ($null -eq $wslCommand) { [pscustomobject]@{ ExitCode = 1; Text = '' } }
        else { Invoke-4twCapture $wslCommand.Source @('--status') }
    $wslAction = Get-4twWslAction ($null -ne $wslCommand) $version.ExitCode $status.ExitCode
    if ($wslAction -eq 'Install') {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            try {
                $saved = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
                if ($saved.PSObject.Properties.Name -contains 'phase' -and
                        $saved.phase -eq 'windows-restart-required') {
                    Show-4twRestartRequired
                    exit 0
                }
            } catch {
                Write-Warning 'Ignoring an unreadable optional launcher state file.'
            }
        }
        Write-Host 'WSL2 must be enabled. Windows will show one Administrator approval prompt.'
        $code = Invoke-4twElevatedStep InstallWsl
        if ($code -eq 10) { Show-4twRestartRequired; exit 0 }
        if ($code -ne 0) { throw 'WSL installation did not complete.' }
    } elseif ($wslAction -eq 'Update') {
        Write-Host 'The installed WSL components need an update. Windows will show one Administrator approval prompt.'
        if ((Invoke-4twElevatedStep UpdateWsl) -ne 0) { throw 'WSL update failed.' }
    }

    $wslCommand = Get-Command 'wsl.exe' -ErrorAction Stop
    $wslPath = $wslCommand.Source
    $list = Invoke-4twCapture $wslPath @('--list', '--verbose')
    if ($list.ExitCode -ne 0) { throw 'WSL is installed but not ready. Restart Windows, then run BUILD-4TW-OS.cmd again.' }
    $installed = @(ConvertFrom-4twWslList $list.Text)
    $ubuntu = $installed | Where-Object { $_.Name -eq $Distro } | Select-Object -First 1
    if ($null -eq $ubuntu) {
        $online = Invoke-4twCapture $wslPath @('--list', '--online')
        if ($online.ExitCode -ne 0 -or -not (Test-4twOnlineDistroAvailable $online.Text $Distro)) {
            throw 'Ubuntu-26.04 is not currently listed by the official WSL catalogue.'
        }
        Write-Host 'Installing Ubuntu 26.04 for WSL2. Existing distributions are not changed.'
        $code = Invoke-4twLive $wslPath @('--install', '--distribution', $Distro, '--no-launch')
        if ($code -ne 0) { throw 'Ubuntu-26.04 installation failed.' }
        Show-4twUbuntuSetup $wslPath
        exit 0
    }
    if ($ubuntu.Version -eq 1) {
        Write-Host 'Converting only Ubuntu-26.04 from WSL1 to the required WSL2 format...'
        if ((Invoke-4twLive $wslPath @('--set-version', $Distro, '2')) -ne 0) {
            throw 'Ubuntu-26.04 could not be converted to WSL2.'
        }
    }

    $repoPath = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--',
        'wslpath', '-a', '-u', $RepositoryRoot)
    if ($repoPath.ExitCode -ne 0) {
        throw 'Could not translate this repository path into Ubuntu.'
    }
    try { $repoWsl = Get-4twPathFromWslOutput $repoPath.Text Unix }
    catch { throw 'Could not isolate the translated repository path from WSL diagnostics.' }
    $initialization = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
        '--', 'bash', 'build/check-wsl-initialized.sh')
    $initializationAction = Get-4twUbuntuInitializationAction $initialization.ExitCode
    if ($initializationAction -eq 'SetupRequired') {
        Show-4twUbuntuSetup $wslPath
        exit 0
    }
    if ($initializationAction -ne 'Ready') { throw 'Could not determine whether Ubuntu first-run setup is complete.' }

    $downloads = Get-4twDownloadsFolder
    $outputDirectory = Resolve-4twOutputDirectory $RepositoryRoot $downloads $env:USERPROFILE
    $windowsMinimumBytes = 4GB
    $nativeMinimumBytes = 18GB
    $windowsFree = Get-4twWindowsFreeBytes $outputDirectory
    if (-not (Test-4twFreeSpace $windowsFree $windowsMinimumBytes)) {
        throw ("The Windows output drive needs approximately 4 GiB free; available: {0:N1} GiB." -f ($windowsFree / 1GB))
    }
    $wslSpace = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--', 'df', '-Pk', '/')
    if ($wslSpace.ExitCode -ne 0) { throw 'Could not check native WSL disk space.' }
    $nativeFree = ConvertFrom-4twDfAvailable $wslSpace.Text
    if (-not (Test-4twFreeSpace $nativeFree $nativeMinimumBytes)) {
        throw ("The native Ubuntu filesystem needs approximately 18 GiB free; available: {0:N1} GiB." -f ($nativeFree / 1GB))
    }

    $hostCheck = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
        '--', 'bash', 'build/setup-host.sh', '--check')
    if ($hostCheck.ExitCode -ne 0) {
        if (-not (Test-4twWindowsEndpoint)) {
            throw 'Ubuntu package sources are not reachable; build-host dependencies were not downloaded.'
        }
        Write-Host 'Installing the required Ubuntu build tools (QEMU is not included)...'
        if ((Invoke-4twLive $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
            '--', 'bash', 'build/run-wsl.sh', 'host-deps')) -ne 0) {
            throw 'Ubuntu build-host dependency setup failed.'
        }
    }

    $nativeResult = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
        '--', 'python3', 'build/resolve-native-build.py')
    if ($nativeResult.ExitCode -ne 0) {
        throw ("The portable WSL build-user resolver stopped: " + $nativeResult.Text.Trim())
    }
    try { $nativeBuild = Get-4twPathFromWslOutput $nativeResult.Text Unix }
    catch { throw 'The portable WSL build-user resolver did not return one safe native path.' }
    $buildStatus = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
        '--', 'bash', 'build/run-wsl.sh', 'status')
    if ($buildStatus.ExitCode -eq 20) { throw $buildStatus.Text.Trim() }
    if ($buildStatus.ExitCode -notin @(0, 10)) { throw 'Could not determine the resumable build state.' }
    if ($buildStatus.ExitCode -eq 10) {
        Write-Host 'Checking the authenticated Ubuntu and Mozilla package sources...'
        if ((Invoke-4twLive $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
            '--', 'bash', 'build/check-internet.sh')) -ne 0) {
            throw 'Required Ubuntu or Mozilla package sources are not reachable. No image build was started.'
        }
        Write-Host 'Starting the resumable six-stage Release workflow.' -ForegroundColor Green
        Write-Host 'The first package preparation is normally the longest stage.'
        Invoke-4twBuildRunner {
            Invoke-4twLive $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
                '--', 'bash', 'build/run-wsl.sh', 'all')
        } | Out-Null
    } else {
        Write-Host 'The first four stages already have a verified IMG matching the current runtime source.'
    }

    $releaseStatus = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
        '--', 'bash', 'build/run-wsl.sh', 'release-status')
    if ($releaseStatus.ExitCode -eq 10) {
        Write-Host '[5/6] Compressing release with Zstandard' -ForegroundColor Green
        Write-Host 'Compressing 4TW-OS for distribution...'
        Write-Host 'This may take several minutes.'
        Save-4twState 'release-compression'
        if ((Invoke-4twLive $wslPath @('-d', $Distro, '-u', 'root', '--cd', $repoWsl,
            '--', 'bash', 'build/run-wsl.sh', 'release')) -ne 0) {
            throw 'Release compression failed. The verified raw IMG and cache were preserved; rerun this launcher to resume.'
        }
    } elseif ($releaseStatus.ExitCode -eq 0) {
        if ($buildStatus.ExitCode -eq 0) {
            Write-Host '[5/6] Existing compressed release verified; compression is being reused.' -ForegroundColor Green
        }
    } elseif ($releaseStatus.ExitCode -eq 3) {
        throw 'GitHub Release size check failed: the compressed artifact is not below 2 GiB.'
    } else {
        throw 'The compressed Release status could not be validated.'
    }

    $nativeRelease = "$nativeBuild/artifacts/4TW-OS_RELEASE.img.zst"
    $nativeChecksum = "$nativeBuild/artifacts/4TW-OS_RELEASE.img.zst.sha256"
    $releasePath = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--', 'wslpath', '-w', $nativeRelease)
    $checksumPath = Invoke-4twCapture $wslPath @('-d', $Distro, '-u', 'root', '--', 'wslpath', '-w', $nativeChecksum)
    if ($releasePath.ExitCode -ne 0 -or $checksumPath.ExitCode -ne 0) {
        throw 'The verified compressed output could not be exposed to Windows.'
    }
    try {
        $releaseWindows = Get-4twPathFromWslOutput $releasePath.Text Windows
        $checksumWindows = Get-4twPathFromWslOutput $checksumPath.Text Windows
    } catch { throw 'Could not isolate the verified compressed Windows paths from WSL diagnostics.' }
    Write-Host '[6/6] Verifying and exporting the compressed release' -ForegroundColor Green
    Write-Host 'Copying the compressed release to Windows once, then hashing the Windows copy...'
    Save-4twState 'release-export'
    $export = Export-4twVerifiedRelease $releaseWindows $checksumWindows $outputDirectory
    if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -Force }

    Write-4twBanner @(
        '             4TW-OS BUILD COMPLETE',
        '',
        'Your distributable 4TW-OS image is ready:',
        $export.Release,
        '',
        ("Compressed size: {0:N2} GiB" -f $export.SizeGiB),
        'GitHub Release size check: PASS',
        ("Headroom: approximately {0:N0} MiB" -f $export.HeadroomMiB),
        '',
        'SHA-256:',
        $export.Hash,
        '',
        'The release file has been verified after copying to Windows.',
        '',
        'FOR NORMAL USERS:',
        'Use Rufus 4.7 or newer.',
        '1. Open Rufus.',
        '2. Select your USB drive.',
        '3. Select 4TW-OS_RELEASE.img.zst directly.',
        '4. Click Start. Rufus decompresses it while flashing.',
        '',
        'WARNING: The selected USB will be erased.',
        '',
        'FOR PROJECT MAINTAINERS:',
        'Upload 4TW-OS_RELEASE.img.zst and its .sha256 file',
        'as GitHub Release assets, not as ordinary Git files.'
    )
    if (-not $NonInteractive) {
        Read-Host 'Press Enter to open the output folder' | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList @($outputDirectory)
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host '4TW-OS BUILD STOPPED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host "Logs are retained under: $PSScriptRoot\artifacts"
    Write-Host 'After correcting the reported problem, run BUILD-4TW-OS.cmd again.'
    if (-not $LaunchedFromCmd) { Wait-4twUser }
    exit 1
}
