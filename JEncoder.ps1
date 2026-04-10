# Define the script version as a variable
$ScriptVersion = "1.6.0"

<#
Script Name: JEncoder
Author: Jarsky
Version History:
  - v1.6.0: Fixed bugs, eliminated code duplication, added custom inline progress bars.
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
- Provides detailed feedback and custom inline progress bars during encoding.
- Option to move original files to a "to_be_deleted" folder after processing.

.FUNCTIONS
- Show-Header: Displays a formatted header in the console.
- Open-Config: Reads the configuration file and loads settings (backfills missing keys from defaults).
- Save-Config: Saves the current settings back to the configuration file.
- Show-Configuration: Displays the current configuration settings in the console.
- Edit-Configuration: Allows users to update configuration settings interactively.
- Confirm-Encoders: Verifies if the required encoding tools are available.
- Get-Encoders: Downloads and installs any missing encoders (runs once at startup).
- Save-HandBrakeCLI / Save-FFmpegTools / Save-MKVPropEdit: Shared download helpers.
- Write-ColoredHost: Outputs colored text to the console.
- Write-ProgressBar: Draws a custom inline progress bar that updates in place.
- Invoke-EncoderWithProgress: Runs an encoder process and drives the progress bar.

.CONFIGURATION OPTIONS
- Encoding quality settings for HandBrakeCLI and FFmpeg.
- Directory paths for output, deletion, and encoders.
- Options for handling spaces in filenames, fixing subtitles, and moving original files post-processing.

.NOTES
- Ensure the required encoders (HandBrakeCLI, FFmpeg, MKVPropEdit) are available in the `encoders`
  folder or the script will attempt to download them automatically.
- The version number is defined as `$ScriptVersion` at the start of the script for easy management.
#>


### VARIABLES ###

# Config File and Default Config
$configFile = Join-Path -Path $PSScriptRoot -ChildPath "config.ini"

$defaultConfig = [ordered]@{
    replaceSpaces         = $false
    fixSubtitles          = $false
    outputDir             = "output"
    renameOutputFile      = $true
    toDeleteDir           = "to_be_deleted"
    deleteOriginals       = $true
    handbrakeEncoder      = "x265"
    handbrakePreset       = "medium"
    handbrakeEncoderNVENC = "nvenc_h265"
    handbrakeNVENCPreset  = "default"
    handbrakeQuality      = "21"
    ffmpegEncoder         = "libx265"
    ffmpegPreset          = "medium"
    ffmpegEncoderNVENC    = "hevc_nvenc"
    ffmpegNVENCPreset     = "default"
    ffmpegQuality         = "18"
    audioEncoder          = "copy"
    skipExisting          = $true
}


### CONFIG FUNCTIONS ###

