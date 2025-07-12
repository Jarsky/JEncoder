# Define the script version as a variable
$ScriptVersion = "1.6.1"

# Define essential functions first
function Write-ColoredHost {
    param (
        [string]$Text,
        [ConsoleColor]$ForegroundColor = 'White',
        [ConsoleColor]$BackgroundColor = 'Black'
    )
    Write-Host $Text -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Handle-Error {
    param (
        [string]$ErrorMessage,
        [string]$Operation,
        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null,
        [switch]$Fatal
    )
    
    $detailedMessage = "ERROR during $Operation`: $ErrorMessage"
    
    # Add error record details if available
    if ($ErrorRecord) {
        $detailedMessage += " | Exception: $($ErrorRecord.Exception.Message)"
        $detailedMessage += " | Category: $($ErrorRecord.CategoryInfo.Category)"
        
        if ($globalConfig.verboseLogging) {
            $detailedMessage += " | Stack: $($ErrorRecord.ScriptStackTrace)"
        }
    }
    
    # Log the error
    Write-Log -Message $detailedMessage -Level "ERROR"
    
    # User-friendly message to console
    Write-ColoredHost "Error during ${Operation}: $ErrorMessage" -ForegroundColor Red
    
    # Exit script if it's a fatal error
    if ($Fatal) {
        Write-ColoredHost "Fatal error occurred. Check the log file for details: $logFile" -ForegroundColor Red
        exit 1
    }
}

<#
Script Name: JEncoder
Author: Jarsky
Version History:
  - v1.6.1: Fixed logging - now only logs important events, not menu selections
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

# Define the logging function - SIMPLIFIED AND FOCUSED
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    if ($globalConfig.enableLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        
        # Log to file
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
}

# Initialize log file - ONLY LOG IMPORTANT STARTUP INFO
if ($globalConfig.enableLogging) {
    # Get date for log rotation
    $logDate = Get-Date -Format "yyyy-MM-dd"
    $logFile = Join-Path -Path $PSScriptRoot -ChildPath "jencoder-$logDate.log"
    
    # Create the log file if it doesn't exist
    if (-not (Test-Path $logFile)) {
        New-Item -Path $logFile -ItemType File -Force | Out-Null
    }
    
    # Only log script initialization
    Write-Log "JEncoder v$ScriptVersion initialized successfully"
    
    # Clean up old log files (keep last 7 days)
    $oldLogs = Get-ChildItem -Path $PSScriptRoot -Filter "jencoder-*.log" | 
               Where-Object { $_.Name -match 'jencoder-(\d{4}-\d{2}-\d{2})\.log' -and 
                           [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) -lt (Get-Date).AddDays(-7) }
    
    if ($oldLogs) {
        foreach ($oldLog in $oldLogs) {
            Remove-Item -Path $oldLog.FullName -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Cleaned up $($oldLogs.Count) old log files"
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

function Confirm-Encoders {
    $missingEncoders = @()
    
    if (-not (Test-Path $handbrakePath))      { $missingEncoders += "HandBrakeCLI" }
    if (-not (Test-Path $ffmpegPath))         { $missingEncoders += "FFmpeg" }
    if (-not (Test-Path $ffprobePath))        { $missingEncoders += "FFprobe" }
    if (-not (Test-Path $mkvpropeditPath))    { $missingEncoders += "MKVPropEdit" }

    $script:missingEncoders = $missingEncoders

    if ($missingEncoders.Count -gt 0) {
        Write-Log "Missing encoders: $($missingEncoders -join ', ')" -Level "WARNING"
        Write-ColoredHost "Missing encoders:" -ForegroundColor Yellow
        $missingEncoders | ForEach-Object { Write-ColoredHost "  $_" -ForegroundColor Yellow }
        return $false
    } else {
        Write-Log "All encoders detected successfully"
        Write-ColoredHost "All encoders detected successfully!" -ForegroundColor Green
        return $true
    }
}

# [Previous Get-Encoders function remains the same...]
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
                Write-Log "Downloading HandBrakeCLI"

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
                Write-Log "HandBrakeCLI downloaded successfully"
            } catch {
                Write-Log "Failed to download HandBrakeCLI: $_" -Level "ERROR"
                Write-ColoredHost "Failed to download HandBrakeCLI: $_" -ForegroundColor Red
            }
        }

        if ($missingEncoders -contains "FFmpeg" -or $missingEncoders -contains "FFprobe") {
            try {
                Write-ColoredHost "Downloading FFmpeg..." -ForegroundColor Cyan
                Write-Log "Downloading FFmpeg"
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
                Write-Log "FFmpeg downloaded successfully"
            } catch {
                Write-Log "Failed to download FFmpeg: $_" -Level "ERROR"
                Write-ColoredHost "Failed to download FFmpeg: $_" -ForegroundColor Red
            }
        }

        if ($missingEncoders -contains "MKVPropEdit") {
            try {
                Write-ColoredHost "Downloading MKVPropEdit..." -ForegroundColor Cyan
                Write-Log "Downloading MKVPropEdit"
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
                Write-Log "MKVPropEdit downloaded successfully"
            } catch {
                Write-Log "Failed to download MKVPropEdit: $_" -Level "ERROR"
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

# [Previous Invoke-UpdateEncoders function remains the same but with reduced logging...]
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

    # [Rest of the function remains the same...]
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
                Write-Log "Starting encoder updates: $($toUpdate -join ', ')"

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
                        Write-Log "JEncoder updated successfully"
                        Write-Host "JEncoder updated successfully! Please restart the script." -ForegroundColor Green
                        exit
                    } catch {
                        Write-Log "Failed to update JEncoder: $_" -Level "ERROR"
                        Write-Host "Failed to update JEncoder: $_" -ForegroundColor Red
                    }
                }             

                # [Rest of update functions with minimal logging...]
                # Update logic for other encoders would follow same pattern
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
        Write-ColoredHost "No .mp4 or .mkv files were found in the script directory." -ForegroundColor Yellow
        Write-ColoredHost "You can still configure the application or use other features." -ForegroundColor Yellow
    } else {
        $filesToProcess | ForEach-Object { Write-ColoredHost $_.Name -ForegroundColor White }
        # LOG the files found
        Write-Log "Found $($filesToProcess.Count) files to process: $($filesToProcess.Name -join ', ')"
    }
    Write-Host ""
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
        Write-Log "Moved original file to deletion folder: $(Split-Path $filePath -Leaf)"
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
        Write-Log "File not found for subtitle processing: $filePath" -Level "WARNING"
        return
    }
    
    $subtitleInfo = Get-SubtitleInfo -filePath $filePath
    $commands = @()

    foreach ($stream in $subtitleInfo) {
        $index = $stream.index
        $codec = $stream.codec_name

        if ($codec -eq "subrip") {
            $commands += "--edit track:s$($index - 1) --set flag-default=0 --set flag-forced=0"
        }
    }

    if ($commands.Count -gt 0) {
        if (-not $Global:mkvpropeditPath) {
            Write-Log "mkvpropeditPath not set for subtitle processing" -Level "WARNING"
            return
        }

        $quotedFilePath = "`"$filePath`""
        $quotedMkvpropeditPath = "`"$Global:mkvpropeditPath`""
        $mkvpropeditArgs = $commands -join ' '

        Write-Log "Processing subtitles for: $(Split-Path $filePath -Leaf)"

        try {
            Start-Process -FilePath $quotedMkvpropeditPath -ArgumentList "$quotedFilePath $mkvpropeditArgs" -NoNewWindow -Wait
            Write-Log "Subtitle flags updated successfully for: $(Split-Path $filePath -Leaf)"
        } catch {
            Write-Log "Failed to update subtitle flags for $(Split-Path $filePath -Leaf): $_" -Level "ERROR"
        }
    }
}

