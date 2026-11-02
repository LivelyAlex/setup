#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Interactive initial configuration for Windows Server 2025.
.DESCRIPTION
Run locally in elevated Windows PowerShell 5.1. Uses only Windows components.
Prompts for adapter, static IPv4 settings, and computer name before changes.
The IP change can disconnect remote access. No automatic reboot is performed.
Use on a standalone server before joining a domain or installing Exchange.
Existing Windows Update source settings still apply.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Use Windows PowerShell 5.1 (powershell.exe).'
}

function Read-Default {
    param([string]$Label, [string]$Default)
    $answer = Read-Host "$Label [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Test-IPv4 {
    param([string]$Address)
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($octet in $Address.Split('.')) {
        if ([int]$octet -gt 255) { return $false }
        if ($octet.Length -gt 1 -and $octet.StartsWith('0')) { return $false }
    }
    return $true
}

function Read-IPv4 {
    param([string]$Label, [string]$Default, [switch]$AllowNone)
    while ($true) {
        $answer = Read-Default $Label $Default
        if ($AllowNone -and $answer -eq 'none') { return 'none' }
        if (Test-IPv4 $answer) { return $answer }
        Write-Warning 'Enter an IPv4 address in dotted decimal notation.'
    }
}

function ConvertTo-Mask {
    param([int]$PrefixLength)
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    return ((0..3 | ForEach-Object {
        [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2)
    }) -join '.')
}

