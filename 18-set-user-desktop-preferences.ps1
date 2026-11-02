#Requires -Version 5.1
<#
.SYNOPSIS
Sets desktop preferences for the account running this script.
.DESCRIPTION
Run in Windows PowerShell 5.1 as the intended signed-in user on Windows
Server 2025 with Desktop Experience. Administrator rights are not required.
Sign out and sign back in after running. Safe to run repeatedly.
Domain Group Policy may override these preferences.
================
setup windows taskbar to hide search bar, enable left arrangement, merge icons only if we have no space for them
set english as a default input language instead of language list
open my computer when opening explorer
disale hiding extension for known file types
enable showing hidden files
show the This PC system icon on the desktop
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Use the built-in International module in Windows PowerShell 5.1.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this script using Windows PowerShell (powershell.exe), not PowerShell 7.'
}
Import-Module International -ErrorAction Stop

# Ensure English (United States), with the US keyboard, is available.
# Keep the existing languages, their order, and their keyboard layouts.
$inputTip = '0409:00000409'
$languages = Get-WinUserLanguageList
$english = $languages | Where-Object { $_.LanguageTag -eq 'en-US' } | Select-Object -First 1
$languageListChanged = $false
if ($null -eq $english) {
    $englishList = New-WinUserLanguageList -Language 'en-US'
    $languages.Add($englishList[0])
    $languageListChanged = $true
} elseif ($english.InputMethodTips -notcontains $inputTip) {
    $english.InputMethodTips.Add($inputTip)
    $languageListChanged = $true
}
if ($languageListChanged) {
    Set-WinUserLanguageList -LanguageList $languages -Force
}

# Explicit default instead of "Use language list (recommended)".
Set-WinDefaultInputMethodOverride -InputTip $inputTip

$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$search = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
$desktopIcons = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
$thisPC = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'

$settings = @(
    @{ Path = $search;   Name = 'SearchboxTaskbarMode'; Value = 0 } # Hide search
    @{ Path = $advanced; Name = 'TaskbarAl';           Value = 0 } # Align left
    @{ Path = $advanced; Name = 'TaskbarGlomLevel';    Value = 1 } # Combine when full
    @{ Path = $advanced; Name = 'MMTaskbarGlomLevel';  Value = 1 } # Other monitors
    @{ Path = $advanced; Name = 'LaunchTo';            Value = 1 } # Open This PC
    @{ Path = $advanced; Name = 'HideFileExt';         Value = 0 } # Show extensions
    @{ Path = $advanced; Name = 'Hidden';              Value = 1 } # Show hidden files
    @{ Path = $advanced; Name = 'HideIcons';           Value = 0 } # Enable desktop icons
    # Equivalent to checking "Computer" in Desktop Icon Settings.
    @{ Path = "$desktopIcons\NewStartPanel"; Name = $thisPC; Value = 0 }
    @{ Path = "$desktopIcons\ClassicStartMenu"; Name = $thisPC; Value = 0 }
)

foreach ($setting in $settings) {
    if (-not (Test-Path -LiteralPath $setting.Path)) {
        New-Item -Path $setting.Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name `
        -PropertyType DWord -Value $setting.Value -Force | Out-Null
}

Write-Host ('Preferences saved for {0}\{1}.' -f $env:USERDOMAIN, $env:USERNAME)
Write-Host 'Default input: English (United States), US keyboard.'
Write-Host 'Sign out and sign back in to apply all changes.'
