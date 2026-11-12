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
$SetupRunId = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$WorkPath = Join-Path $env:TEMP "WindowsSetup-$PID"

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

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SystemParametersInfo(
            uint action,
            uint parameter,
            string value,
            uint winIni);
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
    $LogPath = Join-Path $ScriptsPath "setup.$SetupRunId.log"

    if ($WhatIf) {
        Write-Host "[WHATIF] Provisioning started: $date"
    } else {
        New-Item -ItemType Directory -Force -Path $Downloads, $ScriptsPath, $WorkPath | Out-Null
        Set-Content $LogPath "Provisioning started: $date"
    }

    # --- Logging ---
    function Write-SetupLog {
        param(
            [Parameter(Mandatory)]
            [string]$Msg,
            [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "WHATIF")]
            [string]$Type = "INFO"
        )
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
        Write-Host $line
        if (-not $WhatIf) {
            Add-Content $LogPath $line
        }
    }

    Write-SetupLog "Starting provisioning"

    function Write-Phase {
        param([Parameter(Mandatory)][string]$Name)
        Write-SetupLog "PHASE: $Name"
    }

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

    if ($WhatIf) {
        Write-SetupLog "WHATIF: Would run $Name" "WHATIF"
        return
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Stop"
        & $ScriptBlock
    } catch {
        Write-SetupLog "FAILED: $Name - $_" "ERROR"
        $global:HadErrors = $true
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Restart-ExplorerShell {
    Get-Process -Name "explorer" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
    Start-Process `
        -FilePath (Join-Path $env:WINDIR "explorer.exe") `
        -ArgumentList "/factory" `
        -WindowStyle Hidden `
        -ErrorAction Stop | Out-Null
}

function Invoke-FinalVerification {
    Write-Phase "Verification"
    if ($WhatIf) {
        Write-SetupLog "WHATIF: Would verify registry, language, startup, and scheduled-task settings" "WHATIF"
        return
    }

    $failedChecks = [System.Collections.Generic.List[string]]::new()
    function Assert-SetupCheck {
        param([string]$Name, [scriptblock]$Test)
        try {
            if (& $Test) {
                Write-SetupLog "PASS: $Name" "SUCCESS"
            } else {
                Write-SetupLog "FAIL: $Name" "ERROR"
                $failedChecks.Add($Name) | Out-Null
            }
        } catch {
            Write-SetupLog "FAIL: $Name - $($_.Exception.Message)" "ERROR"
            $failedChecks.Add($Name) | Out-Null
        }
    }

    Assert-SetupCheck "Input method indicator hidden" {
        (Get-ItemPropertyValue "HKCU:\Control Panel\Input Method" -Name "ShowStatus" -ErrorAction Stop) -eq 2
    }
    Assert-SetupCheck "Taskbar controls hidden" {
        $advanced = Get-ItemProperty `
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
            -ErrorAction Stop
        $advanced.SearchboxTaskbarMode -eq 0 -and
            $advanced.TaskbarSearchMode -eq 0 -and
            $advanced.ShowTaskViewButton -eq 0 -and
            $advanced.TaskbarDa -eq 0 -and
            $advanced.TaskbarMn -eq 0 -and
            $advanced.ShowCopilotButton -eq 0
    }
    Assert-SetupCheck "Polish keyboard layout configured" {
        $polish = Get-WinUserLanguageList |
            Where-Object LanguageTag -eq "pl-PL" |
            Select-Object -First 1
        $null -ne $polish -and $polish.InputMethodTips -contains "0415:00000415"
    }
    Assert-SetupCheck "Startup script deployed" {
        Test-Path (Join-Path $BasePath "scripts\windows-startup.ps1") -PathType Leaf
    }
    Assert-SetupCheck "Graphical startup task registered" {
        $null -ne (Get-ScheduledTask -TaskName "Graphical Environment Startup" -ErrorAction Stop)
    }
    Assert-SetupCheck "Komorebi watchdog task registered" {
        $null -ne (Get-ScheduledTask -TaskName "Komorebi Process Watchdog" -ErrorAction Stop)
    }

    if ($failedChecks.Count -gt 0) {
        $global:HadErrors = $true
        Write-SetupLog "Verification failed for $($failedChecks.Count) check(s)" "ERROR"
    } else {
        Write-SetupLog "Verification passed for all 6 checks" "SUCCESS"
    }
}

function Get-File {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Out,
        [string]$ExpectedSha256
    )

    $downloadPath = Join-Path $WorkPath ([IO.Path]::GetFileName($Out) + ".$PID.download")

    for ($i=0; $i -lt 3; $i++) {
        try {
            Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest $Url -OutFile $downloadPath -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
            $download = Get-Item $downloadPath -ErrorAction Stop
            if ($download.Length -eq 0) {
                throw "Downloaded file was empty: $Url"
            }
            if ($ExpectedSha256) {
                $actualSha256 = (Get-FileHash $downloadPath -Algorithm SHA256).Hash
                if ($actualSha256 -ne $ExpectedSha256.ToUpperInvariant()) {
                    throw "SHA-256 mismatch for $Url. Expected $ExpectedSha256, got $actualSha256"
                }
            }
            Move-Item $downloadPath $Out -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq 2) {
                throw "Download failed after 3 attempts: $Url - $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-RawRepositoryFile($RelativePath, $Out) {
    Get-File `
        "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/$RelativePath" `
        $Out
}

function Get-LatestGitHubAsset {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$AssetName
    )

    $release = Invoke-RestMethod `
        "https://api.github.com/repos/$Repository/releases/latest" `
        -Headers @{ "User-Agent" = "WindowsSetup" } `
        -ErrorAction Stop
    $asset = $release.assets | Where-Object name -eq $AssetName | Select-Object -First 1
    if (-not $asset) {
        throw "GitHub release asset was not found: $Repository/$AssetName"
    }

    [pscustomobject]@{
        Url = $asset.browser_download_url
        Sha256 = if ($asset.digest -match "^sha256:([a-f0-9]{64})$") {
            $Matches[1]
        } else {
            $null
        }
    }
}

function Set-SymbolicLink($Source, $Target) {
    $targetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($targetItem) {
        Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
    }

    New-Item -ItemType SymbolicLink -Path $Target -Target $Source -ErrorAction Stop | Out-Null
}

function Set-DefaultWallpaper($RepositoryPath) {
    $sourceWallpaper = Join-Path $RepositoryPath "home\.config\default.png"
    if (-not (Test-Path $sourceWallpaper -PathType Leaf)) {
        throw "Wallpaper file was not found: $sourceWallpaper"
    }

    $configDir = Join-Path $BasePath ".config"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $targetWallpaper = Join-Path $configDir "default.png"
    Set-SymbolicLink $sourceWallpaper $targetWallpaper
    if (-not [WindowsSetup.ConsoleNative]::SystemParametersInfo(20, 0, $targetWallpaper, 3)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not set wallpaper. Windows error code: $errorCode"
    }

    Write-SetupLog "Set desktop wallpaper to $targetWallpaper"

    $sourceLockScreen = Join-Path $RepositoryPath "home\.config\default_lock.png"
    if (-not (Test-Path $sourceLockScreen -PathType Leaf)) {
        throw "Lock screen image was not found: $sourceLockScreen"
    }

    $targetLockScreen = Join-Path $configDir "default_lock.png"
    Set-SymbolicLink $sourceLockScreen $targetLockScreen

    $personalizationPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
    New-Item -Path $personalizationPath -Force | Out-Null
    New-ItemProperty `
        -Path $personalizationPath `
        -Name "LockScreenImagePath" `
        -Value $targetLockScreen `
        -PropertyType String `
        -Force | Out-Null
    New-ItemProperty `
        -Path $personalizationPath `
        -Name "LockScreenImageUrl" `
        -Value $targetLockScreen `
        -PropertyType String `
        -Force | Out-Null
    New-ItemProperty `
        -Path $personalizationPath `
        -Name "LockScreenImageStatus" `
        -Value 1 `
        -PropertyType DWord `
        -Force | Out-Null

    Write-SetupLog "Set lock screen image to $targetLockScreen"
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

function Invoke-WingetInstallWithKeepAlive($id) {
    $wingetPath = (Get-Command winget -ErrorAction Stop).Source
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $wingetPath
    $startInfo.Arguments = "install -e --id `"$id`" --silent --accept-package-agreements --accept-source-agreements"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start winget for $id"
        }

        while (-not $process.WaitForExit(15000)) {
            $process.StandardInput.WriteLine()
            $process.StandardInput.Flush()
        }

        return $process.ExitCode
    } finally {
        $process.StandardInput.Close()
        $process.Dispose()
    }
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
    $exitCode = Invoke-WingetInstallWithKeepAlive $id
    if ($exitCode -ne 0) {
        throw "Winget failed for $id with exit code $exitCode"
    }
}

