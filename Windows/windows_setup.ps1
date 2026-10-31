<# 
Yes, it is (mostly) vibe-coded. I'm not learning Powershell.
#>

param(
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"
$ScriptUrl = "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/Windows/windows_setup.ps1"
$PromptTimeoutSeconds = 5
$HadErrors = $false

if (-not ("WindowsSetup.ConsoleNative" -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class ConsoleNative {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleMode(IntPtr handle, out uint mode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleMode(IntPtr handle, uint mode);
    }
}
'@
}

# --- Self-elevation ---
if (-not $WhatIf -and -not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $elevatedScript = Join-Path $env:TEMP "windows-setup-$PID.ps1"
    $localStartupScript = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "home\scripts\windows-startup.ps1"
    }
    $elevatedStartupScript = Join-Path $env:TEMP "windows-setup-startup.ps1"
    if ($PSCommandPath -and (Test-Path $PSCommandPath -PathType Leaf)) {
        Copy-Item $PSCommandPath $elevatedScript -Force
        if (Test-Path $localStartupScript -PathType Leaf) {
            Copy-Item $localStartupScript $elevatedStartupScript -Force
        }
    } else {
        Invoke-WebRequest $ScriptUrl -OutFile $elevatedScript -UseBasicParsing
    }

    $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $shell) {
        $shell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedScript`""
    if (-not $shell) {
        throw "Could not find PowerShell to run the elevated setup."
    }

    try {
        $process = Start-Process $shell -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        throw "Could not start the elevated setup. Approve the UAC prompt and try again. $($_.Exception.Message)"
    }
    Remove-Item $elevatedScript -Force -ErrorAction SilentlyContinue
    Remove-Item $elevatedStartupScript -Force -ErrorAction SilentlyContinue
    exit $process.ExitCode
}

# --- Clear cache ---
if (-not $WhatIf) {
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
}

# =========================
# MAIN SCRIPT EXECUTION
# Wrapped in try-catch to handle errors gracefully
# =========================
try {
    # --- Core paths ---
    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $BasePath = [Environment]::GetFolderPath("UserProfile")
    $Downloads = Join-Path $BasePath "Downloads"
    $ScriptsPath = Join-Path $BasePath "scripts"
    $LogPath = Join-Path $ScriptsPath "setup.log"

    New-Item -ItemType Directory -Force -Path $Downloads, $ScriptsPath | Out-Null
    Set-Content $LogPath "Provisioning started: $date"

    # --- Logging ---
    function Write-SetupLog {
    param($Msg, $Type = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Output $line
    Add-Content $LogPath $line
}

Write-SetupLog "Starting provisioning"

function Read-TimedChoice {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [Parameter(Mandatory)]
        [string]$Default
    )

    if ([Console]::IsInputRedirected) {
        return $Default
    }

    $inputHandle = [WindowsSetup.ConsoleNative]::GetStdHandle(-10)
    [uint32]$originalMode = 0
    $restoreConsoleMode = $inputHandle -ne [IntPtr]::Zero -and
        [WindowsSetup.ConsoleNative]::GetConsoleMode($inputHandle, [ref]$originalMode)
    if ($restoreConsoleMode) {
        $noQuickEditMode = [uint32](($originalMode -bor 0x0080) -band 0xFFFFFFBF)
        if (-not [WindowsSetup.ConsoleNative]::SetConsoleMode($inputHandle, $noQuickEditMode)) {
            $restoreConsoleMode = $false
        }
    }

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($PromptTimeoutSeconds)
        $lastShown = -1

        while ($true) {
            $remaining = [Math]::Max(0, [Math]::Ceiling(
                ($deadline - [DateTime]::UtcNow).TotalSeconds
            ))
            if ($remaining -ne $lastShown) {
                [Console]::Write("`r$Prompt [$remaining] ")
                $lastShown = $remaining
            }

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) {
                    [Console]::WriteLine("`r$Prompt [$remaining] $Default")
                    return $Default
                }
                if (-not [char]::IsControl($key.KeyChar)) {
                    [Console]::WriteLine("`r$Prompt [$remaining] $($key.KeyChar)")
                    return [string]$key.KeyChar
                }
            }

            if ([DateTime]::UtcNow -ge $deadline) {
                [Console]::WriteLine("`r$Prompt [0] $Default")
                return $Default
            }

            Start-Sleep -Milliseconds 100
        }
    } finally {
        if ($restoreConsoleMode) {
            [WindowsSetup.ConsoleNative]::SetConsoleMode($inputHandle, $originalMode) | Out-Null
        }
    }
}