function Open-Config {
    # Seed with all defaults first so missing keys are always present
    $configHashtable = [ordered]@{}
    foreach ($key in $defaultConfig.Keys) {
        $configHashtable[$key] = $defaultConfig[$key]
    }

    if (Test-Path $configFile) {
        $ini = Get-Content $configFile | Where-Object { $_ -match "=" }
        foreach ($line in $ini) {
            $parts = $line -split '=', 2
            $key   = $parts[0].Trim()
            $val   = $parts[1].Trim()
            if ($defaultConfig.Keys -contains $key) {
                if ($defaultConfig[$key] -is [bool]) {
                    $configHashtable[$key] = ($val -ieq 'True')
                } else {
                    try {
                        $configHashtable[$key] = [Convert]::ChangeType($val, $defaultConfig[$key].GetType())
                    } catch {
                        Write-Warning "Invalid config value for '$key': '$val'. Using default."
                        $configHashtable[$key] = $defaultConfig[$key]
                    }
                }
            }
        }
    } else {
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
    $globalConfig  = Open-Config
    $keys          = [string[]]($defaultConfig.Keys)
    $selectedIndex = 0

    while ($true) {
        Clear-Host
        Show-Header
        Write-Host "  Edit Configuration" -ForegroundColor Yellow
        Write-Host "  ------------------" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  UP/DOWN: navigate   SPACE/ENTER: toggle or edit   S: save   Q: discard" -ForegroundColor DarkGray
        Write-Host ""

        for ($i = 0; $i -lt $keys.Length; $i++) {
            $k       = $keys[$i]
            $val     = $globalConfig[$k]
            $default = $defaultConfig[$k]
            $isBool  = $default -is [bool]

            $valStr = if ($isBool) {
                if ([bool]$val) { "[ ON]" } else { "[OFF]" }
            } else { "$val" }

            $prefix = if ($i -eq $selectedIndex) { "> " } else { "  " }
            $line   = "  {0}{1,-26} {2,-22} (default: {3})" -f $prefix, $k, $valStr, $default

            if ($i -eq $selectedIndex) {
                Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
            } elseif ($isBool -and [bool]$val) {
                Write-Host $line -ForegroundColor Green
            } else {
                Write-Host $line -ForegroundColor White
            }
        }

        Write-Host ""
        $keyInfo = [Console]::ReadKey($true)

        switch ($keyInfo.Key) {
            ([ConsoleKey]::UpArrow) {
                if ($selectedIndex -gt 0) { $selectedIndex-- }
            }
            ([ConsoleKey]::DownArrow) {
                if ($selectedIndex -lt ($keys.Length - 1)) { $selectedIndex++ }
            }
            ([ConsoleKey]::Spacebar) {
                $k = $keys[$selectedIndex]
                if ($defaultConfig[$k] -is [bool]) {
                    $globalConfig[$k] = -not [bool]$globalConfig[$k]
                }
            }
            ([ConsoleKey]::Enter) {
                $k = $keys[$selectedIndex]
                if ($defaultConfig[$k] -is [bool]) {
                    $globalConfig[$k] = -not [bool]$globalConfig[$k]
                } else {
                    Write-Host ("  New value for '{0}' (current: '{1}'): " -f $k, $globalConfig[$k]) -NoNewline -ForegroundColor Cyan
                    $newVal = Read-Host
                    if ($newVal -ne "") {
                        try {
                            $globalConfig[$k] = [Convert]::ChangeType($newVal, $defaultConfig[$k].GetType())
                        } catch {
                            Write-Host "  Invalid value, keeping current." -ForegroundColor Red
                            Start-Sleep -Milliseconds 1000
                        }
                    }
                }
            }
            ([ConsoleKey]::Escape) { return }
            default {
                if ($keyInfo.KeyChar -eq 's' -or $keyInfo.KeyChar -eq 'S') {
                    Save-Config $globalConfig
                    $script:globalConfig = $globalConfig
                    foreach ($k in $globalConfig.Keys) {
                        Set-Variable -Name $k -Value $globalConfig[$k] -Scope Global
                    }
                    Write-Host "  Configuration saved." -ForegroundColor Green
                    Start-Sleep -Milliseconds 1000
                    return
                }
                if ($keyInfo.KeyChar -eq 'q' -or $keyInfo.KeyChar -eq 'Q') { return }
            }
        }
    }
}

# Load config and expose keys as global variables
$globalConfig = Open-Config
foreach ($key in $globalConfig.Keys) {
    Set-Variable -Name $key -Value $globalConfig[$key] -Scope Global
}


### PATHS ###

$script:scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:encoderDir     = Join-Path $script:scriptDir "encoders"
$script:handbrakePath  = Join-Path $script:encoderDir "HandBrakeCLI.exe"
$script:ffmpegPath     = Join-Path $script:encoderDir "ffmpeg.exe"
$script:ffprobePath    = Join-Path $script:encoderDir "ffprobe.exe"
$script:mkvpropeditPath = Join-Path $script:encoderDir "mkvpropedit.exe"


### DISPLAY HELPERS ###

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

function Write-ColoredHost {
    param (
        [string]$Text,
        [ConsoleColor]$ForegroundColor = 'White'
    )
    Write-Host $Text -ForegroundColor $ForegroundColor
}


### PROGRESS BAR ###

function Write-ProgressBar {
    param (
        [int]$Percent,
        [string]$FPS     = "",
        [string]$ETA     = "",
        [string]$Speed   = "",
        [string]$Elapsed = ""
    )

    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    if ($consoleWidth -lt 40) { $consoleWidth = 80 }

    # Build the stats suffix
    $stats = " {0,3}%" -f [math]::Min($Percent, 100)
    if ($FPS)     { $stats += " | $FPS fps" }
    if ($Speed)   { $stats += " | $Speed" }
    if ($ETA)     { $stats += " | ETA: $ETA" }
    if ($Elapsed) { $stats += " | Elapsed: $Elapsed" }

    # Bar fills remaining width: [####....] stats
    $barWidth = $consoleWidth - $stats.Length - 3   # 2 brackets + 1 safety margin
    if ($barWidth -lt 5) { $barWidth = 5 }

    $filled = [math]::Floor($barWidth * [math]::Min($Percent, 100) / 100)
    $empty  = $barWidth - $filled

    $bar = "[" + ([string]::new([char]0x2588, $filled)) + ([string]::new([char]0x2591, $empty)) + "]" + $stats
    $bar = $bar.PadRight($consoleWidth - 1)

    Write-Host "`r$bar" -NoNewline -ForegroundColor Cyan
}

function Get-FileDuration {
    param ([string]$FilePath)
    $result = & $script:ffprobePath -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 "$FilePath" 2>$null
    if ($result -match '^\d+(\.\d+)?$') { return [double]$result }
    return 0
}

function Get-FFmpegProgress {
    param (
        [string]$Line,
        [hashtable]$ParserData
    )
    # FFmpeg stderr stats line example:
    #   frame=  123 fps= 23 q=28.0 size=  12kB time=00:01:23.45 bitrate=1234.5kbits/s speed=3.45x
    if ($Line -notmatch 'time=(\d+):(\d+):(\d+\.\d+)') { return $null }

    $currentTime  = [int]$matches[1] * 3600 + [int]$matches[2] * 60 + [double]$matches[3]
    $totalDuration = $ParserData.Duration
    $percent = if ($totalDuration -gt 0) {
        [math]::Min([math]::Floor($currentTime / $totalDuration * 100), 100)
    } else { 0 }

    $fps = ""
    if ($Line -match 'fps=\s*(\d+\.?\d*)') { $fps = $matches[1] }

    $speed = ""
    if ($Line -match 'speed=\s*(\S+)') { $speed = $matches[1] }

    $eta = ""
    if ($totalDuration -gt 0 -and $currentTime -gt 0 -and $speed -match '([\d.]+)x') {
        $multiplier = [double]$matches[1]
        if ($multiplier -gt 0) {
            $remaining = ($totalDuration - $currentTime) / $multiplier
            $eta = [TimeSpan]::FromSeconds([math]::Max($remaining, 0)).ToString("hh\hmm\mss\s")
        }
    }

    return @{ Percent = $percent; FPS = $fps; ETA = $eta; Speed = $speed }
}

function Get-HandBrakeProgress {
    param (
        [string]$Line,
        [hashtable]$ParserData
    )
    # HandBrake stdout example:
    #   Encoding: task 1 of 1, 45.32 % (234.56 fps, avg 234.56 fps, ETA 00h02m30s)
    if ($Line -notmatch '(\d+\.?\d*)\s*%') { return $null }
    $percent = [math]::Min([math]::Floor([double]$matches[1]), 100)
    $fps = if ($Line -match '(\d+\.\d+)\s*fps') { $matches[1] } else { "" }
    $eta = if ($Line -match 'ETA\s+(\d+h\d+m\d+s)') { $matches[1] } else { "" }
    return @{ Percent = $percent; FPS = $fps; ETA = $eta; Speed = "" }
}

function Invoke-EncoderWithProgress {
    param (
        [string]$Executable,
        [string]$ArgumentString,
        [scriptblock]$ProgressParser,
        [hashtable]$ParserData = @{},
        [string]$FileLabel,
        [int]$FileIndex,
        [int]$TotalFiles,
        [string]$ProgressStream = 'stderr'
    )

    $tempErr = [System.IO.Path]::GetTempFileName()
    $tempOut = [System.IO.Path]::GetTempFileName()

    try {
        Write-Host "  [$FileIndex/$TotalFiles] $FileLabel" -ForegroundColor White
        Write-Host ""   # blank line that the progress bar will overwrite

        $proc = Start-Process -FilePath $Executable `
            -ArgumentList $ArgumentString `
            -NoNewWindow -PassThru `
            -RedirectStandardError  $tempErr `
            -RedirectStandardOutput $tempOut

        $startTime = Get-Date

        $progressFile = if ($ProgressStream -eq 'stdout') { $tempOut } else { $tempErr }

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            try {
                $content = Get-Content -Path $progressFile -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $lines = $content -split "[\r\n]+" | Where-Object { $_.Trim() -ne "" }
                    $progressLine = ($lines | Where-Object { $_ -match '%|time=' }) | Select-Object -Last 1
                    if ($progressLine) {
                        $progress = & $ProgressParser $progressLine $ParserData
                        if ($null -ne $progress) {
                            $elapsedStr = "{0:hh\hmm\mss\s}" -f ((Get-Date) - $startTime)
                            Write-ProgressBar -Percent $progress.Percent `
                                -FPS $progress.FPS -ETA $progress.ETA -Speed $progress.Speed `
                                -Elapsed $elapsedStr
                        }
                    }
                }
            } catch { }
        }

        $proc.WaitForExit()
        $elapsedStr = "{0:hh\hmm\mss\s}" -f ((Get-Date) - $startTime)
        Write-ProgressBar -Percent 100 -Elapsed $elapsedStr   # ensure bar shows 100% on completion
        Write-Host ""

        $stderrContent = ""
        try {
            $allLines = Get-Content -Path $tempErr -ErrorAction SilentlyContinue
            if ($allLines) { $stderrContent = ($allLines | Select-Object -Last 15) -join "`n" }
        } catch { }

        $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
        return @{ ExitCode = $exitCode; Stderr = $stderrContent }
    } finally {
        Remove-Item $tempErr, $tempOut -Force -ErrorAction SilentlyContinue
    }
}