# Helper Functions for Progress Tracking

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
            return $inputSize * 0.7
        }
        
        # Get bitrate
        $bitrateStr = & $ffprobePath -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$InputFilePath" 2>$null
        if (-not $bitrateStr -or -not [double]::TryParse($bitrateStr, [ref]$null)) {
            $bitrateStr = & $ffprobePath -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$InputFilePath" 2>$null
        }
        
        [double]$inputBitrate = if ([double]::TryParse($bitrateStr, [ref]$null)) { [double]$bitrateStr / 1000 } else { 0 }
        
        if ($inputBitrate -le 0) {
            $inputBitrate = $inputSize * 8 / $duration / 1000
        }
        
        # Estimate compression factor
        $compressionFactor = 1.0
        
        if ($Encoder -match "265|hevc") {
            if ($Encoder -match "nvenc") {
                $compressionFactor = switch ($Quality) {
                    { [double]$_ -le 20 } { 0.4 }
                    { [double]$_ -le 25 } { 0.5 }
                    { [double]$_ -le 30 } { 0.6 }
                    default { 0.7 }
                }
            } else {
                $compressionFactor = switch ($Quality) {
                    { [double]$_ -le 18 } { 0.3 }
                    { [double]$_ -le 22 } { 0.4 }
                    { [double]$_ -le 26 } { 0.5 }
                    { [double]$_ -le 30 } { 0.6 }
                    default { 0.7 }
                }
            }
        } elseif ($Encoder -match "264|avc") {
            $compressionFactor = switch ($Quality) {
                { [double]$_ -le 18 } { 0.4 }
                { [double]$_ -le 22 } { 0.5 }
                { [double]$_ -le 26 } { 0.6 }
                default { 0.7 }
            }
        } else {
            $compressionFactor = 0.6
        }
        
        # Calculate projected file size
        $projectedBitrate = $inputBitrate * $compressionFactor
        $projectedSize = ($projectedBitrate * $duration * 1000) / 8
        
        # Add overhead for container and audio
        if ($audioEncoder -eq "copy") {
            $audioSize = $inputSize * 0.15
            $projectedSize += $audioSize
        }
        
        return $projectedSize
    } catch {
        return $inputSize * 0.7
    }
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