function Invoke-Step($Name, $ScriptBlock) {
    Write-SetupLog "RUN: $Name"

    if ($WhatIf) { return }

    try {
        & $ScriptBlock
    } catch {
        Write-SetupLog "FAILED: $Name - $_" "ERROR"
        $global:HadErrors = $true
    }
}

# =========================
# ASK ALL QUESTIONS UPFRONT
# =========================
Write-SetupLog "Collecting user preferences..."

$installAllRecommendedPackages = $false
$response = Read-TimedChoice `
    "Install all recommended packages? [y/N] (Choosing 'N' installs only strictly necessary packages)" `
    "n"
if ($response -eq "y") {
    $installAllRecommendedPackages = $true
} elseif ($response -and $response -ne "n") {
    Write-SetupLog "Unrecognized package installation choice: '$response'. Defaulting to strictly necessary packages" "WARN"
}

$installFedoraWSL = $false
$response = Read-TimedChoice "Install the latest Fedora on WSL? [y/N]" "n"
if ($response -eq "y") {
    $installFedoraWSL = $true
}

Write-SetupLog "User preferences collected. Starting provisioning..."

# --- Download helper ---
function Get-File($Url, $Out) {
    if (Test-Path $Out) { return }

    for ($i=0; $i -lt 3; $i++) {
        try {
            Invoke-WebRequest $Url -OutFile $Out -TimeoutSec 60 -UseBasicParsing
            return
        } catch {
            Start-Sleep 2
        }
    }

    throw "Download failed: $Url"
}

function Get-RawRepositoryFile($RelativePath, $Out) {
    Get-File `
        "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/$RelativePath" `
        $Out
}

function Install-FontFiles($FontFiles) {
    $fontsPath = Join-Path $env:WINDIR "Fonts"
    $fontRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

    foreach ($fontFile in $FontFiles) {
        $target = Join-Path $fontsPath $fontFile.Name
        if (-not (Test-Path $target -PathType Leaf)) {
            Copy-Item $fontFile.FullName $target
        }

        $fontType = switch ([IO.Path]::GetExtension($fontFile.Name).ToLowerInvariant()) {
            ".otf" { "OpenType" }
            default { "TrueType" }
        }
        $fontDisplayName = "$([IO.Path]::GetFileNameWithoutExtension($fontFile.Name)) ($fontType)"
        New-ItemProperty `
            -Path $fontRegistryPath `
            -Name $fontDisplayName `
            -Value $fontFile.Name `
            -PropertyType String `
            -Force | Out-Null
    }
}

function Set-WindowsTerminalFont {
    $settingsPaths = @(
        (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json")
    ) | Where-Object { Test-Path $_ -PathType Leaf }

    if (-not $settingsPaths) {
        Write-SetupLog "Windows Terminal settings were not found; skipping terminal font configuration" "WARN"
        return
    }

    foreach ($settingsPath in $settingsPaths) {
        $settings = Get-Content $settingsPath -Raw
        $defaultsPattern = '(?s)("profiles"\s*:\s*\{\s*"defaults"\s*:\s*\{)(.*?)(\}\s*,\s*"list"\s*:)'
        $defaultsMatch = [regex]::Match($settings, $defaultsPattern)
        if (-not $defaultsMatch.Success) {
            throw "Could not locate Windows Terminal profiles.defaults in $settingsPath"
        }

        $defaults = $defaultsMatch.Groups[2].Value
        $fontPattern = '(?s)"font"\s*:\s*\{.*?\}'
        if ([regex]::IsMatch($defaults, $fontPattern)) {
            $defaults = [regex]::Replace(
                $defaults,
                $fontPattern,
                '"font": { "face": "FiraCode Nerd Font Mono" }',
                1
            )
        } else {
            $defaults = "`n            `"font`": { `"face`": `"FiraCode Nerd Font Mono`" }," + $defaults
        }

        $settings = $settings.Substring(0, $defaultsMatch.Groups[2].Index) +
            $defaults +
            $settings.Substring($defaultsMatch.Groups[2].Index + $defaultsMatch.Groups[2].Length)
        Set-Content $settingsPath $settings -Encoding utf8
        Write-SetupLog "Set Windows Terminal default font to FiraCode Nerd Font Mono in $settingsPath"
    }
}