### ENCODER DOWNLOAD HELPERS ###

function Save-HandBrakeCLI {
    param (
        [string]$DestPath,
        [string]$TempDir
    )
    $hbRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/HandBrake/HandBrake/releases/latest" `
        -Headers @{ "User-Agent" = "PowerShell" }
    $hbAsset = $hbRelease.assets |
        Where-Object { $_.name -match "HandBrakeCLI.*win.*x86_64\.zip" } |
        Select-Object -First 1
    if (-not $hbAsset) { throw "Could not find a matching HandBrakeCLI zip asset." }

    $hbZip = Join-Path $TempDir "HandBrakeCLI.zip"
    Invoke-WebRequest -Uri $hbAsset.browser_download_url -OutFile $hbZip
    Expand-Archive -Path $hbZip -DestinationPath $TempDir -Force

    $hbExe = Get-ChildItem -Path $TempDir -Recurse -Filter "HandBrakeCLI.exe" | Select-Object -First 1
    if (-not $hbExe) { throw "HandBrakeCLI.exe not found after extraction." }

    Copy-Item -Path $hbExe.FullName -Destination $DestPath -Force
    Remove-Item $hbZip -Force
}

function Get-7ZipPath {
    # 1. Already downloaded alongside other encoder tools
    $local = Join-Path $script:encoderDir "7z.exe"
    if (Test-Path $local) { return $local }

    # 2. On system PATH
    $inPath = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    # 3. Standard 7-Zip installation locations
    foreach ($candidate in @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }

    # 4. Download standalone 7za.exe from 7-zip.org
    Write-ColoredHost "Downloading 7-Zip standalone..." -ForegroundColor Cyan
    $dest = Join-Path $script:encoderDir "7z.exe"
    try {
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7za.exe" -OutFile $dest -UseBasicParsing
        Write-ColoredHost "7-Zip downloaded successfully." -ForegroundColor Green
        return $dest
    } catch {
        throw "Could not obtain 7z.exe: $_"
    }
}

function Save-FFmpegTools {
    param (
        [string]$FFmpegDest,
        [string]$FFprobeDest,
        [string]$TempDir,
        [string]$SevenZipPath
    )
    $ff7z = Join-Path $TempDir "ffmpeg.7z"
    Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z" -OutFile $ff7z
    & $SevenZipPath x $ff7z -o"$TempDir\ffmpeg" -y | Out-Null

    $ffDir = Get-ChildItem "$TempDir\ffmpeg" -Directory | Select-Object -First 1
    if ($FFmpegDest)  { Copy-Item "$($ffDir.FullName)\bin\ffmpeg.exe"  -Destination $FFmpegDest  -Force }
    if ($FFprobeDest) { Copy-Item "$($ffDir.FullName)\bin\ffprobe.exe" -Destination $FFprobeDest -Force }
    Remove-Item $ff7z -Force
}