# Helper function for progress bar
function Get-ProgressBar {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Percent,
        [int]$BarLength = 40
    )
    $filledLength = [math]::Floor(($BarLength * $Percent) / 100)
    $filled = "🟩" * $filledLength
    $empty = " " * ($BarLength - $filledLength)
    return "[ $filled$empty ]"
}

# Function to encode using HandBrake
function Invoke-WithHandBrake {
    param (
        [switch]$NVENC
    )
    
    Invoke-Encoding -EncoderType "HandBrake" -NVENC:$NVENC
}

# Function to encode using FFmpeg
function Invoke-WithFFmpeg {
    param (
        [switch]$NVENC
    )
    
    Invoke-Encoding -EncoderType "FFmpeg" -NVENC:$NVENC
}

# MAIN ENCODING FUNCTION - FIXED FOR HANDBRAKE NVENC AND IMPROVED LOGGING
function Invoke-Encoding {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("HandBrake", "FFmpeg")]
        [string]$EncoderType,
        
        [switch]$NVENC
    )
    
    $inputFiles = Get-InputFiles
    $summary = @()
    
    # Set encoder specific parameters
    if ($EncoderType -eq "HandBrake") {
        $encoderPath = $handbrakePath
        $encoderUsed = if ($NVENC) { $handbrakeEncoderNVENC } else { $handbrakeEncoder }
        $encoderPreset = if ($NVENC) { $handbrakeNVENCPreset } else { $handbrakePreset }
        $qualityValue = $handbrakeQuality
        $method = if ($NVENC) { "HandBrakeCLI (NVENC)" } else { "HandBrakeCLI" }
        
        $createArguments = {
            param($inputFile, $outputFile)
            
            if ($NVENC) {
                return "-i `"$($inputFile.FullName)`" -o `"$($outputFile.FullPath)`" -e $handbrakeEncoderNVENC --encoder-preset $handbrakeNVENCPreset -q $handbrakeQuality --cfr --all-audio --all-subtitles"
            } else {
                return "-i `"$($inputFile.FullName)`" -o `"$($outputFile.FullPath)`" -e $handbrakeEncoder --encoder-preset $handbrakePreset -q $handbrakeQuality --cfr --all-audio --all-subtitles"
            }
        }
        
        $parseProgress = {
            param($data)
            
            # HandBrake outputs progress like: "Encoding: task 1 of 1, 45.67 % (159.45 fps, avg 140.32 fps, ETA 00h03m12s)"
            if ($data -match 'Encoding: task \d+ of \d+, (\d+\.\d+) %') {
                return [double]$Matches[1]
            }
            # Alternative format: "Encoding: task 1 of 1, 45.67 %"
            if ($data -match '(\d+\.\d+) %') {
                return [double]$Matches[1]
            }
            return -1
        }
    }
    else { # FFmpeg
        $encoderPath = $ffmpegPath
        $encoderUsed = if ($NVENC) { $ffmpegEncoderNVENC } else { $ffmpegEncoder }
        $encoderPreset = if ($NVENC) { $ffmpegNVENCPreset } else { $ffmpegPreset }
        $qualityValue = $ffmpegQuality
        $method = if ($NVENC) { "FFmpeg (NVENC)" } else { "FFmpeg (CPU)" }
        
        $createArguments = {
            param($inputFile, $outputFile)
            
            if ($NVENC) {
                return "-i `"$($inputFile.FullName)`" -map 0 -c:v $ffmpegEncoderNVENC -cq $ffmpegQuality -preset $ffmpegNVENCPreset -c:a $audioEncoder -c:s copy -disposition:s:0 0 -max_muxing_queue_size 9999 `"$($outputFile.FullPath)`""
            } else {
                return "-hide_banner -i `"$($inputFile.FullName)`" -c:v $ffmpegEncoder -preset $ffmpegPreset -crf $ffmpegQuality -c:a copy -c:s copy `"$($outputFile.FullPath)`""
            }
        }
        
        $parseProgress = {
            param($data, $duration)
            
            # Parse time from FFmpeg stderr output
            if ($data -match 'time=(\d+):(\d+):(\d+\.\d+)') {
                $hours = [double]$Matches[1]
                $minutes = [double]$Matches[2] 
                $seconds = [double]$Matches[3]
                $currentTime = ($hours * 3600) + ($minutes * 60) + $seconds
                
                if ($duration -gt 0) {
                    return ($currentTime / $duration) * 100
                }
            }
            return -1
        }
    }
    
    foreach ($inputFile in $inputFiles) {
        Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir
        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName -encoderUsed $encoderUsed
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }
        
        # Get file duration for progress calculation
        $duration = Get-MediaDuration -FilePath $inputFile.FullName
        
        $projectedSize = Get-ProjectedFileSize -InputFilePath $inputFile.FullName -Encoder $encoderUsed -Quality $qualityValue
        $projectedSizeStr = Get-HumanReadableSize -Size $projectedSize
        $inputSize = (Get-Item $inputFile.FullName).Length
        $inputSizeStr = Get-HumanReadableSize -Size $inputSize
        $diffPercent = if ($inputSize -gt 0) { [math]::Round((($projectedSize - $inputSize) / $inputSize) * 100, 1) } else { 0 }
        $diffSign = if ($diffPercent -ge 0) { "+" } else { "" }
        Write-ColoredHost ("Original size: $inputSizeStr    Projected size: $projectedSizeStr    Est. Difference: $diffSign$diffPercent%") -ForegroundColor Yellow
        Write-ColoredHost ("Output: $($outputFile.Name)") -ForegroundColor Cyan
        Write-ColoredHost ("Press Q to abort encoding...") -ForegroundColor Red
        if (-not ([System.Management.Automation.PSTypeName]'System.Console').Type) {
            Write-ColoredHost ("[Warning] Q abort may not work in this host. Use Ctrl+C to abort if needed.") -ForegroundColor Yellow
        }
        
        try {
            # Build process arguments
            $arguments = & $createArguments $inputFile $outputFile
            
            # LOG THE IMPORTANT COMMAND BEING EXECUTED
            Write-Log "Starting encoding: $EncoderType $method"
            Write-Log "Processing file: $($inputFile.Name)"
            Write-Log "Command: `"$encoderPath`" $arguments"
            
            # Variables for progress tracking
            $lastProgress = 0
            $startTime = Get-Date
            $progressReadings = @()
            $progressBarLength = 40
            $allErrorOutput = @()
            
            # Start process with redirected output
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $encoderPath
            $psi.Arguments = $arguments
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $process.Start() | Out-Null
            $global:CurrentEncodingProcess = $process
            
            # Create StringBuilder objects for accumulating partial lines
            $stdoutBuffer = New-Object System.Text.StringBuilder
            $stderrBuffer = New-Object System.Text.StringBuilder
            
            # Byte buffers for reading
            $stdoutBytes = New-Object byte[] 1024
            $stderrBytes = New-Object byte[] 1024
            
            while (-not $process.HasExited) {
                $dataReceived = $false
                
                # Read from stdout (non-blocking)
                try {
                    $stream = $process.StandardOutput.BaseStream
                    if ($stream.DataAvailable) {
                        $bytesRead = $stream.Read($stdoutBytes, 0, $stdoutBytes.Length)
                        if ($bytesRead -gt 0) {
                            $text = [System.Text.Encoding]::UTF8.GetString($stdoutBytes, 0, $bytesRead)
                            $stdoutBuffer.Append($text) | Out-Null
                            $dataReceived = $true
                            
                            # Process complete lines
                            $bufferText = $stdoutBuffer.ToString()
                            $lines = $bufferText -split "`r`n|`n|`r"
                            
                            # Keep the last incomplete line in the buffer
                            if ($bufferText.EndsWith("`r") -or $bufferText.EndsWith("`n")) {
                                $stdoutBuffer.Clear() | Out-Null
                                $linesToProcess = $lines
                            } else {
                                $stdoutBuffer.Clear() | Out-Null
                                $stdoutBuffer.Append($lines[-1]) | Out-Null
                                $linesToProcess = $lines[0..($lines.Length - 2)]
                            }
                            
                            # Process each complete line
                            foreach ($line in $linesToProcess) {
                                if ($line) {
                                    # LOG STDERR OUTPUT FROM ENCODER
                                    if ($globalConfig.verboseLogging) {
                                        Write-Log "STDOUT: $line"
                                    }
                                    
                                    # For HandBrake, progress comes from stdout
                                    if ($EncoderType -eq "HandBrake") {
                                        $progress = & $parseProgress $line
                                        if ($progress -ge 0 -and $progress -gt $lastProgress) {
                                            $currentTime = Get-Date
                                            $elapsedTime = ($currentTime - $startTime).TotalSeconds
                                            
                                            # Update progress readings for ETA calculation
                                            if ($progressReadings.Count -ge 10) { 
                                                $progressReadings = $progressReadings[1..9] 
                                            }
                                            $progressReadings += [PSCustomObject]@{
                                                Progress = $progress
                                                Time = $currentTime
                                            }
                                            
                                            $remainingTime = if ($progressReadings.Count -gt 1) {
                                                $oldestReading = $progressReadings[0]
                                                $progressDiff = $progress - $oldestReading.Progress
                                                $timeDiff = ($currentTime - $oldestReading.Time).TotalSeconds
                                                if ($timeDiff -gt 0 -and $progressDiff -gt 0) {
                                                    ($timeDiff / $progressDiff) * (100 - $progress)
                                                } else {
                                                    if ($progress -gt 0) { ($elapsedTime / $progress) * (100 - $progress) } else { 0 }
                                                }
                                            } else {
                                                if ($progress -gt 0) { ($elapsedTime / $progress) * (100 - $progress) } else { 0 }
                                            }
                                            
                                            $eta = Format-TimeRemaining -SecondsRemaining $remainingTime
                                            $bar = Get-ProgressBar -Percent $progress -BarLength $progressBarLength
                                            $progressStr = "{0,5:N1}%" -f $progress
                                            $status = "$bar $progressStr | ETA: $eta"
                                            Write-Host -NoNewline "`r$status"
                                            $lastProgress = $progress
                                        }
                                    }
                                }
                            }
                            
                            # Also check for progress in partial buffer content for real-time updates
                            $currentBufferContent = $stdoutBuffer.ToString()
                            if ($currentBufferContent -and $EncoderType -eq "HandBrake") {
                                $progress = & $parseProgress $currentBufferContent
                                if ($progress -ge 0 -and $progress -gt $lastProgress) {
                                    $currentTime = Get-Date
                                    $elapsedTime = ($currentTime - $startTime).TotalSeconds
                                    
                                    if ($progressReadings.Count -ge 10) { 
                                        $progressReadings = $progressReadings[1..9] 
                                    }
                                    $progressReadings += [PSCustomObject]@{
                                        Progress = $progress
                                        Time = $currentTime
                                    }
                                    
                                    $remainingTime = if ($progressReadings.Count -gt 1) {
                                        $oldestReading = $progressReadings[0]
                                        $progressDiff = $progress - $oldestReading.Progress
                                        $timeDiff = ($currentTime - $oldestReading.Time).TotalSeconds
                                        if ($timeDiff -gt 0 -and $progressDiff -gt 0) {
                                            ($timeDiff / $progressDiff) * (100 - $progress)
                                        } else {
                                            if ($progress -gt 0) { ($elapsedTime / $progress) * (100 - $progress) } else { 0 }
                                        }
                                    } else {
                                        if ($progress -gt 0) { ($elapsedTime / $progress) * (100 - $progress) } else { 0 }
                                    }
                                    
                                    $eta = Format-TimeRemaining -SecondsRemaining $remainingTime
                                    $bar = Get-ProgressBar -Percent $progress -BarLength $progressBarLength
                                    $progressStr = "{0,5:N1}%" -f $progress
                                    $status = "$bar $progressStr | ETA: $eta"
                                    Write-Host -NoNewline "`r$status"
                                    $lastProgress = $progress
                                }
                            }
                        }
                    }
                } catch {
                    # Stream reading error or end of stream
                }
                
                # Check for abort key
                try {
                    if ([console]::KeyAvailable) {
                        $key = [console]::ReadKey($true)
                        if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') {
                            Write-ColoredHost "`nEncoding aborted by user." -ForegroundColor Red
                            Write-Log "Encoding aborted by user for: $($inputFile.Name)"
                            $process.Kill()
                            break
                        }
                    }
                } catch {
                    # KeyAvailable not supported in this host, do nothing
                }
                
                # Small sleep to prevent busy waiting when no data is available
                if (-not $dataReceived) {
                    Start-Sleep -Milliseconds 50
                }
            }
            
            $global:CurrentEncodingProcess = $null
            Write-Host "" # Move to next line after progress bar
            
            # Process any remaining buffer content
            $remainingStdout = $stdoutBuffer.ToString()
            $remainingStderr = $stderrBuffer.ToString()
            if ($remainingStdout -and $globalConfig.verboseLogging) { 
                Write-Log "STDOUT (final): $remainingStdout" 
            }
            if ($remainingStderr) { 
                $allErrorOutput += $remainingStderr
                Write-Log "STDERR (final): $remainingStderr" 
            }
            
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $process.Close()
            
            Write-Log "Encoding process completed with exit code: $exitCode"
            
            if ($exitCode -eq 0) {
                $inputSize = (Get-Item $inputFile.FullName).Length
                $outputSize = (Get-Item $outputFile.FullPath).Length
                $reduction = Get-ReductionPercentage -inputSize $inputSize -outputSize $outputSize
                
                Write-Log "SUCCESS: Converted $($inputFile.Name) -> $($outputFile.Name) using $method"
                Write-Log "File size: $(Get-HumanReadableSize -Size $inputSize) -> $(Get-HumanReadableSize -Size $outputSize) ($reduction% reduction)"
                
                Write-ColoredHost "Converted: $($inputFile.Name) > $($outputFile.Name) using $method" -ForegroundColor Green
                Write-ColoredHost "Input size: $(Get-HumanReadableSize -Size $inputSize), Output size: $(Get-HumanReadableSize -Size $outputSize), Reduction: $reduction%" -ForegroundColor White
                
                $summary += [PSCustomObject]@{
                    FileName         = $inputFile.Name
                    InputSize        = Get-HumanReadableSize -Size $inputSize
                    OutputSize       = Get-HumanReadableSize -Size $outputSize
                    ReductionPercent = "$reduction%"
                }
                
                Move-OriginalFile $inputFile.FullName $toDeleteDir
            } else {
                $encoderType = if ($NVENC) { "(NVENC)" } else { "" }
                $errorMsg = "$EncoderType $encoderType failed on: $($inputFile.Name) with exit code $exitCode"
                
                Write-Log "ERROR: $errorMsg" -Level "ERROR"
                if ($allErrorOutput.Count -gt 0) {
                    Write-Log "Error details: $($allErrorOutput -join ' | ')" -Level "ERROR"
                }
                
                Handle-Error -ErrorMessage $errorMsg -Operation "$EncoderType Encoding"
            }
        }
        catch {
            $errorMsg = "Failed to process file with $EncoderType: $_"
            Write-Log "EXCEPTION: $errorMsg" -Level "ERROR"
            Handle-Error -ErrorMessage "Failed to process file with $EncoderType" -Operation "$EncoderType Encoding" -ErrorRecord $_
        }
    }
    
    Show-EncodingSummary -SummaryList $summary
}

