$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $Project 'build\windows-launcher.psm1') -Force
$Passed = 0

function Assert-Launcher {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Passed++
    Write-Host "PASS: $Message"
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ("4TW OS launcher tests " + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $zipRoot = Join-Path $temporary 'ZIP checkout with spaces'
    [IO.Directory]::CreateDirectory((Join-Path $zipRoot 'build')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $zipRoot 'assets')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $zipRoot 'build\run-wsl.sh'), '')
    [IO.File]::WriteAllText((Join-Path $zipRoot 'build\setup-host.sh'), '')
    [IO.File]::WriteAllText((Join-Path $zipRoot 'build\compress-release.sh'), '')
    [IO.File]::WriteAllText((Join-Path $zipRoot 'assets\4TW-OS.png'), 'logo')
    $resolved = Assert-4twRepository $zipRoot
    Assert-Launcher ($resolved -eq $zipRoot) 'repository paths containing spaces work'
    Assert-Launcher (-not (Test-Path (Join-Path $zipRoot '.git'))) 'ZIP checkout works without Git metadata'

    Assert-Launcher ((Get-4twWslAction $true 0 0) -eq 'Ready') 'WSL-present path is ready'
    Assert-Launcher ((Get-4twWslAction $false 1 1) -eq 'Install') 'missing WSL requests installation'
    Assert-Launcher ((Get-4twWindowsSetupOutcome InstallWsl 3010) -eq 'RestartRequired') 'restart-required setup result pauses safely'
    Assert-Launcher ((Get-4twWindowsSetupOutcome InstallWsl 0 $true) -eq 'Ready') 'ready-after-install result avoids an unnecessary restart'

    $warningOutput = "wsl: Failed to translate 'D:\Program Files\example'`n/mnt/c/Source folder with spaces"
    Assert-Launcher ((Get-4twPathFromWslOutput $warningOutput Unix) -eq '/mnt/c/Source folder with spaces') `
        'unrelated WSL PATH warnings cannot contaminate a translated Unix path'
    $uncOutput = "wsl: diagnostic text`n\\wsl.localhost\Ubuntu-26.04\home\builder\image.img"
    Assert-Launcher ((Get-4twPathFromWslOutput $uncOutput Windows) -like '\\wsl.localhost\*') `
        'unrelated WSL diagnostics cannot contaminate a translated Windows path'
    Assert-Launcher ((Get-4twUserFromWslOutput "wsl: diagnostic text`nwriter") -eq 'writer') `
        'unrelated WSL diagnostics cannot contaminate the selected account name'
    $ambiguousPathStopped = $false
    try { Get-4twPathFromWslOutput "/one`n/two" Unix | Out-Null } catch { $ambiguousPathStopped = $true }
    Assert-Launcher $ambiguousPathStopped 'ambiguous WSL path output fails closed'

    $wslList = "  NAME             STATE           VERSION`n* Ubuntu-26.04     Stopped         2`n  Debian           Running         2"
    $parsed = @(ConvertFrom-4twWslList $wslList)
    Assert-Launcher (($parsed | Where-Object Name -eq 'Ubuntu-26.04').Version -eq 2) 'Ubuntu-present WSL2 path is parsed'
    $localized = @(ConvertFrom-4twWslList "* Ubuntu-26.04     Arrêtée et prête     2")
    Assert-Launcher ($localized[0].Version -eq 2) 'localized WSL state text does not hide an installed distro'
    Assert-Launcher ((Test-4twOnlineDistroAvailable "Ubuntu-24.04 Ubuntu`nUbuntu-26.04 Ubuntu") -eq $true) 'missing installed distro can be found in online catalogue'
    Assert-Launcher ((Get-4twUbuntuInitializationAction 10) -eq 'SetupRequired') 'uninitialized Ubuntu pauses for standard user setup'

    $failureSeen = $false
    try { Invoke-4twBuildRunner { 27 } | Out-Null } catch { $failureSeen = $_.Exception.Message -match 'exit code 27' }
    Assert-Launcher $failureSeen 'build-stage failure is surfaced and stops orchestration'
    Assert-Launcher (-not (Test-4twFreeSpace 3GB 4GB)) 'insufficient Windows release space fails preflight'
    $belowLimit = Get-4twGitHubReleaseSize 2147483647
    $atLimit = Get-4twGitHubReleaseSize 2147483648
    Assert-Launcher ($belowLimit.Pass -and -not $atLimit.Pass) 'GitHub release size requires strictly less than 2 GiB'

    $downloads = Join-Path $temporary 'Downloads'
    $output = Resolve-4twOutputDirectory $zipRoot $downloads ''
    Assert-Launcher ($output -eq (Join-Path $downloads '4TW-OS')) 'Windows Downloads output is resolved without a username assumption'

    $source = Join-Path $temporary 'source image.img.zst'
    [IO.File]::WriteAllText($source, 'small simulated verified compressed image')
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksum = Join-Path $temporary '4TW-OS_RELEASE.img.zst.sha256'
    [IO.File]::WriteAllText($checksum, "$hash  4TW-OS_RELEASE.img.zst`n")
    Assert-Launcher (Test-4twChecksumMatch $source $hash) 'matching source checksum is accepted'
    Assert-Launcher (-not (Test-4twChecksumMatch $source ('0' * 64))) 'checksum mismatch is rejected'
    $export = Export-4twVerifiedRelease $source $checksum $output '2026-01-02-030405'
    Assert-Launcher ((Test-Path $export.Release) -and (Test-4twChecksumMatch $export.Release $hash) -and
        (Test-Path $export.Report) -and -not (Test-Path (Join-Path $output '4TW-OS_RELEASE.img'))) `
        'successful compressed output is copied, rehashed and reported without a raw IMG'
    $firstWrite = (Get-Item -LiteralPath $export.Release).LastWriteTimeUtc
    Start-Sleep -Milliseconds 20
    $reused = Export-4twVerifiedRelease $source $checksum $output '2026-01-02-030406'
    Assert-Launcher ((Get-Item -LiteralPath $reused.Release).LastWriteTimeUtc -eq $firstWrite) `
        'an already matching Windows compressed release is reused without another large copy'

    [IO.File]::WriteAllText($export.Release, 'older verified output placeholder')
    [IO.Directory]::CreateDirectory((Join-Path $output 'previous')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $output 'previous\4TW-OS_RELEASE-obsolete.img.zst'), 'obsolete')
    $replacement = Export-4twVerifiedRelease $source $checksum $output '2026-01-02-030407'
    $previousReleases = @(Get-ChildItem -LiteralPath (Join-Path $output 'previous') -Filter '*.img.zst')
    Assert-Launcher (($previousReleases.Count -eq 1) -and
        ($previousReleases[0].Name -eq '4TW-OS_RELEASE-2026-01-02-030407.img.zst') -and
        (Test-4twChecksumMatch $replacement.Release $hash)) `
        'a replaced Windows release is archived with bounded retention'

    $badOutput = Join-Path $temporary 'bad export'
    $badSource = Join-Path $temporary 'bad-source.img.zst'
    [IO.File]::WriteAllText($badSource, 'not the verified bytes')
    $mismatchStopped = $false
    try {
        Export-4twVerifiedRelease $badSource $checksum $badOutput '2026-01-02-030408' | Out-Null
    } catch { $mismatchStopped = $_.Exception.Message -match 'remains unpublished' }
    Assert-Launcher ($mismatchStopped -and
        -not (Test-Path (Join-Path $badOutput '4TW-OS_RELEASE.img.zst')) -and
        (Test-Path (Join-Path $badOutput '4TW-OS_RELEASE.img.zst.partial'))) `
        'a simulated post-copy checksum mismatch never publishes the Rufus-ready name'
    [IO.File]::WriteAllText($badSource, 'small simulated verified compressed image')
    $resumed = Export-4twVerifiedRelease $badSource $checksum $badOutput '2026-01-02-030409'
    Assert-Launcher ((Test-4twChecksumMatch $resumed.Release $hash) -and
        -not (Test-Path (Join-Path $badOutput '4TW-OS_RELEASE.img.zst.partial'))) `
        'export resumes safely after a prior partial-copy failure'

    $launcherText = Get-Content -Raw -LiteralPath (Join-Path $Project 'BUILD-4TW-OS.ps1')
    Assert-Launcher ($launcherText.Contains('[6/6] Verifying and exporting the compressed release') -and
        $launcherText.Contains('4TW-OS_RELEASE.img.zst directly') -and
        -not $launcherText.Contains('Export-4twVerifiedOutput')) `
        'success workflow presents the compressed release and no raw-IMG export'

    $forbiddenUser = 'jon' + 'be'
    $forbiddenWindowsRoot = 'C:' + [char]92 + 'Users' + [char]92
    $sourceFiles = Get-ChildItem -LiteralPath $Project -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/](artifacts|\.git|\.work|\.build-cache|prompts|__pycache__)[\\/]' }
    $forbiddenFound = $false
    foreach ($file in $sourceFiles) {
        if ($file.Extension -notin @('.ps1', '.psm1', '.cmd', '.sh', '.py', '.md', '.txt', '.conf')) { continue }
        $text = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        if ($text -and ($text.Contains($forbiddenUser) -or $text.Contains($forbiddenWindowsRoot))) {
            $forbiddenFound = $true
            break
        }
    }
    Assert-Launcher (-not $forbiddenFound) 'launcher/source contains no hard-coded developer username or Windows profile path'
    Write-Host "Windows launcher tests passed: $Passed"
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