function Save-MKVPropEdit {
    param (
        [string]$DestPath,
        [string]$TempDir,
        [string]$SevenZipPath
    )
    $page    = Invoke-WebRequest -Uri "https://mkvtoolnix.download/downloads.html" -UseBasicParsing
    $version = ([regex]::Matches($page.Content, 'windows/releases/(\d+\.\d+(?:\.\d+)?)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending)[0]
    if (-not $version) { throw "Could not detect MKVToolNix version from downloads.html." }

    $downloadUrl = "https://mkvtoolnix.download/windows/releases/$version/mkvtoolnix-64-bit-$version.7z"

    $mkv7z = Join-Path $TempDir "mkvtoolnix.7z"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $mkv7z -UseBasicParsing
    & $SevenZipPath x $mkv7z -o"$TempDir\mkv" -y | Out-Null

    $mkvExe = Get-ChildItem "$TempDir\mkv" -Recurse -Filter "mkvpropedit.exe" | Select-Object -First 1
    if (-not $mkvExe) { throw "mkvpropedit.exe not found after extraction." }
    Copy-Item $mkvExe.FullName -Destination $DestPath -Force
    Remove-Item $mkv7z -Force
}


### ENCODER MANAGEMENT ###

function Confirm-Encoders {
    $missingEncoders = @()
    Write-ColoredHost "Checking Encoders:" -ForegroundColor Yellow
    Write-ColoredHost "------------------" -ForegroundColor Yellow
    Write-ColoredHost "HandBrakeCLI Path: $script:handbrakePath" -ForegroundColor White
    Write-ColoredHost "FFmpeg Path:       $script:ffmpegPath"    -ForegroundColor White
    Write-ColoredHost "FFprobe Path:      $script:ffprobePath"   -ForegroundColor White
    Write-ColoredHost "MKVPropEdit Path:  $script:mkvpropeditPath" -ForegroundColor White
    Write-Host ""

    if (-not (Test-Path $script:handbrakePath))    { $missingEncoders += "HandBrakeCLI" }
    if (-not (Test-Path $script:ffmpegPath))       { $missingEncoders += "FFmpeg" }
    if (-not (Test-Path $script:ffprobePath))      { $missingEncoders += "FFprobe" }
    if (-not (Test-Path $script:mkvpropeditPath))  { $missingEncoders += "MKVPropEdit" }

    $script:missingEncoders = $missingEncoders

    if ($missingEncoders.Count -gt 0) {
        Write-ColoredHost "Missing encoders:" -ForegroundColor Red
        $missingEncoders | ForEach-Object { Write-ColoredHost "  $_" -ForegroundColor Red }
        return $false
    } else {
        Write-ColoredHost "All encoders detected successfully!" -ForegroundColor Green
        return $true
    }
}

function Get-Encoders {
    $tempDir      = Join-Path $env:TEMP "EncoderDownloads"

    New-Item -ItemType Directory -Force -Path $script:encoderDir, $tempDir | Out-Null
    $sevenZipPath = Get-7ZipPath

    if (-not (Confirm-Encoders)) {
        Clear-Host
        Show-Header

        if ($script:missingEncoders -contains "HandBrakeCLI") {
            try {
                Write-ColoredHost "Downloading HandBrakeCLI..." -ForegroundColor Cyan
                Save-HandBrakeCLI -DestPath $script:handbrakePath -TempDir $tempDir
            } catch {
                Write-ColoredHost "Failed to download HandBrakeCLI: $_" -ForegroundColor Red
            }
        }

        if ($script:missingEncoders -contains "FFmpeg" -or $script:missingEncoders -contains "FFprobe") {
            try {
                Write-ColoredHost "Downloading FFmpeg..." -ForegroundColor Cyan
                $ffDest  = if ($script:missingEncoders -contains "FFmpeg")  { $script:ffmpegPath  } else { $null }
                $ffpDest = if ($script:missingEncoders -contains "FFprobe") { $script:ffprobePath } else { $null }
                Save-FFmpegTools -FFmpegDest $ffDest -FFprobeDest $ffpDest `
                    -TempDir $tempDir -SevenZipPath $sevenZipPath
            } catch {
                Write-ColoredHost "Failed to download FFmpeg: $_" -ForegroundColor Red
            }
        }

        if ($script:missingEncoders -contains "MKVPropEdit") {
            try {
                Write-ColoredHost "Downloading MKVPropEdit..." -ForegroundColor Cyan
                Save-MKVPropEdit -DestPath $script:mkvpropeditPath `
                    -TempDir $tempDir -SevenZipPath $sevenZipPath
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

    function Write-Status {
        param ([string]$encoder, [string]$current, [string]$status, [string]$statusColor = "Gray")
        Write-Host ("{0,-12}: {1} " -f $encoder, $current) -NoNewline
        Write-Host $status -ForegroundColor $statusColor
    }

    function Get-JEncoderVersion   { return $ScriptVersion }

    function Get-FFmpegVersion {
        $line = & $script:ffmpegPath -version | Select-String -Pattern "^ffmpeg version"
        if ($line -match "ffmpeg version (\d{4}-\d{2}-\d{2})") { return $matches[1] }
        return "Unknown"
    }

    function Get-FFprobeVersion {
        $line = & $script:ffprobePath -version | Select-String -Pattern "^ffprobe version"
        if ($line -match "ffprobe version (\d{4}-\d{2}-\d{2})") { return $matches[1] }
        return "Unknown"
    }

    function Get-HandBrakeVersion {
        $line = & $script:handbrakePath --version 2>&1 | Select-String -Pattern "^HandBrake"
        return ($line.Line -replace "^HandBrake\s+", "").Trim().Split(" ")[0]
    }

    function Get-MKVPropEditVersion {
        $line = & $script:mkvpropeditPath --version | Select-String -Pattern "^mkvpropedit"
        if ($line -match "v(\d+\.\d+)") { return "v$($matches[1])" }
        return "Unknown"
    }

    function Get-LatestVersions {
        $latest = @{}

        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/Jarsky/JEncoder/releases/latest" -UseBasicParsing
            $latest.jencoder      = $rel.tag_name -replace '^JEncoder-v', ''
            $latest.latestRelease = $rel
        } catch { $latest.jencoder = "Unknown" }

        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/HandBrake/HandBrake/releases/latest" `
                -Headers @{ "User-Agent" = "PowerShell" }
            $latest.handbrake = $rel.tag_name.TrimStart("v")
        } catch { $latest.handbrake = "Unknown" }

        try {
            $ver = (Invoke-RestMethod -Uri "https://www.gyan.dev/ffmpeg/builds/git-version" `
                -Headers @{ "User-Agent" = "PowerShell" }).Trim()
            if ($ver -match '(\d{4}-\d{2}-\d{2})') {
                $latest.ffmpeg  = $matches[1]
                $latest.ffprobe = $matches[1]
            } else {
                $latest.ffmpeg  = "Unknown"
                $latest.ffprobe = "Unknown"
            }
        } catch {
            $latest.ffmpeg  = "Unknown"
            $latest.ffprobe = "Unknown"
        }

        try {
            $page    = Invoke-WebRequest -Uri "https://mkvtoolnix.download/downloads.html" -UseBasicParsing
            $latestV = ([regex]::Matches($page.Content, 'windows/releases/(\d+\.\d+(?:\.\d+)?)') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending)[0]
            $latest.mkvpropedit = if ($latestV) { "v$latestV" } else { "Unknown" }
        } catch { $latest.mkvpropedit = "Unknown" }

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
    $toUpdate    = @()

    foreach ($key in $currentVersions.Keys) {
        $current = $currentVersions[$key]
        $latest  = $latestVersions[$key]
        $isNewer = $false

        if ($current -eq "Unknown" -or $latest -eq "Unknown") {
            Write-Status $key $current "(Unable to check)" "DarkGray"
            continue
        } elseif ($current -match '^\d{4}-\d{2}-\d{2}$' -and $latest -match '^\d{4}-\d{2}-\d{2}$') {
            $isNewer = ([datetime]::ParseExact($current, 'yyyy-MM-dd', $null)) -lt `
                       ([datetime]::ParseExact($latest,  'yyyy-MM-dd', $null))
        } else {
            try {
                $isNewer = ([version]($current.TrimStart("v"))) -lt ([version]($latest.TrimStart("v")))
            } catch {
                $isNewer = ($current -ne $latest)
            }
        }

        if (-not $isNewer) {
            Write-Status $key $current "(Latest Version!)" "Green"
        } else {
            Write-Status $key $current "(Update Available: $latest)" "Yellow"
            $needsUpdate = $true
            $toUpdate   += $key
        }
    }

    if (-not $CheckOnly) { return }

    if (-not $needsUpdate) {
        Write-Host "`nAll encoders are up to date." -ForegroundColor Green
        return
    }

    Write-Host "`nUpdates are available. Do you want to update now? (Y/N)" -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -notmatch '^(y|yes)$') { return }

    Write-Host "`nDownloading and updating encoders..." -ForegroundColor Cyan
    $tempDir      = Join-Path $env:TEMP "EncoderDownloads"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $sevenZipPath = Get-7ZipPath

    if ($toUpdate -contains "jencoder") {
        Write-Host "`nUpdating JEncoder script..." -ForegroundColor Cyan
        try {
            $asset = $latestVersions.latestRelease.assets |
                Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
            if (-not $asset) { throw "Could not find latest JEncoder ZIP asset." }

            $jeZip = Join-Path $tempDir "JEncoder.zip"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $jeZip -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $jeZip -DestinationPath $tempDir -Force

            $jePS1 = Get-ChildItem -Path $tempDir -Recurse -Filter "*.ps1" | Select-Object -First 1
            if (-not $jePS1) { throw "No .ps1 script found in extracted archive." }

            Copy-Item -Path $jePS1.FullName -Destination $MyInvocation.MyCommand.Path -Force
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
            Save-HandBrakeCLI -DestPath $script:handbrakePath -TempDir $tempDir
        } catch {
            Write-ColoredHost "Failed to update HandBrakeCLI: $_" -ForegroundColor Red
        }
    }

    if ($toUpdate -contains "ffmpeg" -or $toUpdate -contains "ffprobe") {
        try {
            Write-ColoredHost "Updating FFmpeg/FFprobe..." -ForegroundColor Cyan
            Save-FFmpegTools -FFmpegDest $script:ffmpegPath -FFprobeDest $script:ffprobePath `
                -TempDir $tempDir -SevenZipPath $sevenZipPath
        } catch {
            Write-ColoredHost "Failed to update FFmpeg: $_" -ForegroundColor Red
        }
    }

    if ($toUpdate -contains "mkvpropedit") {
        try {
            Write-ColoredHost "Updating MKVPropEdit..." -ForegroundColor Cyan
            Save-MKVPropEdit -DestPath $script:mkvpropeditPath `
                -TempDir $tempDir -SevenZipPath $sevenZipPath
        } catch {
            Write-ColoredHost "Failed to update MKVPropEdit: $_" -ForegroundColor Red
        }
    }

    Write-ColoredHost "`nUpdate process complete. Rechecking versions..." -ForegroundColor Green
    Invoke-UpdateEncoders -CheckOnly
}


### DIRECTORY SETUP ###

$outputDir = Join-Path -Path $script:scriptDir -ChildPath $globalConfig.outputDir
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory | Out-Null
}

$toDeleteDir = if ($globalConfig.toDeleteDir) {
    Join-Path -Path $script:scriptDir -ChildPath $globalConfig.toDeleteDir
} else { $null }


### FILE HELPERS ###

function Get-InputFiles {
    param ([string]$scriptDir)

    Get-ChildItem -Path $scriptDir -Include *.mp4, *.mkv -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DirectoryName -ne $outputDir) -and
            ($_.DirectoryName -ne $script:encoderDir) -and
            ($null -eq $toDeleteDir -or $_.DirectoryName -ne $toDeleteDir)
        }
}

