# Define the script version as a variable
$ScriptVersion = "1.6.0"

<#
Script Name: JEncoder
Author: Jarsky
Version History:
  - v1.6.0: Added progress bars, suppressed encoder output, added ETA and projected file size
  - v1.5.2: Refactored and standardized some of the code
  - v1.5.1: Small bug fixes. Made the file renaming dynamic based on encoding codec
  - v1.5.0: Added feature for script to automatically update to latest.
  - v1.4.1: Fixed summary report.
  - v1.4.0: Fixed logic in detecting encoder tools versions for comparison.
  - v1.3.5: Fixed Summary of encodes and re-combined the encoder functions.
  - v1.3.0: Added automatically downloading required encoders.
  - v1.2.0: Added handling original files after processing.
  - v1.1.0: Refactored script to include config.ini handling and new menu system.
  - v1.0.0: Initial release with basic HandBrakeCLI and FFmpeg support and NVENC.
  
.FEATURES
- Automates media encoding tasks using HandBrakeCLI (x265) and FFmpeg (libx265, NVENC).
- Supports CPU and NVENC GPU encoding.
- Configurable through a `config.ini` file, allowing users to modify settings interactively.
- Includes audio encoding and subtitle processing.
- Verifies and downloads missing encoders (HandBrakeCLI, FFmpeg, MKVPropEdit).
- Provides detailed feedback and status messages during encoding operations.
- Option to move original files to a "to_be_deleted" folder after processing.
- Shows progress bars with ETA and projected file sizes instead of verbose encoder output.

.FUNCTIONS
- Show-Header: Displays a formatted header in the console.
- Open-Config: Reads the configuration file and loads settings.
- Save-Config: Saves the current settings back to the configuration file.
- Show-Configuration: Displays the current configuration settings in the console.
- Edit-Configuration: Allows users to update configuration settings interactively.
- Confirm-Encoders: Verifies if the required encoding tools (HandBrakeCLI, FFmpeg, MKVPropEdit) are available.
- Get-Encoders: Downloads and installs any missing encoders.
- Write-ColoredHost: Outputs colored text to the console for better visibility.
- Get-EncodingProgress: Parses encoder output to determine progress percentage.
- Get-ProjectedFileSize: Estimates final file size based on codec and quality settings.

.CONFIGURATION OPTIONS
- Encoding quality settings for HandBrakeCLI and FFmpeg.
- Directory paths for output, deletion, and encoders.
- Options for handling spaces in filenames, fixing subtitles, and moving original files post-processing.

.NOTES
- Ensure the required encoders (HandBrakeCLI, FFmpeg, MKVPropEdit) are available in the `encoders` folder or the script will attempt to download them automatically.
- The version number is defined as `$ScriptVersion` at the start of the script for easy management.

#>



### VARIABLES ###

# Config File and Default Config
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configFile = Join-Path -Path $PSScriptRoot -ChildPath "config.ini"
$logFile = Join-Path -Path $PSScriptRoot -ChildPath "jencoder.log"

$defaultConfig = [ordered]@{
    replaceSpaces         = $false
    fixSubtitles          = $false
    outputDir             = "output"
    renameOutputFile      = $true
    toDeleteDir           = "to_be_deleted"
    deleteOriginals       = $false
    handbrakeEncoder      = "x265"
    handbrakePreset       = "default"
    handbrakeEncoderNVENC = "nvenc_h265"
    handbrakeNVENCPreset  = "default"
    handbrakeQuality      = "22"
    ffmpegEncoder         = "libx265"
    ffmpegPreset          = "medium"
    ffmpegEncoderNVENC    = "hevc_nvenc"
    ffmpegNVENCPreset     = "default"
    ffmpegQuality         = "28"
    audioEncoder          = "copy"
    enableLogging         = $true
    verboseLogging        = $false
}