# =========================
# CORE SYSTEM SETUP BLOCKS
# =========================

Invoke-Step "winget" {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $pkg = Join-Path $Downloads "winget.msixbundle"
        Get-File "https://aka.ms/getwinget" $pkg
        Add-AppxPackage $pkg
        Start-Sleep 5
    }
}

Invoke-Step "fonts" {
    $fontArchive = Join-Path $Downloads "WindowsSetup-fonts"
    $firaCodeArchive = Join-Path $Downloads "FiraCode.zip"

    Get-File `
        "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip" `
        $firaCodeArchive

    if (Test-Path $fontArchive) {
        Remove-Item $fontArchive -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $fontArchive | Out-Null

    $firaCodeDirectory = Join-Path $fontArchive "FiraCode"
    $baiJamjureeDirectory = Join-Path $fontArchive "BaiJamjuree"
    Expand-Archive $firaCodeArchive $firaCodeDirectory -Force

    New-Item -ItemType Directory -Force -Path $baiJamjureeDirectory | Out-Null
    $baiJamjureeAssets = Invoke-RestMethod `
        "https://api.github.com/repos/google/fonts/contents/ofl/baijamjuree" `
        -Headers @{ "User-Agent" = "WindowsSetup" } |
        Where-Object { $_.name -match "\.(ttf|otf)$" }
    foreach ($asset in $baiJamjureeAssets) {
        Get-File `
            "https://raw.githubusercontent.com/google/fonts/main/ofl/baijamjuree/$($asset.name)" `
            (Join-Path $baiJamjureeDirectory $asset.name)
    }

    $firaCodeFiles = Get-ChildItem $firaCodeDirectory -Recurse -File |
        Where-Object { $_.Name -like "FiraCodeNerdFont*.ttf" }
    $baiJamjureeFiles = Get-ChildItem $baiJamjureeDirectory -Recurse -File |
        Where-Object { $_.Extension -in @(".ttf", ".otf") }

    if (-not $firaCodeFiles) {
        throw "FiraCode Nerd Font files were not found in the downloaded archive."
    }
    if (-not $baiJamjureeFiles) {
        throw "Bai Jamjuree font files were not found in the downloaded archive."
    }

    Install-FontFiles (@($firaCodeFiles) + @($baiJamjureeFiles))

    $fontSubstitutesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"
    New-Item -Path $fontSubstitutesPath -Force | Out-Null
    New-ItemProperty `
        -Path $fontSubstitutesPath `
        -Name "Segoe UI" `
        -Value "FiraCode Nerd Font" `
        -PropertyType String `
        -Force | Out-Null

    Write-SetupLog "Installed FiraCode NF, FiraCode Mono NF, and Bai Jamjuree system-wide"
    Write-SetupLog "Set the Windows UI font substitution to FiraCode Nerd Font; sign out or restart to apply it"

    Set-WindowsTerminalFont
}

function Install-SetupPackage($id) {
    $installed = $null | & winget list --exact --id $id `
        --accept-source-agreements --disable-interactivity 2>&1 |
        Out-String
    if ($installed -match "(?im)\b$([regex]::Escape($id))\b") {
        Write-SetupLog "Skipping already installed package $id"
        return
    }

    Write-SetupLog "Installing $id"
    $null | & winget install -e --id $id --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "Winget failed for $id with exit code $LASTEXITCODE"
    }
}

