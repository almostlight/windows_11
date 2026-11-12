<#
.SYNOPSIS
    Comprehensive Windows system setup, software installation, and configuration.

.DESCRIPTION
    This script performs a complete Windows setup including:
    - Package manager installation (winget)
    - Font installation (FiraCode Nerd Font, Bai Jamjuree)
    - Software installation via winget
    - MSYS2 development environment configuration (via separate script)
    - Dotfiles and configuration deployment
    - PowerToys configuration
    - Optional WSL installation
    - System and desktop settings configuration
    - Debloat operations

.PARAMETER WhatIf
    If specified, shows what would be done without making any changes.

.EXAMPLE
    .\windows_setup.ps1
    Runs the complete Windows setup.

.EXAMPLE
    .\windows_setup.ps1 -WhatIf
    Shows what would be configured without making changes.

.NOTES
    File Name: windows_setup.ps1
    Author: AlmostLight
    License: As-is
    
    The script requires administrator privileges and will self-elevate if needed.
    Logs are written to %USERPROFILE%\scripts\setup.<timestamp>.log
#>

[CmdletBinding()]
param (
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
$ScriptUrl = 'https://raw.githubusercontent.com/almostlight/WindowsSetup/main/Windows/windows_setup.ps1'
$PromptTimeoutSeconds = 5
$HadErrors = $False
$SetupRunId = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$WorkPath = Join-Path $Env:TEMP "WindowsSetup-$PID"

# Dot-source shared functions
$SetupFunctionsPath = Join-Path $PSScriptRoot 'SetupFunctions.ps1'
if (Test-Path $SetupFunctionsPath) {
    . $SetupFunctionsPath
} else {
    throw "SetupFunctions.ps1 not found at $SetupFunctionsPath"
}

if (-not $WhatIf -and -not ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $ElevatedScript = Join-Path $Env:TEMP "windows-setup-$PID.ps1"
    $LocalStartupScript = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot 'home\scripts\windows-startup.ps1'
    }
    $ElevatedStartupScript = Join-Path $Env:TEMP 'windows-setup-startup.ps1'
    $ElevatedFunctionsScript = Join-Path $Env:TEMP 'SetupFunctions.ps1'
    
    if ($PSCommandPath -and (Test-Path $PSCommandPath -PathType Leaf)) {
        Copy-Item $PSCommandPath $ElevatedScript -Force
        if (Test-Path $LocalStartupScript -PathType Leaf) {
            Copy-Item $LocalStartupScript $ElevatedStartupScript -Force
        }
        $SetupFunctionsSource = Join-Path $PSScriptRoot 'SetupFunctions.ps1'
        if (Test-Path $SetupFunctionsSource -PathType Leaf) {
            Copy-Item $SetupFunctionsSource $ElevatedFunctionsScript -Force
        }
    } else {
        Invoke-WebRequest $ScriptUrl -OutFile $ElevatedScript -UseBasicParsing
        Get-RawRepositoryFile -RelativePath 'Windows/SetupFunctions.ps1' -Out $ElevatedFunctionsScript
    }

    $Shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $Shell) {
        $Shell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    }
    
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ElevatedScript`""
    if (-not $Shell) {
        throw 'Could not find PowerShell to run the elevated setup.'
    }


    try {
        $Process = Start-Process $Shell -ArgumentList $Arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        throw "Could not start the elevated setup. Approve the UAC prompt and try again. $($_.Exception.Message)"
    }
    
    Remove-Item $ElevatedScript -Force -ErrorAction SilentlyContinue
    Remove-Item $ElevatedStartupScript -Force -ErrorAction SilentlyContinue
    exit $Process.ExitCode
}

try {
    $Date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $BasePath = [Environment]::GetFolderPath('UserProfile')
    $Downloads = Join-Path $BasePath 'Downloads'
    $ScriptsPath = Join-Path $BasePath 'scripts'
    $LogPath = Join-Path $ScriptsPath "setup.$SetupRunId.log"

    if ($WhatIf) {
        Write-Host '[WHATIF] Provisioning started'
    } else {
        New-Item -ItemType Directory -Force -Path $Downloads, $ScriptsPath, $WorkPath | Out-Null
        Set-Content -Path $LogPath -Value "Provisioning started: $Date"
    }

    function Write-SetupLog {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Msg,
            [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'WHATIF')]
            [string]$Type = 'INFO'
        )
        $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
        Write-Host $Line
        if (-not $WhatIf) {
            Add-Content -Path $LogPath -Value $Line
        }
    }

    function Write-Phase {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Name
        )
        Write-SetupLog -Msg "PHASE: $Name" -Type 'INFO'
    }

    function Read-TimedChoice {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Prompt,
            [Parameter(Mandatory)]
            [string]$Default
        )

        if ([Console]::IsInputRedirected) {
            return $Default
        }

        $InputHandle = [WindowsSetup.ConsoleNative]::GetStdHandle(-10)
        [uint32]$OriginalMode = 0
        $RestoreConsoleMode = $InputHandle -ne [IntPtr]::Zero -and`
            [WindowsSetup.ConsoleNative]::GetConsoleMode($InputHandle, [ref]$OriginalMode)
        
        if ($RestoreConsoleMode) {
            $NoQuickEditMode = [uint32](($OriginalMode -bor 0x0080) -band 0xFFFFFFBF)
            if (-not [WindowsSetup.ConsoleNative]::SetConsoleMode($InputHandle, $NoQuickEditMode)) {
                $RestoreConsoleMode = $False
            }
        }

        try {
            $Deadline = [DateTime]::UtcNow.AddSeconds($PromptTimeoutSeconds)
            $LastShown = -1

            while ($True) {
                $Remaining = [Math]::Max(0, [Math]::Ceiling(
                    ($Deadline - [DateTime]::UtcNow).TotalSeconds
                ))
                if ($Remaining -ne $LastShown) {
                    [Console]::Write("`r$Prompt [$Remaining] ")
                    $LastShown = $Remaining
                }

                if ([Console]::KeyAvailable) {
                    $Key = [Console]::ReadKey($True)
                    if ($Key.Key -eq [ConsoleKey]::Enter) {
                        [Console]::WriteLine("`r$Prompt [$Remaining] $Default")
                        return $Default
                    }
                    if (-not [char]::IsControl($Key.KeyChar)) {
                        [Console]::WriteLine("`r$Prompt [$Remaining] $($Key.KeyChar)")
                        return [string]$Key.KeyChar
                    }
                }

                if ([DateTime]::UtcNow -ge $Deadline) {
                    [Console]::WriteLine("`r$Prompt [0] $Default")
                    return $Default
                }

                Start-Sleep -Milliseconds 100
            }
        } finally {
            if ($RestoreConsoleMode) {
                [WindowsSetup.ConsoleNative]::SetConsoleMode($InputHandle, $OriginalMode) | Out-Null
            }
        }
    }

    function Invoke-Step {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Name,
            [Parameter(Mandatory)]
            [ScriptBlock]$ScriptBlock
        )

        Write-SetupLog -Msg "RUN: $Name" -Type 'INFO'

        if ($WhatIf) {
            Write-SetupLog -Msg "WHATIF: Would run $Name" -Type 'WHATIF'
            return
        }

        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            & $ScriptBlock
        } catch {
            Write-SetupLog -Msg "FAILED: $Name - $_" -Type 'ERROR'
            $Global:HadErrors = $True
        } finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
    }

    function Restart-ExplorerShell {
        Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |`
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
        Start-Process `
            -FilePath (Join-Path $Env:WINDIR 'explorer.exe') `
            -ArgumentList '/factory' `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null
    }

    Write-SetupLog -Msg 'Starting provisioning'

    function Invoke-FinalVerification {
        Write-Phase -Name 'Verification'
        if ($WhatIf) {
            Write-SetupLog -Msg 'WHATIF: Would verify registry, language, startup, and scheduled-task settings' -Type 'WHATIF'
            return
        }

        $FailedChecks = [System.Collections.Generic.List[string]]::new()
        
        function Assert-SetupCheck {
            param (
                [string]$Name,
                [ScriptBlock]$Test
            )
            try {
                if (& $Test) {
                    Write-SetupLog -Msg "PASS: $Name" -Type 'SUCCESS'
                } else {
                    Write-SetupLog -Msg "FAIL: $Name" -Type 'ERROR'
                    $Script:FailedChecks.Add($Name) | Out-Null
                }
            } catch {
                Write-SetupLog -Msg "FAIL: $Name - $($_.Exception.Message)" -Type 'ERROR'
                $Script:FailedChecks.Add($Name) | Out-Null
            }
        }

        Assert-SetupCheck -Name 'Input method indicator hidden' -Test {
            (Get-ItemPropertyValue 'HKCU:\Control Panel\Input Method' -Name 'ShowStatus' -ErrorAction Stop) -eq 2
        }

        Assert-SetupCheck -Name 'Taskbar controls hidden' -Test {
            $Advanced = Get-ItemProperty `
                'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
                -ErrorAction Stop
            $Advanced.SearchboxTaskbarMode -eq 0 -and`
                $Advanced.TaskbarSearchMode -eq 0 -and`
                $Advanced.ShowTaskViewButton -eq 0 -and`
                $Advanced.TaskbarDa -eq 0 -and`
                $Advanced.TaskbarMn -eq 0 -and`
                $Advanced.ShowCopilotButton -eq 0
        }

        Assert-SetupCheck -Name 'Polish keyboard layout configured' -Test {
            $Polish = Get-WinUserLanguageList |`
                Where-Object LanguageTag -eq 'pl-PL' |`
                Select-Object -First 1
            $Null -ne $Polish -and $Polish.InputMethodTips -contains '0415:00000415'
        }

        Assert-SetupCheck -Name 'Startup script deployed' -Test {
            Test-Path (Join-Path $BasePath 'scripts\windows-startup.ps1') -PathType Leaf
        }

        Assert-SetupCheck -Name 'Graphical startup task registered' -Test {
            $Null -ne (Get-ScheduledTask -TaskName 'Graphical Environment Startup' -ErrorAction Stop)
        }

        Assert-SetupCheck -Name 'Komorebi watchdog task registered' -Test {
            $Null -ne (Get-ScheduledTask -TaskName 'Komorebi Process Watchdog' -ErrorAction Stop)
        }

        if ($FailedChecks.Count -gt 0) {
            $Global:HadErrors = $True
            Write-SetupLog -Msg "Verification failed for $($FailedChecks.Count) check(s)" -Type 'ERROR'
        } else {
            Write-SetupLog -Msg 'Verification passed for all 6 checks' -Type 'SUCCESS'
        }
    }

    function Get-File {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Url,
            [Parameter(Mandatory)]
            [string]$Out,
            [string]$ExpectedSha256
        )

        $DownloadPath = Join-Path $WorkPath ([IO.Path]::GetFileName($Out) + ".$PID.download")

        for ($I = 0; $I -lt 3; $I++) {
            try {
                Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
                Invoke-WebRequest $Url -OutFile $DownloadPath -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
                $Download = Get-Item $DownloadPath -ErrorAction Stop
                if ($Download.Length -eq 0) {
                    throw "Downloaded file was empty: $Url"
                }
                if ($ExpectedSha256) {
                    $ActualSha256 = (Get-FileHash $DownloadPath -Algorithm SHA256).Hash
                    if ($ActualSha256 -ne $ExpectedSha256.ToUpperInvariant()) {
                        throw "SHA-256 mismatch for $Url. Expected $ExpectedSha256, got $ActualSha256"
                    }
                }
                Move-Item $DownloadPath $Out -Force -ErrorAction Stop
                return
            } catch {
                if ($I -eq 2) {
                    throw "Download failed after 3 attempts: $Url - $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 2
            }
        }
    }

    function Get-RawRepositoryFile {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$RelativePath,
            [Parameter(Mandatory)]
            [string]$Out
        )
        Get-File `
            "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/$RelativePath" `
            $Out
    }

    function Get-LatestGitHubAsset {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Repository,
            [Parameter(Mandatory)]
            [string]$AssetName
        )

        $Release = Invoke-RestMethod `
            "https://api.github.com/repos/$Repository/releases/latest" `
            -Headers @{ 'User-Agent' = 'WindowsSetup' } `
            -ErrorAction Stop
        $Asset = $Release.assets | Where-Object name -eq $AssetName | Select-Object -First 1
        if (-not $Asset) {
            throw "GitHub release asset was not found: $Repository/$AssetName"
        }

        [pscustomobject]@{
            Url = $Asset.browser_download_url
            Sha256 = if ($Asset.digest -match '^sha256:([a-f0-9]{64})$') {
                $Matches[1]
            } else {
                $Null
            }
        }
    }

    function Set-SymbolicLink {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Source,
            [Parameter(Mandatory)]
            [string]$Target
        )
        $TargetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
        if ($TargetItem) {
            Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
        }
        New-Item -ItemType SymbolicLink -Path $Target -Target $Source -ErrorAction Stop | Out-Null
    }

    function Set-DefaultWallpaper {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$RepositoryPath
        )
        $SourceWallpaper = Join-Path $RepositoryPath 'home\.config\default.png'
        if (-not (Test-Path $SourceWallpaper -PathType Leaf)) {
            throw "Wallpaper file was not found: $SourceWallpaper"
        }

        $ConfigDir = Join-Path $BasePath '.config'
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $TargetWallpaper = Join-Path $ConfigDir 'default.png'
        Set-SymbolicLink -Source $SourceWallpaper -Target $TargetWallpaper
        if (-not [WindowsSetup.ConsoleNative]::SystemParametersInfo(20, 0, $TargetWallpaper, 3)) {
            $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Could not set wallpaper. Windows error code: $ErrorCode"
        }

        Write-SetupLog -Msg "Set desktop wallpaper to $TargetWallpaper"

        $SourceLockScreen = Join-Path $RepositoryPath 'home\.config\default_lock.png'
        if (-not (Test-Path $SourceLockScreen -PathType Leaf)) {
            throw "Lock screen image was not found: $SourceLockScreen"
        }

        $TargetLockScreen = Join-Path $ConfigDir 'default_lock.png'
        Set-SymbolicLink -Source $SourceLockScreen -Target $TargetLockScreen

        $PersonalizationPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
        New-Item -Path $PersonalizationPath -Force | Out-Null
        New-ItemProperty `
            -Path $PersonalizationPath `
            -Name 'LockScreenImagePath' `
            -Value $TargetLockScreen `
            -PropertyType String `
            -Force | Out-Null
        New-ItemProperty `
            -Path $PersonalizationPath `
            -Name 'LockScreenImageUrl' `
            -Value $TargetLockScreen `
            -PropertyType String `
            -Force | Out-Null
        New-ItemProperty `
            -Path $PersonalizationPath `
            -Name 'LockScreenImageStatus' `
            -Value 1 `
            -PropertyType DWord `
            -Force | Out-Null

        Write-SetupLog -Msg "Set lock screen image to $TargetLockScreen"
    }

    function Install-FontFiles {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [array]$FontFiles
        )
        $FontsPath = Join-Path $Env:WINDIR 'Fonts'
        $FontRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

        foreach ($FontFile in $FontFiles) {
            $Target = Join-Path $FontsPath $FontFile.Name
            if (-not (Test-Path $Target -PathType Leaf)) {
                Copy-Item $FontFile.FullName $Target
            }

            $FontType = switch ([IO.Path]::GetExtension($FontFile.Name).ToLowerInvariant()) {
                '.otf' { 'OpenType' }
                default { 'TrueType' }
            }
            $FontDisplayName = "$([IO.Path]::GetFileNameWithoutExtension($FontFile.Name)) ($FontType)"
            New-ItemProperty `
                -Path $FontRegistryPath `
                -Name $FontDisplayName `
                -Value $FontFile.Name `
                -PropertyType String `
                -Force | Out-Null
        }
    }

    function Set-WindowsTerminalFont {
        $SettingsPaths = @(
            (Join-Path $Env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $Env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
        ) | Where-Object { Test-Path $_ -PathType Leaf }

        if (-not $SettingsPaths) {
            Write-SetupLog -Msg 'Windows Terminal settings were not found; skipping terminal font configuration' -Type 'WARN'
            return
        }

        foreach ($SettingsPath in $SettingsPaths) {
            $Settings = Get-Content $SettingsPath -Raw
            $DefaultsPattern = '(?s)("profiles"\s*:\s*\{\s*"defaults"\s*:\s*\{)(.*?)("list"\s*:)'
            $DefaultsMatch = [regex]::Match($Settings, $DefaultsPattern)
            if (-not $DefaultsMatch.Success) {
                throw "Could not locate Windows Terminal profiles.defaults in $SettingsPath"
            }

            $Defaults = $DefaultsMatch.Groups[2].Value
            $FontPattern = '(?s)"font"\s*:\s*\{.*?\}'
            if ([regex]::IsMatch($Defaults, $FontPattern)) {
                $Defaults = [regex]::Replace(
                    $Defaults,
                    $FontPattern,
                    '"font": { "face": "FiraCode Nerd Font Mono" }',
                    1
                )
            } else {
                $Defaults = "`n            `"font`": { `"face`": `"FiraCode Nerd Font Mono`" }," + $Defaults
            }

            $Settings = $Settings.Substring(0, $DefaultsMatch.Groups[2].Index) +`
                $Defaults +`
                $Settings.Substring($DefaultsMatch.Groups[2].Index + $DefaultsMatch.Groups[2].Length)
            Set-Content $SettingsPath $Settings -Encoding utf8
            Write-SetupLog -Msg "Set Windows Terminal default font to FiraCode Nerd Font Mono in $SettingsPath"
        }
    }

    function Invoke-WingetInstallWithKeepAlive {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Id
        )
        $WingetPath = (Get-Command winget -ErrorAction Stop).Source
        $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $StartInfo.FileName = $WingetPath
        $StartInfo.Arguments = "install -e --id `"$Id`" --silent --accept-package-agreements --accept-source-agreements"
        $StartInfo.UseShellExecute = $False
        $StartInfo.RedirectStandardInput = $True

        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $StartInfo
        try {
            if (-not $Process.Start()) {
                throw "Could not start winget for $Id"
            }

            while (-not $Process.WaitForExit(15000)) {
                $Process.StandardInput.WriteLine()
                $Process.StandardInput.Flush()
            }

            return $Process.ExitCode
        } finally {
            $Process.StandardInput.Close()
            $Process.Dispose()
        }
    }

    function Install-SetupPackage {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$Id
        )
        $Installed = $Null | & winget list --exact --id $Id `
            --accept-source-agreements --disable-interactivity 2>&1 |`
            Out-String
        if ($Installed -match '(?im)\b$([regex]::Escape($Id))\b') {
            Write-SetupLog -Msg "Skipping already installed package $Id"
            return
        }

        Write-SetupLog -Msg "Installing $Id"
        $ExitCode = Invoke-WingetInstallWithKeepAlive -Id $Id
        if ($ExitCode -ne 0) {
            throw "Winget failed for $Id with exit code $ExitCode"
        }
    }

    Write-SetupLog -Msg 'Collecting user preferences...'

    $InstallAllRecommendedPackages = $False
    $Response = Read-TimedChoice `
        'Install all recommended packages? [y/N] (Choosing N installs only strictly necessary packages)' `
        'n'
    if ($Response -eq 'y') {
        $InstallAllRecommendedPackages = $True
    } elseif ($Response -and $Response -ne 'n') {
        Write-SetupLog -Msg "Unrecognized package installation choice: '$Response'. Defaulting to strictly necessary packages" -Type 'WARN'
    }

    $InstallFedoraWSL = $False
    $Response = Read-TimedChoice -Prompt 'Install the latest Fedora on WSL? [y/N]' -Default 'n'
    if ($Response -eq 'y') {
        $InstallFedoraWSL = $True
    }

    Write-SetupLog -Msg 'User preferences collected. Starting provisioning...'

    Write-Phase -Name 'Package manager and fonts'

    Invoke-Step -Name 'winget' -ScriptBlock {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            $Pkg = Join-Path $Downloads 'winget.msixbundle'
            Get-File -Url 'https://aka.ms/getwinget' -Out $Pkg
            Add-AppxPackage $Pkg
            Start-Sleep -Seconds 5
        }
    }

    Invoke-Step -Name 'fonts' -ScriptBlock {
        $FontArchive = Join-Path $Downloads 'WindowsSetup-fonts'
        $FiraCodeArchive = Join-Path $Downloads 'FiraCode.zip'

        $FiraCodeAsset = Get-LatestGitHubAsset -Repository 'ryanoasis/nerd-fonts' -AssetName 'FiraCode.zip'
        Get-File -Url $FiraCodeAsset.Url -Out $FiraCodeArchive -ExpectedSha256 $FiraCodeAsset.Sha256

        if (Test-Path $FontArchive) {
            Remove-Item $FontArchive -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $FontArchive | Out-Null

        $FiraCodeDirectory = Join-Path $FontArchive 'FiraCode'
        $BaiJamjureeDirectory = Join-Path $FontArchive 'BaiJamjuree'
        Expand-Archive $FiraCodeArchive $FiraCodeDirectory -Force

        New-Item -ItemType Directory -Force -Path $BaiJamjureeDirectory | Out-Null
        $BaiJamjureeAssets = Invoke-RestMethod `
            'https://api.github.com/repos/google/fonts/contents/ofl/baijamjuree' `
            -Headers @{ 'User-Agent' = 'WindowsSetup' } |`
            Where-Object { $_.Name -match '\.(ttf|otf)$' }
        foreach ($Asset in $BaiJamjureeAssets) {
            Get-File -Url "https://raw.githubusercontent.com/google/fonts/main/ofl/baijamjuree/$($Asset.Name)" `
                -Out (Join-Path $BaiJamjureeDirectory $Asset.Name)
        }

        $FiraCodeFiles = Get-ChildItem $FiraCodeDirectory -Recurse -File |`
            Where-Object { $_.Name -like 'FiraCodeNerdFont*.ttf' }
        $BaiJamjureeFiles = Get-ChildItem $BaiJamjureeDirectory -Recurse -File |`
            Where-Object { $_.Extension -in @('.ttf', '.otf') }

        if (-not $FiraCodeFiles) {
            throw 'FiraCode Nerd Font files were not found in the downloaded archive.'
        }
        if (-not $BaiJamjureeFiles) {
            throw 'Bai Jamjuree font files were not found in the downloaded archive.'
        }

        Install-FontFiles (@($FiraCodeFiles) + @($BaiJamjureeFiles))

        $FontSubstitutesPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes'
        New-Item -Path $FontSubstitutesPath -Force | Out-Null
        New-ItemProperty `
            -Path $FontSubstitutesPath `
            -Name 'Segoe UI' `
            -Value 'FiraCode Nerd Font' `
            -PropertyType String `
            -Force | Out-Null

        Write-SetupLog -Msg 'Installed FiraCode NF, FiraCode Mono NF, and Bai Jamjuree system-wide'
        Write-SetupLog -Msg 'Set the Windows UI font substitution to FiraCode Nerd Font; sign out or restart to apply it'

        Set-WindowsTerminalFont
    }

    Invoke-Step -Name 'packages' -ScriptBlock {
        $PackageList = Join-Path $Env:TEMP 'WindowsSetup-winget-packages.txt'
        $StrictlyNecessaryPackages = @(
            'LGUG2Z.komorebi',
            'LGUG2Z.whkd',
            'AutoHotkey.AutoHotkey',
            'Microsoft.PowerToys',
            'Microsoft.PowerShell',
            'msys2.msys2'
        )

        Get-RawRepositoryFile -RelativePath 'Windows/winget-packages.txt' -Out $PackageList

        $AllRecommendedPackages = Get-Content $PackageList |`
            ForEach-Object { $_.Trim() } |`
            Where-Object { $_ -and -not $_.StartsWith('#') }

        $PackagesToInstall = if ($InstallAllRecommendedPackages) {
            $AllRecommendedPackages
        } else {
            $StrictlyNecessaryPackages
        }

        foreach ($PackageId in $PackagesToInstall) {
            Install-SetupPackage -Id $PackageId
        }
    }

    Invoke-Step -Name 'msys2-setup' -ScriptBlock {
        $Msys2SetupScript = Join-Path $PSScriptRoot 'msys2_setup.ps1'
        
        if (-not (Test-Path $Msys2SetupScript -PathType Leaf)) {
            Write-SetupLog -Msg "MSYS2 setup script not found at $Msys2SetupScript, skipping developer environment configuration" -Type 'WARN'
            return
        }
        
        Write-SetupLog -Msg 'Invoking MSYS2 setup script...'
        
        $Msys2Arguments = @()
        if ($WhatIf) {
            $Msys2Arguments += '-WhatIf'
        }
        
        & $Msys2SetupScript @Msys2Arguments
        
        if ($LASTEXITCODE -ne 0) {
            Write-SetupLog -Msg "MSYS2 setup script failed with exit code $LASTEXITCODE" -Type 'ERROR'
            throw 'MSYS2 setup failed'
        }
        
        Write-SetupLog -Msg 'MSYS2 setup completed successfully' -Type 'SUCCESS'
    }

    Invoke-Step -Name 'dotfiles-vimrc' -ScriptBlock {
        $VimrcSource = Join-Path $BasePath '.vimrc'
        $VimrcUrl = 'https://raw.githubusercontent.com/almostlight/dotfiles/main/home/headless/rc/.vimrc'
        
        if (Test-Path $VimrcSource) {
            Write-SetupLog -Msg "vimrc already exists at $VimrcSource"
        } else {
            Write-SetupLog -Msg 'Downloading .vimrc from dotfiles...'
            Get-File -Url $VimrcUrl -Out $VimrcSource
            Write-SetupLog -Msg "Downloaded .vimrc to $VimrcSource" -Type 'SUCCESS'
        }
    }

    Write-Phase -Name 'PowerToys configuration'

    Invoke-Step -Name 'powertoys' -ScriptBlock {
        $PowerToysCli = Join-Path $Env:LOCALAPPDATA 'PowerToys\bin\PowerToys.Settings.CLI.exe'
        $PowerToysExe = Join-Path $Env:LOCALAPPDATA 'PowerToys\PowerToys.exe'

        if (-not (Test-Path $PowerToysCli)) {
            Write-SetupLog -Msg "PowerToys CLI not found at $PowerToysCli, skipping PowerToys configuration" -Type 'WARN'
            return
        }

        $PowerToysRunning = @(Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue)
        if ($PowerToysRunning) {
            Write-SetupLog -Msg 'Stopping PowerToys to configure modules...'
            foreach ($Process in $PowerToysRunning) {
                Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            }
            Start-Sleep -Seconds 3
        }

        Write-SetupLog -Msg 'Configuring PowerToys modules...'

        foreach ($Module in @('PowerLauncher', 'AutoHideCursor', 'PowerAccent', 'PowerPreview', 'RegistryPreview')) {
            & $PowerToysCli enable $Module
            if ($LASTEXITCODE -ne 0) {
                throw "PowerToys failed to enable $Module with exit code $LASTEXITCODE"
            }
        }
        foreach ($Module in @('FancyZones', 'Workspaces', 'AltWindowCycle')) {
            & $PowerToysCli disable $Module
            if ($LASTEXITCODE -ne 0) {
                throw "PowerToys failed to disable $Module with exit code $LASTEXITCODE"
            }
        }

        Write-SetupLog -Msg 'Setting PowerLauncher hotkey to Alt+Space...'
        $SettingsConfigured = $False
        $SettingsPath = Join-Path $Env:LOCALAPPDATA 'Microsoft\PowerToys\PowerToys Run\settings.json'
        if (Test-Path $SettingsPath) {
            $CurrentSettings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            if (-not $CurrentSettings.Properties) {
                $CurrentSettings | Add-Member -MemberType NoteProperty -Name Properties -Value ([pscustomobject]@{})
            }
            $CurrentSettings.Properties.open_powerlauncher = @{ win=$False; ctrl=$False; alt=$True; shift=$False; code=32; key='' }
            $CurrentSettings | ConvertTo-Json -Depth 10 | Set-Content $SettingsPath -Encoding utf8
            $SettingsConfigured = $True
        }
        $SettingsPath2 = Join-Path $Env:LOCALAPPDATA 'Microsoft\PowerToys\PowerToys.Run\settings.json'
        if (Test-Path $SettingsPath2) {
            $CurrentSettings = Get-Content $SettingsPath2 -Raw | ConvertFrom-Json
            $CurrentSettings.hotkey = @{ win=$False; ctrl=$False; alt=$True; shift=$False; code=32 }
            $CurrentSettings.enabled = $True
            $CurrentSettings | ConvertTo-Json -Depth 10 | Set-Content $SettingsPath2 -Encoding utf8
            $SettingsConfigured = $True
        }
        if (-not $SettingsConfigured) {
            throw 'PowerLauncher settings file was not found'
        }

        Write-SetupLog -Msg 'Restarting PowerToys...'
        if (-not (Test-Path $PowerToysExe -PathType Leaf)) {
            throw "PowerToys executable was not found: $PowerToysExe"
        }
        Start-Process $PowerToysExe -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 5
        if (-not (Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue)) {
            throw 'PowerToys did not start after configuration'
        }

        Write-SetupLog -Msg 'PowerToys configuration complete'
    }

    Write-Phase -Name 'Optional WSL installation'

    Invoke-Step -Name 'fedora-wsl' -ScriptBlock {
        if ($InstallFedoraWSL) {
            Write-SetupLog -Msg 'Installing Fedora on WSL'

            if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
                Write-SetupLog -Msg 'WSL is not installed. Please install WSL first.' -Type 'WARN'
                return
            }

            $Distros = (wsl --list --quiet 2>$Null) -join '' -replace '\x00', ''
            if ($Distros -match 'Fedora') {
                Write-SetupLog -Msg 'Fedora is already installed on WSL'
                return
            }

            Write-SetupLog -Msg 'Downloading and installing Fedora via WSL...'
            wsl --install -d Fedora
            if ($LASTEXITCODE -ne 0) {
                throw "Fedora WSL installation failed with exit code $LASTEXITCODE"
            }
            Write-SetupLog -Msg 'Fedora installed on WSL successfully'
        } else {
            Write-SetupLog -Msg 'Skipping Fedora WSL installation'
        }
    }

    Write-Phase -Name 'Configuration and startup'

    Invoke-Step -Name 'home-config-and-startup' -ScriptBlock {
        $RepoDir = Join-Path $BasePath '.almostlight-windows-setup'
        
        if (-not (Test-Path $RepoDir)) {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                throw 'Git is required to clone the WindowsSetup repository'
            }
            Write-SetupLog -Msg 'Cloning repository with git'
            & git clone https://github.com/almostlight/WindowsSetup.git $RepoDir --depth 1
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone failed with exit code $LASTEXITCODE"
            }
            Write-SetupLog -Msg "Repository cloned to $RepoDir"
        } else {
            Write-SetupLog -Msg "Repository already exists at $RepoDir"
        }
        
        $RepoHomeDir = Join-Path $RepoDir 'Windows\home'
        
        $ConfigFiles = @{
            'komorebi.json' = 'komorebi.json'
            'komorebi.bar.json' = 'komorebi.bar.json'
            'komorebi.bar.1.json' = 'komorebi.bar.1.json'
            '.config\whkdrc' = '.config\whkdrc'
            'scripts\autohotkey\loop_accept.ahk' = 'scripts\autohotkey\loop_accept.ahk'
            'scripts\autohotkey\master.ahk' = 'scripts\autohotkey\master.ahk'
            'scripts\windows-startup.ps1' = 'scripts\windows-startup.ps1'
        }
        
        foreach ($RelativePath in $ConfigFiles.Keys) {
            $SourceFile = Join-Path $RepoHomeDir $RelativePath
            $Target = Join-Path $BasePath $ConfigFiles[$RelativePath]
            
            New-Item -ItemType Directory -Force -Path (Split-Path $Target) | Out-Null
            
            if ($RelativePath -eq 'scripts\windows-startup.ps1' -and`
                (Test-Path (Join-Path $Env:TEMP 'windows-setup-startup.ps1'))) {
                $TargetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
                if ($TargetItem) {
                    Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
                }
                Copy-Item (Join-Path $Env:TEMP 'windows-setup-startup.ps1') $Target -Force -ErrorAction Stop
            } else {
                Set-SymbolicLink -Source $SourceFile -Target $Target
            }
        }

        Set-DefaultWallpaper -RepositoryPath (Join-Path $RepoDir 'Windows')
        
        $SourceVimrc = Join-Path $BasePath '.vimrc'
        $TargetVimrc = Join-Path $Env:LOCALAPPDATA 'Microsoft VS Code\.vimrc'
        
        if (Test-Path $SourceVimrc) {
            Set-SymbolicLink -Source $SourceVimrc -Target $TargetVimrc
            Write-SetupLog -Msg "Created symlink from $SourceVimrc to $TargetVimrc" -Type 'SUCCESS'
        } else {
            Write-SetupLog -Msg "Source .vimrc not found at $SourceVimrc, skipping symlink" -Type 'WARN'
        }
        
        $StartupScript = Join-Path $BasePath 'scripts\windows-startup.ps1'
        if (-not (Test-Path $StartupScript -PathType Leaf)) {
            throw "Startup script was not deployed: $StartupScript"
        }

        $Shell = New-Object -ComObject WScript.Shell
        $ShellApplication = New-Object -ComObject Shell.Application
        $HomeFolder = $ShellApplication.Namespace($BasePath)
        if (-not $HomeFolder) {
            throw "Could not access the user home folder: $BasePath"
        }
        $HomeFolder.Self.InvokeVerb('pintohome')
        Write-SetupLog -Msg 'Pinned the user home folder to Quick Access'

        $StartupFolder = Join-Path $Env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
        Remove-Item (Join-Path $StartupFolder '01-startup.lnk') -Force -ErrorAction SilentlyContinue

        $StartupTaskName = 'Graphical Environment Startup'
        $PowerShellPath = Join-Path $Env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $TaskAction = New-ScheduledTaskAction `
            -Execute $PowerShellPath `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`""
        $TaskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$Env:USERDOMAIN\$Env:USERNAME"
        $TaskPrincipal = New-ScheduledTaskPrincipal `
            -UserId "$Env:USERDOMAIN\$Env:USERNAME" `
            -LogonType Interactive `
            -RunLevel Highest
        $TaskSettings = New-ScheduledTaskSettingsSet `
            -Priority 0 `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries
        Register-ScheduledTask `
            -TaskName $StartupTaskName `
            -Action $TaskAction `
            -Trigger $TaskTrigger `
            -Principal $TaskPrincipal `
            -Settings $TaskSettings `
            -Force | Out-Null
        Write-SetupLog -Msg 'Configured scheduled startup task'

        $WatchdogTaskName = 'Komorebi Process Watchdog'
        $WatchdogAction = New-ScheduledTaskAction `
            -Execute $PowerShellPath `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`" -BarWatchdog"
        $WatchdogTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$Env:USERDOMAIN\$Env:USERNAME"
        $WatchdogSettings = New-ScheduledTaskSettingsSet `
            -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -StartWhenAvailable `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries
        Register-ScheduledTask `
            -TaskName $WatchdogTaskName `
            -Action $WatchdogAction `
            -Trigger $WatchdogTrigger `
            -Principal $TaskPrincipal `
            -Settings $WatchdogSettings `
            -Force | Out-Null
        Start-ScheduledTask -TaskName $WatchdogTaskName
        Write-SetupLog -Msg 'Configured Komorebi process watchdog task'

        $LocalStartupPath = "$Env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
        $ConfigDir = Join-Path $BasePath '.config'

        $LocalStartupShortcut = $Shell.CreateShortcut((Join-Path $ConfigDir 'startup-local.lnk'))
        $LocalStartupShortcut.TargetPath = $LocalStartupPath
        $LocalStartupShortcut.Save()

        $GlobalStartupShortcut = $Shell.CreateShortcut((Join-Path $ConfigDir 'startup-global.lnk'))
        $GlobalStartupPath = Join-Path $Env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
        $GlobalStartupShortcut.TargetPath = $GlobalStartupPath
        $GlobalStartupShortcut.Save()

        Write-SetupLog -Msg 'Created shortcuts to local and global startup folders in .config'
    }

    Write-Phase -Name 'System and desktop settings'

    Invoke-Step -Name 'rdp' -ScriptBlock {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name 'fDenyTSConnections' -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    }

    Invoke-Step -Name 'ui-and-komorebi-hotkeys' -ScriptBlock {
        $P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (-not (Test-Path $P)) {
            New-Item $P | Out-Null
        }
        Set-ItemProperty -Path $P -Name 'AppsUseLightTheme' -Value 0
        Set-ItemProperty -Path $P -Name 'SystemUsesLightTheme' -Value 0
        Set-ItemProperty -Path $P -Name 'EnableTransparency' -Value 0 -Type DWord

        $P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        if (-not (Test-Path $P)) {
            New-Item $P | Out-Null
        }
        @{
            TaskbarAl = 0
            TaskbarSi = 0
            SearchboxTaskbarMode = 0
            TaskbarSearchMode = 0
            ShowTaskViewButton = 0
            TaskbarDa = 0
            TaskbarMn = 0
            ShowCopilotButton = 0
        }.GetEnumerator() | ForEach-Object {
            Set-ItemProperty -Path $P -Name $_.Key -Value $_.Value -Type DWord
        }
        $TaskbarDeveloperSettingsPath = Join-Path $P 'TaskbarDeveloperSettings'
        New-Item -Path $TaskbarDeveloperSettingsPath -Force | Out-Null
        Set-ItemProperty -Path $TaskbarDeveloperSettingsPath -Name 'TaskbarEndTask' -Value 1 -Type DWord

        $LegacyContextMenuPath = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        New-Item -Path $LegacyContextMenuPath -Force | Out-Null
        New-ItemProperty `
            -Path $LegacyContextMenuPath `
            -Name '(default)' `
            -Value '' `
            -PropertyType String `
            -Force | Out-Null

        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WindowArrangementActive' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'EnableSnapAssist' -Value 0 -Type DWord
        $AccentPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
        if (-not (Test-Path $AccentPath)) {
            New-Item $AccentPath | Out-Null
        }
        Set-ItemProperty -Path $AccentPath -Name 'AccentColorMenu' -Value 0xFF24AEDF -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -Value 0 -Type DWord
        $InputMethodPath = 'HKCU:\Control Panel\Input Method'
        if (-not (Test-Path $InputMethodPath)) {
            New-Item $InputMethodPath | Out-Null
        }
        Set-ItemProperty -Path $InputMethodPath -Name 'ShowStatus' -Value 2 -Type DWord
        Write-SetupLog -Msg 'Configured taskbar settings, hid optional taskbar controls and input indicator, enabled End Task, and restored the legacy context menu'
    }

    Invoke-Step -Name 'unpin-taskbar' -ScriptBlock {
        $TaskbandPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        $Taskband = Get-ItemProperty -Path $TaskbandPath -ErrorAction SilentlyContinue
        $HadPins = $Null -ne $Taskband
        if ($HadPins) {
            $PropertyNames = $Taskband.PSObject.Properties.Name
            $HadPins = ($PropertyNames -contains 'Favorites') -or`
                ($PropertyNames -contains 'FavoritesResolve')
        }

        Remove-ItemProperty -Path $TaskbandPath -Name @('Favorites', 'FavoritesResolve') -ErrorAction SilentlyContinue
        Restart-ExplorerShell

        if ($HadPins) {
            Write-SetupLog -Msg 'Removed all pinned taskbar items and restarted Explorer'
        } else {
            Write-SetupLog -Msg 'No pinned taskbar items found; restarted Explorer to apply taskbar settings'
        }
    }

    Invoke-Step -Name 'keyboard' -ScriptBlock {
        $Lang = New-WinUserLanguageList pl-PL
        $Lang[0].InputMethodTips.Clear()
        $Lang[0].InputMethodTips.Add('0415:00000415')
        Set-WinUserLanguageList $Lang -Force
        Write-SetupLog -Msg 'Polish language and keyboard layout configured successfully'
    }

    Invoke-Step -Name 'debloat' -ScriptBlock {
        $Apps = @(
            'Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay',
            'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.GamingApp', 'Microsoft.ZuneMusic',
            'Microsoft.ZuneVideo', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp',
            'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.People',
            'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub',
            'MicrosoftTeams', 'Microsoft.SkypeApp'
        )

        foreach ($A in $Apps) {
            Get-AppxPackage -Name $A -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
        }

        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell' -Name 'OneDrive' -ErrorAction SilentlyContinue
    }

    Invoke-Step -Name 'scheduled-task-debloat' -ScriptBlock {
        $TasksToDisable = @(
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' }
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' }
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' }
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask' }
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' }
            @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' }
            @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' }
        )

        foreach ($TaskDefinition in $TasksToDisable) {
            $Task = Get-ScheduledTask `
                -TaskPath $TaskDefinition.Path `
                -TaskName $TaskDefinition.Name `
                -ErrorAction SilentlyContinue
            if (-not $Task) {
                Write-SetupLog -Msg "Scheduled task not present, skipping: $($TaskDefinition.Path)$($TaskDefinition.Name)"
                continue
            }

            if ($Task.State -eq 'Disabled') {
                Write-SetupLog -Msg "Scheduled task already disabled: $($TaskDefinition.Path)$($TaskDefinition.Name)"
                continue
            }

            Disable-ScheduledTask `
                -TaskPath $TaskDefinition.Path `
                -TaskName $TaskDefinition.Name `
                -ErrorAction Stop | Out-Null
            Write-SetupLog -Msg "Disabled scheduled task: $($TaskDefinition.Path)$($TaskDefinition.Name)"
        }
    }

    Invoke-Step -Name 'startup-and-restart-explorer' -ScriptBlock {
        & (Join-Path $BasePath 'scripts\windows-startup.ps1')
        Restart-ExplorerShell
        Write-SetupLog -Msg 'Restarted Explorer shell without opening an Explorer window'
    }

    Invoke-FinalVerification

    Write-SetupLog -Msg 'Provisioning complete'
} catch {
    $Global:HadErrors = $True
    Write-SetupLog -Msg "ERROR: $_" -Type 'ERROR'
}

if (Test-Path $WorkPath) {
    Remove-Item $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $WhatIf) {
    Write-Host "Setup log: $LogPath"
    exit $(if ($HadErrors) { 1 } else { 0 })
}