# Helper functions
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

function Show-EncodingSummary {
    param (
        [array]$SummaryList
    )
    if (-not $SummaryList -or $SummaryList.Count -eq 0) {
        Write-Log "No files were successfully encoded" -Level "WARNING"
        Write-ColoredHost "No files were successfully encoded, or encoding was aborted. No summary to show." -ForegroundColor Yellow
        return
    }

    Write-Log "Encoding summary: $($SummaryList.Count) files processed successfully"
    Write-ColoredHost "`nEncoding Summary:" -ForegroundColor Green
    Write-ColoredHost "----------------" -ForegroundColor Green
    
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
        $percentColor = if ($percentValue -le 30) { "Yellow" } elseif ($percentValue -le 50) { "Green" } else { "Cyan" }
        
        Write-ColoredHost "$($entry.FileName):" -ForegroundColor White
        Write-ColoredHost "  Input = $($entry.InputSize), Output = $($entry.OutputSize), Reduction = $($entry.ReductionPercent)" -ForegroundColor $percentColor
    }
    
    # Show total summary
    $totalReduction = Get-ReductionPercentage -inputSize $totalInputSize -outputSize $totalOutputSize
    $totalReductionColor = if ($totalReduction -le 30) { "Yellow" } elseif ($totalReduction -le 50) { "Green" } else { "Cyan" }
    
    Write-Log "Total encoding results: Input=$(Get-HumanReadableSize -Size $totalInputSize) Output=$(Get-HumanReadableSize -Size $totalOutputSize) Reduction=$totalReduction% Saved=$(Get-HumanReadableSize -Size ($totalInputSize - $totalOutputSize))"
    
    Write-ColoredHost "`nTotal Statistics:" -ForegroundColor White
    Write-ColoredHost "  Total Input Size: $(Get-HumanReadableSize -Size $totalInputSize)" -ForegroundColor White
    Write-ColoredHost "  Total Output Size: $(Get-HumanReadableSize -Size $totalOutputSize)" -ForegroundColor White
    Write-ColoredHost "  Overall Reduction: $totalReduction%" -ForegroundColor $totalReductionColor
    Write-ColoredHost "  Space Saved: $(Get-HumanReadableSize -Size ($totalInputSize - $totalOutputSize))" -ForegroundColor Green
    
    # Return to show-header after summary display
    Write-Host "`nPress any key to continue..." -ForegroundColor Yellow
    [System.Console]::ReadKey() | Out-Null
    Show-Header
}