Invoke-Step "packages" {
    $packageList = Join-Path $env:TEMP "WindowsSetup-winget-packages.txt"
    $strictlyNecessaryPackages = @("LGUG2Z.komorebi", "LGUG2Z.whkd", "AutoHotkey.AutoHotkey", "Microsoft.PowerToys")

    Get-RawRepositoryFile "Windows/winget-packages.txt" $packageList

    $allRecommendedPackages = Get-Content $packageList |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") }

    $packagesToInstall = if ($installAllRecommendedPackages) {
        $allRecommendedPackages
    } else {
        $strictlyNecessaryPackages
    }

    foreach ($packageId in $packagesToInstall) {
        Install-SetupPackage $packageId
    }
}

Invoke-Step "powertoys" {
    $powerToysCli = Join-Path $env:LOCALAPPDATA "PowerToys\bin\PowerToys.Settings.CLI.exe"
    $powerToysExe = Join-Path $env:LOCALAPPDATA "PowerToys\PowerToys.exe"

    if (-not (Test-Path $powerToysCli)) {
        Write-SetupLog "PowerToys CLI not found at $powerToysCli, skipping PowerToys configuration" "WARN"
        return
    }

    $powerToysRunning = Get-Process -Name "PowerToys" -ErrorAction SilentlyContinue
    if ($powerToysRunning) {
        Write-SetupLog "Stopping PowerToys to configure modules..."
        Stop-Process -Name "PowerToys" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    Write-SetupLog "Configuring PowerToys modules..."

    & $powerToysCli enable PowerLauncher
    & $powerToysCli enable AutoHideCursor
    & $powerToysCli enable PowerAccent
    & $powerToysCli enable PowerPreview
    & $powerToysCli enable RegistryPreview

    & $powerToysCli disable FancyZones
    & $powerToysCli disable Workspaces
    & $powerToysCli disable AltWindowCycle

    Write-SetupLog "Setting PowerLauncher hotkey to Alt+Space..."
    $powerLauncherSettings = @{
        properties = @{
            open_powerlauncher = @{ win=$false; ctrl=$false; alt=$true; shift=$false; code=32; key="" }
        }
    }
    $settingsPath = Join-Path $env:LOCALAPPDATA "Microsoft\PowerToys\PowerToys Run\settings.json"
    if (Test-Path $settingsPath) {
        $currentSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $currentSettings.properties.open_powerlauncher = @{ win=$false; ctrl=$false; alt=$true; shift=$false; code=32; key="" }
        $currentSettings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
    }
    $settingsPath2 = Join-Path $env:LOCALAPPDATA "Microsoft\PowerToys\PowerToys.Run\settings.json"
    if (Test-Path $settingsPath2) {
        $currentSettings = Get-Content $settingsPath2 -Raw | ConvertFrom-Json
        $currentSettings.hotkey = @{ win=$false; ctrl=$false; alt=$true; shift=$false; code=32 }
        $currentSettings.enabled = $true
        $currentSettings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath2 -Encoding utf8
    }

    Write-SetupLog "Restarting PowerToys..."
    Start-Process $powerToysExe -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    Write-SetupLog "PowerToys configuration complete"
}

Invoke-Step "fedora-wsl" {
    if ($installFedoraWSL) {
        Write-SetupLog "Installing Fedora on WSL"

        if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
            Write-SetupLog "WSL is not installed. Please install WSL first." "WARN"
            return
        }

        $distros = (wsl --list --quiet 2>$null) -join '' -replace '\x00', ''
        if ($distros -match "Fedora") {
            Write-SetupLog "Fedora is already installed on WSL"
            return
        }

        Write-SetupLog "Downloading and installing Fedora via WSL..."
        wsl --install -d Fedora
        if ($LASTEXITCODE -ne 0) {
            throw "Fedora WSL installation failed with exit code $LASTEXITCODE"
        }
        Write-SetupLog "Fedora installed on WSL successfully"
    } else {
        Write-SetupLog "Skipping Fedora WSL installation"
    }
}

