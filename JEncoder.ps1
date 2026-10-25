<#
.SYNOPSIS
    JEncoder - batch video encoding with HandBrakeCLI or FFmpeg (CPU or NVENC).

.DESCRIPTION
    Interactive by default: pick a folder, pick files, pick an encoder.
    Missing tools (HandBrakeCLI, FFmpeg/FFprobe, MKVPropEdit) are downloaded to .\encoders.
    Settings live in config.ini next to the script (created on first run).

    Non-interactive (servers, scheduled tasks, remote sessions): pass -Encoder to encode every
    eligible file under -Path (default: the script folder) without any menus.

.PARAMETER Path
    Folder to scan for .mp4/.mkv files (recursively). Defaults to the script folder.

.PARAMETER Encoder
    Run without menus using this encoder: HandBrake, FFmpeg, HandBrakeNVENC or FFmpegNVENC.

.PARAMETER EstimateOnly
    With -Encoder: encode short samples and report the predicted output sizes; nothing is fully encoded.

.EXAMPLE
    .\JEncoder.ps1
.EXAMPLE
    .\JEncoder.ps1 -Path 'D:\Media\Incoming' -Encoder FFmpegNVENC
.EXAMPLE
    .\JEncoder.ps1 -Path 'D:\Media\Incoming' -Encoder FFmpeg -EstimateOnly

.NOTES
    Version history:
      - v1.9.0: Target-size mode with the tdarr-adaptive-hevc rules: sample encodes (size + SSIM)
                pick the quality for ~50% smaller, never more than 60%, skip if under 20%; one
                corrected retry if the real result misses. Skips HEVC/AV1, Dolby Vision, already-lean
                and very short sources. 10-bit HEVC output, HDR10/HLG metadata kept, bitrate capped at
                the source's. Size estimates without encoding (-EstimateOnly).
      - v1.8.0: Simplified; fixes: failed encodes counted as success (exit code + output now
                verified before originals are moved), HandBrake audioEncoder ignored (audio was
                downmixed), file/folder names with [ ] brackets, dead 7-Zip download URL, downloads
                on Windows Server (TLS 1.2, no IE engine), self-update, renameOutputFile ignored,
                stale archives reused on update. Adds non-interactive mode (-Path/-Encoder).
      - v1.7.0: Arrow-key navigation for all menus, folder scan selector, interactive file
                multi-select, per-source to_be_deleted subfolder.
      - v1.6.0: Fixed bugs, eliminated code duplication, added custom inline progress bars.
      - v1.5.x: Refactoring, dynamic renaming based on codec, script auto-update.
      - v1.4.x: Fixed summary report and encoder version detection.
      - v1.3.x: Automatic encoder downloads; combined encoder functions.
      - v1.2.0: Handling of original files after processing.
      - v1.1.0: config.ini handling and menu system.
      - v1.0.0: Initial release with HandBrakeCLI, FFmpeg and NVENC.
#>
param (
    [string]$Path,
    [ValidateSet('HandBrake', 'FFmpeg', 'HandBrakeNVENC', 'FFmpegNVENC')]
    [string]$Encoder,
    [switch]$EstimateOnly
)

$ScriptVersion = "1.9.0"

# Windows PowerShell 5.1 on older servers may not offer TLS 1.2, which GitHub requires.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Invoke-WebRequest's progress display makes large downloads crawl on 5.1; we draw our own bars.
$ProgressPreference = 'SilentlyContinue'


### PATHS & CONFIG ###

$ScriptDir  = $PSScriptRoot
$EncoderDir = Join-Path $ScriptDir "encoders"
$ConfigFile = Join-Path $ScriptDir "config.ini"
$LogFile    = Join-Path $ScriptDir "encoding_log.txt"
$Tools = @{
    HandBrake   = Join-Path $EncoderDir "HandBrakeCLI.exe"
    FFmpeg      = Join-Path $EncoderDir "ffmpeg.exe"
    FFprobe     = Join-Path $EncoderDir "ffprobe.exe"
    MKVPropEdit = Join-Path $EncoderDir "mkvpropedit.exe"
}
$MediaExtensions = @('.mp4', '.mkv')

$DefaultConfig = [ordered]@{
    replaceSpaces         = $false
    fixSubtitles          = $false
    outputDir             = "output"
    renameOutputFile      = $true
    toDeleteDir           = "to_be_deleted"
    deleteOriginals       = $true
    handbrakeEncoder      = "x265"
    handbrakePreset       = "medium"
    handbrakeEncoderNVENC = "nvenc_h265"
    handbrakeNVENCPreset  = "medium"
    handbrakeQuality      = "21"
    ffmpegEncoder         = "libx265"
    ffmpegPreset          = "medium"
    ffmpegEncoderNVENC    = "hevc_nvenc"
    ffmpegNVENCPreset     = "default"
    ffmpegQuality         = "18"
    audioEncoder          = "copy"
    skipExisting          = $true
    tenBit                = $true   # HEVC output in 10-bit (main10): smaller at the same quality; HDR always is
    # "target": test-encode samples and pick the quality that lands near targetReduction (the same
    # rules as tdarr-adaptive-hevc). "fixed": always use handbrakeQuality / ffmpegQuality.
    encodeMode            = "target"
    targetReduction       = "50"    # aim for the output to be this % smaller than the source
    maxReduction          = "60"    # never shrink a file by more than this % (protects detail/grain)
    minKeepReduction      = "20"    # skip a file if the best quality-safe setting saves less than this %
    ssimFloor             = "0.975" # minimum SSIM of the sample encodes vs the source (quality wins over size)
    sampleCount           = "3"
    sampleSeconds         = "8"
    maxRetries            = "1"     # extra full encodes with a corrected quality if the result misses badly
    skipCodecs            = "hevc,av1"  # source video codecs not worth re-encoding (empty = encode all)
}

function Read-Config {
    # Start from defaults so keys added in newer versions are always present
    $loaded = [ordered]@{}
    foreach ($key in $DefaultConfig.Keys) { $loaded[$key] = $DefaultConfig[$key] }

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Save-Config $loaded
        return $loaded
    }
    foreach ($line in Get-Content -LiteralPath $ConfigFile) {
        if ($line -notmatch '^\s*([^#;=]+?)\s*=(.*)$') { continue }
        $key, $value = $matches[1], $matches[2].Trim()
        if (-not $DefaultConfig.Contains($key)) { continue }
        $loaded[$key] = if ($DefaultConfig[$key] -is [bool]) { $value -ieq 'True' } else { $value }
    }
    return $loaded
}

function Save-Config($Values) {
    $Values.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value } |
        Set-Content -LiteralPath $ConfigFile -Encoding ASCII
}

$Config    = Read-Config
$OutputDir = Join-Path $ScriptDir $Config.outputDir