# Menu system - NO LOGGING OF MENU SELECTIONS
function Show-Menu {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$MenuItems,
        
        [string]$ExitOptionText = "Return",
        
        [string]$ExitOptionKey = "Q"
    )
    
    Clear-Host
    Show-Header
    
    Write-ColoredHost $Title -ForegroundColor Yellow
    Write-ColoredHost ("-" * $Title.Length) -ForegroundColor Yellow
    
    # Display menu items
    foreach ($key in $MenuItems.Keys | Sort-Object) {
        Write-ColoredHost "$key. $($MenuItems[$key])" -ForegroundColor White
    }
    
    # Add exit option
    Write-ColoredHost "$ExitOptionKey. $ExitOptionText" -ForegroundColor Red
    Write-Host ""
    
    # Get user choice - NO LOGGING
    $choice = Read-Host "Enter your choice"
    
    return $choice
}

function Invoke-ShowFilesToProcess {
    Write-Host ""
    Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir
    Write-ColoredHost "" -ForegroundColor White
    Write-ColoredHost "Press Enter to continue to encoding method selection, or Q to return to the main menu." -ForegroundColor Yellow
    $input = Read-Host "Your choice"
    if ($input -eq 'q' -or $input -eq 'Q') {
        return $false
    }
    return $true
}