Invoke-Step "home-config-and-startup" {
    $repoDir = Join-Path $BasePath ".almostlight-windows-setup"
    
    if (-not (Test-Path $repoDir)) {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            Write-SetupLog "Cloning repository with git"
            & git clone https://github.com/almostlight/WindowsSetup.git $repoDir --depth 1
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone failed with exit code $LASTEXITCODE"
            }
        } else {
            Write-SetupLog "Git not found, falling back to ZIP download"
            $repoZip = Join-Path $env:TEMP "WindowsSetup-repo.zip"
            $repoUrl = "https://github.com/almostlight/WindowsSetup/archive/refs/heads/main.zip"
            $tempExtractDir = Join-Path $env:TEMP "WindowsSetup-extract"
            
            Get-File $repoUrl $repoZip
            if (Test-Path $tempExtractDir) {
                Remove-Item $tempExtractDir -Recurse -Force
            }
            New-Item -ItemType Directory -Force -Path $tempExtractDir | Out-Null
            Expand-Archive $repoZip $tempExtractDir -Force
            
            $extractedDir = Get-ChildItem -Path $tempExtractDir -Directory | Select-Object -First 1
            if (-not $extractedDir) {
                throw "No directory found after extracting repository ZIP"
            }
            Copy-Item $extractedDir.FullName $repoDir -Recurse -Force
            Remove-Item $tempExtractDir -Recurse -Force
            
            Write-SetupLog "Initializing Git repository"
            Push-Location $repoDir
            & git init
            & git remote add origin https://github.com/almostlight/WindowsSetup.git
            & git fetch --depth 1 origin main
            & git checkout main
            Pop-Location
            if ($LASTEXITCODE -ne 0) {
                throw "Git initialization failed with exit code $LASTEXITCODE"
            }
        }
        Write-SetupLog "Repository cloned to $repoDir"
    } else {
        Write-SetupLog "Repository already exists at $repoDir"
    }
    
    $repoHomeDir = Join-Path $repoDir "Windows\home"
    
    $configFiles = @{
        ".config\whkdrc" = ".config\whkdrc"
        "scripts\autohotkey\loop_accept.ahk" = "scripts\autohotkey\loop_accept.ahk"
        "scripts\autohotkey\master.ahk" = "scripts\autohotkey\master.ahk"
        "scripts\windows-startup.ps1" = "scripts\windows-startup.ps1"
    }
    
    $symlinkFiles = @("komorebi.bar.json", "komorebi.json")
    
    foreach ($relativePath in $configFiles.Keys) {
        $sourceFile = Join-Path $repoHomeDir $relativePath
        $target = Join-Path $BasePath $configFiles[$relativePath]
        
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        
        if ($relativePath -eq "scripts\windows-startup.ps1" -and
            (Test-Path (Join-Path $env:TEMP "windows-setup-startup.ps1"))) {
            Copy-Item (Join-Path $env:TEMP "windows-setup-startup.ps1") $target -Force -ErrorAction SilentlyContinue
        } else {
            Copy-Item $sourceFile $target -Force -ErrorAction SilentlyContinue
        }
        
        if ($relativePath -eq ".config\whkdrc") {
            $content = Get-Content $target -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $content -replace "(?im)^super\b", "win" |
                    Set-Content $target -Encoding utf8 -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    foreach ($file in $symlinkFiles) {
        $sourceFile = Join-Path $repoHomeDir $file
        $targetPath = Join-Path $BasePath $file
        
        if ($file -eq "komorebi.json" -and (Test-Path $sourceFile)) {
            (Get-Content $sourceFile -Raw) -replace '(?m)^\s*"app_specific_configuration_path":[^\r\n]*\r?\n', "" |
                Set-Content $sourceFile -Encoding utf8 -ErrorAction SilentlyContinue
        }
        
        New-Item -ItemType Directory -Force -Path (Split-Path $targetPath) | Out-Null
        
        if (-not $WhatIf) {
            if (Test-Path $targetPath) {
                $item = Get-Item $targetPath -ErrorAction SilentlyContinue
                if ($item -and $item.Attributes -match "ReparsePoint") {
                    $existingTarget = $item.Target
                    if ($existingTarget -eq $sourceFile) {
                        Write-SetupLog "Symlink already exists and is correct: $targetPath -> $sourceFile"
                        continue
                    }
                }
                Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
            }
            
            if (Test-Path $sourceFile) {
                New-Item -ItemType SymbolicLink -Path $targetPath -Target $sourceFile -Force -ErrorAction SilentlyContinue
                Write-SetupLog "Created symlink: $targetPath -> $sourceFile"
            } else {
                Write-SetupLog "Source file not found, skipping symlink: $sourceFile" "WARN"
            }
        }
    }

    $startupScript = Join-Path $BasePath "scripts\windows-startup.ps1"
    if (-not (Test-Path $startupScript -PathType Leaf)) {
        throw "Startup script was not deployed: $startupScript"
    }

    $shell = New-Object -ComObject WScript.Shell
    $shellApplication = New-Object -ComObject Shell.Application
    $homeFolder = $shellApplication.Namespace($BasePath)
    if (-not $homeFolder) {
        throw "Could not access the user's home folder: $BasePath"
    }
    $homeFolder.Self.InvokeVerb("pintohome")
    Write-SetupLog "Pinned the user's home folder to Quick Access"

    $startupFolder = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
    Remove-Item (Join-Path $startupFolder "01-startup.lnk") -Force -ErrorAction SilentlyContinue

    $startupTaskName = "Graphical Environment Startup"
    $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskAction = New-ScheduledTaskAction `
        -Execute $powershellPath `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startupScript`""
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet `
        -Priority 0 `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    Register-ScheduledTask `
        -TaskName $startupTaskName `
        -Action $taskAction `
        -Trigger $taskTrigger `
        -Principal $taskPrincipal `
        -Settings $taskSettings `
        -Force | Out-Null
    Write-SetupLog "Configured scheduled startup task"

    $localStartupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $configDir = Join-Path $BasePath ".config"

    $localStartupShortcut = $shell.CreateShortcut((Join-Path $configDir "startup-local.lnk"))
    $localStartupShortcut.TargetPath = $localStartupPath
    $localStartupShortcut.Save()

    $globalStartupShortcut = $shell.CreateShortcut((Join-Path $configDir "startup-global.lnk"))
    $globalStartupPath = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
    $globalStartupShortcut.TargetPath = $globalStartupPath
    $globalStartupShortcut.Save()

    Write-SetupLog "Created shortcuts to local and global startup folders in .config"
}

Invoke-Step "rdp" {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
}

# =========================
# UI / SYSTEM TWEAKS
# =========================

Invoke-Step "ui-and-komorebi-hotkeys" {
    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not (Test-Path $p)) {
        New-Item $p | Out-Null
    }
    Set-ItemProperty -Path $p -Name "AppsUseLightTheme" -Value 0
    Set-ItemProperty -Path $p -Name "SystemUsesLightTheme" -Value 0

    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (-not (Test-Path $p)) {
        New-Item $p | Out-Null
    }
    Set-ItemProperty -Path $p -Name "TaskbarAl" -Value 0 -Type DWord
    Set-ItemProperty -Path $p -Name "TaskbarSi" -Value 0 -Type DWord

    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WindowArrangementActive" -Value 0 -Type DWord
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "EnableSnapAssist" -Value 0 -Type DWord
    Write-SetupLog "Configured taskbar settings and disabled window snapping (Aero Snap and Snap Assist)"

    $stuckRectsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3"
    $stuckRects = Get-ItemProperty -Path $stuckRectsPath -Name "Settings" -ErrorAction Stop
    $taskbarSettings = [byte[]]$stuckRects.Settings
    if ($taskbarSettings.Length -le 12) {
        throw "Taskbar settings are incomplete: $stuckRectsPath"
    }
    $taskbarSettings[8] = 3
    $taskbarSettings[12] = 0
    Set-ItemProperty -Path $stuckRectsPath -Name "Settings" -Value $taskbarSettings -Type Binary
}

Invoke-Step "unpin-taskbar" {
    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    $taskband = Get-ItemProperty -Path $taskbandPath -ErrorAction SilentlyContinue
    $hadPins = $null -ne $taskband
    if ($hadPins) {
        $propertyNames = $taskband.PSObject.Properties.Name
        $hadPins = ($propertyNames -contains "Favorites") -or
            ($propertyNames -contains "FavoritesResolve")
    }

    Remove-ItemProperty -Path $taskbandPath -Name @("Favorites", "FavoritesResolve") -ErrorAction SilentlyContinue;

    Get-Process -Name "explorer" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force }
    Start-Process "explorer.exe"

    if ($hadPins) {
        Write-SetupLog "Removed all pinned taskbar items and restarted Explorer"
    } else {
        Write-SetupLog "No pinned taskbar items found; restarted Explorer to apply taskbar settings"
    }
}

Invoke-Step "keyboard" {
    try {
        $lang = New-WinUserLanguageList en-US
        $lang[0].InputMethodTips.Clear()
        $lang[0].InputMethodTips.Add("0415:00000415")
        Set-WinUserLanguageList $lang -Force
        Write-SetupLog "Keyboard layout configured successfully"
    } catch {
        Write-SetupLog "Failed to configure keyboard layout: $_" "WARN"
    }
}

# =========================
# DEBLOAT
# =========================

Invoke-Step "debloat" {
    $apps = @(
        "Microsoft.XboxApp","Microsoft.XboxGamingOverlay","Microsoft.XboxGameOverlay",
        "Microsoft.XboxSpeechToTextOverlay","Microsoft.GamingApp","Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo","Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GetHelp",
        "Microsoft.Getstarted","Microsoft.MicrosoftOfficeHub","Microsoft.People",
        "Microsoft.PowerAutomateDesktop","Microsoft.Todos","Microsoft.WindowsFeedbackHub",
        "MicrosoftTeams","Microsoft.SkypeApp","Microsoft.YourPhone"
    )

    foreach ($a in $apps) {
        Get-AppxPackage -Name $a -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
    }

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell" -Name "OneDrive" -ErrorAction SilentlyContinue
}

Invoke-Step "edge-blocker" {
    $edgeUrl = "https://securedl.chip-downloads.de/downloads/41092168/EdgeBlock2.0.zip?cdr=4&cid=88734083&platform=chip&1779964617-1779972117-46994b-B-30a845019b172eaee80a888a40bb5b9f"
    $out = Join-Path $Downloads "EdgeBlocker.zip"
    $dir = Join-Path $Downloads "EdgeBlocker"

    try {
        Write-SetupLog "Downloading Edge Blocker from secured mirror"
        Get-File $edgeUrl $out

        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive $out $dir -Force

        $exe = Get-ChildItem $dir -Recurse -Filter "*EdgeBlock*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($exe) {
            Write-SetupLog "Launching Edge Blocker: $($exe.FullName)"
            Start-Process -FilePath $exe.FullName -WorkingDirectory $dir -Verb RunAs
        } else {
            Write-SetupLog "EdgeBlocker executable not found after extraction, opening download pages" "WARN"
            Start-Process "https://www.sordum.org/9312/edge-blocker-v2-0/"
            Start-Process "https://github.com/Sordum/Edge-Blocker/releases"
        }
    } catch {
        Write-SetupLog "Edge Blocker automated install failed: $_" "WARN"
        Start-Process "https://www.sordum.org/9312/edge-blocker-v2-0/"
        Start-Process "https://github.com/Sordum/Edge-Blocker/releases"
    }
}

# =========================
# CLEANUP
# =========================

Invoke-Step "startup script" {
    $startupScript = Join-Path $BasePath "scripts\windows-startup.ps1"
    if (-not (Test-Path $startupScript -PathType Leaf)) {
        Write-SetupLog "Startup script was not deployed: $startupScript" "ERROR"
        $global:HadErrors = $true
        return
    }
    & $startupScript
}

Invoke-Step "restart-explorer" {
    Get-Process -Name "explorer" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force }
    Start-Process "explorer.exe"
    Write-SetupLog "Restarted Explorer to apply all UI changes"
}

    Write-SetupLog "Provisioning complete"
} catch {
    $global:HadErrors = $true
    Write-SetupLog "ERROR: $_" "ERROR"
}

# Always open the log file and keep window open (unless in WhatIf mode)
if (-not $WhatIf) {
    Start-Sleep -Seconds 2
    notepad $LogPath
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}