function Show-Header {
    Clear-Host
    $header = @"
      _ ______                     _           
     | |  ____|                   | |          
     | | |__   _ __   ___ ___   __| | ___ _ __ 
 _   | |  __| | '_ \ / __/ _ \ / _  |/ _ \ '__|
| |__| | |____| | | | (_| (_) | (_| |  __/ |   
 \____/|______|_| |_|\___\___/ \__,_|\___|_|   

                        Version: $ScriptVersion
                                               
"@
    Write-ColoredHost $header -ForegroundColor Cyan
}
function Open-Config {
    $configHashtable = [ordered]@{}
    if (Test-Path $configFile) {
        $ini = Get-Content $configFile | Where-Object { $_ -match "=" }
        foreach ($line in $ini) {
            $parts = $line -split '=', 2
            $key = $parts[0].Trim()
            $val = $parts[1].Trim()
            if ($defaultConfig.Keys -contains $key) {
                try {
                    $convertedValue = [Convert]::ChangeType($val, $defaultConfig[$key].GetType())
                    $configHashtable[$key] = $convertedValue
                } catch {
                    Write-Warning "Invalid config value for '$key': '$val'. Using default."
                    $configHashtable[$key] = $defaultConfig[$key]
                }
            }
        }
    } else {
        $configHashtable = $defaultConfig
        Save-Config $configHashtable
    }
    return $configHashtable
}

function Save-Config($configToSave) {
    $configOut = $configToSave.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }
    Set-Content -Path $configFile -Value $configOut
    Write-Host "Config saved to $configFile" -ForegroundColor Green
}

function Show-Configuration {
    Clear-Host
    Show-Header

    Write-ColoredHost "Current Configuration Settings:" -ForegroundColor Yellow
    Write-ColoredHost "-------------------------------" -ForegroundColor Yellow

    if (-not (Test-Path $configFile)) {
        Write-ColoredHost "Configuration file not found at $configFile" -ForegroundColor Red
        return
    }

    $config = Get-Content $configFile
    foreach ($line in $config) {
        if ($line -match '^\s*\[.*\]\s*$') {
            Write-ColoredHost "`n$line" -ForegroundColor Cyan
        } elseif ($line -match '^\s*[^#;].*=.*$') {
            Write-ColoredHost $line -ForegroundColor White
        } else {
            Write-ColoredHost $line -ForegroundColor DarkGray
        }
    }
}


function Edit-Configuration {
    Clear-Host
    Show-Header
    $globalConfig = Open-Config

    foreach ($key in $defaultConfig.Keys) {
        $currentValue = $globalConfig[$key]
        $defaultValue = $defaultConfig[$key]
        $configInput = Read-Host "[$key] Current: '$currentValue' (Default: '$defaultValue') - Enter new value or press Enter to keep"

        if ($configInput -ne "") {
            try {
                $convertedValue = [Convert]::ChangeType($configInput, $defaultValue.GetType())
                $globalConfig[$key] = $convertedValue
            } catch {
                Write-Warning "Invalid input for '$key'. Keeping current value: '$currentValue'"
            }
        }
    }

    Save-Config $globalConfig

    # RELOAD the config and set the session variables
    foreach ($key in $globalConfig.Keys) {
        Set-Variable -Name $key -Value $globalConfig[$key] -Scope Global
    }

    Write-Host "`nConfiguration updated and reloaded." -ForegroundColor Green
}


$globalConfig = Open-Config
foreach ($key in $globalConfig.Keys) {
    Set-Variable -Name $key -Value $globalConfig[$key] -Scope Global
}

# Initialize log file
if ($globalConfig.enableLogging) {
    # Get date for log rotation
    $logDate = Get-Date -Format "yyyy-MM-dd"
    $logFile = Join-Path -Path $PSScriptRoot -ChildPath "jencoder-$logDate.log"
    
    # Create the log file if it doesn't exist
    if (-not (Test-Path $logFile)) {
        New-Item -Path $logFile -ItemType File -Force | Out-Null
        Add-Content -Path $logFile -Value "[$logDate] [INFO] JEncoder v$ScriptVersion logging started"
    }
    
    # Clean up old log files (keep last 7 days)
    $oldLogs = Get-ChildItem -Path $PSScriptRoot -Filter "jencoder-*.log" | 
               Where-Object { $_.Name -match 'jencoder-(\d{4}-\d{2}-\d{2})\.log' -and 
                           [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) -lt (Get-Date).AddDays(-7) }
    
    if ($oldLogs) {
        foreach ($oldLog in $oldLogs) {
            Remove-Item -Path $oldLog.FullName -Force
        }
    }
}

### Paths ###

if (-not $script:scriptDir) {
    $script:scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$script:encoderDir       = Join-Path $script:scriptDir "encoders"
$script:handbrakePath    = Join-Path $script:encoderDir "HandBrakeCLI.exe"
$script:ffmpegPath       = Join-Path $script:encoderDir "ffmpeg.exe"
$script:ffprobePath      = Join-Path $script:encoderDir "ffprobe.exe"
$script:mkvpropeditPath  = Join-Path $script:encoderDir "mkvpropedit.exe"



### MAIN SCRIPT ###

function Write-ColoredHost {
    param (
        [string]$Text,
        [ConsoleColor]$ForegroundColor = 'White',
        [ConsoleColor]$BackgroundColor = 'Black'
    )
    Write-Host $Text -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Confirm-Encoders {
    $missingEncoders = @()
    Write-Log "Checking Encoders:" -Level "INFO"
    Write-Log "------------------" -Level "INFO"
    Write-Log "HandBrakeCLI Path: $handbrakePath" -Level "INFO" -NoConsole
    Write-Log "FFmpeg Path: $ffmpegPath" -Level "INFO" -NoConsole
    Write-Log "FFprobe Path: $ffprobePath" -Level "INFO" -NoConsole
    Write-Log "MKVPropEdit Path: $mkvpropeditPath" -Level "INFO" -NoConsole
    
    if (-not (Test-Path $handbrakePath))      { $missingEncoders += "HandBrakeCLI" }
    if (-not (Test-Path $ffmpegPath))         { $missingEncoders += "FFmpeg" }
    if (-not (Test-Path $ffprobePath))        { $missingEncoders += "FFprobe" }
    if (-not (Test-Path $mkvpropeditPath))    { $missingEncoders += "MKVPropEdit" }

    $script:missingEncoders = $missingEncoders

    if ($missingEncoders.Count -gt 0) {
        Write-Log "Missing encoders:" -Level "WARNING"
        $missingEncoders | ForEach-Object { Write-Log $_ -Level "WARNING" }
        return $false
    } else {
        Write-Log "All encoders detected successfully!" -Level "SUCCESS"
        return $true
    }
}


function Get-Encoders {
    $encoderDir = Join-Path $scriptDir "encoders"
    $tempDir = Join-Path $env:TEMP "EncoderDownloads"
    $sevenZipPath = Join-Path $scriptDir "7z.exe"

    New-Item -ItemType Directory -Force -Path $encoderDir, $tempDir | Out-Null

    if (-not (Confirm-Encoders)) {
        Clear-Host
        Show-Header

        if ($missingEncoders -contains "HandBrakeCLI") {
            try {
                Write-ColoredHost "Downloading HandBrakeCLI..." -ForegroundColor Cyan

                $githubApiUrl = "https://api.github.com/repos/HandBrake/HandBrake/releases/latest"
                $hbRelease = Invoke-RestMethod -Uri $githubApiUrl -Headers @{ "User-Agent" = "PowerShell" }

                $hbAsset = $hbRelease.assets | Where-Object { $_.name -match "HandBrakeCLI.*win.*x86_64\.zip" } | Select-Object -First 1
                if (-not $hbAsset) { throw "Could not find a matching HandBrakeCLI zip asset." }

                $hbZip = Join-Path $tempDir "HandBrakeCLI.zip"
                Invoke-WebRequest -Uri $hbAsset.browser_download_url -OutFile $hbZip

                Expand-Archive -Path $hbZip -DestinationPath $tempDir -Force
                $hbExe = Get-ChildItem -Path $tempDir -Recurse -Filter "HandBrakeCLI.exe" | Select-Object -First 1
                if (-not $hbExe) { throw "HandBrakeCLI.exe not found after extraction." }

                Copy-Item -Path $hbExe.FullName -Destination $handbrakePath -Force
                Remove-Item $hbZip -Force
            } catch {
                Write-ColoredHost "Failed to download HandBrakeCLI: $_" -ForegroundColor Red
            }
        }

        if ($missingEncoders -contains "FFmpeg" -or $missingEncoders -contains "FFprobe") {
            try {
                Write-ColoredHost "Downloading FFmpeg..." -ForegroundColor Cyan
                $ff7z = Join-Path $tempDir "ffmpeg.7z"
                Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z" -OutFile $ff7z
                & $sevenZipPath x $ff7z -o"$tempDir\ffmpeg" -y | Out-Null
                $ffDir = Get-ChildItem "$tempDir\ffmpeg" -Directory | Select-Object -First 1
                if ($missingEncoders -contains "FFmpeg") {
                    Copy-Item "$($ffDir.FullName)\bin\ffmpeg.exe" -Destination $ffmpegPath -Force
                }
                if ($missingEncoders -contains "FFprobe") {
                    Copy-Item "$($ffDir.FullName)\bin\ffprobe.exe" -Destination $ffprobePath -Force
                }
                Remove-Item $ff7z -Force
            } catch {
                Write-ColoredHost "Failed to download FFmpeg: $_" -ForegroundColor Red
            }
        }

        if ($missingEncoders -contains "MKVPropEdit") {
            try {
                Write-ColoredHost "Downloading MKVPropEdit..." -ForegroundColor Cyan
                $mkvtoolnixBaseUrl = "https://mkvtoolnix.download/windows/continuous/64-bit/"
                $mkvtoolnixBasePage = Invoke-WebRequest -Uri $mkvtoolnixBaseUrl
                $versionFolders = $mkvtoolnixBasePage.Links | Where-Object { $_.href -match "(\d+\.\d+)" } | ForEach-Object { $matches[1] } | Sort-Object -Descending
                $latestVersionFolder = $versionFolders[0]
                $mkvtoolnixVersionDirUrl = $mkvtoolnixBaseUrl.TrimEnd('/')
                $mkvtoolnixVersionPage = Invoke-WebRequest -Uri "$mkvtoolnixVersionDirUrl/$latestVersionFolder/"
                $mkvLinks = $mkvtoolnixVersionPage.Links | Where-Object { $_.href -match "mkvtoolnix-64-bit-$latestVersionFolder-revision-(\d+)-" }
                $revisions = ($mkvLinks | Where-Object { $_.href -match "mkvtoolnix-64-bit-$latestVersionFolder-revision-(\d+)-" } | ForEach-Object { $matches[1].PadLeft(3,'0') }) | Sort-Object -Descending
                $latestRevision = $revisions[0]
                $downloadLink = ($mkvLinks | Where-Object { $_.href -match "mkvtoolnix-64-bit-$latestVersionFolder-revision-$latestRevision-.*\.7z$" }).href
                $mkvUrl = "https://mkvtoolnix.download$downloadLink"
                $mkv7z = Join-Path $tempDir "mkvtoolnix.7z"
                Invoke-WebRequest -Uri $mkvUrl -OutFile $mkv7z
                & $sevenZipPath x $mkv7z -o"$tempDir\mkv" -y | Out-Null
                Copy-Item (Get-ChildItem "$tempDir\mkv" -Recurse -Filter "mkvpropedit.exe").FullName -Destination $mkvpropeditPath -Force
                Remove-Item $mkv7z -Force
            } catch {
                Write-ColoredHost "Failed to download MKVPropEdit: $_" -ForegroundColor Red
            }
        }

        Write-ColoredHost "`nRechecking after downloads..." -ForegroundColor Yellow
        Confirm-Encoders | Out-Null
    } else {
        Write-ColoredHost "All encoders are already present. No download needed." -ForegroundColor Green
        Write-Host ""
    }
}

function Invoke-UpdateEncoders {
    param(
        [switch]$CheckOnly
    )

    # Output helpers
    function Write-Status {
        param (
            [string]$encoder,
            [string]$current,
            [string]$status,
            [string]$statusColor = "Gray"
        )
        Write-Host ("{0,-12}: {1} " -f $encoder, $current) -NoNewline
        Write-Host $status -ForegroundColor $statusColor
    }

    # Version Checkers

    function Get-JEncoderVersion {
        return $ScriptVersion
    }
    
    function Get-FFmpegVersion {
        $versionLine = & $script:ffmpegPath -version | Select-String -Pattern "^ffmpeg version"
        if ($versionLine -match "ffmpeg version (\d{4}-\d{2}-\d{2})") {
            return $matches[1]
        }
        return "Unknown"
    }

    function Get-FFprobeVersion {
        $versionLine = & $script:ffprobePath -version | Select-String -Pattern "^ffprobe version"
        if ($versionLine -match "ffprobe version (\d{4}-\d{2}-\d{2})") {
            return $matches[1]
        }
        return "Unknown"
    }

    function Get-HandBrakeVersion {
        $versionLine = & $script:handbrakePath --version 2>&1 | Select-String -Pattern "^HandBrake"
        return ($versionLine.Line -replace "^HandBrake\s+", "").Trim().Split(" ")[0]
    }

    function Get-MKVPropEditVersion {
        $versionLine = & $script:mkvpropeditPath --version | Select-String -Pattern "^mkvpropedit"
        if ($versionLine -match "(v\d+(\.\d+)*)") {
            return $matches[1]
        }
        return $versionLine.Trim()
    }

    # Fetch latest versions
    function Get-LatestVersions {
        $latest = @{ }
 
        # Get Latest JEncoder Version
        try {
            $Repo = "Jarsky/JEncoder"
            $releaseUrl = "https://api.github.com/repos/$Repo/releases/latest"
            $latestRelease = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing
            $latest.jencoder = $latestRelease.tag_name -replace '^JEncoder-v', ''
            $latest.latestRelease = $latestRelease
        } catch { 
            $latest.jencoder = "Unknown" 
        }

        # Get Latest Handbrake Version
        try {
            $hbRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/HandBrake/HandBrake/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
            $latest.handbrake = $hbRelease.tag_name.TrimStart("v")
        } catch { $latest.handbrake = "Unknown" }
        
        # Get Latest FFMpeg Version
        try {
            $webContent = Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/"
            $versionElement = $webContent.ParsedHtml.getElementById("git-version")
        
            $fullVersion = $versionElement.innerText.Trim()

            if ($fullVersion -match "(\d{4}-\d{2}-\d{2})") {
                $latest.ffmpeg = $matches[1]
            } else {
                $latest.ffmpeg = "Unknown"
            }
            $latest.ffprobe = $latest.ffmpeg
        } catch { 
            $latest.ffmpeg = "Unknown"
            $latest.ffprobe = "Unknown" 
        }
    
        # Get Latest MKVTools Version
        try {
            $mkvtoolnixBaseUrl = "https://mkvtoolnix.download/windows/continuous/64-bit/"
            $mkvtoolnixBasePage = Invoke-WebRequest -Uri $mkvtoolnixBaseUrl
            $versionFolders = $mkvtoolnixBasePage.Links | Where-Object { $_.href -match "(\d+\.\d+)" } | ForEach-Object { $matches[1] } | Sort-Object -Descending
            $latestVersionFolder = $versionFolders[0]
            $latest.mkvpropedit = "v$latestVersionFolder"
        } catch {
            $latest.mkvpropedit = "Unknown"
        }

        return $latest
    }

    $latestVersions = Get-LatestVersions
    $currentVersions = @{
        jencoder    = Get-JEncoderVersion
        ffmpeg      = Get-FFmpegVersion
        ffprobe     = Get-FFprobeVersion
        handbrake   = Get-HandBrakeVersion
        mkvpropedit = Get-MKVPropEditVersion
    }

    Write-Host "`nChecking encoder versions...`n"
    $needsUpdate = $false
    $toUpdate = @()

    foreach ($key in $currentVersions.Keys) {
        $current = $currentVersions[$key]
        $latest  = $latestVersions[$key]
    
        $isNewer = $false
        if ($current -eq "Unknown" -or $latest -eq "Unknown") {
            $isNewer = $true
        }
        elseif ($current -match '^\d{4}-\d{2}-\d{2}$' -and $latest -match '^\d{4}-\d{2}-\d{2}$') {
            $currentDate = [datetime]::ParseExact($current, 'yyyy-MM-dd', $null)
            $latestDate = [datetime]::ParseExact($latest, 'yyyy-MM-dd', $null)
    
            $isNewer = $currentDate -lt $latestDate
        }
        else {
            try {
                $currentVer = [version]($current.TrimStart("v"))
                $latestVer = [version]($latest.TrimStart("v"))
                $isNewer = $currentVer -lt $latestVer
            } catch {
                $isNewer = ($current -ne $latest)
            }
        }
    
        if (-not $isNewer) {
            Write-Status $key $current "(Latest Version!)" "Green"
        } else {
            Write-Status $key $current "(Update Available: $latest)" "Yellow"
            $needsUpdate = $true
            $toUpdate += $key
        }
    }
    

    if ($CheckOnly) {
        if ($needsUpdate) {
            Write-Host "`nUpdates are available. Do you want to update now? (Y/N)" -ForegroundColor Yellow
            $confirm = Read-Host
            if ($confirm -match '^(y|yes)$') {
                Write-Host "`nDownloading and updating encoders..." -ForegroundColor Cyan

                $tempDir = Join-Path $env:TEMP "EncoderDownloads"
                $sevenZipPath = Join-Path $scriptDir "7z.exe"
                New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

                if ($toUpdate -contains "jencoder") {
                    Write-Host "`nUpdating JEncoder script..." -ForegroundColor Cyan
                
                    try {
                        $jeVersion = $latestVersions.latestRelease.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
                        if (-not $jeVersion) {
                            throw "Could not find latest JEncoder ZIP asset."
                        }
                        $jeRelease = $jeVersion.browser_download_url
                        $jeZip = Join-Path $tempDir "JEncoder.zip"
                        try {
                            Invoke-WebRequest -Uri $jeRelease -OutFile $jeZip -UseBasicParsing -ErrorAction Stop
                        } catch {
                            throw "Failed to download JEncoder ZIP from $jeRelease. $_"
                        }
                        Expand-Archive -Path $jeZip -DestinationPath $tempDir -Force
                        $jePS1 = Get-ChildItem -Path $tempDir -Recurse -Filter "*.ps1" | Select-Object -First 1
                        if (-not $jePS1) {
                            throw "No .ps1 script found in extracted archive."
                        }
                        $scriptPath = $MyInvocation.MyCommand.Path  
                        Copy-Item -Path $jePS1.FullName -Destination $scriptPath -Force
                        Remove-Item $jeZip -Force                      
                        Write-Host "JEncoder updated successfully! Please restart the script." -ForegroundColor Green
                        exit
                    } catch {
                        Write-Host "Failed to update JEncoder: $_" -ForegroundColor Red
                    }
                }             

                if ($toUpdate -contains "handbrake") {
                    try {
                        Write-ColoredHost "Updating HandBrakeCLI..." -ForegroundColor Cyan
                        $hbRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/HandBrake/HandBrake/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
                        $hbAsset = $hbRelease.assets | Where-Object { $_.name -match "HandBrakeCLI.*win.*x86_64\.zip" } | Select-Object -First 1
                        $hbZip = Join-Path $tempDir "HandBrakeCLI.zip"
                        Invoke-WebRequest -Uri $hbAsset.browser_download_url -OutFile $hbZip
                        Expand-Archive -Path $hbZip -DestinationPath $tempDir -Force
                        $hbExe = Get-ChildItem -Path $tempDir -Recurse -Filter "HandBrakeCLI.exe" | Select-Object -First 1
                        Copy-Item -Path $hbExe.FullName -Destination $script:handbrakePath -Force
                        Remove-Item $hbZip -Force
                    } catch {
                        Write-ColoredHost "Failed to update HandBrakeCLI: $_" -ForegroundColor Red
                    }
                }

                if ($toUpdate -contains "ffmpeg" -or $toUpdate -contains "ffprobe") {
                    try {
                        Write-ColoredHost "Updating FFmpeg/FFprobe..." -ForegroundColor Cyan
                        $ff7z = Join-Path $tempDir "ffmpeg.7z"
                        Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z" -OutFile $ff7z
                        & $sevenZipPath x $ff7z -o"$tempDir\ffmpeg" -y | Out-Null
                        $ffDir = Get-ChildItem "$tempDir\ffmpeg" -Directory | Select-Object -First 1
                        Copy-Item "$($ffDir.FullName)\bin\ffmpeg.exe" -Destination $script:ffmpegPath -Force
                        Copy-Item "$($ffDir.FullName)\bin\ffprobe.exe" -Destination $script:ffprobePath -Force
                        Remove-Item $ff7z -Force
                    } catch {
                        Write-ColoredHost "Failed to update FFmpeg: $_" -ForegroundColor Red
                    }
                }

                if ($toUpdate -contains "mkvpropedit") {
                    try {
                        Write-ColoredHost "Updating MKVPropEdit..." -ForegroundColor Cyan
                        $mkvtoolnixBaseUrl = "https://mkvtoolnix.download/windows/continuous/64-bit/"
                        $mkvtoolnixBasePage = Invoke-WebRequest -Uri $mkvtoolnixBaseUrl
                        $versionFolders = $mkvtoolnixBasePage.Links | Where-Object { $_.href -match "(\d+\.\d+)" } | ForEach-Object { $matches[1] } | Sort-Object -Descending
                        $latestVersionFolder = $versionFolders[0]
                        $mkvtoolnixVersionDirUrl = $mkvtoolnixBaseUrl.TrimEnd('/')
                        $mkvtoolnixVersionPage = Invoke-WebRequest -Uri "$mkvtoolnixVersionDirUrl/$latestVersionFolder/"
                        $mkvLinks = $mkvtoolnixVersionPage.Links | Where-Object { $_.href -match "mkvtoolnix-64-bit-$latestVersionFolder-revision-(\d+)-" }
                        $revisions = ($mkvLinks | Where-Object { $_.href -match "mkvtoolnix-64-bit-$latestVersionFolder-revision-(\d+)-" } | ForEach-Object { $matches[1].PadLeft(3,'0') }) | Sort-Object -Descending
                        $latestRevision = $revisions[0]
                        $downloadLink = ($mkvLinks | Where-Object { $_.href -match "mkvtoolnix-64-bit-$latestVersionFolder-revision-$latestRevision-.*\.7z$" }).href
                        $latestVersionUrl = "https://mkvtoolnix.download$downloadLink"
                        $mkv7z = Join-Path $tempDir "mkvtoolnix.7z"
                        Invoke-WebRequest -Uri $latestVersionUrl -OutFile $mkv7z
                        & $sevenZipPath x $mkv7z -o"$tempDir\mkv" -y | Out-Null
                        Copy-Item (Get-ChildItem "$tempDir\mkv" -Recurse -Filter "mkvpropedit.exe").FullName -Destination $script:mkvpropeditPath -Force
                        Remove-Item $mkv7z -Force
                    } catch {
                        Write-ColoredHost "Failed to update MKVPropEdit: $_" -ForegroundColor Red
                    }
                }

                Write-ColoredHost "`nUpdate process complete. Rechecking versions..." -ForegroundColor Green
                Invoke-UpdateEncoders -CheckOnly
            }
        } else {
            Write-Host "`nAll encoders are up to date." -ForegroundColor Green
        }
        return
    }

}



# Output Directory Setup
$outputDir = Join-Path -Path $scriptDir -ChildPath $globalConfig.outputDir
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory | Out-Null
}

# To-Delete Directory Setup
if ($globalConfig.toDeleteDir) {
    $toDeleteDir = Join-Path -Path $scriptDir -ChildPath $globalConfig.toDeleteDir
} else {
    $toDeleteDir = $null
}


# Function to get the input files
function Get-InputFiles {
    param (
        [string]$scriptDir
    )

    $inputFiles = Get-ChildItem -Path $scriptDir -Include *.mp4, *.mkv -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        ($_.DirectoryName -ne $outputDir) -and
        ($null -eq $toDeleteDir -or $_.DirectoryName -ne $toDeleteDir)
    }

    return $inputFiles
}




# Function to process and rename the output files
function Set-OutputFileName {
    param (
        [string]$inputFilePath,
        [string]$encoderUsed,
        [string]$audioEncoder = "copy",
        [switch]$renameOutputFile
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFilePath)
    $fileExtension = [System.IO.Path]::GetExtension($inputFilePath)

    if ($replaceSpaces) {
        $baseName = $baseName -replace ' ', '.'
    }

    switch -Regex ($encoderUsed.ToLower()) {
        "265"  { $targetCodec = "x265"; break }
        "264"  { $targetCodec = "x264"; break }
        "av1"  { $targetCodec = "av1"; break }
        default { $targetCodec = "encoded" }
    }

    $baseName = $baseName -replace "(h[\s\.-]?264|x[\s\.-]?264|h[\s\.-]?265|x[\s\.-]?265|av1|xvid|divx|mpeg2?)", $targetCodec

    if ($audioEncoder -ne "copy") {
        $audioTargets = @{
            "truehd"      = "TrueHD"
            "opus"        = "Opus"
            "libopus"     = "Opus"
            "^pcm"        = "PCM"
            "flac"        = "FLAC"
            "eac3"        = "AC3"
            "ac3"         = "AC3"
            "mp3"         = "MP3"
            "aac"         = "AAC"
            "wmv"         = "WMV"
        }

        foreach ($pattern in $audioTargets.Keys) {
            if ($audioEncoder -match $pattern) {
                $targetAudio = $audioTargets[$pattern]
                $baseName = $baseName -replace "(DD\+|FLAC|DTS[-\s]?HD\s?MA|LPCM|AC3|AAC|MP3|Opus)", $targetAudio
                break
            }
        }
    }

    if ($renameOutputFile) {
        Write-ColoredHost "Renaming to: $baseName$fileExtension" -ForegroundColor Cyan
    }

    $outputFileName = "$baseName$fileExtension"
    $outputFilePath = Join-Path -Path $outputDir -ChildPath $outputFileName

    $n = 1
    while (Test-Path $outputFilePath) {
        $outputFilePath = Join-Path -Path $outputDir -ChildPath "$baseName-$n$fileExtension"
        $n++
    }

    return $outputFilePath
}

# List files to process
function Show-FilesToProcess {
    param (
        [string]$scriptDir,
        [string]$outputDir
    )
    $filesToProcess = Get-InputFiles -scriptDir $scriptDir
    Write-ColoredHost "Files found:" -ForegroundColor Yellow
    Write-ColoredHost "------------" -ForegroundColor Yellow
    if ($filesToProcess.Count -eq 0) {
        Write-ColoredHost "None" -ForegroundColor White
    } else {
        $filesToProcess | ForEach-Object { Write-ColoredHost $_.Name -ForegroundColor White }
        Write-ColoredHost "" -ForegroundColor White
    }
    if ($filesToProcess.Count -eq 0) {
        Write-ColoredHost "No .mp4 or .mkv files were found in the script directory." -ForegroundColor Red
        Write-ColoredHost "Press any key to exit..." -ForegroundColor White
        [System.Console]::ReadKey() | Out-Null
        exit
    }
    Write-Host ""
}

function Use-Files {
    param (
        [ScriptBlock]$InvokeFunction # The specific encoding function to call (e.g., Invoke-WithHandBrake)
    )

    $inputFiles = Get-InputFiles
    foreach ($file in $inputFiles) {
        if ($null -eq $file.FullName) {
            Write-Warning "Invalid input file: $file"
            continue
        }
        $outputFilePath = Set-OutputFileName -inputFilePath $file.FullName
        if ([string]::IsNullOrEmpty($outputFilePath)) {
            Write-Warning "Failed to generate output file path for: $file.FullName"
            continue
        }
        Write-Host "Processing File:"
        Write-Host "  Input:  $($file.FullName)"
        Write-Host "  Output: $outputFilePath"
        try {
            & $InvokeFunction.Invoke($file, $outputFilePath)
        } catch {
            Write-Error "Error processing file $($file.FullName): $_"
        }
    }
}

# Move original file if deleteOriginals is true
function Move-OriginalFile {
    param (
        [string]$filePath,
        [string]$toDeleteDir
    )
    if ($globalConfig.deleteOriginals) {
        if (-not (Test-Path $toDeleteDir)) {
            New-Item -Path $toDeleteDir -ItemType Directory | Out-Null
        }

        $dest = Join-Path -Path $toDeleteDir -ChildPath (Split-Path $filePath -Leaf)
        Move-Item -Path $filePath -Destination $dest -Force
        Write-Host "Moved original to: $dest" -ForegroundColor DarkGray
    }
}


function Get-Codec {
    param (
        [string]$filePath
    )
    $codec = & $ffprobePath -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$filePath"
    return $codec
}

function Get-SubtitleInfo {
    param (
        [string]$filePath
    )
    # Run ffprobe to get details of subtitle streams
    $subtitleInfo = & $ffprobePath -v error -select_streams s -show_entries stream=index,codec_type,codec_name -of json "$filePath"
    $subtitleInfo | ConvertFrom-Json | Select-Object -ExpandProperty streams
}

function Update-SubtitleFlags {
    param (
        [string]$filePath
    )

    if (-not (Test-Path $filePath)) {
        Write-Warning "File not found: $filePath"
        return
    }
    # Assumes Get-SubtitleInfo returns a list of subtitle track info with properties like index and codec_name
    $subtitleInfo = Get-SubtitleInfo -filePath $filePath
    $commands = @()

    foreach ($stream in $subtitleInfo) {
        $index = $stream.index
        $codec = $stream.codec_name

        if ($codec -eq "subrip") {
            # mkvpropedit uses 0-based subtitle track index internally
            $commands += "--edit track:s$($index - 1) --set flag-default=0 --set flag-forced=0"
        }
    }

    if ($commands.Count -gt 0) {
        if (-not $Global:mkvpropeditPath) {
            Write-Warning "mkvpropeditPath is not set. Please define it before calling this function."
            return
        }

        $quotedFilePath = "`"$filePath`""
        $quotedMkvpropeditPath = "`"$Global:mkvpropeditPath`""
        $mkvpropeditArgs = $commands -join ' '

        Write-Host "Updating subtitle flags with mkvpropedit..." -ForegroundColor Cyan
        Write-Host "$quotedMkvpropeditPath $quotedFilePath $mkvpropeditArgs" -ForegroundColor Cyan

        try {
            Start-Process -FilePath $quotedMkvpropeditPath -ArgumentList "$quotedFilePath $mkvpropeditArgs" -NoNewWindow -Wait
            Write-Host "Subtitle flags updated successfully." -ForegroundColor Green
        } catch {
            Write-Error "Failed to update subtitle flags: $_"
        }
    } else {
        Write-Host "No 'subrip' subtitle tracks found that require flag updates." -ForegroundColor Yellow
    }
}

# New Helper Functions for Progress Tracking

function Get-ProjectedFileSize {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputFilePath,
        [Parameter(Mandatory = $true)]
        [string]$Encoder,
        [Parameter(Mandatory = $true)]
        [string]$Quality
    )

    try {
        # Get input file size
        $inputSize = (Get-Item $InputFilePath).Length
        
        # Get video duration
        $durationStr = & $ffprobePath -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$InputFilePath" 2>$null
        if (-not $durationStr -or -not [double]::TryParse($durationStr, [ref]$null)) {
            $durationStr = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$InputFilePath" 2>$null
        }
        
        [double]$duration = if ([double]::TryParse($durationStr, [ref]$null)) { [double]$durationStr } else { 0 }
        
        if ($duration -le 0) {
            # If can't get duration, make a rough estimate based on the encoder and quality
            return $inputSize * 0.7 # Default estimate of 70% of original size
        }
        
        # Get bitrate
        $bitrateStr = & $ffprobePath -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$InputFilePath" 2>$null
        if (-not $bitrateStr -or -not [double]::TryParse($bitrateStr, [ref]$null)) {
            $bitrateStr = & $ffprobePath -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$InputFilePath" 2>$null
        }
        
        [double]$inputBitrate = if ([double]::TryParse($bitrateStr, [ref]$null)) { [double]$bitrateStr / 1000 } else { 0 }
        
        if ($inputBitrate -le 0) {
            $inputBitrate = $inputSize * 8 / $duration / 1000 # Calculate bitrate from filesize and duration (kbps)
        }
        
        # Estimate output bitrate based on encoder and quality
        $compressionFactor = 1.0
        
        # HandBrakeCLI (x265) quality factor is inverse (lower value = higher quality)
        if ($Encoder -match "265|hevc") {
            # HEVC/x265 encoders
            if ($Encoder -match "nvenc") {
                # NVENC has different scaling
                $compressionFactor = switch ($Quality) {
                    { [double]$_ -le 20 } { 0.4 }
                    { [double]$_ -le 25 } { 0.5 }
                    { [double]$_ -le 30 } { 0.6 }
                    default { 0.7 }
                }
            } else {
                # Regular x265/HEVC
                $compressionFactor = switch ($Quality) {
                    { [double]$_ -le 18 } { 0.3 }  # High quality
                    { [double]$_ -le 22 } { 0.4 }  # Medium quality
                    { [double]$_ -le 26 } { 0.5 }  # Low quality
                    { [double]$_ -le 30 } { 0.6 }  # Very low quality
                    default { 0.7 }
                }
            }
        } elseif ($Encoder -match "264|avc") {
            # x264/AVC has slightly worse compression
            $compressionFactor = switch ($Quality) {
                { [double]$_ -le 18 } { 0.4 }
                { [double]$_ -le 22 } { 0.5 }
                { [double]$_ -le 26 } { 0.6 }
                default { 0.7 }
            }
        } else {
            # Default for other encoders
            $compressionFactor = 0.6
        }
        
        # Calculate projected file size
        $projectedBitrate = $inputBitrate * $compressionFactor
        $projectedSize = ($projectedBitrate * $duration * 1000) / 8 # Convert back to bytes
        
        # Add overhead for container and audio (if not reencoded)
        if ($audioEncoder -eq "copy") {
            # Calculate audio size and add it
            $audioSize = $inputSize * 0.15  # Rough estimate that audio is about 15% of file
            $projectedSize += $audioSize
        }
        
        return $projectedSize
    } catch {
        Write-Debug "Error calculating projected file size: $_"
        return $inputSize * 0.7 # Default to 70% of original size on error
    }
}