function Get-ConfigNumber([string]$Key) {
    # Numeric settings are stored as text; fall back to the default if one was edited into nonsense
    $value = 0.0
    foreach ($candidate in $Config[$Key], $DefaultConfig[$Key]) {
        if ([double]::TryParse("$candidate", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $value }
    }
    return 0.0
}

function Format-Number([double]$Value) {
    # Encoder command lines need "22.5", never "22,5" (regional settings)
    return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}


### CONSOLE HELPERS ###

function Test-InteractiveConsole {
    # [Console]::ReadKey needs a real console: not a remote session, ISE or redirected input
    try { return (-not [Console]::IsInputRedirected) -and ($Host.Name -eq 'ConsoleHost') } catch { return $false }
}

function Wait-AnyKey([string]$Message = "Press any key to continue...") {
    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
    [void][Console]::ReadKey($true)
}

function Show-Header {
    Clear-Host
    Write-Host @"
      _ ______                     _
     | |  ____|                   | |
     | | |__   _ __   ___ ___   __| | ___ _ __
 _   | |  __| | '_ \ / __/ _ \ / _  |/ _ \ '__|
| |__| | |____| | | | (_| (_) | (_| |  __/ |
 \____/|______|_| |_|\___\___/ \__,_|\___|_|

                        Version: $ScriptVersion

"@ -ForegroundColor Cyan
}

function Write-Title([string]$Title) {
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("  " + ("-" * $Title.Length)) -ForegroundColor Yellow
    Write-Host ""
}

function Show-Menu {
    # Arrow-key single-select menu. Returns the 0-based index, or -1 for Escape.
    param ([string]$Title, [string[]]$Items, [int[]]$RedItems = @())
    $idx = 0
    while ($true) {
        Show-Header
        Write-Title $Title
        for ($i = 0; $i -lt $Items.Length; $i++) {
            if ($i -eq $idx) {
                Write-Host ("  > " + $Items[$i]) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                $color = if ($RedItems -contains $i) { 'Red' } else { 'White' }
                Write-Host ("    " + $Items[$i]) -ForegroundColor $color
            }
        }
        Write-Host ""
        Write-Host "  UP/DOWN: navigate   ENTER: select   ESC: back" -ForegroundColor DarkGray
        switch ([Console]::ReadKey($true).Key) {
            'UpArrow'   { if ($idx -gt 0) { $idx-- } }
            'DownArrow' { if ($idx -lt $Items.Length - 1) { $idx++ } }
            'Enter'     { return $idx }
            'Escape'    { return -1 }
        }
    }
}

function Format-ByteSize([double]$Bytes) {
    $units = 'Bytes', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Length - 1) { $Bytes /= 1024; $i++ }
    return "{0:N2} {1}" -f $Bytes, $units[$i]
}


### CONFIGURATION SCREENS ###

function Show-Configuration {
    Show-Header
    Write-Title "Current Configuration ($ConfigFile)"
    foreach ($key in $Config.Keys) {
        Write-Host ("  {0,-24} {1}" -f $key, $Config[$key]) -ForegroundColor White
    }
    Wait-AnyKey "Press any key to return..."
}

function Edit-Configuration {
    $draft = [ordered]@{}
    foreach ($key in $Config.Keys) { $draft[$key] = $Config[$key] }
    $keys = [string[]]$DefaultConfig.Keys
    $idx  = 0

    while ($true) {
        Show-Header
        Write-Title "Edit Configuration"
        Write-Host "  UP/DOWN: navigate   SPACE/ENTER: toggle or edit   S: save   Q/ESC: discard" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $keys.Length; $i++) {
            $key    = $keys[$i]
            $isBool = $DefaultConfig[$key] -is [bool]
            $shown  = if ($isBool) { if ($draft[$key]) { "[ ON]" } else { "[OFF]" } } else { "$($draft[$key])" }
            $line   = "  {0}{1,-26} {2,-22} (default: {3})" -f $(if ($i -eq $idx) { "> " } else { "  " }), $key, $shown, $DefaultConfig[$key]
            if ($i -eq $idx)                      { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
            elseif ($isBool -and $draft[$key])    { Write-Host $line -ForegroundColor Green }
            else                                  { Write-Host $line -ForegroundColor White }
        }
        Write-Host ""

        $keyInfo = [Console]::ReadKey($true)
        $key     = $keys[$idx]
        switch ($keyInfo.Key) {
            'UpArrow'   { if ($idx -gt 0) { $idx-- } }
            'DownArrow' { if ($idx -lt $keys.Length - 1) { $idx++ } }
            'Escape'    { return }
            { $_ -in 'Spacebar', 'Enter' } {
                if ($DefaultConfig[$key] -is [bool]) {
                    $draft[$key] = -not $draft[$key]
                } elseif ($keyInfo.Key -eq 'Enter') {
                    $newValue = Read-Host ("  New value for '{0}' (current: '{1}')" -f $key, $draft[$key])
                    if ($newValue.Trim() -ne '') { $draft[$key] = $newValue.Trim() }
                }
            }
            default {
                if ($keyInfo.KeyChar -eq 's') {
                    Save-Config $draft
                    foreach ($k in $draft.Keys) { $script:Config[$k] = $draft[$k] }
                    $script:OutputDir = Join-Path $ScriptDir $Config.outputDir
                    Write-Host "  Configuration saved." -ForegroundColor Green
                    Start-Sleep -Milliseconds 1000
                    return
                }
                if ($keyInfo.KeyChar -eq 'q') { return }
            }
        }
    }
}


### MEDIA FILE SELECTION ###

function Get-MediaFiles([string]$Root) {
    # -LiteralPath everywhere: media folder/file names often contain [ ], which -Path treats as wildcards
    $outputPrefix = $OutputDir.TrimEnd('\') + '\'
    $toDelPattern = '\\' + [regex]::Escape($Config.toDeleteDir) + '(\\|$)'
    Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            ($MediaExtensions -contains $_.Extension.ToLower()) -and
            -not ($_.DirectoryName + '\').StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            ($_.DirectoryName -ne $EncoderDir) -and
            ($_.DirectoryName -notmatch $toDelPattern)
        } |
        Sort-Object FullName
}

function Select-ScanFolder([string]$Current) {
    # Returns a folder path, or $null to cancel
    while ($true) {
        Show-Header
        Write-Title "Select Scan Folder"
        Write-Host "  Enter the full path of the folder to scan for media files." -ForegroundColor White
        Write-Host "  Leave blank for $(if ($Current) { 'the current folder' } else { 'the script folder' }). Type Q to cancel." -ForegroundColor DarkGray
        if ($Current) { Write-Host "  Current: $Current" -ForegroundColor Cyan }
        Write-Host ""

        $raw = (Read-Host "  Path").Trim().Trim('"')
        if ($raw -ieq 'q') { return $null }
        $target = if ($raw) { $raw } elseif ($Current) { $Current } else { $ScriptDir }

        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            Write-Host "  Folder not found: $target" -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        if (@(Get-MediaFiles $target).Count -gt 0) { return $target }

        $answer = Read-Host "  No .mp4/.mkv files found there. Choose a different folder? (Y/N)"
        if ($answer -imatch '^n') { return $null }
    }
}

function Select-FilesToProcess([string]$ScanDir) {
    # Checkbox multi-select. Returns the chosen FileInfo objects, or $null to go back.
    $files = @(Get-MediaFiles $ScanDir)
    if ($files.Count -eq 0) {
        Write-Host "  No eligible media files found in: $ScanDir" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return $null
    }

    $checked  = @($true) * $files.Count
    $idx      = 0
    $pageSize = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height - 15)

    while ($true) {
        Show-Header
        Write-Title "Select Files to Encode"
        Write-Host "  SPACE: toggle   A: toggle all   ENTER: confirm   ESC: back" -ForegroundColor DarkGray
        Write-Host ""
        $checkedCount = @($checked | Where-Object { $_ }).Count
        Write-Host ("  {0}/{1} file(s) selected" -f $checkedCount, $files.Count) -ForegroundColor Cyan
        Write-Host ""

        $first = [Math]::Max(0, [Math]::Min($idx - [Math]::Floor($pageSize / 2), $files.Count - $pageSize))
        $last  = [Math]::Min($files.Count - 1, $first + $pageSize - 1)
        for ($i = $first; $i -le $last; $i++) {
            $relative = $files[$i].FullName.Substring($ScanDir.TrimEnd('\').Length).TrimStart('\')
            $line = "  {0} {1,-55} {2,10}" -f $(if ($checked[$i]) { "[x]" } else { "[ ]" }), $relative, (Format-ByteSize $files[$i].Length)
            if ($i -eq $idx)       { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
            elseif ($checked[$i])  { Write-Host $line -ForegroundColor White }
            else                   { Write-Host $line -ForegroundColor DarkGray }
        }
        if ($files.Count -gt $pageSize) {
            Write-Host ("`n  (showing {0}-{1} of {2})" -f ($first + 1), ($last + 1), $files.Count) -ForegroundColor DarkGray
        }

        $keyInfo = [Console]::ReadKey($true)
        switch ($keyInfo.Key) {
            'UpArrow'   { if ($idx -gt 0) { $idx-- } }
            'DownArrow' { if ($idx -lt $files.Count - 1) { $idx++ } }
            'Spacebar'  { $checked[$idx] = -not $checked[$idx] }
            'Escape'    { return $null }
            'Enter' {
                $chosen = @(for ($i = 0; $i -lt $files.Count; $i++) { if ($checked[$i]) { $files[$i] } })
                if ($chosen.Count -gt 0) { return $chosen }
                Write-Host "  Select at least one file." -ForegroundColor Red
                Start-Sleep -Milliseconds 1200
            }
            default {
                if ($keyInfo.KeyChar -eq 'a') {
                    $allOn = $checkedCount -eq $files.Count
                    for ($i = 0; $i -lt $files.Count; $i++) { $checked[$i] = -not $allOn }
                }
            }
        }
    }
}


### TOOL DOWNLOADS ###

function Invoke-Download([string]$Uri, [string]$OutFile) {
    # -UseBasicParsing: Windows Server often has no IE engine, which 5.1 otherwise needs
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers @{ 'User-Agent' = 'JEncoder' } -ErrorAction Stop
}

function Get-Json([string]$Uri) {
    Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'JEncoder' } -ErrorAction Stop
}

function New-TempDir {
    # A fresh folder per download, so an older extracted build is never picked up by mistake
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("JEncoder-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

function Get-SevenZip {
    # Needed only for the FFmpeg and MKVToolNix .7z archives
    $candidates = @(
        (Join-Path $EncoderDir "7z.exe"), (Join-Path $EncoderDir "7zr.exe"), (Join-Path $ScriptDir "7z.exe"),
        "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    $onPath = Get-Command 7z.exe, 7za.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    # 7zr.exe is 7-Zip's official standalone extractor for .7z (the old 7za.exe URL is gone)
    Write-Host "Downloading 7-Zip (7zr.exe)..." -ForegroundColor Cyan
    $dest = Join-Path $EncoderDir "7zr.exe"
    Invoke-Download "https://www.7-zip.org/a/7zr.exe" $dest
    return $dest
}

function Expand-7z([string]$Archive, [string]$Destination) {
    & (Get-SevenZip) x $Archive "-o$Destination" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to extract $Archive (exit code $LASTEXITCODE)" }
}

function Install-HandBrake {
    $temp = New-TempDir
    try {
        $release = Get-Json "https://api.github.com/repos/HandBrake/HandBrake/releases/latest"
        $asset = $release.assets | Where-Object { $_.name -match '^HandBrakeCLI-.*-win-x86_64\.zip$' } | Select-Object -First 1
        if (-not $asset) { throw "No HandBrakeCLI x86_64 zip in release $($release.tag_name)" }
        $zip = Join-Path $temp "HandBrakeCLI.zip"
        Invoke-Download $asset.browser_download_url $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force
        $exe = Get-ChildItem -LiteralPath $temp -Recurse -Filter "HandBrakeCLI.exe" | Select-Object -First 1
        if (-not $exe) { throw "HandBrakeCLI.exe not found in the download" }
        Copy-Item -LiteralPath $exe.FullName -Destination $Tools.HandBrake -Force
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-FFmpeg {
    $temp = New-TempDir
    try {
        $archive = Join-Path $temp "ffmpeg.7z"
        Invoke-Download "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z" $archive
        Expand-7z $archive $temp
        foreach ($name in 'ffmpeg', 'ffprobe') {
            $exe = Get-ChildItem -LiteralPath $temp -Recurse -Filter "$name.exe" | Select-Object -First 1
            if (-not $exe) { throw "$name.exe not found in the download" }
            Copy-Item -LiteralPath $exe.FullName -Destination $Tools[$(if ($name -eq 'ffmpeg') { 'FFmpeg' } else { 'FFprobe' })] -Force
        }
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-LatestMKVToolNixVersion {
    $page = Invoke-WebRequest -Uri "https://mkvtoolnix.download/downloads.html" -UseBasicParsing -ErrorAction Stop
    [regex]::Matches($page.Content, 'windows/releases/(\d+\.\d+(?:\.\d+)?)') |
        ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending | Select-Object -First 1
}

function Install-MKVPropEdit {
    $temp = New-TempDir
    try {
        $version = Get-LatestMKVToolNixVersion
        if (-not $version) { throw "Could not detect the latest MKVToolNix version" }
        $archive = Join-Path $temp "mkvtoolnix.7z"
        Invoke-Download "https://mkvtoolnix.download/windows/releases/$version/mkvtoolnix-64-bit-$version.7z" $archive
        Expand-7z $archive $temp
        $exe = Get-ChildItem -LiteralPath $temp -Recurse -Filter "mkvpropedit.exe" | Select-Object -First 1
        if (-not $exe) { throw "mkvpropedit.exe not found in the download" }
        Copy-Item -LiteralPath $exe.FullName -Destination $Tools.MKVPropEdit -Force
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Which installer provides which tool
$Installers = [ordered]@{
    HandBrake   = { Install-HandBrake }
    FFmpeg      = { Install-FFmpeg }
    MKVPropEdit = { Install-MKVPropEdit }
}

function Install-Tool([string]$Name) {
    Write-Host "Downloading $Name..." -ForegroundColor Cyan
    try {
        & $Installers[$Name]
        Write-Host "  $Name installed." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  Failed to download ${Name}: $_" -ForegroundColor Red
        return $false
    }
}

function Install-MissingTools {
    New-Item -ItemType Directory -Force -Path $EncoderDir | Out-Null
    Write-Host "Checking encoders in $EncoderDir" -ForegroundColor Yellow
    $missing = @($Tools.Keys | Where-Object { -not (Test-Path -LiteralPath $Tools[$_]) } | Sort-Object)
    if ($missing.Count -eq 0) {
        Write-Host "All encoders present." -ForegroundColor Green
        return
    }
    Write-Host ("Missing: " + ($missing -join ', ')) -ForegroundColor Red
    # FFprobe comes with FFmpeg
    $toInstall = $missing | ForEach-Object { if ($_ -eq 'FFprobe') { 'FFmpeg' } else { $_ } } | Select-Object -Unique
    foreach ($name in $toInstall) { [void](Install-Tool $name) }
}


### UPDATES ###

function Get-InstalledVersions {
    $versions = @{ JEncoder = $ScriptVersion }
    $probe = @{
        HandBrake   = { (& $Tools.HandBrake --version 2>$null | Select-String '^HandBrake\s+(\S+)').Matches.Groups[1].Value }
        FFmpeg      = { (& $Tools.FFmpeg -version | Select-String '^ffmpeg version (\d{4}-\d{2}-\d{2})').Matches.Groups[1].Value }
        MKVPropEdit = { (& $Tools.MKVPropEdit --version | Select-String 'v(\d+\.\d+(\.\d+)?)').Matches.Groups[1].Value }
    }
    foreach ($name in $probe.Keys) {
        $versions[$name] = 'Unknown'
        if (Test-Path -LiteralPath $Tools[$name]) {
            try { $v = & $probe[$name]; if ($v) { $versions[$name] = $v } } catch { }
        }
    }
    return $versions
}

function Get-LatestVersions {
    $latest = @{ JEncoder = 'Unknown'; HandBrake = 'Unknown'; FFmpeg = 'Unknown'; MKVPropEdit = 'Unknown'; JEncoderRelease = $null }
    try {
        $release = Get-Json "https://api.github.com/repos/Jarsky/JEncoder/releases/latest"
        $latest.JEncoder        = $release.tag_name -replace '^(JEncoder-)?v', ''
        $latest.JEncoderRelease = $release
    } catch { }
    try { $latest.HandBrake = (Get-Json "https://api.github.com/repos/HandBrake/HandBrake/releases/latest").tag_name.TrimStart('v') } catch { }
    try {
        $git = [string](Get-Json "https://www.gyan.dev/ffmpeg/builds/git-version")
        if ($git -match '(\d{4}-\d{2}-\d{2})') { $latest.FFmpeg = $matches[1] }
    } catch { }
    try { $latest.MKVPropEdit = "$(Get-LatestMKVToolNixVersion)" } catch { }
    return $latest
}

function Test-NewerVersion([string]$Current, [string]$Latest) {
    # FFmpeg git builds are dated (yyyy-MM-dd); the rest are dotted versions. Both compare as [version].
    try { return [version]($Latest -replace '-', '.') -gt [version]($Current -replace '-', '.') } catch { return $Current -ne $Latest }
}

function Update-JEncoderScript($Release) {
    $temp = New-TempDir
    try {
        $asset = $Release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if (-not $asset) { throw "The latest release has no .zip asset" }
        $zip = Join-Path $temp "JEncoder.zip"
        Invoke-Download $asset.browser_download_url $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force
        $newScript = Get-ChildItem -LiteralPath $temp -Recurse -Filter "*.ps1" | Select-Object -First 1
        if (-not $newScript) { throw "No .ps1 in the release archive" }
        # $PSCommandPath is this script's path ($MyInvocation inside a function is the function)
        Copy-Item -LiteralPath $newScript.FullName -Destination $PSCommandPath -Force
        Unblock-File -LiteralPath $PSCommandPath   # otherwise RemoteSigned policy refuses to run it
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-UpdateCheck {
    Show-Header
    Write-Title "Checking for updates"
    $installed = Get-InstalledVersions
    $latest    = Get-LatestVersions
    $outdated  = @()

    foreach ($name in 'JEncoder', 'HandBrake', 'FFmpeg', 'MKVPropEdit') {
        Write-Host ("  {0,-12} {1,-14}" -f $name, $installed[$name]) -NoNewline
        if ($installed[$name] -eq 'Unknown' -or $latest[$name] -eq 'Unknown') {
            Write-Host "(unable to check)" -ForegroundColor DarkGray
        } elseif (Test-NewerVersion $installed[$name] $latest[$name]) {
            Write-Host "(update available: $($latest[$name]))" -ForegroundColor Yellow
            $outdated += $name
        } else {
            Write-Host "(up to date)" -ForegroundColor Green
        }
    }

    if ($outdated.Count -eq 0) { Wait-AnyKey "Press any key to return..."; return }
    if ((Read-Host "`n  Update now? (Y/N)") -notmatch '^(y|yes)$') { return }

    foreach ($name in $outdated) {
        if ($name -eq 'JEncoder') {
            try {
                Update-JEncoderScript $latest.JEncoderRelease
                Write-Host "JEncoder updated. Please start the script again." -ForegroundColor Green
                exit
            } catch {
                Write-Host "Failed to update JEncoder: $_" -ForegroundColor Red
            }
        } else {
            [void](Install-Tool $name)
        }
    }
    Wait-AnyKey "Press any key to return..."
}


### ENCODING ###

# Quality search range and the bitrate a 1080p encode gets at quality 28 (first-guess model), as in
# tdarr-adaptive-hevc: NVENC needs ~1-2 more CQ than x265 CRF for the same size.
$Backends = @{
    HandBrake      = @{ Label = 'HandBrake (CPU)';   Tool = 'HandBrake'; NVENC = $false; QualityMin = 16; QualityMax = 34; Ref28Kbps = 2300 }
    HandBrakeNVENC = @{ Label = 'HandBrake (NVENC)'; Tool = 'HandBrake'; NVENC = $true;  QualityMin = 18; QualityMax = 38; Ref28Kbps = 2900 }
    FFmpeg         = @{ Label = 'FFmpeg (CPU)';      Tool = 'FFmpeg';    NVENC = $false; QualityMin = 16; QualityMax = 34; Ref28Kbps = 2300 }
    FFmpegNVENC    = @{ Label = 'FFmpeg (NVENC)';    Tool = 'FFmpeg';    NVENC = $true;  QualityMin = 18; QualityMax = 38; Ref28Kbps = 2900 }
}

function Get-VideoEncoderName([string]$BackendName) {
    switch ($BackendName) {
        'HandBrake'      { $Config.handbrakeEncoder }
        'HandBrakeNVENC' { $Config.handbrakeEncoderNVENC }
        'FFmpeg'         { $Config.ffmpegEncoder }
        'FFmpegNVENC'    { $Config.ffmpegEncoderNVENC }
    }
}

function Get-OutputName([IO.FileInfo]$File, [string]$VideoEncoder) {
    $name = $File.BaseName
    if ($Config.replaceSpaces) { $name = $name -replace ' ', '.' }

    if ($Config.renameOutputFile) {
        # Swap codec tags in the release name for the codec actually used
        # e.g. x265, libx265, nvenc_h265, hevc_nvenc -> x265
        $codecTag = switch -Regex ($VideoEncoder) { '265|hevc' { 'x265'; break } '264|avc' { 'x264'; break } 'av1' { 'AV1'; break } default { $null } }
        if ($codecTag) {
            $name = $name -replace '(?<![a-z0-9])([hx][\s\.-]?26[45]|hevc|av1|xvid|divx)(?![a-z0-9])', $codecTag
        }
        $audioTag = switch -Regex ($Config.audioEncoder) {
            '^copy$' { $null; break } 'truehd' { 'TrueHD'; break } 'opus' { 'Opus'; break } '^pcm' { 'PCM'; break }
            'flac' { 'FLAC'; break } 'eac3' { 'DDP'; break } 'ac3' { 'AC3'; break } 'mp3' { 'MP3'; break } 'aac' { 'AAC'; break }
            default { $null }
        }
        if ($audioTag) {
            $name = $name -replace '(?<![a-z0-9])(DDP?\+?|DD|E?AC3|FLAC|DTS(-?HD)?([\s\.-]?MA)?|L?PCM|TrueHD|AAC|MP3|Opus)(?=[\s\.-]?\d\.\d|[^a-z0-9]|$)', $audioTag
        }
    }
    return $name + $File.Extension
}

function Get-HandBrakeAudioArgs {
    # HandBrake re-encodes audio to stereo unless told otherwise; honour audioEncoder like FFmpeg does
    $map = @{ copy = 'copy'; aac = 'av_aac'; libfdk_aac = 'av_aac'; opus = 'opus'; libopus = 'opus'
              ac3 = 'ac3'; eac3 = 'eac3'; flac = 'flac24'; mp3 = 'mp3'; libmp3lame = 'mp3' }
    $audio = $Config.audioEncoder.ToLower()
    $hbAudio = if ($map.ContainsKey($audio)) { $map[$audio] } else { $audio }
    if ($hbAudio -eq 'copy') { return "--all-audio -E copy --audio-fallback av_aac" }
    return "--all-audio -E $hbAudio --mixdown none"
}

function Get-ConfiguredQuality([string]$BackendName) {
    if ($Backends[$BackendName].Tool -eq 'HandBrake') { return Get-ConfigNumber 'handbrakeQuality' }
    return Get-ConfigNumber 'ffmpegQuality'
}

function Get-EncoderArgs {
    # The same arguments are used for the sample encodes and the real encode, so samples predict it.
    # $Info (from Get-SourceInfo) adds the HEVC extras: 10-bit, HDR metadata, a bitrate cap at the
    # source's video bitrate so the encode is never bigger than the original.
    param ([string]$BackendName, [string]$InputPath, [string]$OutputPath, [double]$Quality, [hashtable]$Info)
    $q       = $Config
    $quality = Format-Number $Quality
    $hevc    = (Get-VideoEncoderName $BackendName) -match '265|hevc'
    $tenBit  = $hevc -and ($q.tenBit -or ($Info -and $Info.Hdr -ne 'SDR'))
    $kbps    = if ($hevc -and $Info -and $Info.VideoKbps -gt 0) { [int][Math]::Round($Info.VideoKbps) } else { 0 }
    switch ($BackendName) {
        { $_ -in 'HandBrake', 'HandBrakeNVENC' } {
            if ($_ -eq 'HandBrake') {
                $encoder, $preset = $q.handbrakeEncoder, $q.handbrakePreset
            } else {
                # HandBrake's NVENC presets are fastest..slowest; older configs used "default"
                $encoder = $q.handbrakeEncoderNVENC
                $preset  = if ($q.handbrakeNVENCPreset -eq 'default') { 'medium' } else { $q.handbrakeNVENCPreset }
            }
            # HandBrake carries HDR10/HLG metadata itself for 10-bit HEVC
            if ($tenBit -and $encoder -in 'x265', 'nvenc_h265') { $encoder += '_10bit' }
            $vbv = if ($kbps -and $encoder -like 'x265*') { " --encopts vbv-maxrate=$($kbps):vbv-bufsize=$(2 * $kbps)" } else { "" }
            "-i `"$InputPath`" -o `"$OutputPath`" -e $encoder --encoder-preset $preset -q $quality$vbv --cfr " +
            "$(Get-HandBrakeAudioArgs) --all-subtitles"
        }
        { $_ -in 'FFmpeg', 'FFmpegNVENC' } {
            $color = if ($Info -and $Info.Hdr -ne 'SDR') {
                " -color_primaries $($Info.Color.Primaries) -color_trc $($Info.Color.Transfer) -colorspace $($Info.Color.Space)"
            } else { "" }
            if ($_ -eq 'FFmpeg') {
                $video = "-c:v $($q.ffmpegEncoder) -preset $($q.ffmpegPreset) -crf $quality"
                if ($hevc) {
                    $params = @('log-level=error')
                    if ($kbps) { $params += "vbv-maxrate=$kbps", "vbv-bufsize=$(2 * $kbps)" }
                    if ($Info -and $Info.X265Hdr) { $params += $Info.X265Hdr }
                    if ($tenBit) { $video += " -pix_fmt yuv420p10le -profile:v main10" }
                    $video += " -x265-params $($params -join ':')"
                }
            } else {
                # -cq only acts as a quality target in VBR mode; -maxrate caps it at the source bitrate
                $video = "-c:v $($q.ffmpegEncoderNVENC) -preset $($q.ffmpegNVENCPreset) -rc vbr -cq $quality -b:v 0"
                if ($tenBit) { $video += " -profile:v main10 -pix_fmt p010le" }
                if ($kbps) { $video += " -maxrate $($kbps)k -bufsize $(2 * $kbps)k" }
            }
            # -c copy first so attachments/data streams are copied rather than failing codec selection
            $extra = if ($_ -eq 'FFmpegNVENC') { " -disposition:s:0 0 -max_muxing_queue_size 9999" } else { "" }
            "-y -hide_banner -i `"$InputPath`" -map 0 -c copy $video$color -c:a $($q.audioEncoder)$extra `"$OutputPath`""
        }
    }
}

function Get-MediaDuration([string]$FilePath) {
    $value = & $Tools.FFprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null
    $seconds = 0.0
    if ([double]::TryParse("$value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) { return $seconds }
    return 0.0
}

function Read-FileTail([string]$FilePath, [int]$Bytes = 8192) {
    # Reads the end of a log the encoder is still writing (shared read, no full re-read each tick)
    try {
        $stream = [IO.File]::Open($FilePath, 'Open', 'Read', 'ReadWrite')
        try {
            $length = [int][Math]::Min($Bytes, $stream.Length)
            if ($length -le 0) { return '' }
            [void]$stream.Seek(-$length, 'End')
            $buffer = New-Object byte[] $length
            $read = $stream.Read($buffer, 0, $length)
            return [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        } finally { $stream.Dispose() }
    } catch { return '' }
}

function Get-Progress([string]$Text, [string]$Tool, [double]$Duration) {
    # Returns @{Percent; FPS; Speed; ETA} from the latest progress line, or $null
    $lines = $Text -split '[\r\n]+'
    if ($Tool -eq 'HandBrake') {
        # Encoding: task 1 of 1, 45.32 % (234.56 fps, avg 230.10 fps, ETA 00h02m30s)
        $line = $lines | Where-Object { $_ -match '\d+\.\d+\s*%' } | Select-Object -Last 1
        if (-not $line) { return $null }
        $null = $line -match '(\d+\.\d+)\s*%'; $percent = [double]$matches[1]
        $fps = if ($line -match '\((\d+\.\d+)\s*fps') { $matches[1] } else { '' }
        $eta = if ($line -match 'ETA\s+(\S+?)\)') { $matches[1] } else { '' }
        return @{ Percent = $percent; FPS = $fps; Speed = ''; ETA = $eta }
    }
    # frame=  123 fps= 23 q=28.0 size= 12kB time=00:01:23.45 bitrate=... speed=3.45x
    $line = $lines | Where-Object { $_ -match 'time=\d+:\d+:\d+' } | Select-Object -Last 1
    if (-not $line) { return $null }
    $null = $line -match 'time=(\d+):(\d+):(\d+(\.\d+)?)'
    $position = [int]$matches[1] * 3600 + [int]$matches[2] * 60 + [double]::Parse($matches[3], [Globalization.CultureInfo]::InvariantCulture)
    $percent  = if ($Duration -gt 0) { 100 * $position / $Duration } else { 0 }
    $fps   = if ($line -match 'fps=\s*(\d+(\.\d+)?)') { $matches[1] } else { '' }
    $speed = if ($line -match 'speed=\s*(\d+(\.\d+)?)x') { $matches[1] + 'x' } else { '' }
    $eta = ''
    if ($speed -and [double]$speed.TrimEnd('x') -gt 0 -and $Duration -gt 0) {
        $eta = [TimeSpan]::FromSeconds([Math]::Max(0.0, ($Duration - $position) / [double]$speed.TrimEnd('x'))).ToString("hh\hmm\mss\s")
    }
    return @{ Percent = $percent; FPS = $fps; Speed = $speed; ETA = $eta }
}

function Write-ProgressBar([double]$Percent, [string]$FPS, [string]$Speed, [string]$ETA, [string]$Elapsed) {
    $width = try { $Host.UI.RawUI.WindowSize.Width } catch { 80 }
    if ($width -lt 40) { $width = 80 }
    $Percent = [Math]::Min([Math]::Max($Percent, 0), 100)
    $stats = " {0,3:N0}%" -f $Percent
    if ($FPS)     { $stats += " | $FPS fps" }
    if ($Speed)   { $stats += " | $Speed" }
    if ($ETA)     { $stats += " | ETA: $ETA" }
    if ($Elapsed) { $stats += " | Elapsed: $Elapsed" }
    $barWidth = [Math]::Max(5, $width - $stats.Length - 3)
    $filled = [int][Math]::Floor($barWidth * $Percent / 100)
    $bar = "[" + ([string][char]0x2588 * $filled) + ([string][char]0x2591 * ($barWidth - $filled)) + "]" + $stats
    Write-Host ("`r" + $bar.PadRight($width - 1)) -NoNewline -ForegroundColor Cyan
}

function Invoke-EncoderProcess {
    # Runs the encoder (with a live progress bar unless -Quiet). Returns @{ ExitCode; Log }.
    param ([string]$BackendName, [string]$InputPath, [string]$OutputPath, [double]$Quality, [hashtable]$Info, [switch]$Quiet)
    $tool     = $Backends[$BackendName].Tool
    $duration = if ($tool -eq 'FFmpeg' -and -not $Quiet) { Get-MediaDuration $InputPath } else { 0 }
    $errLog   = [IO.Path]::GetTempFileName()
    $outLog   = [IO.Path]::GetTempFileName()
    # HandBrake reports progress on stdout, FFmpeg on stderr
    $progressLog = if ($tool -eq 'HandBrake') { $outLog } else { $errLog }
    try {
        $arguments = Get-EncoderArgs -BackendName $BackendName -InputPath $InputPath -OutputPath $OutputPath `
            -Quality $Quality -Info $Info
        $proc = Start-Process -FilePath $Tools[$tool] -ArgumentList $arguments `
            -NoNewWindow -PassThru -RedirectStandardError $errLog -RedirectStandardOutput $outLog
        # Without touching .Handle, ExitCode is $null after exit (PowerShell quirk). v1.7 read that
        # as 0, so failed encodes were reported as successful and their originals moved away.
        $null = $proc.Handle
        $started = Get-Date
        $interactive = (Test-InteractiveConsole) -and -not $Quiet

        while (-not $proc.WaitForExit(500)) {
            $progress = Get-Progress (Read-FileTail $progressLog) $tool $duration
            if ($progress -and $interactive) {
                $elapsed = "{0:hh\hmm\mss\s}" -f ((Get-Date) - $started)
                Write-ProgressBar $progress.Percent $progress.FPS $progress.Speed $progress.ETA $elapsed
            }
        }
        $proc.WaitForExit()
        if ($interactive) {
            Write-ProgressBar 100 '' '' '' ("{0:hh\hmm\mss\s}" -f ((Get-Date) - $started))
            Write-Host ""
        }
        $log = (Get-Content -LiteralPath $errLog -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
        return @{ ExitCode = $proc.ExitCode; Log = $log }
    } finally {
        Remove-Item -LiteralPath $errLog, $outLog -Force -ErrorAction SilentlyContinue
    }
}

### TARGET-SIZE QUALITY SEARCH ###
# The same rules as tdarr-adaptive-hevc (Source Profile, Quality Report, Verify). Size rules are for the
# whole file (aim for targetReduction, never past maxReduction, skip under minKeepReduction) and are
# converted to a video-stream target per file, because audio and subtitles are copied unchanged.

$SizeRules = @{
    OnTarget    = 5      # a sample result within +/- this many % of the target ends the search
    MaxRounds   = 5      # sample rounds per file
    RetryBelow  = 30     # a real encode saving less than this % is retried with a corrected quality
    AcceptAbove = 15     # when no retry is left, still replace the original if it saves this % or more
    Grace       = 3      # samples are estimates: allow this much past maxReduction before a retry
    BrokenAbove = 90     # saving more than this % means a broken encode, not a good one
    LeanBpp     = 0.045  # H.264-equivalent bits/pixel below which a source is already lean
    MinSeconds  = 20
}
# How efficient each source codec is relative to H.264, for the "already lean?" test
$CodecEfficiency = @{ mpeg1video = 0.45; mpeg2video = 0.5; msmpeg4v2 = 0.55; msmpeg4v3 = 0.6; mpeg4 = 0.65; wmv1 = 0.6
                      wmv2 = 0.65; wmv3 = 0.8; vc1 = 0.85; vp8 = 0.9; h264 = 1.0; vp9 = 1.4 }

function ConvertTo-Double($Value) {
    $n = 0.0
    if ([double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    return 0.0
}

function ConvertTo-Fraction([string]$Text) {
    # "24000/1001" -> 23.976; ffprobe's mastering-display values use the same form
    $parts = "$Text".Split('/')
    if ($parts.Count -eq 2 -and (ConvertTo-Double $parts[1]) -ne 0) { return (ConvertTo-Double $parts[0]) / (ConvertTo-Double $parts[1]) }
    return ConvertTo-Double $Text
}

function Get-StreamKbps($Stream) {
    $bps = ConvertTo-Double $Stream.bit_rate
    if (-not $bps -and $Stream.tags) {
        foreach ($p in $Stream.tags.PSObject.Properties) { if ($p.Name -match '^BPS(-eng)?$') { $bps = ConvertTo-Double $p.Value } }
    }
    return $bps / 1000
}

function Get-SourceInfo([string]$FilePath) {
    # Everything the skip rules, the size maths and the encoder arguments need to know about the source
    $probe    = (& $Tools.FFprobe -v error -of json -show_format -show_streams $FilePath) -join "`n" | ConvertFrom-Json
    $streams  = @($probe.streams)
    $video    = $streams | Where-Object { $_.codec_type -eq 'video' -and -not $_.disposition.attached_pic } | Select-Object -First 1
    $duration = ConvertTo-Double $probe.format.duration
    $size     = ConvertTo-Double $probe.format.size
    $info = @{ Duration = $duration; Size = $size; VideoCodec = ''; Height = 0; FrameRate = '24'; VideoKbps = 0.0; VideoBytes = $size * 0.85
               EffectiveBpp = 0.0; Hdr = 'SDR'; DolbyVision = $false; Color = $null; X265Hdr = '' }
    if (-not $video) { return $info }

    # Per-stream bitrate tags (MKV "BPS") can be stale when a tool re-encoded the file but copied the old
    # tags, so check them against the real size and fall back to "total minus the other streams"
    $totalKbps = if ($duration -gt 0) { $size * 8 / 1000 / $duration } else { 0 }
    $otherKbps = 0.0
    foreach ($s in $streams) { if (-not [object]::ReferenceEquals($s, $video)) { $otherKbps += Get-StreamKbps $s } }
    $sizeKbps = [Math]::Max(0.0, $totalKbps - [Math]::Min($totalKbps * 0.6, $otherKbps))
    $kbps     = Get-StreamKbps $video
    if ($totalKbps -and (-not $kbps -or $kbps -gt $totalKbps * 1.05 -or $kbps -lt $sizeKbps * 0.6)) { $kbps = $sizeKbps }

    $info.FrameRate = "$($video.avg_frame_rate)"
    $fps = ConvertTo-Fraction $info.FrameRate
    if (-not $fps) { $info.FrameRate = "$($video.r_frame_rate)"; $fps = ConvertTo-Fraction $info.FrameRate }
    if (-not $fps) { $info.FrameRate = '24'; $fps = 24 }
    $pixels = (ConvertTo-Double $video.width) * (ConvertTo-Double $video.height) * $fps
    $eff    = if ($CodecEfficiency.ContainsKey("$($video.codec_name)")) { $CodecEfficiency["$($video.codec_name)"] } else { 0.8 }

    $info.VideoCodec   = "$($video.codec_name)"
    $info.Height       = [int](ConvertTo-Double $video.height)
    $info.VideoKbps    = $kbps
    if ($kbps -gt 0 -and $duration -gt 0) { $info.VideoBytes = [Math]::Min($size, $kbps * 1000 / 8 * $duration) }
    if ($pixels -gt 0) { $info.EffectiveBpp = $kbps * 1000 / $pixels * $eff }
    $info.DolbyVision  = @($video.side_data_list | Where-Object { "$($_.side_data_type)" -match 'DOVI' }).Count -gt 0

    $transfer = "$($video.color_transfer)"
    if ($transfer -notin 'smpte2084', 'arib-std-b67') { return $info }
    $info.Hdr   = if ($transfer -eq 'smpte2084') { 'HDR10' } else { 'HLG' }
    $primaries  = if ($video.color_primaries) { "$($video.color_primaries)" } else { 'bt2020' }
    $matrix     = if ($video.color_space -eq 'bt2020c') { 'bt2020c' } else { 'bt2020nc' }
    $info.Color = @{ Primaries = $primaries; Transfer = $transfer; Space = $matrix }
    # x265 needs the HDR signalling spelled out (FFmpeg CPU path; HandBrake handles it itself)
    $params = @("colorprim=$primaries", "transfer=$transfer", "colormatrix=$matrix", 'repeat-headers=1')
    if ($info.Hdr -eq 'HDR10') {
        $params += 'hdr10=1', 'hdr10-opt=1'
        $frames = (& $Tools.FFprobe -v error -select_streams v:0 -of json -show_frames -read_intervals '%+#1' `
            -show_entries frame=side_data_list $FilePath) -join "`n" | ConvertFrom-Json
        $side = @(@($frames.frames)[0].side_data_list)
        $md = $side | Where-Object { "$($_.side_data_type)" -match 'Mastering display' } | Select-Object -First 1
        $cl = $side | Where-Object { "$($_.side_data_type)" -match 'Content light' } | Select-Object -First 1
        if ($md -and $md.red_x) {
            $c = { param($v) [int][Math]::Round((ConvertTo-Fraction $v) * 50000) }
            $l = { param($v) [int][Math]::Round((ConvertTo-Fraction $v) * 10000) }
            $params += "master-display=G($(& $c $md.green_x),$(& $c $md.green_y))B($(& $c $md.blue_x),$(& $c $md.blue_y))" +
                       "R($(& $c $md.red_x),$(& $c $md.red_y))WP($(& $c $md.white_point_x),$(& $c $md.white_point_y))" +
                       "L($(& $l $md.max_luminance),$(& $l $md.min_luminance))"
        }
        if ($cl) { $params += "max-cll=$([int]$cl.max_content),$([int]$cl.max_average)" }
    }
    $info.X265Hdr = $params -join ':'
    return $info
}

function Get-SkipReason([hashtable]$Info, [string[]]$SkipCodecs) {
    # Sources not worth re-encoding (or that re-encoding would damage); $null = encode it
    if (-not $Info.VideoCodec) { return "no video stream" }
    if ($SkipCodecs -contains $Info.VideoCodec.ToLower()) { return "video is already $($Info.VideoCodec) (skipCodecs)" }
    if ($Info.DolbyVision) { return "Dolby Vision (re-encoding would drop the DV layer)" }
    if ($Info.Duration -gt 0 -and $Info.Duration -lt $SizeRules.MinSeconds) { return "shorter than $($SizeRules.MinSeconds) s" }
    if ($Info.EffectiveBpp -gt 0 -and $Info.EffectiveBpp -lt $SizeRules.LeanBpp) {
        return "already lean ({0:N3} H.264-equivalent bits/pixel); re-encoding would mostly cost quality" -f $Info.EffectiveBpp
    }
    return $null
}

function Get-SizeTargets([hashtable]$Info) {
    # Whole-file rules -> video-stream size ratios (the audio/subtitle share of the file doesn't shrink)
    $other = if ($Info.Size -gt 0) { [Math]::Max(0.0, [Math]::Min(0.9, ($Info.Size - $Info.VideoBytes) / $Info.Size)) } else { 0.15 }
    $fileTarget = 1 - (Get-ConfigNumber 'targetReduction') / 100
    $fileMin    = 1 - (Get-ConfigNumber 'maxReduction') / 100
    return @{
        Other      = $other
        FileTarget = $fileTarget
        Target     = [Math]::Max(0.15, ($fileTarget - $other) / (1 - $other))
        Min        = [Math]::Max(0.10, ($fileMin - $other) / (1 - $other))
    }
}

function ConvertTo-FileRatio([hashtable]$Targets, [double]$VideoRatio) {
    return $Targets.Other + (1 - $Targets.Other) * $VideoRatio
}

function New-SampleClips([hashtable]$Info, [string]$InputPath, [string]$WorkDir) {
    # Short stream copies of the source video spread through the file (past intros, before credits).
    # Encoding these clips, rather than seeking in the full file, keeps each sample frame-identical to
    # its reference, so both the size ratio and SSIM compare like with like.
    $short  = $Info.Duration -lt 180
    $count  = if ($short) { 1 } else { [Math]::Max(1, [int](Get-ConfigNumber 'sampleCount')) }
    $length = if ($short) { [Math]::Min($Info.Duration * 0.5, 30) }
              elseif ($Info.Height -gt 1600) { 6 }
              else { [Math]::Max(2.0, (Get-ConfigNumber 'sampleSeconds')) }
    $clips = @()
    for ($i = 0; $i -lt $count; $i++) {
        $at   = if ($count -eq 1) { $Info.Duration * 0.1 } else { $Info.Duration * (0.15 + 0.7 * $i / ($count - 1)) }
        $clip = Join-Path $WorkDir "src$i.mkv"
        & $Tools.FFmpeg -hide_banner -loglevel error -y -ss (Format-Number ([Math]::Round($at, 2))) -i $InputPath `
            -t (Format-Number ([Math]::Round($length, 2))) -map 0:v:0 -c copy -an -sn -dn $clip 2>$null
        if ((Test-Path -LiteralPath $clip) -and (Get-Item -LiteralPath $clip).Length -gt 0) { $clips += Get-Item -LiteralPath $clip }
    }
    return $clips
}

function Measure-Ssim([string]$Encoded, [string]$Reference, [string]$FrameRate) {
    # Luma SSIM of an encoded sample vs its source clip; $null if they can't be compared (different size).
    # Both sides are resampled to the source frame rate so frames pair up by timestamp: HandBrake --cfr
    # adds frames, and a stream-copied clip can start with frames the encoder drops. Paired by order,
    # a 0.99 encode measured ~0.95.
    $dims = foreach ($f in $Encoded, $Reference) {
        (& $Tools.FFprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $f) -join ''
    }
    if ($dims[0] -ne $dims[1]) { return $null }
    $text = (& $Tools.FFmpeg -hide_banner -nostats -i $Encoded -i $Reference -lavfi `
        "[0:v]fps=$FrameRate,format=yuv420p10le[a];[1:v]fps=$FrameRate,format=yuv420p10le[b];[a][b]ssim" -f null - 2>&1) -join "`n"
    if ($text -match 'SSIM Y:([0-9.]+)') { return ConvertTo-Double $matches[1] }
    return $null
}

function Measure-SampleQuality {
    # Encodes every clip at $Quality with the real settings; returns the encoded/source video size ratio
    # and the mean SSIM ($null if not measurable)
    param ([string]$BackendName, [IO.FileInfo[]]$Clips, [double]$Quality, [hashtable]$Info)
    $encodedBytes = 0.0; $sourceBytes = 0.0; $scores = @()
    foreach ($clip in $Clips) {
        $out = Join-Path $clip.DirectoryName ("{0}-q{1}.mkv" -f $clip.BaseName, (Format-Number $Quality))
        $result = Invoke-EncoderProcess -BackendName $BackendName -InputPath $clip.FullName -OutputPath $out `
            -Quality $Quality -Info $Info -Quiet
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $out)) {
            throw "sample encode failed (exit code $($result.ExitCode)): $($result.Log)"
        }
        $encodedBytes += (Get-Item -LiteralPath $out).Length
        $sourceBytes  += $clip.Length
        $ssim = Measure-Ssim $out $clip.FullName $Info.FrameRate
        if ($null -ne $ssim) { $scores += $ssim }
    }
    $mean = if ($scores.Count) { ($scores | Measure-Object -Average).Average } else { $null }
    return [PSCustomObject]@{ Quality = $Quality; Ratio = $encodedBytes / $sourceBytes; Ssim = $mean }
}

function Find-TargetQuality {
    # Sample-encodes the file and searches for the quality whose whole-file size lands near the target:
    # bracket the target, then interpolate on the measured size curve (curves differ a lot: ~6 quality
    # steps per halving for lean WEB sources, 2-3 for grainy Blu-rays). A quality that fails the SSIM
    # floor caps every later guess below it. -MeasureOnly just predicts the configured quality's size.
    # Returns @{ Quality; Reduction; Ssim; Skip (reason or $null); Slope; VideoTarget; Estimated }.
    param ([string]$BackendName, [IO.FileInfo]$File, [hashtable]$Info, [switch]$MeasureOnly)
    $backend   = $Backends[$BackendName]
    $t         = Get-SizeTargets $Info
    $floor     = Get-ConfigNumber 'ssimFloor'
    $qLo, $qHi = $backend.QualityMin, $backend.QualityMax
    $qCeil     = $qHi
    $tried     = New-Object System.Collections.ArrayList
    $clampQ    = { param($q) [double][Math]::Max($qLo, [Math]::Min($qHi, [Math]::Round($q))) }
    $log2      = { param($x) [Math]::Log($x, 2) }
    $qualityOk = { param($p) $null -eq $p.Ssim -or $p.Ssim -ge $floor }
    $fileDiff  = { param($p) [Math]::Abs((ConvertTo-FileRatio $t $p.Ratio) - $t.FileTarget) }
    $onTarget  = { param($p) (& $fileDiff $p) * 100 -le $SizeRules.OnTarget -and $p.Ratio -ge $t.Min }
    $getBracket = {
        @{  # highest quality value still too big / lowest one already small enough
            Big   = $tried | Where-Object { $_.Ratio -gt $t.Target } | Sort-Object Quality -Descending | Select-Object -First 1
            Small = $tried | Where-Object { $_.Ratio -le $t.Target } | Sort-Object Quality | Select-Object -First 1
        }
    }
    $between = { param($big, $small, $r)
        $big.Quality + ($small.Quality - $big.Quality) * [Math]::Log($big.Ratio / $r) / [Math]::Log($big.Ratio / $small.Ratio)
    }
    $getSlope = {
        # Quality steps per halving of size: from the bracket, else the last two points not pinned at the
        # bitrate cap (> 95%), else the x265 rule of thumb of 6
        $br = & $getBracket
        $s  = 6.0
        if ($br.Big -and $br.Small -and $br.Big.Ratio -le 0.95 -and $br.Small.Quality -gt $br.Big.Quality) {
            $s = ($br.Small.Quality - $br.Big.Quality) / (& $log2 ($br.Big.Ratio / $br.Small.Ratio))
        } else {
            $u = @($tried | Where-Object { $_.Ratio -le 0.95 })
            if ($u.Count -ge 2) {
                $d = & $log2 ($u[-2].Ratio / $u[-1].Ratio)
                if ([Math]::Abs($d) -gt 0.05) { $s = ($u[-1].Quality - $u[-2].Quality) / $d }
            }
        }
        [Math]::Max(1.5, [Math]::Min(12.0, $s))
    }

    $work = New-TempDir
    try {
        $clips = @(New-SampleClips $Info $File.FullName $work)
        if ($clips.Count -eq 0) { throw "could not cut sample clips" }
        $measure = { param($q)
            $p = Measure-SampleQuality -BackendName $BackendName -Clips $clips -Quality $q -Info $Info
            [void]$tried.Add($p)
            $ssimText = if ($null -eq $p.Ssim) { 'n/a' } else { $p.Ssim.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture) }
            Write-Host ("  Sample round {0}: quality {1,-4} -> ~{2:N0}% smaller, SSIM {3}" -f $tried.Count, (Format-Number $q),
                (100 * (1 - (ConvertTo-FileRatio $t $p.Ratio))), $ssimText) -ForegroundColor DarkCyan
            $p
        }

        if ($MeasureOnly) {
            [void](& $measure (Get-ConfiguredQuality $BackendName))
        } else {
            # First guess from the source bitrate vs what quality 28 gives at this resolution
            $height = if ($Info.Height -gt 0) { $Info.Height } else { 1080 }
            $ref    = $backend.Ref28Kbps * [Math]::Pow([Math]::Pow($height / 1080, 2), 0.75)
            $guess  = if ($Info.VideoKbps -gt 0) { 28 + 6 * (& $log2 ($ref / ($Info.VideoKbps * $t.Target))) } else { ($qLo + $qHi) / 2 }
            $cur    = & $measure (& $clampQ $guess)
            while ($true) {
                if (-not (& $qualityOk $cur)) { $qCeil = [Math]::Min($qCeil, $cur.Quality - 1) }
                if ((& $qualityOk $cur) -and (& $onTarget $cur)) { break }
                if ($tried.Count -ge $SizeRules.MaxRounds) { break }
                $br = & $getBracket
                if ($br.Big -and $br.Small) {
                    $next = & $between $br.Big $br.Small $t.Target
                } elseif ($br.Big) {
                    $minStep = if ($br.Big.Ratio -gt 0.95) { 4.0 } else { 1.0 }   # pinned at the cap: only says "too big"
                    $next = $br.Big.Quality + [Math]::Max($minStep, (& $getSlope) * (& $log2 ($br.Big.Ratio / $t.Target)))
                } else {
                    $next = $br.Small.Quality - [Math]::Max(1.0, (& $getSlope) * (& $log2 ($t.Target / $br.Small.Ratio)))
                }
                $next = & $clampQ $next
                if ($br.Big -and $br.Small) { $next = [Math]::Max($br.Big.Quality + 1, [Math]::Min($br.Small.Quality - 1, $next)) }
                $next = [Math]::Min($next, $qCeil)
                if ($next -lt $qLo) { break }   # the SSIM floor can't be met inside the range
                $next = & $clampQ $next
                if (@($tried | Where-Object { $_.Quality -eq $next }).Count) { break }   # bracket closed
                $cur = & $measure $next
            }
        }
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

    $result = @{ Quality = $null; Reduction = $null; Ssim = $null; Skip = $null; Slope = (& $getSlope); VideoTarget = $t.Target; Estimated = $false }
    if ($MeasureOnly) {
        $best = $tried[0]
    } else {
        # Closest to the target among points that pass the SSIM floor and the maximum reduction
        $best = $tried | Where-Object { (& $qualityOk $_) -and $_.Ratio -ge $t.Min } | Sort-Object { & $fileDiff $_ } | Select-Object -First 1
        $br   = & $getBracket
        if ((-not $best -or -not (& $onTarget $best)) -and $br.Big -and $br.Small -and ($br.Small.Quality - $br.Big.Quality) -gt 1) {
            # Not converged, but the target is bracketed: interpolate; the post-encode check corrects a miss
            $q    = [Math]::Min($qCeil, [Math]::Max($br.Big.Quality + 1, [Math]::Min($br.Small.Quality - 1, [Math]::Round((& $between $br.Big $br.Small $t.Target)))))
            $f    = ($q - $br.Big.Quality) / ($br.Small.Quality - $br.Big.Quality)
            $best = [PSCustomObject]@{ Quality = $q; Ssim = $br.Small.Ssim
                                       Ratio = [Math]::Exp([Math]::Log($br.Big.Ratio) + $f * ([Math]::Log($br.Small.Ratio) - [Math]::Log($br.Big.Ratio))) }
            $result.Estimated = $true
        }
        if (-not $best) {
            $lowest = $tried | Sort-Object Quality | Select-Object -First 1
            $result.Skip = if ($lowest.Ratio -lt $t.Min -and $lowest.Quality -le $qLo + 1) {
                "even quality $qLo makes it ~{0:N0}% smaller (maxReduction {1}%)" -f (100 * (1 - (ConvertTo-FileRatio $t $lowest.Ratio))), (Get-ConfigNumber 'maxReduction')
            } else { "no quality setting met the SSIM floor $floor at a useful size" }
            return $result
        }
    }
    $result.Quality   = $best.Quality
    $result.Ssim      = $best.Ssim
    $result.Reduction = 100 * (1 - [Math]::Min(1.0, (ConvertTo-FileRatio $t $best.Ratio)))
    $minKeep = Get-ConfigNumber 'minKeepReduction'
    if (-not $MeasureOnly -and $result.Reduction -lt $minKeep) {
        $result.Skip = "the best quality-safe setting ({0}) only makes it ~{1:N0}% smaller (minKeepReduction {2}%)" -f (Format-Number $best.Quality), $result.Reduction, $minKeep
    }
    return $result
}

function Test-EncodedOutput([string]$InputPath, [string]$OutputPath) {
    # Returns $null if the output looks complete, otherwise the reason it doesn't
    if (-not (Test-Path -LiteralPath $OutputPath)) { return "no output file was created" }
    if ((Get-Item -LiteralPath $OutputPath).Length -eq 0) { return "the output file is empty" }
    $inDuration  = Get-MediaDuration $InputPath
    $outDuration = Get-MediaDuration $OutputPath
    if ($inDuration -gt 0 -and $outDuration -lt ($inDuration - [Math]::Max(2.0, $inDuration * 0.02))) {
        return ("the output is shorter than the source ({0:N0}s vs {1:N0}s)" -f $outDuration, $inDuration)
    }
    return $null
}

function Move-OriginalFile([IO.FileInfo]$File) {
    if (-not $Config.deleteOriginals) { return }
    if (-not $Config.toDeleteDir) { Write-Host "  Not moving the original: toDeleteDir is empty." -ForegroundColor Yellow; return }
    # Held in a to_be_deleted folder next to the source, for manual deletion later
    $folder = Join-Path $File.DirectoryName $Config.toDeleteDir
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    try {
        Move-Item -LiteralPath $File.FullName -Destination (Join-Path $folder $File.Name) -Force -ErrorAction Stop
        Write-Host "  Moved original to: $folder" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Failed to move the original: $_" -ForegroundColor Red
    }
}

function Update-SubtitleFlags([string]$FilePath) {
    # Clear default/forced flags on SRT subtitle tracks so players don't auto-enable them
    $streams = (& $Tools.FFprobe -v error -select_streams s -show_entries stream=codec_name -of json $FilePath | ConvertFrom-Json).streams
    $edits = @()
    for ($i = 0; $i -lt @($streams).Count; $i++) {
        # mkvpropedit's track:sN counts subtitle tracks from 1
        if ($streams[$i].codec_name -eq 'subrip') { $edits += "--edit track:s$($i + 1) --set flag-default=0 --set flag-forced=0" }
    }
    if ($edits.Count -eq 0) { return }
    & $Tools.MKVPropEdit $FilePath ($edits -join ' ').Split(' ') | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  Subtitle flags updated." -ForegroundColor Green }
    else { Write-Host "  mkvpropedit failed (exit code $LASTEXITCODE)." -ForegroundColor Red }
}

function Test-DiskSpace([IO.FileInfo[]]$Files, [bool]$CanPrompt) {
    $needed = ($Files | Measure-Object -Property Length -Sum).Sum
    try { $free = ([IO.DriveInfo]([IO.Path]::GetPathRoot($OutputDir))).AvailableFreeSpace } catch { return $true }
    $neededGB, $freeGB = [Math]::Round($needed / 1GB, 2), [Math]::Round($free / 1GB, 2)
    if ($free -lt $needed * 0.10) {
        Write-Host "  WARNING: very low disk space - input total $neededGB GB, free $freeGB GB" -ForegroundColor Red
        if (-not $CanPrompt) { return $false }
        return (Read-Host "  Continue? (Y/N)") -match '^(y|yes)$'
    }
    if ($free -lt $needed) {
        Write-Host "  Note: free space ($freeGB GB) is below the input total ($neededGB GB); output is usually smaller." -ForegroundColor Yellow
    }
    return $true
}

function Invoke-FileEncode {
    # Encodes one file and checks the real result. In target mode ($Search set), a result outside the
    # size rules is re-encoded with a quality corrected from the real size (up to maxRetries).
    # Returns @{ Status = 'ok' | 'failed' | 'kept'; Quality; OutSize; Reduction; Message; Log }.
    param ([string]$BackendName, [IO.FileInfo]$File, [string]$OutputPath, [hashtable]$Info, [double]$Quality, [hashtable]$Search)
    $backend = $Backends[$BackendName]
    $maxRed  = Get-ConfigNumber 'maxReduction'
    $retries = [int](Get-ConfigNumber 'maxRetries')
    for ($attempt = 0; ; $attempt++) {
        Write-Host "  Encoding at quality $(Format-Number $Quality)" -ForegroundColor Cyan
        $result  = Invoke-EncoderProcess -BackendName $BackendName -InputPath $File.FullName -OutputPath $OutputPath -Quality $Quality -Info $Info
        $problem = Test-EncodedOutput $File.FullName $OutputPath
        if ($result.ExitCode -ne 0 -and -not $problem) {
            Write-Host "  Warning: encoder exited with code $($result.ExitCode), but the output is complete." -ForegroundColor Yellow
        }
        $outSize   = if ($problem) { 0 } else { (Get-Item -LiteralPath $OutputPath).Length }
        $reduction = if ($File.Length -gt 0) { 100 * ($File.Length - $outSize) / $File.Length } else { 0 }
        if (-not $problem -and $reduction -gt $SizeRules.BrokenAbove) { $problem = "the output is suspiciously small ({0:N0}% smaller)" -f $reduction }
        if ($problem) {
            # Remove the partial file: with skipExisting on, it would block this file forever
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
            return @{ Status = 'failed'; Message = "$problem (exit code $($result.ExitCode))"; Log = $result.Log }
        }
        $ok = @{ Status = 'ok'; Quality = $Quality; OutSize = $outSize; Reduction = $reduction }

        $tooBig = $reduction -lt $(if ($Search) { $SizeRules.RetryBelow } else { $SizeRules.AcceptAbove })
        $tooFar = $Search -and $reduction -gt $maxRed + $SizeRules.Grace
        if (-not $tooBig -and -not $tooFar) { return $ok }
        $why = if ($tooBig) { "only {0:N0}% smaller" -f $reduction } else { "{0:N0}% smaller, past maxReduction {1}%" -f $reduction, $maxRed }

        # Corrected quality from the real result: ~Slope quality steps per halving of the video size
        $next = $Quality
        if ($Search -and $attempt -lt $retries) {
            $videoRatio = [Math]::Max(0.001, ($outSize - ($File.Length - $Info.VideoBytes)) / $Info.VideoBytes)
            $next = [Math]::Round($Quality + $Search.Slope * [Math]::Log($videoRatio / $Search.VideoTarget, 2))
            if ($next -eq $Quality) { $next = if ($tooBig) { $Quality + 1 } else { $Quality - 1 } }
            $next = [Math]::Max($backend.QualityMin, [Math]::Min($backend.QualityMax, $next))
        }
        if ($next -eq $Quality) {
            # No retry left: still worth replacing the original if it saved a fair amount
            if ($tooBig -and $reduction -ge $SizeRules.AcceptAbove) {
                Write-Host "  $why, but it still saves enough to keep." -ForegroundColor Yellow
                return $ok
            }
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
            return @{ Status = 'kept'; Message = "$why; keeping the original." }
        }
        Write-Host ("  Retry {0}/{1}: {2}; quality {3} -> {4}" -f ($attempt + 1), $retries, $why, (Format-Number $Quality), (Format-Number $next)) -ForegroundColor Yellow
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        $Quality = $next
    }
}

function Invoke-Encoding {
    # Encodes the files (or with -EstimateOnly just predicts their sizes); returns $true if none failed
    param ([string]$BackendName, [IO.FileInfo[]]$Files, [switch]$EstimateOnly)
    $backend = $Backends[$BackendName]
    if (-not (Test-Path -LiteralPath $Tools[$backend.Tool]) -or -not (Test-Path -LiteralPath $Tools.FFprobe) -or -not (Test-Path -LiteralPath $Tools.FFmpeg)) {
        Write-Host "  $($backend.Tool), FFmpeg and FFprobe are required. Restart the script to download them, or use Check for Updates." -ForegroundColor Red
        return $false
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    if (-not $EstimateOnly -and -not (Test-DiskSpace $Files (Test-InteractiveConsole))) {
        Write-Host "  Encoding cancelled." -ForegroundColor Yellow
        return $false
    }

    $targetMode   = $Config.encodeMode -ieq 'target'
    $skipCodecs   = @("$($Config.skipCodecs)".ToLower() -split '[,\s]+' | Where-Object { $_ })
    $videoEncoder = Get-VideoEncoderName $BackendName
    $summary = @()
    $failed  = 0
    if ($targetMode) {
        Write-Host ("  Target: {0}% smaller (at most {1}%, skip if under {2}%), SSIM >= {3}, quality range {4}-{5}" -f
            (Get-ConfigNumber 'targetReduction'), (Get-ConfigNumber 'maxReduction'), (Get-ConfigNumber 'minKeepReduction'),
            (Format-Number (Get-ConfigNumber 'ssimFloor')), $backend.QualityMin, $backend.QualityMax) -ForegroundColor Cyan
    }

    for ($i = 0; $i -lt $Files.Count; $i++) {
        $file       = $Files[$i]
        $outputName = Get-OutputName $file $videoEncoder
        $outputPath = Join-Path $OutputDir $outputName
        Write-Host ""
        Write-Host ("  [{0}/{1}] {2}  ({3})" -f ($i + 1), $Files.Count, $file.Name, (Format-ByteSize $file.Length)) -ForegroundColor White

        if (-not $EstimateOnly -and (Test-Path -LiteralPath $outputPath)) {
            if ($Config.skipExisting) {
                Write-Host "  Skipping: $outputName already exists in $OutputDir" -ForegroundColor Yellow
                continue
            }
            $n = 1
            do { $outputPath = Join-Path $OutputDir ("{0}-{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($outputName), $n++, $file.Extension) }
            while (Test-Path -LiteralPath $outputPath)
        }
        $info = Get-SourceInfo $file.FullName
        $skip = Get-SkipReason $info $skipCodecs

        # Choose the quality: sample-based search, or the configured value
        $quality = Get-ConfiguredQuality $BackendName
        $search  = $null
        $predicted = $null
        if (-not $skip -and ($targetMode -or $EstimateOnly)) {
            if ($info.Duration -le 0) {
                Write-Host "  Could not read the duration; using the configured quality $(Format-Number $quality)." -ForegroundColor Yellow
            } else {
                try {
                    $found = Find-TargetQuality -BackendName $BackendName -File $file -Info $info -MeasureOnly:(-not $targetMode)
                    $skip  = $found.Skip
                    if (-not $skip) {
                        $quality, $predicted = $found.Quality, $found.Reduction
                        if ($targetMode) { $search = $found }
                        if ($found.Estimated) { Write-Host "  Search did not converge; using the interpolated quality $(Format-Number $quality)." -ForegroundColor DarkGray }
                    }
                } catch {
                    Write-Host "  Sampling failed ($_); using the configured quality $(Format-Number $quality)." -ForegroundColor Yellow
                }
            }
        }
        if ($skip) {
            Write-Host "  Skipping: $skip" -ForegroundColor Yellow
            if ($EstimateOnly) { $summary += [PSCustomObject]@{ FileName = $file.Name; Note = "skip - $skip" } }
            continue
        }

        if ($EstimateOnly) {
            $summary += [PSCustomObject]@{
                FileName  = $file.Name
                InputSize = Format-ByteSize $file.Length
                OutSize   = if ($null -ne $predicted) { "~" + (Format-ByteSize ($file.Length * (1 - $predicted / 100))) } else { "?" }
                Reduction = if ($null -ne $predicted) { [int][Math]::Round($predicted) } else { $null }
                Predicted = $null
                Quality   = $quality
            }
            continue
        }

        if ($outputName -ne $file.Name) { Write-Host "  Output: $(Split-Path $outputPath -Leaf)" -ForegroundColor Cyan }
        $result = Invoke-FileEncode -BackendName $BackendName -File $file -OutputPath $outputPath -Info $info -Quality $quality -Search $search
        if ($result.Status -eq 'failed') {
            $failed++
            Write-Host "  $($backend.Label) failed on $($file.Name): $($result.Message)" -ForegroundColor Red
            if ($result.Log) { Write-Host $result.Log -ForegroundColor DarkGray }
            continue
        }
        if ($result.Status -eq 'kept') {
            Write-Host "  $($result.Message)" -ForegroundColor Yellow
            continue
        }
        $reduction = [int][Math]::Round($result.Reduction)
        $summary += [PSCustomObject]@{
            FileName  = $file.Name
            InputSize = Format-ByteSize $file.Length
            OutSize   = Format-ByteSize $result.OutSize
            Reduction = $reduction
            Predicted = if ($null -ne $predicted) { [int][Math]::Round($predicted) } else { $null }
            Quality   = $result.Quality
        }
        Write-Host "  Converted with $($backend.Label): $reduction% smaller." -ForegroundColor Green

        if ($Config.fixSubtitles -and $file.Extension -ieq '.mkv') {
            if (Test-Path -LiteralPath $Tools.MKVPropEdit) { Update-SubtitleFlags $outputPath }
            else { Write-Host "  Skipping subtitle fix: mkvpropedit.exe not found." -ForegroundColor Yellow }
        }
        Move-OriginalFile $file
    }

    Write-Summary $summary $backend.Label $failed -EstimateOnly:$EstimateOnly
    return $failed -eq 0
}

function Write-Summary {
    param ($Summary, [string]$BackendLabel, [int]$Failed, [switch]$EstimateOnly)
    Write-Host ""
    if ($Summary.Count -eq 0) {
        Write-Host "No files were $(if ($EstimateOnly) { 'estimated' } else { 'encoded' })$(if ($Failed) { " ($Failed failed)" })." -ForegroundColor Yellow
        return
    }
    Write-Host $(if ($EstimateOnly) { "Size Estimates (from samples; nothing was encoded):" } else { "Encoding Summary:" }) -ForegroundColor Cyan
    foreach ($entry in $Summary) {
        if ($entry.Note) { Write-Host ("  {0}: {1}" -f $entry.FileName, $entry.Note) -ForegroundColor DarkGray; continue }
        Write-Host ("  {0}: quality {1}, {2} -> {3}, " -f $entry.FileName, (Format-Number $entry.Quality), $entry.InputSize, $entry.OutSize) -NoNewline
        if ($null -eq $entry.Reduction) { Write-Host "no estimate" -ForegroundColor DarkGray; continue }
        $color = if ($entry.Reduction -lt 30) { 'Yellow' } elseif ($entry.Reduction -le 70) { 'Green' } else { 'Red' }
        Write-Host "$($entry.Reduction)% smaller" -ForegroundColor $color -NoNewline
        Write-Host $(if ($null -ne $entry.Predicted) { " (predicted $($entry.Predicted)%)" } else { "" }) -ForegroundColor DarkGray
    }
    if ($Failed) { Write-Host "  $Failed file(s) failed - see above." -ForegroundColor Red }
    if ($EstimateOnly) { return }

    $lines = @("[{0}] Backend: {1} - {2} file(s)" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $BackendLabel, $Summary.Count)
    $lines += $Summary | ForEach-Object {
        $predictedText = if ($null -ne $_.Predicted) { " (predicted $($_.Predicted)%)" } else { "" }
        "  {0}`tQuality: {1}`tIn: {2}`tOut: {3}`tReduction: {4}%{5}" -f $_.FileName, (Format-Number $_.Quality), $_.InputSize, $_.OutSize, $_.Reduction, $predictedText
    }
    $lines += ""
    try {
        Add-Content -LiteralPath $LogFile -Value $lines -Encoding UTF8
        Write-Host "  Log saved to: $LogFile" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not write the encoding log: $_"
    }
}


### MENUS ###

function Start-EncodeFlow {
    # Folder -> files -> encoder -> encode, then back to file selection. ESC steps back.
    $menuBackends = 'HandBrake', 'FFmpeg', 'HandBrakeNVENC', 'FFmpegNVENC'
    $menuItems = @(
        "HandBrake  (CPU Encoding)"
        "FFmpeg     (CPU Encoding)"
        "HandBrake  (NVENC - GPU Encoding)"
        "FFmpeg     (NVENC - GPU Encoding)"
        "Estimate output sizes only (sample encodes, no full encode)"
        "Back to Main Menu"
    )
    $scanDir = $null

    while ($true) {
        if (-not $scanDir) {
            $scanDir = Select-ScanFolder
            if (-not $scanDir) { return }
        }
        $files = Select-FilesToProcess $scanDir
        if (-not $files) { $scanDir = Select-ScanFolder $scanDir; if (-not $scanDir) { return }; continue }

        $title  = "Encoding Method   [Folder: $(Split-Path $scanDir -Leaf) | $($files.Count) file(s) selected]"
        $choice = Show-Menu -Title $title -Items $menuItems -RedItems 5
        if ($choice -eq 5) { return }
        if ($choice -eq -1) { continue }

        if ($choice -eq 4) {
            # Estimates use the encoder that would actually run, so ask which one
            $which = Show-Menu -Title "Estimate with which encoder?" -Items $menuItems[0..3]
            if ($which -eq -1) { continue }
            Show-Header
            [void](Invoke-Encoding -BackendName $menuBackends[$which] -Files $files -EstimateOnly)
        } else {
            Show-Header
            [void](Invoke-Encoding -BackendName $menuBackends[$choice] -Files $files)
        }
        Wait-AnyKey
    }
}


### ENTRY POINT ###

if ($Encoder) {
    # Non-interactive: no menus, suitable for scheduled tasks and remote sessions
    $root = if ($Path) { $Path } else { $ScriptDir }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Write-Error "Folder not found: $root"; exit 2 }
    Install-MissingTools
    $files = @(Get-MediaFiles $root)
    Write-Host ("Found {0} .mp4/.mkv file(s) under {1}" -f $files.Count, $root) -ForegroundColor Cyan
    if ($files.Count -eq 0) { exit 0 }
    $ok = Invoke-Encoding -BackendName $Encoder -Files $files -EstimateOnly:$EstimateOnly
    exit $(if ($ok) { 0 } else { 1 })
}

if (-not (Test-InteractiveConsole)) {
    Write-Host "JEncoder's menus need an interactive console window (not ISE, a remote PSSession or redirected input)." -ForegroundColor Red
    Write-Host "To run without menus:  .\JEncoder.ps1 -Path 'D:\Media' -Encoder FFmpeg   (or HandBrake, HandBrakeNVENC, FFmpegNVENC)" -ForegroundColor Yellow
    exit 2
}

Show-Header
Install-MissingTools
Start-Sleep -Milliseconds 800

$mainItems = "Encode Files", "Show Current Configuration", "Edit Configuration", "Check for Updates", "Quit"
while ($true) {
    switch (Show-Menu -Title "Main Menu" -Items $mainItems -RedItems 4) {
        0 { Start-EncodeFlow }
        1 { Show-Configuration }
        2 { Edit-Configuration }
        3 { Invoke-UpdateCheck }
        default { Show-Header; Write-Host "  Goodbye!" -ForegroundColor Green; return }
    }
}
