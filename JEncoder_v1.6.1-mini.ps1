# JEncoder v1.6.1 - Streamlined Version
$ScriptVersion = "1.6.1"

### CONFIGURATION ###
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configFile = Join-Path $PSScriptRoot "config.ini"
$logFile = Join-Path $PSScriptRoot "jencoder-$(Get-Date -Format 'yyyy-MM-dd').log"

$defaultConfig = @{
    outputDir = "output"
    toDeleteDir = "to_be_deleted"
    deleteOriginals = $false
    handbrakeQuality = "22"
    ffmpegQuality = "28"
    audioEncoder = "copy"
    enableLogging = $true
    verboseLogging = $false
}

### HELPER FUNCTIONS ###
function Write-ColoredHost($Text, $Color = 'White') { 
    Write-Host $Text -ForegroundColor $Color 
}

function Write-Log($Message, $Level = "INFO") {
    if ($config.enableLogging) {
        Add-Content -Path $logFile -Value "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message" -ErrorAction SilentlyContinue
    }
}

function Show-Header {
    Clear-Host
    Write-ColoredHost @"
      _ ______                     _           
     | |  ____|                   | |          
     | | |__   _ __   ___ ___   __| | ___ _ __ 
 _   | |  __| | '_ \ / __/ _ \ / _  |/ _ \ '__|
| |__| | |____| | | | (_| (_) | (_| |  __/ |   
 \____/|______|_| |_|\___\___/ \__,_|\___|_|   
                        Version: $ScriptVersion
"@ -Color Cyan
}

function Get-Config {
    if (Test-Path $configFile) {
        $config = @{}
        (Get-Content $configFile) | ForEach-Object {
            if ($_ -match '(.+)=(.+)') { 
                $config[$matches[1].Trim()] = $matches[2].Trim() 
            }
        }
        return $config
    }
    return $defaultConfig
}

function Get-HumanReadableSize($Size) {
    $units = @('Bytes', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($Size -ge 1024 -and $index -lt 4) { 
        $Size /= 1024
        $index++ 
    }
    return "{0:N2} {1}" -f $Size, $units[$index]
}

function Get-ProgressBar($Percent, $Length = 40) {
    $filled = [math]::Floor($Length * $Percent / 100)
    $bar = "🟩" * $filled + " " * ($Length - $filled)
    return "[ $bar ]"
}

function Format-TimeRemaining($Seconds) {
    if ($Seconds -le 0) { return "Calculating..." }
    $time = [TimeSpan]::FromSeconds($Seconds)
    if ($time.TotalHours -ge 1) {
        return "{0:D2}:{1:D2}:{2:D2}" -f $time.Hours, $time.Minutes, $time.Seconds
    }
    return "{0:D2}:{1:D2}" -f $time.Minutes, $time.Seconds
}

### ENCODER MANAGEMENT ###
function Get-EncoderPaths {
    $encoderDir = Join-Path $scriptDir "encoders"
    return @{
        HandBrake = Join-Path $encoderDir "HandBrakeCLI.exe"
        FFmpeg = Join-Path $encoderDir "ffmpeg.exe"
        FFprobe = Join-Path $encoderDir "ffprobe.exe"
    }
}

function Test-Encoders {
    $paths = Get-EncoderPaths
    $missing = $paths.GetEnumerator() | Where-Object { -not (Test-Path $_.Value) } | ForEach-Object { $_.Key }
    
    if ($missing) {
        Write-ColoredHost "Missing encoders: $($missing -join ', ')" Yellow
        Write-Log "Missing encoders: $($missing -join ', ')" "WARNING"
        return $false
    }
    
    Write-ColoredHost "All encoders detected!" Green
    Write-Log "All encoders detected successfully"
    return $true
}

### FILE MANAGEMENT ###
function Get-InputFiles {
    return Get-ChildItem -Path $scriptDir -Include *.mp4, *.mkv -File | Where-Object {
        $_.DirectoryName -ne $outputDir -and $_.DirectoryName -ne $toDeleteDir
    }
}

function Get-OutputFileName($inputPath, $encoder) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inputPath)
    $ext = [System.IO.Path]::GetExtension($inputPath)
    
    # Replace codec in filename
    $codec = if ($encoder -match "265|hevc") { "x265" } else { "encoded" }
    $base = $base -replace "(h[\s\.-]?264|x[\s\.-]?264|h[\s\.-]?265|x[\s\.-]?265)", $codec
    
    $outputPath = Join-Path $outputDir "$base$ext"
    $counter = 1
    while (Test-Path $outputPath) {
        $outputPath = Join-Path $outputDir "$base-$counter$ext"
        $counter++
    }
    return $outputPath
}

function Get-MediaDuration($filePath) {
    $paths = Get-EncoderPaths
    $duration = & $paths.FFprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$filePath" 2>$null
    return if ([double]::TryParse($duration, [ref]$null)) { [double]$duration } else { 0 }
}

### MAIN ENCODING FUNCTION ###
function Invoke-Encoding($EncoderType, $UseNVENC = $false) {
    $paths = Get-EncoderPaths
    $inputFiles = Get-InputFiles
    
    if (-not $inputFiles) {
        Write-ColoredHost "No media files found to encode!" Yellow
        return
    }
    
    # Set encoder parameters
    if ($EncoderType -eq "HandBrake") {
        $encoderPath = $paths.HandBrake
        $encoder = if ($UseNVENC) { "nvenc_h265" } else { "x265" }
        $method = if ($UseNVENC) { "HandBrake (NVENC)" } else { "HandBrake (CPU)" }
        $quality = $config.handbrakeQuality
        
        $buildArgs = { 
            param($input, $output)
            "-i `"$input`" -o `"$output`" -e $encoder --encoder-preset default -q $quality --cfr --all-audio --all-subtitles"
        }
        
        $parseProgress = { 
            param($line)
            if ($line -match 'Encoding: task \d+ of \d+, (\d+\.\d+) %') { 
                return [double]$matches[1] 
            }
            return -1
        }
    } else { # FFmpeg
        $encoderPath = $paths.FFmpeg
        $encoder = if ($UseNVENC) { "hevc_nvenc" } else { "libx265" }
        $method = if ($UseNVENC) { "FFmpeg (NVENC)" } else { "FFmpeg (CPU)" }
        $quality = $config.ffmpegQuality
        
        $buildArgs = { 
            param($input, $output)
            if ($UseNVENC) {
                "-i `"$input`" -c:v hevc_nvenc -cq $quality -preset default -c:a copy -c:s copy `"$output`""
            } else {
                "-hide_banner -i `"$input`" -c:v libx265 -preset medium -crf $quality -c:a copy -c:s copy `"$output`""
            }
        }
        
        $parseProgress = { 
            param($line, $duration)
            if ($line -match 'time=(\d+):(\d+):(\d+\.\d+)' -and $duration -gt 0) {
                $currentTime = ([double]$matches[1] * 3600) + ([double]$matches[2] * 60) + [double]$matches[3]
                return ($currentTime / $duration) * 100
            }
            return -1
        }
    }
    
    # Process each file
    foreach ($inputFile in $inputFiles) {
        $outputPath = Get-OutputFileName $inputFile.FullName $encoder
        $duration = Get-MediaDuration $inputFile.FullName
        $args = & $buildArgs $inputFile.FullName $outputPath
        
        Write-ColoredHost "`nProcessing: $($inputFile.Name)" Cyan
        Write-ColoredHost "Output: $(Split-Path $outputPath -Leaf)" White
        Write-ColoredHost "Press Q to abort..." Red
        
        Write-Log "Starting $method encoding"
        Write-Log "File: $($inputFile.Name)"
        Write-Log "Command: `"$encoderPath`" $args"
        
        # Start encoding process
        $process = Start-Process -FilePath $encoderPath -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput "stdout.tmp" -RedirectStandardError "stderr.tmp"
        $global:CurrentProcess = $process
        
        # Progress tracking
        $startTime = Get-Date
        $lastProgress = 0
        $progressHistory = @()
        
        while (-not $process.HasExited) {
            # Read output for progress
            $output = if (Test-Path "stdout.tmp") { Get-Content "stdout.tmp" -Tail 5 } else { @() }
            $errors = if (Test-Path "stderr.tmp") { Get-Content "stderr.tmp" -Tail 5 } else { @() }
            
            # Parse progress from appropriate stream
            $progressLines = if ($EncoderType -eq "HandBrake") { $output } else { $errors }
            
            foreach ($line in $progressLines) {
                if ($line) {
                    if ($config.verboseLogging) { 
                        Write-Log "OUTPUT: $line" 
                    }
                    
                    $progress = if ($EncoderType -eq "HandBrake") { 
                        & $parseProgress $line 
                    } else { 
                        & $parseProgress $line $duration 
                    }
                    
                    if ($progress -ge 0 -and $progress -gt $lastProgress) {
                        $elapsed = (Get-Date - $startTime).TotalSeconds
                        
                        # Calculate ETA
                        if ($progressHistory.Count -ge 5) { 
                            $progressHistory = $progressHistory[1..4] 
                        }
                        $progressHistory += @{ Progress = $progress; Time = Get-Date }
                        
                        $eta = if ($progressHistory.Count -gt 1) {
                            $oldest = $progressHistory[0]
                            $rate = ($progress - $oldest.Progress) / ((Get-Date) - $oldest.Time).TotalSeconds
                            if ($rate -gt 0) { (100 - $progress) / $rate } else { 0 }
                        } else { 
                            if ($progress -gt 0) { $elapsed * (100 - $progress) / $progress } else { 0 } 
                        }
                        
                        $bar = Get-ProgressBar $progress
                        $status = "$bar {0:N1}% | ETA: {1}" -f $progress, (Format-TimeRemaining $eta)
                        Write-Host "`r$status" -NoNewline
                        $lastProgress = $progress
                    }
                }
            }
            
            # Check for user abort
            if ([console]::KeyAvailable) {
                $key = [console]::ReadKey($true)
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') {
                    Write-ColoredHost "`nEncoding aborted!" Red
                    $process.Kill()
                    break
                }
            }
            
            Start-Sleep -Milliseconds 100
        }
        
        Write-Host "" # New line after progress
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        
        # Clean up temp files
        Remove-Item "stdout.tmp", "stderr.tmp" -ErrorAction SilentlyContinue
        
        if ($exitCode -eq 0 -and (Test-Path $outputPath)) {
            $inputSize = $inputFile.Length
            $outputSize = (Get-Item $outputPath).Length
            $reduction = [math]::Round((($inputSize - $outputSize) / $inputSize) * 100)
            
            Write-ColoredHost "✓ Success! $(Get-HumanReadableSize $inputSize) → $(Get-HumanReadableSize $outputSize) ($reduction% reduction)" Green
            Write-Log "SUCCESS: $($inputFile.Name) encoded successfully ($reduction% reduction)"
            
            # Move original if configured
            if ($config.deleteOriginals) {
                if (-not (Test-Path $toDeleteDir)) { 
                    New-Item $toDeleteDir -ItemType Directory | Out-Null 
                }
                Move-Item $inputFile.FullName (Join-Path $toDeleteDir $inputFile.Name) -Force
                Write-Log "Moved original to deletion folder"
            }
        } else {
            Write-ColoredHost "✗ Encoding failed (exit code: $exitCode)" Red
            Write-Log "ERROR: Encoding failed for $($inputFile.Name) with exit code $exitCode" "ERROR"
            
            # Log error details
            if (Test-Path "stderr.tmp") {
                $errorOutput = Get-Content "stderr.tmp" -Raw
                Write-Log "Error details: $errorOutput" "ERROR"
            }
        }
    }
    
    $global:CurrentProcess = $null
}