# Collect choices before running setup steps.
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

# Run setup steps in explicit phases.

Write-Phase "Package manager and fonts"
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

    $firaCodeAsset = Get-LatestGitHubAsset "ryanoasis/nerd-fonts" "FiraCode.zip"
    Get-File `
        $firaCodeAsset.Url `
        $firaCodeArchive `
        $firaCodeAsset.Sha256

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

Invoke-Step "packages" {
    $packageList = Join-Path $env:TEMP "WindowsSetup-winget-packages.txt"
    $strictlyNecessaryPackages = @(
        "LGUG2Z.komorebi",
        "LGUG2Z.whkd",
        "AutoHotkey.AutoHotkey",
        "Microsoft.PowerToys",
        "Microsoft.PowerShell",
        "msys2.msys2"
    )

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

Invoke-Step "msys2-setup" {
    $msys2Path = "C:\msys64"
    
    if (-not (Test-Path $msys2Path)) {
        Write-SetupLog "MSYS2 not found at $msys2Path, skipping configuration" "WARN"
        return
    }
    
    Write-SetupLog "Configuring MSYS2 development environment..."
    
    $pacmanPath = Join-Path $msys2Path "usr\bin\pacman.exe"
    if (-not (Test-Path $pacmanPath)) {
        Write-SetupLog "pacman not found at $pacmanPath, skipping MSYS2 configuration" "WARN"
        return
    }
    
    Write-SetupLog "Updating package database..."
    $updateArgs = "-Syu --noconfirm --disable-download-timeout"
    $updateProcess = Start-Process -FilePath $pacmanPath -ArgumentList $updateArgs -Wait -PassThru -NoNewWindow
    if ($updateProcess.ExitCode -ne 0) {
        Write-SetupLog "pacman update failed with exit code $($updateProcess.ExitCode)" "WARN"
    }
    
    Write-SetupLog "Installing gcc, g++, gdb, make via pacman..."
    $pacmanArgs = "-S --needed --noconfirm --disable-download-timeout mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb mingw-w64-ucrt-x86_64-make"
    $process = Start-Process -FilePath $pacmanPath -ArgumentList $pacmanArgs -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        Write-SetupLog "pacman installation failed with exit code $($process.ExitCode)" "WARN"
    } else {
        Write-SetupLog "MSYS2 toolchain installed successfully" "SUCCESS"
    }
    
    Write-SetupLog "Verifying gcc, g++, gdb installations..."
    $ucrtBinPath = Join-Path $msys2Path "ucrt64\bin"
    $tools = @("gcc.exe", "g++.exe", "gdb.exe", "make.exe")
    $missingTools = @()
    
    foreach ($tool in $tools) {
        $toolPath = Join-Path $ucrtBinPath $tool
        if (-not (Test-Path $toolPath)) {
            $missingTools += $tool
            Write-SetupLog "MISSING: $toolPath not found" "WARN"
        } else {
            Write-SetupLog "FOUND: $toolPath" "SUCCESS"
        }
    }
    
    if ($missingTools.Count -gt 0) {
        Write-SetupLog "WARNING: Missing tools: $($missingTools -join ', ')" "WARN"
    }
    
    Write-SetupLog "Configuring PATH for MSYS2..."
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $newPaths = @(
        Join-Path $msys2Path "ucrt64\bin",
        Join-Path $msys2Path "mingw64\bin",
        Join-Path $msys2Path "usr\bin"
    )
    
    foreach ($newPath in $newPaths) {
        if ($userPath -notlike "*$newPath*") {
            $userPath = "$newPath;$userPath"
        }
    }
    [Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    
    $env:Path = $userPath
    
    Write-SetupLog "MSYS2 PATH configuration complete"
    Write-SetupLog "Developer environment configured: MSYS2 with Mingw-w64 UCRT toolchain" "SUCCESS"
}

Write-Phase "PowerToys configuration"
Invoke-Step "powertoys" {
    $powerToysCli = Join-Path $env:LOCALAPPDATA "PowerToys\bin\PowerToys.Settings.CLI.exe"
    $powerToysExe = Join-Path $env:LOCALAPPDATA "PowerToys\PowerToys.exe"

    if (-not (Test-Path $powerToysCli)) {
        Write-SetupLog "PowerToys CLI not found at $powerToysCli, skipping PowerToys configuration" "WARN"
        return
    }

    $powerToysRunning = @(Get-Process -Name "PowerToys" -ErrorAction SilentlyContinue)
    if ($powerToysRunning) {
        Write-SetupLog "Stopping PowerToys to configure modules..."
        foreach ($process in $powerToysRunning) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        Start-Sleep -Seconds 3
    }

    Write-SetupLog "Configuring PowerToys modules..."

    foreach ($module in @("PowerLauncher", "AutoHideCursor", "PowerAccent", "PowerPreview", "RegistryPreview")) {
        & $powerToysCli enable $module
        if ($LASTEXITCODE -ne 0) {
            throw "PowerToys failed to enable $module with exit code $LASTEXITCODE"
        }
    }
    foreach ($module in @("FancyZones", "Workspaces", "AltWindowCycle")) {
        & $powerToysCli disable $module
        if ($LASTEXITCODE -ne 0) {
            throw "PowerToys failed to disable $module with exit code $LASTEXITCODE"
        }
    }

    Write-SetupLog "Setting PowerLauncher hotkey to Alt+Space..."
    $settingsConfigured = $false
    $settingsPath = Join-Path $env:LOCALAPPDATA "Microsoft\PowerToys\PowerToys Run\settings.json"
    if (Test-Path $settingsPath) {
        $currentSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if (-not $currentSettings.properties) {
            $currentSettings | Add-Member -MemberType NoteProperty -Name properties -Value ([pscustomobject]@{})
        }
        $currentSettings.properties.open_powerlauncher = @{ win=$false; ctrl=$false; alt=$true; shift=$false; code=32; key="" }
        $currentSettings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
        $settingsConfigured = $true
    }
    $settingsPath2 = Join-Path $env:LOCALAPPDATA "Microsoft\PowerToys\PowerToys.Run\settings.json"
    if (Test-Path $settingsPath2) {
        $currentSettings = Get-Content $settingsPath2 -Raw | ConvertFrom-Json
        $currentSettings.hotkey = @{ win=$false; ctrl=$false; alt=$true; shift=$false; code=32 }
        $currentSettings.enabled = $true
        $currentSettings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath2 -Encoding utf8
        $settingsConfigured = $true
    }
    if (-not $settingsConfigured) {
        throw "PowerLauncher settings file was not found"
    }

    Write-SetupLog "Restarting PowerToys..."
    if (-not (Test-Path $powerToysExe -PathType Leaf)) {
        throw "PowerToys executable was not found: $powerToysExe"
    }
    Start-Process $powerToysExe -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 5
    if (-not (Get-Process -Name "PowerToys" -ErrorAction SilentlyContinue)) {
        throw "PowerToys did not start after configuration"
    }

    Write-SetupLog "PowerToys configuration complete"
}

Write-Phase "Optional WSL installation"
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

Write-Phase "Configuration and startup"
Invoke-Step "home-config-and-startup" {
    $repoDir = Join-Path $BasePath ".almostlight-windows-setup"
    
    if (-not (Test-Path $repoDir)) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "Git is required to clone the WindowsSetup repository"
        }
        Write-SetupLog "Cloning repository with git"
        & git clone https://github.com/almostlight/WindowsSetup.git $repoDir --depth 1
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone failed with exit code $LASTEXITCODE"
        }
        Write-SetupLog "Repository cloned to $repoDir"
    } else {
        Write-SetupLog "Repository already exists at $repoDir"
    }
    
    $repoHomeDir = Join-Path $repoDir "Windows\home"
    
    $configFiles = @{
        "komorebi.json" = "komorebi.json"
        "komorebi.bar.json" = "komorebi.bar.json"
        "komorebi.bar.1.json" = "komorebi.bar.1.json"
        ".config\whkdrc" = ".config\whkdrc"
        "scripts\autohotkey\loop_accept.ahk" = "scripts\autohotkey\loop_accept.ahk"
        "scripts\autohotkey\master.ahk" = "scripts\autohotkey\master.ahk"
        "scripts\windows-startup.ps1" = "scripts\windows-startup.ps1"
    }
    
    foreach ($relativePath in $configFiles.Keys) {
        $sourceFile = Join-Path $repoHomeDir $relativePath
        $target = Join-Path $BasePath $configFiles[$relativePath]
        
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        
        if ($relativePath -eq "scripts\windows-startup.ps1" -and
            (Test-Path (Join-Path $env:TEMP "windows-setup-startup.ps1"))) {
            $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            if ($targetItem) {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            }
            Copy-Item (Join-Path $env:TEMP "windows-setup-startup.ps1") $target -Force -ErrorAction Stop
        } else {
            Set-SymbolicLink $sourceFile $target
        }
    }

    Set-DefaultWallpaper (Join-Path $repoDir "Windows")
    
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

    $watchdogTaskName = "Komorebi Process Watchdog"
    $watchdogAction = New-ScheduledTaskAction `
        -Execute $powershellPath `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startupScript`" -BarWatchdog"
    $watchdogTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $watchdogSettings = New-ScheduledTaskSettingsSet `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    Register-ScheduledTask `
        -TaskName $watchdogTaskName `
        -Action $watchdogAction `
        -Trigger $watchdogTrigger `
        -Principal $taskPrincipal `
        -Settings $watchdogSettings `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $watchdogTaskName
    Write-SetupLog "Configured Komorebi process watchdog task"

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

Write-Phase "System and desktop settings"
Invoke-Step "rdp" {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
}

Invoke-Step "ui-and-komorebi-hotkeys" {
    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not (Test-Path $p)) {
        New-Item $p | Out-Null
    }
    Set-ItemProperty -Path $p -Name "AppsUseLightTheme" -Value 0
    Set-ItemProperty -Path $p -Name "SystemUsesLightTheme" -Value 0
    Set-ItemProperty -Path $p -Name "EnableTransparency" -Value 0 -Type DWord

    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (-not (Test-Path $p)) {
        New-Item $p | Out-Null
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
        Set-ItemProperty -Path $p -Name $_.Key -Value $_.Value -Type DWord
    }
    $taskbarDeveloperSettingsPath = Join-Path $p "TaskbarDeveloperSettings"
    New-Item -Path $taskbarDeveloperSettingsPath -Force | Out-Null
    Set-ItemProperty -Path $taskbarDeveloperSettingsPath -Name "TaskbarEndTask" -Value 1 -Type DWord

    $legacyContextMenuPath = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    New-Item -Path $legacyContextMenuPath -Force | Out-Null
    New-ItemProperty `
        -Path $legacyContextMenuPath `
        -Name "(default)" `
        -Value "" `
        -PropertyType String `
        -Force | Out-Null

    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WindowArrangementActive" -Value 0 -Type DWord
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "EnableSnapAssist" -Value 0 -Type DWord
    $accentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"
    if (-not (Test-Path $accentPath)) {
        New-Item $accentPath | Out-Null
    }
    Set-ItemProperty -Path $accentPath -Name "AccentColorMenu" -Value 0xFF24AEDF -Type DWord
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "ColorPrevalence" -Value 0 -Type DWord
    $inputMethodPath = "HKCU:\Control Panel\Input Method"
    if (-not (Test-Path $inputMethodPath)) {
        New-Item $inputMethodPath | Out-Null
    }
    Set-ItemProperty -Path $inputMethodPath -Name "ShowStatus" -Value 2 -Type DWord
    Write-SetupLog "Configured taskbar settings, hid optional taskbar controls and input indicator, enabled End Task, and restored the legacy context menu"
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

    Restart-ExplorerShell

    if ($hadPins) {
        Write-SetupLog "Removed all pinned taskbar items and restarted Explorer"
    } else {
        Write-SetupLog "No pinned taskbar items found; restarted Explorer to apply taskbar settings"
    }
}