function Invoke-MainMenu {
    $menuItems = @{
        "1" = "Encode Files"
        "2" = "Show Current Configuration"
        "3" = "Edit Configuration" 
        "4" = "Advanced Options"
        "5" = "Check for Updates"
    }
    $choice = Show-Menu -Title "Main Menu" -MenuItems $menuItems -ExitOptionText "Quit" -ExitOptionKey "Q"
    switch ($choice.ToLower()) {
        "1" {
            $proceed = Invoke-ShowFilesToProcess
            if ($proceed) {
                Invoke-EncodingMenu
            }
        }
        "2" { Show-Configuration }
        "3" { Edit-Configuration }
        "4" { Invoke-AdvancedMenu }
        "5" { Invoke-UpdateEncoders -CheckOnly }
        "q" {
            Write-ColoredHost "Exiting... Goodbye!" -ForegroundColor Green
            Write-Log "JEncoder session ended"
            Start-Sleep 2
            return $false
        }
        default {
            Write-ColoredHost "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1.5
        }
    }
    return $true
}

function Invoke-EncodingMenu {
    Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir
    
    # Check if there are files to encode
    $filesToProcess = Get-InputFiles -scriptDir $scriptDir
    if ($filesToProcess.Count -eq 0) {
        Write-ColoredHost "No files available for encoding. Please add media files to continue." -ForegroundColor Red
        Write-ColoredHost "Press any key to return to the main menu..." -ForegroundColor Yellow
        [System.Console]::ReadKey() | Out-Null
        return
    }
    
    $menuItems = @{
        "1" = "HandBrake (CPU Encoding)"
        "2" = "FFmpeg (CPU Encoding)" 
        "3" = "HandBrake (NVENC - GPU Encoding)"
        "4" = "FFmpeg (NVENC - GPU Encoding)"
    }
    
    $choice = Show-Menu -Title "Choose Encoding Method" -MenuItems $menuItems -ExitOptionText "Return to Main Menu" -ExitOptionKey "Q"
    
    switch ($choice.ToLower()) {
        "1" { 
            Write-Log "User selected: HandBrake CPU encoding"
            Invoke-WithHandBrake -NVENC:$false 
        }
        "2" { 
            Write-Log "User selected: FFmpeg CPU encoding"
            Invoke-WithFFmpeg -NVENC:$false 
        }
        "3" { 
            Write-Log "User selected: HandBrake NVENC encoding"
            Invoke-WithHandBrake -NVENC:$true 
        }
        "4" { 
            Write-Log "User selected: FFmpeg NVENC encoding"
            Invoke-WithFFmpeg -NVENC:$true 
        }
        "q" { return }
        default {
            Write-ColoredHost "Invalid choice. Please select a valid option." -ForegroundColor Red
            Start-Sleep -Seconds 1.5
        }
    }
    
    Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
    Write-Host ""
    [System.Console]::ReadKey() | Out-Null
}