### MENU FUNCTIONS ###
function Show-Menu($Title, $Options) {
    Clear-Host
    Show-Header
    Write-ColoredHost $Title Yellow
    Write-ColoredHost ("-" * $Title.Length) Yellow
    
    $Options.GetEnumerator() | Sort-Object Key | ForEach-Object {
        Write-ColoredHost "$($_.Key). $($_.Value)" White
    }
    Write-ColoredHost "Q. Quit" Red
    
    return (Read-Host "`nEnter choice").ToLower()
}

function Show-Files {
    $files = Get-InputFiles
    Write-ColoredHost "`nFiles found:" Yellow
    if ($files) {
        $files | ForEach-Object { Write-ColoredHost "  $($_.Name)" White }
        Write-Log "Found $($files.Count) files: $($files.Name -join ', ')"
    } else {
        Write-ColoredHost "  None" Gray
        Write-ColoredHost "  Add .mp4 or .mkv files to this directory" Yellow
    }
}

### MAIN SCRIPT ###
# Initialize
Write-Log "JEncoder v$ScriptVersion started"
$config = Get-Config
$outputDir = Join-Path $scriptDir $config.outputDir
$toDeleteDir = if ($config.toDeleteDir) { Join-Path $scriptDir $config.toDeleteDir } else { $null }