Invoke-Step "keyboard" {
    $lang = New-WinUserLanguageList pl-PL
    $lang[0].InputMethodTips.Clear()
    $lang[0].InputMethodTips.Add("0415:00000415")
    Set-WinUserLanguageList $lang -Force
    Write-SetupLog "Polish language and keyboard layout configured successfully"
}

Invoke-Step "debloat" {
    $apps = @(
        "Microsoft.XboxApp","Microsoft.XboxGamingOverlay","Microsoft.XboxGameOverlay",
        "Microsoft.XboxSpeechToTextOverlay","Microsoft.GamingApp","Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo","Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GetHelp",
        "Microsoft.Getstarted","Microsoft.MicrosoftOfficeHub","Microsoft.People",
        "Microsoft.PowerAutomateDesktop","Microsoft.Todos","Microsoft.WindowsFeedbackHub",
        "MicrosoftTeams","Microsoft.SkypeApp"
    )

    foreach ($a in $apps) {
        Get-AppxPackage -Name $a -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
    }

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell" -Name "OneDrive" -ErrorAction SilentlyContinue
}

Invoke-Step "scheduled-task-debloat" {
    $tasksToDisable = @(
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser" }
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "ProgramDataUpdater" }
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "Consolidator" }
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "KernelCeipTask" }
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "UsbCeip" }
        @{ Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClient" }
        @{ Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClientOnScenarioDownload" }
    )

    foreach ($taskDefinition in $tasksToDisable) {
        $task = Get-ScheduledTask `
            -TaskPath $taskDefinition.Path `
            -TaskName $taskDefinition.Name `
            -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-SetupLog "Scheduled task not present, skipping: $($taskDefinition.Path)$($taskDefinition.Name)"
            continue
        }

        if ($task.State -eq "Disabled") {
            Write-SetupLog "Scheduled task already disabled: $($taskDefinition.Path)$($taskDefinition.Name)"
            continue
        }

        Disable-ScheduledTask `
            -TaskPath $taskDefinition.Path `
            -TaskName $taskDefinition.Name `
            -ErrorAction Stop | Out-Null
        Write-SetupLog "Disabled scheduled task: $($taskDefinition.Path)$($taskDefinition.Name)"
    }
}

Invoke-Step "startup-and-restart-explorer" {
    & (Join-Path $BasePath "scripts\windows-startup.ps1")
    Restart-ExplorerShell
    Write-SetupLog "Restarted Explorer shell without opening an Explorer window"
}

Invoke-FinalVerification

    Write-SetupLog "Provisioning complete"
} catch {
    $global:HadErrors = $true
    Write-SetupLog "ERROR: $_" "ERROR"
}

# Only clean up this run's private working directory.
if (Test-Path $WorkPath) {
    Remove-Item $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
}

# Finish without opening interactive UI.
if (-not $WhatIf) {
    Write-Host "Setup log: $LogPath"
    exit $(if ($HadErrors) { 1 } else { 0 })
}