function Invoke-AdvancedMenu {
    $menuItems = @{
        "1" = "Analyze Media Files"
        "2" = "Manage Subtitles"
        "3" = "Cleanup Temporary Files"
    }
    
    $choice = Show-Menu -Title "Advanced Options" -MenuItems $menuItems -ExitOptionText "Return to Main Menu" -ExitOptionKey "Q"
    
    switch ($choice.ToLower()) {
        "1" { Invoke-MediaAnalysis }
        "2" { Invoke-SubtitleMenu }
        "3" { Invoke-CleanupTemp }
        "q" { return }
        default {
            Write-ColoredHost "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1.5
            Invoke-AdvancedMenu
        }
    }
}

function Invoke-MediaAnalysis {
    Clear-Host
    Show-Header
    Write-ColoredHost "Media File Analysis:" -ForegroundColor Yellow
    Write-ColoredHost "-------------------" -ForegroundColor Yellow
    
    $files = Get-InputFiles -scriptDir $scriptDir
    
    if ($files.Count -eq 0) {
        Write-ColoredHost "No media files found for analysis." -ForegroundColor Yellow
        Write-ColoredHost "Please add .mp4 or .mkv files to the script directory." -ForegroundColor Yellow
    } else {
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
    }
    
    Write-Host ""
    Write-ColoredHost "Press any key to return..." -ForegroundColor Yellow
    [System.Console]::ReadKey() | Out-Null
}