$system = Get-CimInstance Win32_ComputerSystem
if ($system.PartOfDomain) {
    throw 'This script is for standalone servers before domain join.'
}
$configs = @(Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' })
if ($configs.Count -eq 0) { throw 'No active network adapters found.' }
$configs | Select-Object InterfaceIndex, InterfaceAlias,
    @{n='IPv4';e={ $_.IPv4Address.IPAddress -join ', ' }},
    @{n='Gateway';e={ $_.IPv4DefaultGateway.NextHop -join ', ' }} | Format-Table -AutoSize
$defaultConfig = $configs | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
if ($null -eq $defaultConfig) { $defaultConfig = $configs[0] }
while ($true) {
    $choice = Read-Default 'Adapter interface index' ([string]$defaultConfig.InterfaceIndex)
    $config = $configs | Where-Object { [string]$_.InterfaceIndex -eq $choice } | Select-Object -First 1
    if ($null -ne $config) { break }
    Write-Warning 'Select an interface index shown above.'
}
$interfaceIndex = $config.InterfaceIndex
$addresses = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' })
if ($addresses.Count -gt 1) {
    throw 'Selected adapter has multiple IPv4 addresses. Configure it manually to preserve secondary addresses.'
}
$currentAddress = $addresses | Select-Object -First 1
$defaultIP = ''
$defaultMask = '255.255.255.0'
if ($null -ne $currentAddress) {
    $defaultIP = $currentAddress.IPAddress
    $defaultMask = ConvertTo-Mask $currentAddress.PrefixLength
}
$defaultGateway = $config.IPv4DefaultGateway | Select-Object -First 1 -ExpandProperty NextHop
if (-not $defaultGateway) { $defaultGateway = 'none' }
$defaultDNS = (Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4).ServerAddresses -join ', '

$ip = Read-IPv4 'Static IPv4 address' $defaultIP
while ($true) {
    $mask = Read-IPv4 'Subnet mask' $defaultMask
    $maskBits = ($mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    if ($maskBits -match '^1+0*$') { break }
    Write-Warning 'The subnet mask must have contiguous leading 1 bits.'
}
$gateway = Read-IPv4 'Default gateway (type none for no gateway)' $defaultGateway -AllowNone
while ($true) {
    $dnsInput = Read-Default 'DNS IPv4 servers, separated by commas' $defaultDNS
    $dns = @($dnsInput -split '[,;\s]+' | Where-Object { $_ })
    $invalidDNS = @($dns | Where-Object { -not (Test-IPv4 $_) })
    if ($dns.Count -gt 0 -and $invalidDNS.Count -eq 0) { break }
    Write-Warning 'Enter at least one valid DNS IPv4 address.'
}

$proposedName = 'aVSRV{0}' -f (Get-Random -Minimum 1000 -Maximum 10000)
while ($true) {
    $newName = Read-Default 'New computer name (or enter current name to keep it)' $proposedName
    if ($newName.Length -le 15 -and $newName -match '^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$' -and $newName -match '[a-zA-Z]') { break }
    Write-Warning 'Use 1-15 letters, digits, or hyphens; start/end with a letter or digit and include a letter.'
}
$rename = $newName -ine $env:COMPUTERNAME
if ($rename -and (Test-Path 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup')) {
    throw 'This initial-setup script does not rename installed Exchange servers. Rerun and enter the current name to keep it.'
}

Write-Host "`nAdapter: $($config.InterfaceAlias) ($interfaceIndex)"
Write-Host "Static IPv4: $ip   Mask: $mask   Gateway: $gateway"
Write-Host "DNS: $($dns -join ', ')"
Write-Host "Computer name: $newName (effective after manual reboot)"
Write-Host 'Enable RDP with NLA; set the selected network profile to Private; request update detection.'
Write-Warning 'IP changes can disconnect this session. Ensure the static address is excluded/reserved in DHCP to avoid duplicate allocation.'
if ((Read-Host 'Type APPLY to continue') -cne 'APPLY') {
    Write-Host 'Cancelled; no changes applied.'
    return
}

# Save the original configuration for reference, without credentials.
$backupPath = Join-Path $env:ProgramData ('ServerSetup-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[ordered]@{
    ComputerName = $env:COMPUTERNAME
    InterfaceIndex = $interfaceIndex
    InterfaceAlias = $config.InterfaceAlias
    IPv4 = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 |
        Select-Object IPAddress, PrefixLength, PrefixOrigin)
    Interface = @(Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 |
        Select-Object Dhcp, InterfaceMetric)
    Routes = @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 |
        Select-Object DestinationPrefix, NextHop, RouteMetric)
    DNS = @(Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex |
        Select-Object AddressFamily, ServerAddresses)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8
Write-Host "Original network settings saved: $backupPath"

# Queue the local rename before changing network connectivity.
if ($rename) {
    Rename-Computer -NewName $newName -Force -ErrorAction Stop
    Write-Host 'Rename queued. This script will not reboot.'
}

$terminalServer = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
New-ItemProperty -Path $terminalServer -Name fDenyTSConnections -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path "$terminalServer\WinStations\RDP-Tcp" -Name UserAuthentication -PropertyType DWord -Value 1 -Force | Out-Null
# Rule names are independent of Windows display language.
Get-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP','RemoteDesktop-UserMode-In-UDP' |
    Set-NetFirewallRule -Enabled True -Profile Private
Start-Service TermService
Write-Host 'RDP enabled with Network Level Authentication (Private firewall profile).'

# netsh is built into Windows and replaces DHCP with the requested static
# configuration even when retaining the same address as the current DHCP lease.
& "$env:SystemRoot\System32\netsh.exe" interface ipv4 set address `
    "name=$interfaceIndex" source=static "address=$ip" "mask=$mask" "gateway=$gateway" store=persistent
if ($LASTEXITCODE -ne 0) {
    throw "Static IPv4 configuration failed. Inspect the adapter and backup at $backupPath. Earlier changes may already be applied."
}
Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $dns
Write-Host 'Static IPv4 and DNS settings applied.'

foreach ($profile in @(Get-NetConnectionProfile -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue)) {
    try {
        Set-NetConnectionProfile -InterfaceIndex $interfaceIndex -NetworkCategory Private
        Write-Host 'Network profile set to Private.'
    } catch {
        Write-Warning "Could not set Private profile: $($_.Exception.Message)"
    }
}

try {
    # Uses the existing Windows Update/WSUS configuration. Detection only.
    $automaticUpdates = New-Object -ComObject Microsoft.Update.AutoUpdate
    $automaticUpdates.DetectNow()
    Write-Host 'Windows Update detection requested; scanning runs asynchronously.'
} catch {
    Write-Warning "Update detection request failed: $($_.Exception.Message)"
}

Write-Host "`nConfiguration steps finished. Review any warnings above."
Write-Host 'No reboot was requested. Reboot manually when ready to activate the new computer name.'
