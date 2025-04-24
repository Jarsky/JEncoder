### VARIABLES ###

# Config File and Default Config
$configFile = Join-Path -Path $PSScriptRoot -ChildPath "config.ini"

$defaultConfig = [ordered]@{
    replaceSpaces         = $false
    fixSubtitles          = $false
    outputDir             = "output"
    toDeleteDirectory     = "to_be_deleted"
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
    Write-ColoredHost "Checking Encoders:" -ForegroundColor Yellow
    Write-ColoredHost "------------------" -ForegroundColor Yellow
    Write-ColoredHost "HandBrakeCLI Path: $handbrakePath" -ForegroundColor White
    Write-ColoredHost "FFmpeg Path: $ffmpegPath" -ForegroundColor White
    Write-ColoredHost "FFprobe Path: $ffprobePath" -ForegroundColor White
    Write-ColoredHost "MKVPropEdit Path: $mkvpropeditPath" -ForegroundColor White
    Write-Host ""

    if (-not (Test-Path $handbrakePath))      { $missingEncoders += "HandBrakeCLI" }
    if (-not (Test-Path $ffmpegPath))         { $missingEncoders += "FFmpeg" }
    if (-not (Test-Path $ffprobePath))        { $missingEncoders += "FFprobe" }
    if (-not (Test-Path $mkvpropeditPath))    { $missingEncoders += "MKVPropEdit" }

    $script:missingEncoders = $missingEncoders  # Store for use in Get-Encoders

    if ($missingEncoders.Count -gt 0) {
        Write-ColoredHost "Missing encoders:" -ForegroundColor Red
        $missingEncoders | ForEach-Object { Write-ColoredHost $_ -ForegroundColor Red }
        return $false  # You can return false if there are missing encoders but avoid printing it
    } else {
        Write-ColoredHost "All encoders detected successfully!" -ForegroundColor Green
        return $true
    }

    Write-Host ""
}


function Get-Encoders {
    $encoderDir = Join-Path $scriptDir "encoders"
    $tempDir = Join-Path $env:TEMP "EncoderDownloads"
    $sevenZipPath = Join-Path $scriptDir "7z.exe"

    # Create necessary directories if they don't exist
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

                # Use a known good static URL instead of scraping
                $mkvUrl = "https://mkvtoolnix.download/windows/releases/82.0/mkvtoolnix-64-bit-82.0.7z"
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


# Output Directory Setup
$outputDir = Join-Path -Path $scriptDir -ChildPath $globalConfig.outputDir
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory | Out-Null
}

# Function to get the input files
function Get-InputFiles {
    $inputFiles = Get-ChildItem -Path $scriptDir -Include *.mp4, *.mkv -File -Recurse -ErrorAction SilentlyContinue
    $inputFiles = $inputFiles | Where-Object { $_.DirectoryName -ne $outputDir }
    return $inputFiles
}

# Function to process and rename the output files
function Set-OutputFileName {
    param (
        [string]$inputFilePath
    )

    # Base filename without extension
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFilePath)
    $fileExtension = [System.IO.Path]::GetExtension($inputFilePath)

    # Replace spaces in the base name if needed
    if ($replaceSpaces) {
        $baseName = $baseName -replace ' ', '.'
    }

    # Rename the file (replace x264 or H264 with x265)
    $outputFileName = $baseName -replace "H[\s.]*264|x[\s.]*264", "x265"
    $outputFilePath = Join-Path -Path $outputDir -ChildPath "$outputFileName$fileExtension"
    
    # Handle file name conflicts (e.g., append a number if file exists)
    $n = 1
    while (Test-Path $outputFilePath) {
        $outputFilePath = Join-Path -Path $outputDir -ChildPath "$outputFileName-$n$fileExtension"
        $n++
    }
    
    return $outputFilePath
}

# Move-to-be-deleted Directory Setup
$toDeleteDir = Join-Path -Path $scriptDir -ChildPath $globalConfig.toDeleteDirectory
if (-not (Test-Path $toDeleteDir)) {
    New-Item -Path $toDeleteDir -ItemType Directory | Out-Null
}

function Show-FilesToProcess {
    param (
        [string]$scriptDir,
        [string]$outputDir
    )

    # Get the files to process
    $filesToProcess = Get-ChildItem -Path $scriptDir -Include *.mp4, *.mkv -File -Recurse -ErrorAction SilentlyContinue
    $filesToProcess = $filesToProcess | Where-Object { $_.DirectoryName -ne $outputDir }

    # Display the files found
    Write-ColoredHost "Files found:" -ForegroundColor Yellow
    Write-ColoredHost "------------" -ForegroundColor Yellow
    if ($filesToProcess.Count -eq 0) {
        Write-ColoredHost "None" -ForegroundColor White
    } else {
        $filesToProcess | ForEach-Object { Write-ColoredHost $_.Name -ForegroundColor White }
        Write-ColoredHost "" -ForegroundColor White
    }

    # If no files are found, show a message and exit
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
        # Ensure FullName is not null
        if ($null -eq $file.FullName) {
            Write-Warning "Invalid input file: $file"
            continue
        }

        # Generate output file path
        $outputFilePath = Set-OutputFileName -inputFilePath $file.FullName

        # Ensure outputFilePath is not null or empty
        if ([string]::IsNullOrEmpty($outputFilePath)) {
            Write-Warning "Failed to generate output file path for: $file.FullName"
            continue
        }

        # Debugging: Show paths
        Write-Host "Processing File:"
        Write-Host "  Input:  $($file.FullName)"
        Write-Host "  Output: $outputFilePath"

        # Call the specific invoke function
        try {
            & $InvokeFunction.Invoke($file, $outputFilePath)
        } catch {
            Write-Error "Error processing file $($file.FullName): $_"
        }
    }
}