function Parse-HandBrakeProgress {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Line
    )
    
    if ($Line -match '(\d+\.\d+) %') {
        return [double]$Matches[1]
    }
    return -1
}

function Parse-FFmpegProgress {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Line,
        [Parameter(Mandatory = $true)]
        [double]$TotalDuration
    )
    
    if ($Line -match 'time=(\d+):(\d+):(\d+\.\d+)') {
        $hours = [double]$Matches[1]
        $minutes = [double]$Matches[2]
        $seconds = [double]$Matches[3]
        $currentTime = ($hours * 3600) + ($minutes * 60) + $seconds
        
        if ($TotalDuration -gt 0) {
            return ($currentTime / $TotalDuration) * 100
        }
    }
    return -1
}

function Get-MediaDuration {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    
    $durationStr = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FilePath" 2>$null
    
    if ([double]::TryParse($durationStr, [ref]$null)) {
        return [double]$durationStr
    }
    
    return 0
}

function Format-TimeRemaining {
    param (
        [Parameter(Mandatory = $true)]
        [double]$SecondsRemaining
    )
    
    if ($SecondsRemaining -le 0) {
        return "Calculating..."
    }
    
    $timeSpan = [TimeSpan]::FromSeconds([Math]::Round($SecondsRemaining))
    
    if ($timeSpan.TotalHours -ge 1) {
        return "{0:D2}:{1:D2}:{2:D2}" -f $timeSpan.Hours, $timeSpan.Minutes, $timeSpan.Seconds
    } else {
        return "{0:D2}:{1:D2}" -f $timeSpan.Minutes, $timeSpan.Seconds
    }
}