function Show-FilesToProcess {
    param ([string]$scriptDir, [string]$outputDir)

    $files = Get-InputFiles -scriptDir $scriptDir

    if ($files.Count -eq 0) {
        Write-ColoredHost "Files found:" -ForegroundColor Yellow
        Write-ColoredHost "------------" -ForegroundColor Yellow
        Write-ColoredHost "None" -ForegroundColor White
        Write-Host ""
        Write-ColoredHost "No .mp4 or .mkv files were found in the script directory." -ForegroundColor Red
        Write-ColoredHost "Press any key to exit..." -ForegroundColor White
        [System.Console]::ReadKey() | Out-Null
        exit
    }

    $count      = $files.Count
    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    $totalSize  = Format-ByteSize -Bytes $totalBytes
    $plural     = if ($count -ne 1) { "s" } else { "" }

    Write-ColoredHost "Files found ($count file$plural, $totalSize total):" -ForegroundColor Yellow
    Write-ColoredHost "----------------------------------------------" -ForegroundColor Yellow
    foreach ($f in $files) {
        $sizeStr = Format-ByteSize -Bytes $f.Length
        Write-ColoredHost ("  {0,-50} {1,10}" -f $f.Name, $sizeStr) -ForegroundColor White
    }
    Write-Host ""
}