# AFTER processing a file (in your encoding functions):
# Move original file if deleteOriginals is true
function Move-OriginalFile {
    param (
        [string]$filePath
    )
    if ($globalConfig.deleteOriginals) {
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

    # Convert JSON output to PowerShell object
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



# Function to encode using HandBrake
function Invoke-WithHandBrake {
    $inputFiles = Get-InputFiles

    foreach ($inputFile in $inputFiles) {
        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }

        & $handbrakePath -i "$($inputFile.FullName)" -o "$($outputFile.FullPath)" -e $handbrakeEncoder --encoder-preset $handbrakePreset -q $handbrakeQuality --cfr --all-audio --all-subtitles

        if ($LASTEXITCODE -eq 0) {
            Write-ColoredHost "Converted: $($inputFile.Name) > $($outputFile.Name) using HandBrakeCLI" -ForegroundColor Green
            Move-OriginalFile $inputFile.FullName
        } else {
            Write-ColoredHost "HandBrake failed on: $($inputFile.Name)" -ForegroundColor Red
        }
    }
}




# Function to encode using FFmpeg
function Invoke-WithFFmpeg {
    $inputFiles = Get-InputFiles

    foreach ($inputFile in $inputFiles) {
        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }

        & $ffmpegPath -hide_banner -i "$($inputFile.FullName)" -c:v $ffmpegEncoder -preset $ffmpegPreset -crf $ffmpegQuality -c:a copy -c:s copy "$($outputFile.FullPath)"

        if ($LASTEXITCODE -eq 0) {
            Write-ColoredHost "Converted: $($inputFile.Name) > $($outputFile.Name) using FFmpeg (CPU)" -ForegroundColor Green
            Move-OriginalFile $inputFile.FullName
        } else {
            Write-ColoredHost "FFmpeg failed on: $($inputFile.Name)" -ForegroundColor Red
        }
    }
}

# Function to encode using HandBrake with NVENC
function Invoke-WithHandBrakeNVENC {
    $inputFiles = Get-InputFiles

    foreach ($inputFile in $inputFiles) {
        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }

        & $handbrakePath -i "$($inputFile.FullName)" -o "$($outputFile.FullPath)" -e $handbrakeEncoderNVENC --encoder-preset $handbrakeNVENCPreset -q $handbrakeQuality --cfr --all-audio --all-subtitles

        if ($LASTEXITCODE -eq 0) {
            Write-ColoredHost "Converted: $($inputFile.Name) > $($outputFile.Name) using HandBrakeCLI (NVENC)" -ForegroundColor Green
            Move-OriginalFile $inputFile.FullName
        } else {
            Write-ColoredHost "HandBrake (NVENC) failed on: $($inputFile.Name)" -ForegroundColor Red
        }
    }
}



# Function to encode using FFmpeg with NVENC
function Invoke-WithFFmpegNVENC {
    $inputFiles = Get-InputFiles

    foreach ($inputFile in $inputFiles) {
        $outputPath = Set-OutputFileName -inputFilePath $inputFile.FullName
        $outputFile = [PSCustomObject]@{
            FullPath = $outputPath
            Name     = [System.IO.Path]::GetFileName($outputPath)
        }

        & $ffmpegPath -i "$($inputFile.FullName)" -map 0 -c:v $ffmpegEncoderNVENC -cq $ffmpegQuality -preset $ffmpegNVENCPreset -c:a $audioEncoder -c:s copy -disposition:s:0 0 -max_muxing_queue_size 9999 "$($outputFile.FullPath)"

        if ($LASTEXITCODE -eq 0) {
            Write-ColoredHost "Converted: $($inputFile.Name) > $($outputFile.Name) using FFmpeg (NVENC)" -ForegroundColor Green
            Move-OriginalFile $inputFile.FullName
        } else {
            Write-ColoredHost "FFmpeg (NVENC) failed on: $($inputFile.Name)" -ForegroundColor Red
        }
    }
}



function Get-HumanReadableSize {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $fileSize = (Get-Item $Path).Length
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
            '1' { Invoke-WithHandBrake }
            '2' { Invoke-WithFFmpeg }
            '3' { Invoke-WithHandBrakeNVENC }
            '4' { Invoke-WithFFmpegNVENC }
            'q' { return }  # Return to main menu
            default {
                Write-ColoredHost "Invalid choice. Please select a valid option." -ForegroundColor Red
                Start-Sleep -Seconds 1.5
            }
        }

        Write-ColoredHost "Press any key to continue..." -ForegroundColor Yellow
        [System.Console]::ReadKey() | Out-Null
    } while ($true)
}

do {
    Show-Header 
    Get-Encoders 

    Show-FilesToProcess -scriptDir $scriptDir -outputDir $outputDir

    Write-ColoredHost "Main Menu:" -ForegroundColor Yellow
    Write-ColoredHost "----------" -ForegroundColor Yellow
    Write-ColoredHost "1. Encode Files" -ForegroundColor White
    Write-ColoredHost "2. Show Current Configuration" -ForegroundColor White
    Write-ColoredHost "3. Edit Configuration" -ForegroundColor White
    Write-ColoredHost "Q. Quit" -ForegroundColor Red
    Write-Host ""

    $menuChoice = Read-Host "Enter your choice"

    switch ($menuChoice.ToLower()) {
        '1' { Show-EncodingMenu }
        '2' { Show-Configuration }
        '3' { Edit-Configuration }
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