# Function to encode using HandBrake

function Invoke-WithHandBrake {
    param (
        [switch]$NVENC
    )

    $inputFiles = Get-InputFiles
    $summary = @()

    foreach ($inputFile in $inputFiles) {
        $encoderUsed = if ($NVENC) { $handbrakeEncoderNVENC } else { $handbrakeEncoder }
        $encoderQuality = if ($NVENC) { $handbrakeNVENCPreset } else { $handbrakePreset }
        $qualityValue = $handbrakeQuality

        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName -encoderUsed $encoderUsed
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }

        $method = if ($NVENC) { "HandBrakeCLI (NVENC)" } else { "HandBrakeCLI" }
        $projectedSize = Get-ProjectedFileSize -InputFilePath $inputFile.FullName -Encoder $encoderUsed -Quality $qualityValue
        $projectedSizeStr = Get-HumanReadableSize -Size $projectedSize
        
        Write-Log "Starting encode: $($inputFile.Name) using $method" -Level "INFO"
        Write-Log "Output: $($outputFile.Name)" -Level "INFO"
        Write-Log "Projected size: $projectedSizeStr" -Level "INFO"
        
        try {
            # Start process with redirected output
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $handbrakePath
            if ($NVENC) {
                $psi.Arguments = "-i `"$($inputFile.FullName)`" -o `"$($outputFile.FullPath)`" -e $handbrakeEncoderNVENC --encoder-preset $handbrakeNVENCPreset -q $handbrakeQuality --cfr --all-audio --all-subtitles"
            } else {
                $psi.Arguments = "-i `"$($inputFile.FullName)`" -o `"$($outputFile.FullPath)`" -e $handbrakeEncoder --encoder-preset $handbrakePreset -q $handbrakeQuality --cfr --all-audio --all-subtitles"
            }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            
            Write-Log "Executing HandBrakeCLI with arguments: $($psi.Arguments)" -Level "INFO" -NoConsole
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $process.Start() | Out-Null
            
            # Setup progress tracking
            $startTime = Get-Date
            $lastProgress = 0
            $lastTime = $startTime
            $progressReadings = @()
            
            # Async reading of output
            $outputReader = $process.StandardOutput
            $errorReader = $process.StandardError
            
            while (-not $process.HasExited) {
                $line = if ($errorReader.Peek() -gt 0) { $errorReader.ReadLine() } else { $outputReader.ReadLine() }
                
                if ($line) {
                    # Log verbose output if enabled
                    if ($globalConfig.verboseLogging) {
                        Write-Log $line -Level "INFO" -NoConsole
                    }
                    
                    $progress = Parse-HandBrakeProgress -Line $line
                    
                    if ($progress -ge 0 -and $progress -gt $lastProgress) {
                        $currentTime = Get-Date
                        $elapsedTime = ($currentTime - $startTime).TotalSeconds
                        $remainingTime = ($elapsedTime / $progress) * (100 - $progress)
                        
                        # Record this reading for better ETA calculation
                        if ($progressReadings.Count -ge 10) { 
                            $progressReadings = $progressReadings[1..9] 
                        }
                        $progressReadings += [PSCustomObject]@{
                            Progress = $progress
                            Time = $currentTime
                        }
                        
                        # Calculate average speed from recent readings
                        if ($progressReadings.Count -gt 1) {
                            $oldestReading = $progressReadings[0]
                            $progressDiff = $progress - $oldestReading.Progress
                            $timeDiff = ($currentTime - $oldestReading.Time).TotalSeconds
                            
                            if ($timeDiff -gt 0 -and $progressDiff -gt 0) {
                                $remainingTime = ($timeDiff / $progressDiff) * (100 - $progress)
                            }
                        }
                        
                        $eta = Format-TimeRemaining -SecondsRemaining $remainingTime
                        $status = "Encoding with $method | ETA: $eta | Projected size: $projectedSizeStr"
                        
                        Write-Progress -Activity "Encoding $($inputFile.Name)" -Status $status -PercentComplete $progress
                        $lastProgress = $progress
                        $lastTime = $currentTime
                    }
                    
                    # Small sleep to prevent CPU hogging
                    Start-Sleep -Milliseconds 100
                }
            }
            
            Write-Progress -Activity "Encoding $($inputFile.Name)" -Completed
            
            # Read any remaining output
            $remainingError = ""
            while ($errorReader.Peek() -gt 0) { 
                $line = $errorReader.ReadLine()
                $remainingError += "$line`n" 
                if ($globalConfig.verboseLogging) {
                    Write-Log $line -Level "INFO" -NoConsole
                }
            }
            
            while ($outputReader.Peek() -gt 0) { 
                $line = $outputReader.ReadLine()
                if ($globalConfig.verboseLogging) {
                    Write-Log $line -Level "INFO" -NoConsole
                }
            }
            
            $outputReader.Close()
            $errorReader.Close()
            $exitCode = $process.ExitCode
            $process.Close()
            
            if ($exitCode -eq 0) {
                $inputSize = (Get-Item $inputFile.FullName).Length
                $outputSize = (Get-Item $outputFile.FullPath).Length
                $reduction = Get-ReductionPercentage -inputSize $inputSize -outputSize $outputSize

                Write-Log "Converted: $($inputFile.Name) > $($outputFile.Name) using $method" -Level "SUCCESS"
                Write-Log "Input size: $(Get-HumanReadableSize -Size $inputSize), Output size: $(Get-HumanReadableSize -Size $outputSize), Reduction: $reduction%" -Level "INFO"

                $summary += [PSCustomObject]@{
                    FileName         = $inputFile.Name
                    InputSize        = Get-HumanReadableSize -Size $inputSize
                    OutputSize       = Get-HumanReadableSize -Size $outputSize
                    ReductionPercent = "$reduction%"
                }

                Move-OriginalFile $inputFile.FullName $toDeleteDir
            } else {
                $encoderType = if ($NVENC) { "(NVENC)" } else { "" }
                $errorMsg = "HandBrake $encoderType failed on: $($inputFile.Name) with exit code $exitCode"
                if ($remainingError) {
                    $errorMsg += "`nError output: $remainingError"
                }
                Handle-Error -ErrorMessage $errorMsg -Operation "HandBrake Encoding"
            }
        }
        catch {
            Handle-Error -ErrorMessage "Failed to process file with HandBrake" -Operation "HandBrake Encoding" -ErrorRecord $_
        }
    }

    Show-EncodingSummary -SummaryList $summary
}


