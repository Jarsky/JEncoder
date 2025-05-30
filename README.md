# JEncoder

**JEncoder** is a PowerShell-based script that automates media encoding tasks using HandBrakeCLI and FFmpeg. It supports both CPU and NVENC GPU encoding, and provides a flexible, configurable environment for encoding videos with features like subtitle handling, audio encoding, and automatic encoder verification and downloading.

## Features

- Automates media encoding tasks using HandBrakeCLI (x265) and FFmpeg (libx265, NVENC).
- Supports both CPU and NVENC GPU encoding.
- Configurable through a `config.ini` file, allowing users to modify settings interactively.
- Includes audio encoding and subtitle processing.
- Verifies and downloads missing encoders (HandBrakeCLI, FFmpeg, MKVPropEdit).
- Provides detailed feedback and status messages during encoding operations.
- Option to move original files to a "to_be_deleted" folder after processing.

## Version History
- **v1.5.2**: Refactored and standardized some of the code
- **v1.5.1**: Small bug fixes. Made the file renaming dynamic based on encoding codec
- **v1.5.0**: Added auto updating JEncoder script from latest Github release.
- **v1.4.1**: Fixed summary report.
- **v1.4.0**: Fixed logic in detecting encoder tools versions for comparison.
- **v1.3.5**: Fixed Summary of encodes and re-combined the encoder functions.
- **v1.3.0**: Added automatically downloading required encoders.
- **v1.2.0**: Added handling original files after processing.
- **v1.1.0**: Refactored script to include `config.ini` handling and new menu system.
- **v1.0.0**: Initial release with basic HandBrakeCLI and FFmpeg support and NVENC.

## Functions

- **Show-Header**: Displays a formatted header in the console.
- **Open-Config**: Reads the configuration file and loads settings.
- **Save-Config**: Saves the current settings back to the configuration file.
- **Show-Configuration**: Displays the current configuration settings in the console.
- **Edit-Configuration**: Allows users to update configuration settings interactively.
- **Confirm-Encoders**: Verifies if the required encoding tools (HandBrakeCLI, FFmpeg, MKVPropEdit) are available.
- **Get-Encoders**: Downloads and installs any missing encoders.
- **Write-ColoredHost**: Outputs colored text to the console for better visibility.

## Configuration Options

- Encoding quality settings for **HandBrakeCLI** and **FFmpeg**.
- Directory paths for **output**, **deletion**, and **encoders**.
- Options for handling spaces in filenames, fixing subtitles, and moving original files post-processing.

## Notes

- Ensure the required encoders (HandBrakeCLI, FFmpeg, MKVPropEdit) are available in the `encoders` folder, or the script will attempt to download them automatically.
- The version number is defined as `$ScriptVersion` at the start of the script for easy management.

## Installation

1. Clone or download the repository.
2. Ensure the required encoders are available or allow the script to automatically download them.
3. Modify the `config.ini` file to match your desired settings.
4. Run the script in PowerShell.

```powershell
.\JEncoder.ps1

## License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE.md) file for details.