function Set-OutputFileName {
    param (
        [string]$inputFilePath,
        [string]$encoderUsed,
        [string]$audioEncoder    = "copy",
        [switch]$renameOutputFile
    )

    $baseName      = [System.IO.Path]::GetFileNameWithoutExtension($inputFilePath)
    $fileExtension = [System.IO.Path]::GetExtension($inputFilePath)

    if ($replaceSpaces) { $baseName = $baseName -replace ' ', '.' }

    $targetCodec = switch -Regex ($encoderUsed.ToLower()) {
        "265"   { "x265"; break }
        "264"   { "x264"; break }
        "av1"   { "av1";  break }
        default { "encoded" }
    }

    $baseName = $baseName -replace "(h[\s\.-]?264|x[\s\.-]?264|h[\s\.-]?265|x[\s\.-]?265|av1|xvid|divx|mpeg2?)", $targetCodec

    if ($audioEncoder -ne "copy") {
        $audioTargets = @{
            "truehd"  = "TrueHD"
            "opus"    = "Opus"
            "libopus" = "Opus"
            "^pcm"    = "PCM"
            "flac"    = "FLAC"
            "eac3"    = "AC3"
            "ac3"     = "AC3"
            "mp3"     = "MP3"
            "aac"     = "AAC"
            "wmv"     = "WMV"
        }
        foreach ($pattern in $audioTargets.Keys) {
            if ($audioEncoder -match $pattern) {
                $baseName = $baseName -replace "(DD\+|FLAC|DTS[-\s]?HD\s?MA|LPCM|AC3|AAC|MP3|Opus)", $audioTargets[$pattern]
                break
            }
        }
    }

    if ($renameOutputFile) {
        Write-ColoredHost "Renaming to: $baseName$fileExtension" -ForegroundColor Cyan
    }

    $outputFilePath = Join-Path -Path $outputDir -ChildPath "$baseName$fileExtension"
    $n = 1
    while (Test-Path $outputFilePath) {
        $outputFilePath = Join-Path -Path $outputDir -ChildPath "$baseName-$n$fileExtension"
        $n++
    }

    return $outputFilePath
}

function Move-OriginalFile {
    param ([string]$filePath, [string]$toDeleteDir)

    if ($script:globalConfig['deleteOriginals']) {
        if (-not $toDeleteDir) {
            Write-ColoredHost "  Move skipped: toDeleteDir path is empty." -ForegroundColor Yellow
            return
        }
        if (-not (Test-Path $toDeleteDir)) {
            New-Item -Path $toDeleteDir -ItemType Directory | Out-Null
        }
        $dest = Join-Path -Path $toDeleteDir -ChildPath (Split-Path $filePath -Leaf)
        try {
            Move-Item -Path $filePath -Destination $dest -Force
            Write-Host "  Moved original to: $dest" -ForegroundColor DarkGray
        } catch {
            Write-ColoredHost "  Failed to move original file: $_" -ForegroundColor Red
        }
    }
}


### SUBTITLE HELPERS ###

function Get-Codec {
    param ([string]$filePath)
    & $script:ffprobePath -v error -select_streams v:0 -show_entries stream=codec_name `
        -of default=noprint_wrappers=1:nokey=1 "$filePath"
}

function Get-SubtitleInfo {
    param ([string]$filePath)
    $json = & $script:ffprobePath -v error -select_streams s `
        -show_entries stream=index,codec_type,codec_name -of json "$filePath"
    ($json | ConvertFrom-Json).streams
}

function Update-SubtitleFlags {
    param ([string]$filePath)

    if (-not (Test-Path $filePath)) {
        Write-Warning "File not found: $filePath"
        return
    }

    $subtitleInfo    = Get-SubtitleInfo -filePath $filePath
    $commands        = @()
    $subtitleTrackNum = 0

    foreach ($stream in $subtitleInfo) {
        $subtitleTrackNum++
        if ($stream.codec_name -eq "subrip") {
            # mkvpropedit track:sN is 1-based within subtitle tracks, independent of global stream index
            $commands += "--edit track:s$subtitleTrackNum --set flag-default=0 --set flag-forced=0"
        }
    }

    if ($commands.Count -eq 0) {
        Write-Host "No 'subrip' subtitle tracks found that require flag updates." -ForegroundColor Yellow
        return
    }

    if (-not $script:mkvpropeditPath) {
        Write-Warning "mkvpropeditPath is not set."
        return
    }

    Write-Host "Updating subtitle flags with mkvpropedit..." -ForegroundColor Cyan
    try {
        Start-Process -FilePath $script:mkvpropeditPath `
            -ArgumentList "`"$filePath`" $($commands -join ' ')" `
            -NoNewWindow -Wait
        Write-Host "Subtitle flags updated successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to update subtitle flags: $_"
    }
}


### ENCODING ###

function Get-HumanReadableSize {
    param ([Parameter(Mandatory)][string]$Path)
    $size      = (Get-Item $Path).Length
    $units     = @('Bytes','KB','MB','GB','TB','PB','EB')
    $unitIndex = 0
    while ($size -ge 1024 -and $unitIndex -lt $units.Length - 1) {
        $size /= 1024
        $unitIndex++
    }
    return "{0:N2} {1}" -f $size, $units[$unitIndex]
}

function Format-ByteSize {
    param ([long]$Bytes)
    $units = @('Bytes', 'KB', 'MB', 'GB', 'TB')
    $i = 0; $size = [double]$Bytes
    while ($size -ge 1024 -and $i -lt $units.Length - 1) { $size /= 1024; $i++ }
    return "{0:N2} {1}" -f $size, $units[$i]
}

function Get-ReductionPercentage {
    param ([long]$inputSize, [long]$outputSize)
    if ($inputSize -eq 0) { return 0 }
    return [math]::Round((($inputSize - $outputSize) / $inputSize) * 100)
}

function Write-ColoredPercentage {
    param ([int]$percentageReduction)
    $color = if ($percentageReduction -le 30) { "Yellow" } elseif ($percentageReduction -le 50) { "Green" } else { "Red" }
    Write-Host -NoNewline "$percentageReduction%" -ForegroundColor $color
}

function Show-EncodingSummary {
    param ([array]$SummaryList = @())

    if ($SummaryList.Count -eq 0) {
        Write-Host "`nNo files were successfully encoded." -ForegroundColor Yellow
        return
    }

    Write-Host "`nEncoding Summary:`n" -ForegroundColor Cyan
    foreach ($entry in $SummaryList) {
        Write-Host "$($entry.FileName):" -NoNewline
        Write-Host " Input = $($entry.InputSize)," -NoNewline
        Write-Host " Output = $($entry.OutputSize)," -NoNewline
        Write-Host " Reduction = " -NoNewline
        Write-ColoredPercentage ([int]$entry.ReductionPercent.TrimEnd('%'))
        Write-Host ""
    }
}