# Function to encode using FFmpeg

function Invoke-WithFFmpeg {
    param (
        [switch]$NVENC
    )

    $inputFiles = Get-InputFiles
    $summary = @()

    foreach ($inputFile in $inputFiles) {
        $encoderUsed = if ($NVENC) { $ffmpegEncoderNVENC } else { $ffmpegEncoder }
        $encoderPreset = if ($NVENC) { $ffmpegNVENCPreset } else { $ffmpegPreset }
        $qualityValue = $ffmpegQuality

        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName -encoderUsed $encoderUsed
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }

        $method = if ($NVENC) { "FFmpeg (NVENC)" } else { "FFmpeg (CPU)" }
        $duration = Get-MediaDuration -FilePath $inputFile.FullName
        $projectedSize = Get-ProjectedFileSize -InputFilePath $inputFile.FullName -Encoder $encoderUsed -Quality $qualityValue
        $projectedSizeStr = Get-HumanReadableSize -Size $projectedSize
        
        Write-Log "Starting encode: $($inputFile.Name) using $method" -Level "INFO"
        Write-Log "Output: $($outputFile.Name)" -Level "INFO"
        Write-Log "Projected size: $projectedSizeStr" -Level "INFO"
        
        try {
            # Start process with redirected output
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ffmpegPath
            if ($NVENC) {
                $psi.Arguments = "-i `"$($inputFile.FullName)`" -map 0 -c:v $ffmpegEncoderNVENC -cq $ffmpegQuality -preset $ffmpegNVENCPreset -c:a $audioEncoder -c:s copy -disposition:s:0 0 -max_muxing_queue_size 9999 -progress pipe:1 `"$($outputFile.FullPath)`""
            } else {
                $psi.Arguments = "-hide_banner -i `"$($inputFile.FullName)`" -c:v $ffmpegEncoder -preset $ffmpegPreset -crf $ffmpegQuality -c:a copy -c:s copy -progress pipe:1 `"$($outputFile.FullPath)`""
            }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            
            Write-Log "Executing FFmpeg with arguments: $($psi.Arguments)" -Level "INFO" -NoConsole
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $process.Start() | Out-Null
            
            # Setup progress tracking
            $startTime = Get-Date
            $lastProgress = 0
            $lastTime = $startTime
            $progressReadings = @()
            
            # Async reading of output
            $outputReader = $process.StandardOutput
            $errorReader = $process.StandardError
            
            while (-not $process.HasExited) {
                $line = if ($outputReader.Peek() -gt 0) { $outputReader.ReadLine() } else { $errorReader.ReadLine() }
                
                if ($line) {
                    # Log verbose output if enabled
                    if ($globalConfig.verboseLogging) {
                        Write-Log $line -Level "INFO" -NoConsole
                    }
                    
                    if ($line -match 'time=(\d+):(\d+):(\d+\.\d+)') {
                        $hours = [double]$Matches[1]
                        $minutes = [double]$Matches[2]
                        $seconds = [double]$Matches[3]
                        $currentTime = ($hours * 3600) + ($minutes * 60) + $seconds
                        
                        $progress = if ($duration -gt 0) { ($currentTime / $duration) * 100 } else { 0 }
                        
                        if ($progress -gt $lastProgress) {
                            $now = Get-Date
                            $elapsedTime = ($now - $startTime).TotalSeconds
                            $remainingTime = ($elapsedTime / $progress) * (100 - $progress)
                            
                            # Record this reading for better ETA calculation
                            if ($progressReadings.Count -ge 10) { 
                                $progressReadings = $progressReadings[1..9] 
                            }
                            $progressReadings += [PSCustomObject]@{
                                Progress = $progress
                                Time = $now
                            }
                            
                            # Calculate average speed from recent readings
                            if ($progressReadings.Count -gt 1) {
                                $oldestReading = $progressReadings[0]
                                $progressDiff = $progress - $oldestReading.Progress
                                $timeDiff = ($now - $oldestReading.Time).TotalSeconds
                                
                                if ($timeDiff -gt 0 -and $progressDiff -gt 0) {
                                    $remainingTime = ($timeDiff / $progressDiff) * (100 - $progress)
                                }
                            }
                            
                            $eta = Format-TimeRemaining -SecondsRemaining $remainingTime
                            $status = "Encoding with $method | ETA: $eta | Projected size: $projectedSizeStr"
                            
                            Write-Progress -Activity "Encoding $($inputFile.Name)" -Status $status -PercentComplete $progress
                            $lastProgress = $progress
                            $lastTime = $now
                        }
                    }
                    
                    # Small sleep to prevent CPU hogging
                    Start-Sleep -Milliseconds 100
                }
            }
            
            Write-Progress -Activity "Encoding $($inputFile.Name)" -Completed
            
            # Read any remaining output
            $remainingError = ""
            while ($errorReader.Peek() -gt 0) { 
                $line = $errorReader.ReadLine()
                $remainingError += "$line`n" 
                if ($globalConfig.verboseLogging) {
                    Write-Log $line -Level "INFO" -NoConsole
                }
            }
            
            while ($outputReader.Peek() -gt 0) { 
                $line = $outputReader.ReadLine()
                if ($globalConfig.verboseLogging) {
                    Write-Log $line -Level "INFO" -NoConsole
                }
            }
            
            $outputReader.Close()
            $errorReader.Close()
            $exitCode = $process.ExitCode
            $process.Close()

            if ($exitCode -eq 0) {
                $inputSize = (Get-Item $inputFile.FullName).Length
                $outputSize = (Get-Item $outputFile.FullPath).Length
                $reduction = Get-ReductionPercentage -inputSize $inputSize -outputSize $outputSize

                Write-Log "Converted: $($inputFile.Name) > $($outputFile.Name) using $method" -Level "SUCCESS"
                Write-Log "Input size: $(Get-HumanReadableSize -Size $inputSize), Output size: $(Get-HumanReadableSize -Size $outputSize), Reduction: $reduction%" -Level "INFO"

                $summary += [PSCustomObject]@{
                    FileName         = $inputFile.Name
                    InputSize        = Get-HumanReadableSize -Size $inputSize
                    OutputSize       = Get-HumanReadableSize -Size $outputSize
                    ReductionPercent = "$reduction%"
                }

                Move-OriginalFile $inputFile.FullName $toDeleteDir
            } else {
                $encoderType = if ($NVENC) { "(NVENC)" } else { "" }
                $errorMsg = "FFmpeg $encoderType failed on: $($inputFile.Name) with exit code $exitCode"
                if ($remainingError) {
                    $errorMsg += "`nError output: $remainingError"
                }
                Handle-Error -ErrorMessage $errorMsg -Operation "FFmpeg Encoding"
            }
        }
        catch {
            Handle-Error -ErrorMessage "Failed to process file with FFmpeg" -Operation "FFmpeg Encoding" -ErrorRecord $_
        }
    }

    Show-EncodingSummary -SummaryList $summary
}

