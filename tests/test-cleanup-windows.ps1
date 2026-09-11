$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $Project 'build\windows-launcher.psm1') -Force
$Passed = 0

function Assert-Cleanup {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Passed++
    Write-Host "PASS: $Message"
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ("4TW cleanup tests " + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $repository = Join-Path $temporary 'repository with spaces'
    [IO.Directory]::CreateDirectory((Join-Path $repository 'artifacts\previous')) | Out-Null
    $provenancePath = Join-Path $temporary 'Local AppData\4TW-OS\build-provenance.json'
    $first = Initialize-4twProvenance -Path $provenancePath -WslBefore Absent -UbuntuBefore Absent -DistrosBefore @() -RepositoryRoot $repository
    $firstId = $first.cycle_id
    Set-4twProvenanceFields $provenancePath @{
        wsl_install_invoked_by_4tw = $true
        wsl_install_completed = $true
        ubuntu_install_invoked_by_4tw = $true
        ubuntu_installed_by_4tw = $true
        native_build_directory = '/home/writer/4tw-ubuntu-sway-build'
        selected_wsl_user = 'writer'
    } | Out-Null
    $resumed = Initialize-4twProvenance -Path $provenancePath -WslBefore Present -UbuntuBefore Present -DistrosBefore @('Ubuntu-26.04') -RepositoryRoot 'C:\different'
    Assert-Cleanup ($resumed.cycle_id -eq $firstId -and $resumed.ubuntu_before -eq 'Absent') 'restart/resume does not overwrite original pre-build ownership'
    Assert-Cleanup ((Get-4twDistroOwnership $resumed) -eq 'CreatedBy4tw') 'fresh-machine provenance permits only the project-created distro decision'

    $preExisting = [pscustomobject]@{
        distro_name = 'Ubuntu-26.04'; ubuntu_before = 'Present'
        ubuntu_install_invoked_by_4tw = $false; ubuntu_installed_by_4tw = $false
    }
    Assert-Cleanup ((Get-4twDistroOwnership $preExisting) -eq 'PreExisting') 'pre-existing Ubuntu is classified for project-tree-only cleanup'
    Assert-Cleanup ((Get-4twDistroOwnership $null) -eq 'Unknown') 'old builds without provenance fall back to unknown ownership'
    $conflict = [pscustomobject]@{
        distro_name = 'Ubuntu-26.04'; ubuntu_before = 'Present'
        ubuntu_install_invoked_by_4tw = $true; ubuntu_installed_by_4tw = $true
    }
    Assert-Cleanup ((Get-4twDistroOwnership $conflict) -eq 'Conflict') 'contradictory provenance fails closed'

    Set-4twProvenanceFields $provenancePath @{ cleanup_completed = $true } | Out-Null
    $newCycle = Initialize-4twProvenance -Path $provenancePath -WslBefore Present -UbuntuBefore Present -DistrosBefore @('Ubuntu-26.04', 'Debian') -RepositoryRoot $repository
    Assert-Cleanup ($newCycle.cycle_id -ne $firstId -and $newCycle.ubuntu_before -eq 'Present') 'a completed cleanup allows one new provenance cycle'
    Assert-Cleanup (
        $newCycle.PSObject.Properties.Name -contains 'windows_features_before' -and
        $newCycle.PSObject.Properties.Name -contains 'windows_features_changed_by_4tw' -and
        $newCycle.PSObject.Properties.Name -contains 'vm_tools_stage'
    ) 'provenance includes Windows-feature and optional-VM tracking fields'

    $output = Join-Path $temporary 'Downloads with spaces\4TW-OS'
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $release = Join-Path $output '4TW-OS_RELEASE.img.zst'
    [IO.File]::WriteAllText($release, 'verified compressed release')
    $hash = (Get-FileHash -LiteralPath $release -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$release.sha256", "$hash  4TW-OS_RELEASE.img.zst`n")
    $verified = Get-4twVerifiedReleaseAtDirectory $output
    Assert-Cleanup ($verified.Hash -eq $hash -and $verified.FileName -eq '4TW-OS_RELEASE.img.zst') 'compressed public release is verified using its adjacent checksum'

    $corrupt = Join-Path $temporary 'corrupt output'
    [IO.Directory]::CreateDirectory($corrupt) | Out-Null
    [IO.File]::WriteAllText((Join-Path $corrupt '4TW-OS_RELEASE.img.zst'), 'corrupt')
    [IO.File]::WriteAllText((Join-Path $corrupt '4TW-OS_RELEASE.img.zst.sha256'), "$hash  4TW-OS_RELEASE.img.zst`n")
    $corruptStopped = $false
    try { Get-4twVerifiedReleaseAtDirectory $corrupt | Out-Null } catch { $corruptStopped = $true }
    Assert-Cleanup $corruptStopped 'invalid public checksum stops cleanup'

    $legacy = Join-Path $temporary 'legacy output'
    [IO.Directory]::CreateDirectory($legacy) | Out-Null
    $legacyImage = Join-Path $legacy '4TW-OS_RELEASE.img'
    [IO.File]::WriteAllText($legacyImage, 'legacy verified raw release')
    $legacyHash = (Get-FileHash -LiteralPath $legacyImage -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$legacyImage.sha256", "$legacyHash  4TW-OS_RELEASE.img`n")
    Assert-Cleanup ((Get-4twVerifiedReleaseAtDirectory $legacy).Hash -eq $legacyHash) 'legacy verified raw public output remains supported conservatively'

    $ambiguousStopped = $false
    try { Find-4twVerifiedRelease @($output, $legacy) | Out-Null } catch { $ambiguousStopped = $true }
    Assert-Cleanup $ambiguousStopped 'multiple possible public outputs stop cleanup'
    $missingStopped = $false
    try { Find-4twVerifiedRelease @((Join-Path $temporary 'missing')) | Out-Null } catch { $missingStopped = $true }
    Assert-Cleanup $missingStopped 'missing public output stops cleanup'

    $generatedImage = Join-Path $repository 'artifacts\4TW-OS_RELEASE.img'
    $generatedChecksum = "$generatedImage.sha256"
    $keptLog = Join-Path $repository 'artifacts\verify-img.log'
    [IO.File]::WriteAllText($generatedImage, 'generated')
    [IO.File]::WriteAllText($generatedChecksum, 'checksum')
    [IO.File]::WriteAllText($keptLog, 'diagnostic')
    $generated = @(Get-4twRepositoryGeneratedArtifacts $repository)
    Assert-Cleanup ($generated.Count -eq 2 -and $generated.FullName -contains $generatedImage -and
        $generated.FullName -contains $generatedChecksum -and $generated.FullName -notcontains $keptLog) 'repository cleanup selects generated image pairs but preserves diagnostic logs'

    $nativeStatus = ConvertFrom-4twCleanupStatus "status=present`npath=/home/writer/4tw-ubuntu-sway-build`nselected_user=writer`nsize_bytes=123`nmount_count=2`nloop_count=1`nvm_tools=completed"
    Assert-Cleanup ($nativeStatus.SizeBytes -eq 123 -and $nativeStatus.MountCount -eq 2) 'native diagnostics accept one complete validated identity'
    $unsafeStopped = $false
    try {
        ConvertFrom-4twCleanupStatus "status=present`npath=/mnt/c/build/4tw-ubuntu-sway-build`nselected_user=writer`nsize_bytes=1`nmount_count=0`nloop_count=0`nvm_tools=x" | Out-Null
    } catch { $unsafeStopped = $true }
    Assert-Cleanup $unsafeStopped 'Windows rejects a cleanup path on a mounted Windows drive'

    $cleanupText = Get-Content -Raw -LiteralPath (Join-Path $Project 'CLEANUP-4TW-OS.ps1')
    Assert-Cleanup (
        $cleanupText.Contains('$ownership -eq ''CreatedBy4tw''') -and
        $cleanupText.Contains("-ceq 'REMOVE'") -and
        $cleanupText.Contains('''--terminate'', $Distro') -and
        $cleanupText.Contains('''--unregister'', $Distro')
    ) 'Ubuntu unregister is gated by recorded ownership and explicit REMOVE confirmation'
    Assert-Cleanup (
        -not $cleanupText.Contains("'--shutdown'") -and
        -not $cleanupText.Contains('Disable-WindowsOptionalFeature') -and
        -not $cleanupText.Contains('apt-get purge') -and
        -not $cleanupText.Contains('AppData\Packages') -and
        -not $cleanupText.Contains('Optimize-VHD')
    ) 'cleanup contains no generic WSL shutdown, feature rollback, package purge or VHD manipulation'
    $cmdText = Get-Content -Raw -LiteralPath (Join-Path $Project 'CLEANUP-4TW-OS.cmd')
    Assert-Cleanup ($cmdText.Contains('--dry-run') -and $cmdText.Contains('-DryRun')) 'CMD entry point maps the documented dry-run switch'
    $builderText = Get-Content -Raw -LiteralPath (Join-Path $Project 'BUILD-4TW-OS.ps1')
    Assert-Cleanup (
        $builderText.IndexOf('Initialize-4twProvenance') -lt $builderText.IndexOf('Invoke-4twElevatedStep InstallWsl') -and
        $builderText.Contains('ubuntu_install_invoked_by_4tw') -and
        $builderText.Contains('host_dependencies_install_invoked') -and
        $builderText.Contains('windows_features_changed_by_4tw')
    ) 'builder records original host state before installation and records each host-changing stage'

    Write-Host "Windows cleanup tests passed: $Passed"
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