function Write-EncodingLog {
    param (
        [array]$SummaryList,
        [string]$Backend,
        [switch]$NVENC
    )
    if (-not $SummaryList -or $SummaryList.Count -eq 0) { return }
    $logPath   = Join-Path $script:scriptDir "encoding_log.txt"
    $nvecLabel = if ($NVENC) { " (NVENC)" } else { "" }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $lines     = @("[$timestamp] Backend: $Backend$nvecLabel - $($SummaryList.Count) file(s)")
    foreach ($entry in $SummaryList) {
        $lines += "  $($entry.FileName)`tIn: $($entry.InputSize)`tOut: $($entry.OutputSize)`tReduction: $($entry.ReductionPercent)"
    }
    $lines += ""
    try {
        Add-Content -Path $logPath -Value $lines -Encoding UTF8
        Write-Host "  Log saved to: $logPath" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not write to encoding log: $_"
    }
}

function Test-DiskSpace {
    param (
        [array]$InputFiles,
        [string]$OutputPath
    )
    $totalBytes = ($InputFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $totalBytes -or $totalBytes -eq 0) { return $true }
    try {
        $root      = [System.IO.Path]::GetPathRoot((Resolve-Path $OutputPath -ErrorAction SilentlyContinue))
        $freeBytes = [System.IO.DriveInfo]::new($root).AvailableFreeSpace
    } catch { return $true }

    $inGB   = [math]::Round($totalBytes / 1GB, 2)
    $freeGB = [math]::Round($freeBytes  / 1GB, 2)

    if ($freeBytes -lt ($totalBytes * 0.10)) {
        Write-Host "`n  WARNING: Very low disk space - Input total: $inGB GB, Free: $freeGB GB" -ForegroundColor Red
        $ans = Read-Host "  Continue? (Y/N)"
        if ($ans -notmatch '^(y|yes)$') {
            Write-ColoredHost "Encoding cancelled." -ForegroundColor Yellow
            return $false
        }
    } elseif ($freeBytes -lt $totalBytes) {
        Write-Host "`n  Note: Free space ($freeGB GB) is less than total input size ($inGB GB). Output is typically smaller." -ForegroundColor Yellow
        Write-Host ""
    }
    return $true
}

function Get-EncoderArgs {
    param (
        [string]$Backend,
        [switch]$NVENC,
        [string]$InputPath,
        [string]$OutputPath
    )
    if ($Backend -eq 'HandBrake') {
        $enc    = if ($NVENC) { $globalConfig.handbrakeEncoderNVENC } else { $globalConfig.handbrakeEncoder }
        $preset = if ($NVENC) { $globalConfig.handbrakeNVENCPreset  } else { $globalConfig.handbrakePreset  }
        return "-i `"$InputPath`" -o `"$OutputPath`" " +
               "-e $enc --encoder-preset $preset " +
               "-q $($globalConfig.handbrakeQuality) --cfr --all-audio --all-subtitles"
    } else {
        $enc    = if ($NVENC) { $globalConfig.ffmpegEncoderNVENC } else { $globalConfig.ffmpegEncoder }
        $preset = if ($NVENC) { $globalConfig.ffmpegNVENCPreset  } else { $globalConfig.ffmpegPreset  }
        if ($NVENC) {
            return "-y -i `"$InputPath`" -map 0 " +
                   "-c:v $enc -cq $($globalConfig.ffmpegQuality) -preset $preset " +
                   "-c:a $($globalConfig.audioEncoder) -c:s copy -disposition:s:0 0 -max_muxing_queue_size 9999 " +
                   "`"$OutputPath`""
        } else {
            return "-y -hide_banner -i `"$InputPath`" -map 0 " +
                   "-c:v $enc -preset $preset -crf $($globalConfig.ffmpegQuality) " +
                   "-c:a $($globalConfig.audioEncoder) -c:s copy " +
                   "`"$OutputPath`""
        }
    }
}