# Update the Get-HumanReadableSize function to handle both paths and direct sizes
function Get-HumanReadableSize {
    param (
        [Parameter(ParameterSetName = 'Path')]
        [string]$Path,
        
        [Parameter(ParameterSetName = 'Size')]
        [long]$Size
    )
    
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $fileSize = (Get-Item $Path).Length
    } else {
        $fileSize = $Size
    }
    
    if ($fileSize -lt 0) {
        throw "File size cannot be negative."
    }
    
    $units = @('Bytes', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB')
    $unitIndex = 0
    
    while ($fileSize -ge 1024 -and $unitIndex -lt $units.Length - 1) {
        $fileSize /= 1024
        $unitIndex++
    }
    
    $formattedSize = "{0:N2}" -f $fileSize
    return "$formattedSize $($units[$unitIndex])"
}

function Get-ReductionPercentage {
    param (
        [long]$inputSize,
        [long]$outputSize
    )

    if ($inputSize -eq 0) { return 0 }
    return [math]::Round((($inputSize - $outputSize) / $inputSize) * 100)
}
function Write-ColoredPercentage {
    param (
        [int]$percentageReduction
    )

    if ($percentageReduction -le 30) {
        Write-Host -NoNewline "$percentageReduction%" -ForegroundColor Yellow
    } elseif ($percentageReduction -le 50) {
        Write-Host -NoNewline "$percentageReduction%" -ForegroundColor Green
    } else {
        Write-Host -NoNewline "$percentageReduction%" -ForegroundColor Red
    }
}