# Create directories
@($outputDir, $toDeleteDir) | Where-Object { $_ } | ForEach-Object {
    if (-not (Test-Path $_)) { 
        New-Item $_ -ItemType Directory | Out-Null 
    }
}

# Ctrl+C handler
$global:CurrentProcess = $null
Register-EngineEvent PowerShell.Exiting -Action {
    if ($global:CurrentProcess -and !$global:CurrentProcess.HasExited) {
        $global:CurrentProcess.Kill()
    }
} | Out-Null

# Main loop
do {
    if (-not (Test-Encoders)) {
        Write-ColoredHost "`nPlease install missing encoders in the 'encoders' folder" Red
        Write-ColoredHost "Download from: https://handbrake.fr and https://ffmpeg.org" Cyan
        break
    }
    
    Show-Files
    
    $choice = Show-Menu "Choose Encoding Method" @{
        "1" = "HandBrake (CPU)"
        "2" = "FFmpeg (CPU)"
        "3" = "HandBrake (NVENC)"
        "4" = "FFmpeg (NVENC)"
    }
    
    switch ($choice) {
        "1" { Invoke-Encoding "HandBrake" $false }
        "2" { Invoke-Encoding "FFmpeg" $false }
        "3" { Invoke-Encoding "HandBrake" $true }
        "4" { Invoke-Encoding "FFmpeg" $true }
        "q" { 
            Write-ColoredHost "Goodbye!" Green
            Write-Log "JEncoder session ended"
            break 
        }
        default { 
            Write-ColoredHost "Invalid choice!" Red
            Start-Sleep 1
        }
    }
    
    if ($choice -match "^[1-4]$") {
        Write-ColoredHost "`nPress any key to continue..." Yellow
        [Console]::ReadKey() | Out-Null
    }
} while ($true)