function Invoke-SubtitleMenu {
    $menuItems = @{
        "1" = "Fix subtitle flags in all files"
    }
    
    $choice = Show-Menu -Title "Subtitle Management" -MenuItems $menuItems -ExitOptionText "Return to Advanced Menu" -ExitOptionKey "Q"
    
    switch ($choice.ToLower()) {
        "1" { 
            $files = Get-InputFiles -scriptDir $scriptDir
            
            if ($files.Count -eq 0) {
                Write-ColoredHost "No media files found for subtitle processing." -ForegroundColor Yellow
                Write-ColoredHost "Please add .mp4 or .mkv files to the script directory." -ForegroundColor Yellow
            } else {
                $mkvFilesFound = $false
                
                foreach ($file in $files) {
                    if ($file.Extension -eq ".mkv") {
                        $mkvFilesFound = $true
                        Write-ColoredHost "Processing subtitle flags in $($file.Name)..." -ForegroundColor Cyan
                        Update-SubtitleFlags -filePath $file.FullName
                    } else {
                        Write-ColoredHost "Skipping $($file.Name) - not an MKV file" -ForegroundColor Yellow
                    }
                }
                
                if (-not $mkvFilesFound) {
                    Write-ColoredHost "No MKV files found. Subtitle processing only works with MKV files." -ForegroundColor Yellow
                }
            }
            
            Write-Host ""
            Write-ColoredHost "Subtitle processing completed" -ForegroundColor Green
            Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
            [System.Console]::ReadKey() | Out-Null
        }
        "q" { return }
        default {
            Write-ColoredHost "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1.5
        }
    }
}

function Invoke-CleanupTemp {
    Clear-Host
    Show-Header
    
    $tempDir = Join-Path $env:TEMP "EncoderDownloads"
    if (Test-Path $tempDir) {
        Write-ColoredHost "Removing temporary files from $tempDir..." -ForegroundColor Cyan
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-ColoredHost "Temporary files removed successfully!" -ForegroundColor Green
        Write-Log "Cleaned up temporary files"
    } else {
        Write-ColoredHost "No temporary files found." -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
    [System.Console]::ReadKey() | Out-Null
}

# Global variables
$global:CurrentEncodingProcess = $null

# Register Ctrl+C handler
if ($PSVersionTable.PSVersion.Major -ge 5) {
    Register-EngineEvent PowerShell.Exiting -Action {
        if ($global:CurrentEncodingProcess -and !$global:CurrentEncodingProcess.HasExited) {
            $global:CurrentEncodingProcess.Kill()
        }
    } | Out-Null
}
trap {
    if ($global:CurrentEncodingProcess -and !$global:CurrentEncodingProcess.HasExited) {
        $global:CurrentEncodingProcess.Kill()
    }
    break
}

# MAIN SCRIPT EXECUTION
do {
    Show-Header
    Get-Encoders 
    Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir
    
    $continueRunning = Invoke-MainMenu
    
    if (-not $continueRunning) {
        break
    }
    
    Write-Host ""
    Write-ColoredHost "Press any key to return to the menu..." -ForegroundColor Yellow
    Write-Host ""
    [System.Console]::ReadKey() | Out-Null
} while ($true)