function Show-EncodingSummary {
    param (
        [Parameter(Mandatory = $true)]
        [array]$SummaryList
    )

    if ($SummaryList.Count -eq 0) {
        Write-Log "`nNo files were successfully encoded, so no summary to show." -Level "WARNING"
        return
    }

    Write-Log "`nEncoding Summary:" -Level "INFO"
    Write-Log "----------------" -Level "INFO"
    
    # Calculate totals
    $totalInputSize = 0
    $totalOutputSize = 0
    
    foreach ($entry in $SummaryList) {
        # Parse sizes back to bytes for calculation
        if ($entry.InputSize -match '(\d+\.\d+) (\w+)') {
            $value = [double]$Matches[1]
            $unit = $Matches[2]
            $multiplier = switch ($unit) {
                "Bytes" { 1 }
                "KB" { 1KB }
                "MB" { 1MB }
                "GB" { 1GB }
                "TB" { 1TB }
                default { 1 }
            }
            $totalInputSize += $value * $multiplier
        }
        
        if ($entry.OutputSize -match '(\d+\.\d+) (\w+)') {
            $value = [double]$Matches[1]
            $unit = $Matches[2]
            $multiplier = switch ($unit) {
                "Bytes" { 1 }
                "KB" { 1KB }
                "MB" { 1MB }
                "GB" { 1GB }
                "TB" { 1TB }
                default { 1 }
            }
            $totalOutputSize += $value * $multiplier
        }
        
        # Format individual entry
        $percentValue = [int]$entry.ReductionPercent.TrimEnd('%')
        $percentColor = if ($percentValue -le 30) { "WARNING" } elseif ($percentValue -le 50) { "SUCCESS" } else { "ERROR" }
        
        Write-Log "$($entry.FileName):" -Level "INFO"
        Write-Log "  Input = $($entry.InputSize), Output = $($entry.OutputSize), Reduction = $($entry.ReductionPercent)" -Level $percentColor
    }
    
    # Show total summary
    $totalReduction = Get-ReductionPercentage -inputSize $totalInputSize -outputSize $totalOutputSize
    $totalReductionColor = if ($totalReduction -le 30) { "WARNING" } elseif ($totalReduction -le 50) { "SUCCESS" } else { "ERROR" }
    
    Write-Log "`nTotal Statistics:" -Level "INFO"
    Write-Log "  Total Input Size: $(Get-HumanReadableSize -Size $totalInputSize)" -Level "INFO"
    Write-Log "  Total Output Size: $(Get-HumanReadableSize -Size $totalOutputSize)" -Level "INFO"
    Write-Log "  Overall Reduction: $totalReduction%" -Level $totalReductionColor
    Write-Log "  Space Saved: $(Get-HumanReadableSize -Size ($totalInputSize - $totalOutputSize))" -Level "SUCCESS"
    
    # Return to show-header after summary display
    Write-Host "`nPress any key to continue..." -ForegroundColor Yellow
    [System.Console]::ReadKey() | Out-Null
    Show-Header
}

function Show-EncodingMenu {
    do {
        Clear-Host
        Show-Header
        Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir
        Write-Host ""
        Write-ColoredHost "Choose Encoding Method:" -ForegroundColor Yellow
        Write-ColoredHost "-----------------------" -ForegroundColor Yellow
        Write-ColoredHost "1. HandBrake (CPU Encoding)" -ForegroundColor White
        Write-ColoredHost "2. FFmpeg (CPU Encoding)" -ForegroundColor White
        Write-ColoredHost "3. HandBrake (NVENC - GPU Encoding)" -ForegroundColor White
        Write-ColoredHost "4. FFmpeg (NVENC - GPU Encoding)" -ForegroundColor White
        Write-ColoredHost "Q. Return to Main Menu" -ForegroundColor Red
        Write-Host ""

        $choice = Read-Host "Enter your choice"

        switch ($choice.ToLower()) {
            '1' { Invoke-WithHandBrake -NVENC:$false }
            '2' { Invoke-WithFFmpeg -NVENC:$false }
            '3' { Invoke-WithHandBrake -NVENC:$true }
            '4' { Invoke-WithFFmpeg -NVENC:$true }
            'q' { return }
            default {
                Write-ColoredHost "Invalid choice. Please select a valid option." -ForegroundColor Red
                Start-Sleep -Seconds 1.5
            }
        }

        Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
        Write-Host ""
        [System.Console]::ReadKey() | Out-Null
    } while ($true)
}