function Invoke-Encoder {
    param (
        [ValidateSet('HandBrake', 'FFmpeg')]
        [string]$Backend,
        [switch]$NVENC
    )

    $inputFiles = Get-InputFiles -scriptDir $script:scriptDir
    if (-not $inputFiles -or $inputFiles.Count -eq 0) {
        Write-ColoredHost "No input files found." -ForegroundColor Yellow
        return
    }

    if (-not (Test-DiskSpace -InputFiles $inputFiles -OutputPath $outputDir)) { return }

    $summary    = @()
    $totalFiles = $inputFiles.Count
    $fileIndex  = 0

    foreach ($inputFile in $inputFiles) {
        $fileIndex++

        $encoderUsed = switch ("$Backend-$([bool]$NVENC)") {
            'HandBrake-True'  { $globalConfig.handbrakeEncoderNVENC }
            'HandBrake-False' { $globalConfig.handbrakeEncoder }
            'FFmpeg-True'     { $globalConfig.ffmpegEncoderNVENC }
            'FFmpeg-False'    { $globalConfig.ffmpegEncoder }
        }

        $resolvedOutputPath = Set-OutputFileName -inputFilePath $inputFile.FullName `
            -encoderUsed $encoderUsed -audioEncoder $globalConfig.audioEncoder `
            -renameOutputFile:($globalConfig.renameOutputFile)

        # Skip if output already exists
        if ($globalConfig.skipExisting) {
            $ext         = [System.IO.Path]::GetExtension($resolvedOutputPath)
            $naturalPath = $resolvedOutputPath -replace "-\d+$([regex]::Escape($ext))$", $ext
            if ($naturalPath -ne $resolvedOutputPath) {
                Write-ColoredHost "  Skipping (output exists): $($inputFile.Name)" -ForegroundColor Yellow
                continue
            }
        }

        $outputFile = [PSCustomObject]@{
            FullPath = $resolvedOutputPath
            Name     = [System.IO.Path]::GetFileName($resolvedOutputPath)
        }

        $executable = if ($Backend -eq 'HandBrake') { $script:handbrakePath } else { $script:ffmpegPath }
        $encArgs    = Get-EncoderArgs -Backend $Backend -NVENC:$NVENC `
                          -InputPath $inputFile.FullName -OutputPath $outputFile.FullPath
        $parserData = if ($Backend -eq 'FFmpeg') {
            @{ Duration = (Get-FileDuration -FilePath $inputFile.FullName) }
        } else { @{} }
        $parser = if ($Backend -eq 'HandBrake') {
            { param($l, $d) Get-HandBrakeProgress -Line $l -ParserData $d }
        } else {
            { param($l, $d) Get-FFmpegProgress -Line $l -ParserData $d }
        }
        $progressStream = if ($Backend -eq 'HandBrake') { 'stdout' } else { 'stderr' }

        $result = Invoke-EncoderWithProgress `
            -Executable     $executable `
            -ArgumentString $encArgs `
            -ProgressParser $parser `
            -ParserData     $parserData `
            -FileLabel      $inputFile.Name `
            -FileIndex      $fileIndex `
            -TotalFiles     $totalFiles `
            -ProgressStream $progressStream

        $outputExists = (Test-Path $outputFile.FullPath) -and (Get-Item $outputFile.FullPath).Length -gt 0
        if ($result.ExitCode -eq 0 -or $outputExists) {
            if ($result.ExitCode -ne 0) {
                Write-ColoredHost "  Warning: encoder exited with code $($result.ExitCode) but output file exists - treating as success." -ForegroundColor Yellow
            }
            $nvencLabel = if ($NVENC) { " (NVENC)" } else { "" }
            $cpuLabel   = if (-not $NVENC -and $Backend -eq 'FFmpeg') { " (CPU)" } else { "" }
            $method     = "$Backend$nvencLabel$cpuLabel"
            Write-ColoredHost "Converted: $($inputFile.Name) > $($outputFile.Name) using $method" -ForegroundColor Green

            $inputSz   = (Get-Item $inputFile.FullName).Length
            $outputSz  = (Get-Item $outputFile.FullPath).Length
            $reduction = Get-ReductionPercentage -inputSize $inputSz -outputSize $outputSz

            $summary += [PSCustomObject]@{
                FileName         = $inputFile.Name
                InputSize        = Get-HumanReadableSize -Path $inputFile.FullName
                OutputSize       = Get-HumanReadableSize -Path $outputFile.FullPath
                ReductionPercent = "$reduction%"
            }

            Move-OriginalFile $inputFile.FullName $toDeleteDir

            if ($globalConfig.fixSubtitles -eq $true -and
                [System.IO.Path]::GetExtension($outputFile.FullPath) -ieq '.mkv') {
                Write-Host "  Fixing subtitle flags..." -ForegroundColor Cyan
                Update-SubtitleFlags -filePath $outputFile.FullPath
            }
        } else {
            $tag = if ($NVENC) { " (NVENC)" } else { "" }
            Write-ColoredHost "$Backend$tag failed on: $($inputFile.Name)" -ForegroundColor Red
            if ($result.Stderr -and $result.Stderr.Trim() -ne "") {
                Write-Host "  Encoder output:" -ForegroundColor DarkGray
                Write-Host $result.Stderr -ForegroundColor DarkGray
            }
        }
    }

    Show-EncodingSummary -SummaryList $summary
    Write-EncodingLog -SummaryList $summary -Backend $Backend -NVENC:$NVENC
}


### MENUS ###

function Show-EncodingMenu {
    do {
        Clear-Host
        Show-Header
        Show-FilesToProcess -scriptDir $script:scriptDir -outputDir $outputDir
        Write-Host ""
        Write-ColoredHost "Choose Encoding Method:" -ForegroundColor Yellow
        Write-ColoredHost "-----------------------" -ForegroundColor Yellow
        Write-ColoredHost "1. HandBrake (CPU Encoding)"         -ForegroundColor White
        Write-ColoredHost "2. FFmpeg (CPU Encoding)"            -ForegroundColor White
        Write-ColoredHost "3. HandBrake (NVENC - GPU Encoding)" -ForegroundColor White
        Write-ColoredHost "4. FFmpeg (NVENC - GPU Encoding)"    -ForegroundColor White
        Write-ColoredHost "Q. Return to Main Menu"              -ForegroundColor Red
        Write-Host ""

        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            '1' { Invoke-Encoder -Backend 'HandBrake' -NVENC:$false }
            '2' { Invoke-Encoder -Backend 'FFmpeg'    -NVENC:$false }
            '3' { Invoke-Encoder -Backend 'HandBrake' -NVENC:$true  }
            '4' { Invoke-Encoder -Backend 'FFmpeg'    -NVENC:$true  }
            'q' { return }
            default {
                Write-ColoredHost "Invalid choice. Please select a valid option." -ForegroundColor Red
                Start-Sleep -Milliseconds 1500
            }
        }

        Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
        Write-Host ""
        [System.Console]::ReadKey() | Out-Null
    } while ($true)
}


### ENTRY POINT ###

Show-Header
Get-Encoders

do {
    Show-Header

    Write-ColoredHost "Main Menu:" -ForegroundColor Yellow
    Write-ColoredHost "----------" -ForegroundColor Yellow
    Write-ColoredHost "1. Encode Files"             -ForegroundColor White
    Write-ColoredHost "2. Show Current Configuration" -ForegroundColor White
    Write-ColoredHost "3. Edit Configuration"       -ForegroundColor White
    Write-ColoredHost "4. Check for Updates"        -ForegroundColor White
    Write-ColoredHost "Q. Quit"                     -ForegroundColor Red
    Write-Host ""

    $menuChoice = Read-Host "Enter your choice"
    switch ($menuChoice.ToLower()) {
        '1' { Show-EncodingMenu }
        '2' { Show-Configuration }
        '3' { Edit-Configuration }
        '4' { Invoke-UpdateEncoders -CheckOnly }
        'q' {
            Write-ColoredHost "Exiting... Goodbye!" -ForegroundColor Green
            Start-Sleep 2
            return
        }
        default {
            Write-ColoredHost "Invalid choice. Please try again." -ForegroundColor Red
        }
    }

    if ($menuChoice.ToLower() -ne '1') {
        Write-Host ""
        Write-ColoredHost "Press any key to return to the menu..." -ForegroundColor Yellow
        Write-Host ""
        [System.Console]::ReadKey() | Out-Null
    }
} while ($true)