do {
    Show-Header 
    
    # Log script startup
    Write-Log "JEncoder v$ScriptVersion started" -Level "INFO" -NoConsole
    
    # Verify encoders are present or download them
    Get-Encoders 

    # Show files that will be processed
    Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir

    Write-ColoredHost "Main Menu:" -ForegroundColor Yellow
    Write-ColoredHost "----------" -ForegroundColor Yellow
    Write-ColoredHost "1. Encode Files" -ForegroundColor White
    Write-ColoredHost "2. Show Current Configuration" -ForegroundColor White
    Write-ColoredHost "3. Edit Configuration" -ForegroundColor White
    Write-ColoredHost "4. Advanced Options" -ForegroundColor White
    Write-ColoredHost "5. Check for Updates" -ForegroundColor White
    Write-ColoredHost "Q. Quit" -ForegroundColor Red
    Write-Host ""

    $menuChoice = Read-Host "Enter your choice"
    Write-Log "Menu choice selected: $menuChoice" -Level "INFO" -NoConsole

    switch ($menuChoice.ToLower()) {
        '1' { Show-EncodingMenu }
        '2' { Show-Configuration }
        '3' { Edit-Configuration }
        '4' {
            # Advanced Options submenu
            do {
                Clear-Host
                Show-Header
                
                Write-ColoredHost "Advanced Options:" -ForegroundColor Yellow
                Write-ColoredHost "----------------" -ForegroundColor Yellow
                Write-ColoredHost "1. Analyze Media Files" -ForegroundColor White
                Write-ColoredHost "2. Manage Subtitles" -ForegroundColor White
                Write-ColoredHost "3. Cleanup Temporary Files" -ForegroundColor White
                Write-ColoredHost "Q. Return to Main Menu" -ForegroundColor Red
                Write-Host ""
                
                $advancedChoice = Read-Host "Enter your choice"
                
                switch ($advancedChoice.ToLower()) {
                    '1' {
                        # Analyze current media files and display info
                        Clear-Host
                        Show-Header
                        Write-ColoredHost "Media File Analysis:" -ForegroundColor Yellow
                        Write-ColoredHost "-------------------" -ForegroundColor Yellow
                        
                        $files = Get-InputFiles -scriptDir $scriptDir
                        foreach ($file in $files) {
                            Write-ColoredHost $file.Name -ForegroundColor Cyan
                            
                            # Get basic info using ffprobe
                            $fileInfo = & $ffprobePath -v error -show_format -show_streams -of json "$($file.FullName)" | ConvertFrom-Json
                            
                            $videoStream = $fileInfo.streams | Where-Object { $_.'codec_type' -eq 'video' } | Select-Object -First 1
                            $audioStreams = $fileInfo.streams | Where-Object { $_.'codec_type' -eq 'audio' }
                            $subtitleStreams = $fileInfo.streams | Where-Object { $_.'codec_type' -eq 'subtitle' }
                            
                            # Display file info
                            $duration = [TimeSpan]::FromSeconds([double]$fileInfo.format.duration)
                            $durationStr = if ($duration.TotalHours -ge 1) { 
                                "{0:D2}:{1:D2}:{2:D2}" -f $duration.Hours, $duration.Minutes, $duration.Seconds 
                            } else { 
                                "{0:D2}:{1:D2}" -f $duration.Minutes, $duration.Seconds
                            }
                            
                            Write-Host "  Duration: $durationStr"
                            Write-Host "  Size: $(Get-HumanReadableSize -Size $file.Length)"
                            
                            if ($videoStream) {
                                $videoCodec = $videoStream.codec_name
                                $resolution = "$($videoStream.width)x$($videoStream.height)"
                                Write-Host "  Video: $videoCodec ($resolution)"
                            }
                            
                            if ($audioStreams.Count -gt 0) {
                                Write-Host "  Audio Tracks: $($audioStreams.Count)"
                                foreach ($audio in $audioStreams) {
                                    $index = $audio.index
                                    $codec = $audio.codec_name
                                    $channels = $audio.channels
                                    Write-Host "    [$index] $codec ($channels channels)"
                                }
                            }
                            
                            if ($subtitleStreams.Count -gt 0) {
                                Write-Host "  Subtitle Tracks: $($subtitleStreams.Count)"
                                foreach ($sub in $subtitleStreams) {
                                    $index = $sub.index
                                    $codec = $sub.codec_name
                                    Write-Host "    [$index] $codec"
                                }
                            }
                            
                            Write-Host ""
                        }
                        
                        Write-Host ""
                        Write-ColoredHost "Press any key to return..." -ForegroundColor Yellow
                        [System.Console]::ReadKey() | Out-Null
                    }
                    '2' {
                        # Subtitle management submenu
                        Clear-Host
                        Show-Header
                        
                        Write-ColoredHost "Subtitle Management:" -ForegroundColor Yellow
                        Write-ColoredHost "-------------------" -ForegroundColor Yellow
                        Write-ColoredHost "1. Fix subtitle flags in all files" -ForegroundColor White
                        Write-ColoredHost "2. Return to Advanced Menu" -ForegroundColor Red
                        
                        $subChoice = Read-Host "Enter your choice"
                        
                        if ($subChoice -eq "1") {
                            $files = Get-InputFiles -scriptDir $scriptDir
                            foreach ($file in $files) {
                                if ($file.Extension -eq ".mkv") {
                                    Write-ColoredHost "Processing subtitle flags in $($file.Name)..." -ForegroundColor Cyan
                                    Update-SubtitleFlags -filePath $file.FullName
                                } else {
                                    Write-ColoredHost "Skipping $($file.Name) - not an MKV file" -ForegroundColor Yellow
                                }
                            }
                            
                            Write-Host ""
                            Write-ColoredHost "Subtitle processing completed" -ForegroundColor Green
                            Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
                            [System.Console]::ReadKey() | Out-Null
                        }
                    }
                    '3' {
                        # Cleanup temp files
                        Clear-Host
                        Show-Header
                        
                        $tempDir = Join-Path $env:TEMP "EncoderDownloads"
                        if (Test-Path $tempDir) {
                            Write-ColoredHost "Removing temporary files from $tempDir..." -ForegroundColor Cyan
                            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                            Write-ColoredHost "Temporary files removed successfully!" -ForegroundColor Green
                        } else {
                            Write-ColoredHost "No temporary files found." -ForegroundColor Yellow
                        }
                        
                        Write-Host ""
                        Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
                        [System.Console]::ReadKey() | Out-Null
                    }
                    'q' { break }
                    default {
                        Write-ColoredHost "Invalid choice. Please try again." -ForegroundColor Red
                        Start-Sleep -Seconds 1.5
                    }
                }
            } while ($advancedChoice.ToLower() -ne 'q')
        }
        '5' { Invoke-UpdateEncoders -CheckOnly}
        'q' {
            Write-ColoredHost "Exiting... Goodbye!" -ForegroundColor Green
            Start-Sleep 2
            return
        }
        default {
            Write-ColoredHost "Invalid choice. Please try again." -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-ColoredHost "Press any key to return to the menu..." -ForegroundColor Yellow
    Write-Host ""
    [System.Console]::ReadKey() | Out-Null
} while ($true)

# Add error handling and logging functions
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO",
        [switch]$NoConsole
    )
    
    if (-not $globalConfig -or $globalConfig.enableLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        
        # Log to file
        Add-Content -Path $logFile -Value $logEntry
        
        # Output to console if not suppressed
        if (-not $NoConsole) {
            $foregroundColor = switch ($Level) {
                "ERROR"   { "Red" }
                "WARNING" { "Yellow" }
                "SUCCESS" { "Green" }
                default   { "White" }
            }
            
            Write-ColoredHost $Message -ForegroundColor $foregroundColor
        }
    } elseif (-not $NoConsole) {
        # Still output to console if logging is disabled
        $foregroundColor = switch ($Level) {
            "ERROR"   { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            default   { "White" }
        }
        
        Write-ColoredHost $Message -ForegroundColor $foregroundColor
    }
}

function Handle-Error {
    param (
        [string]$ErrorMessage,
        [string]$Operation,
        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null,
        [switch]$Fatal
    )
    
    $detailedMessage = "Error during $Operation`: $ErrorMessage"
    
    # Add error record details if available
    if ($ErrorRecord) {
        $detailedMessage += "`nException Type: $($ErrorRecord.Exception.GetType().Name)"
        $detailedMessage += "`nException Message: $($ErrorRecord.Exception.Message)"
        $detailedMessage += "`nCategory: $($ErrorRecord.CategoryInfo.Category)"
        $detailedMessage += "`nActivity: $($ErrorRecord.CategoryInfo.Activity)"
        
        if ($globalConfig.verboseLogging) {
            $detailedMessage += "`nStack Trace:`n$($ErrorRecord.ScriptStackTrace)"
        }
    }
    
    # Log the error
    Write-Log -Message $detailedMessage -Level "ERROR" -NoConsole
    
    # User-friendly message to console
    Write-ColoredHost "Error during $Operation: $ErrorMessage" -ForegroundColor Red
    
    # Exit script if it's a fatal error
    if ($Fatal) {
        Write-ColoredHost "Fatal error occurred. Check the log file for details: $logFile" -ForegroundColor Red
        exit 1
    }
}

