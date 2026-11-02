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
Downloads and installs non-optional software updates, accepting their EULAs.
Reports update results and restart requirements; never requests a restart.
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

function Set-PrivateProfileWithRetry {
    param([int]$InterfaceIndex, [int]$Attempts = 13, [int]$DelaySeconds = 5)
    $lastError = 'No connection profile is available yet.'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $profiles = @(Get-NetConnectionProfile -InterfaceIndex $InterfaceIndex -ErrorAction Stop)
            if ($profiles.Count -eq 0) { throw 'No connection profile is available yet.' }
            if (@($profiles | Where-Object { $_.NetworkCategory -ne 'Private' }).Count -gt 0) {
                Set-NetConnectionProfile -InterfaceIndex $InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            }
            $verified = @(Get-NetConnectionProfile -InterfaceIndex $InterfaceIndex -ErrorAction Stop)
            if ($verified.Count -eq 0 -or
                @($verified | Where-Object { $_.NetworkCategory -ne 'Private' }).Count -gt 0) {
                throw 'Network profile has not changed to Private yet.'
            }
            Write-Host 'Network profile verified as Private.'
            return
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($attempt -lt $Attempts) {
            Write-Host "Waiting for network identification ($attempt/$Attempts)..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    Write-Warning "Could not set Private profile after retries: $lastError"
    Write-Warning "RDP is allowed on Private networks only. Once identification completes, run: Set-NetConnectionProfile -InterfaceIndex $InterfaceIndex -NetworkCategory Private"
}

function Enable-VerifiedRemoteDesktop {
    $terminalServer = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $policy = Get-ItemProperty -LiteralPath $policyPath -ErrorAction SilentlyContinue
    if ($null -ne $policy -and $policy.fDenyTSConnections -eq 1) {
        throw 'RDP is disabled by policy (fDenyTSConnections=1). Enable "Allow users to connect remotely by using Remote Desktop Services" in Local Group Policy, then rerun this script.'
    }

    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService
    $namespace = 'root\cimv2\TerminalServices'
    $setting = Get-CimInstance -Namespace $namespace -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $setting -MethodName SetAllowTSConnections -Arguments @{
        AllowTSConnections = [uint32]1
        ModifyFirewallException = [uint32]0
    } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) {
        throw "SetAllowTSConnections failed with code $($result.ReturnValue)."
    }
    New-ItemProperty -Path "$terminalServer\WinStations\RDP-Tcp" -Name UserAuthentication -PropertyType DWord -Value 1 -Force | Out-Null
    # Set firewall rules explicitly without relying on localized group names.
    Get-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP','RemoteDesktop-UserMode-In-UDP' -ErrorAction Stop |
        Set-NetFirewallRule -Enabled True -Action Allow -Profile Private -ErrorAction Stop

    $port = (Get-ItemProperty -Path "$terminalServer\WinStations\RDP-Tcp" -Name PortNumber).PortNumber
    $listener = @()
    for ($attempt = 0; $attempt -lt 16; $attempt++) {
        $listener = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($listener.Count -gt 0) { break }
        if ($attempt -lt 15) { Start-Sleep -Seconds 2 }
    }
    $effective = Get-CimInstance -Namespace $namespace -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
    $deny = (Get-ItemProperty -Path $terminalServer -Name fDenyTSConnections).fDenyTSConnections
    if ($effective.AllowTSConnections -ne 1 -or $deny -ne 0) {
        throw "RDP verification failed: AllowTSConnections=$($effective.AllowTSConnections), fDenyTSConnections=$deny. Check local policy."
    }
    if ($listener.Count -eq 0) {
        throw "RDP is allowed, but no TCP listener appeared on port $port within 30 seconds. Inspect TermService and the RDP-Tcp listener configuration; no service restart or reboot was forced."
    }
    if ($port -ne 3389) {
        Write-Warning "RDP uses custom port $port. Check that your firewall rules permit this port."
    }
    Write-Host "RDP verified: connections allowed, TermService running, TCP port $port listening."
    Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory | Format-Table -AutoSize
    Write-Host 'RDP firewall rules allow Private networks. The connection used for RDP must be Private.'
    Write-Host 'Close and reopen Settings to refresh the Remote Desktop switch. Test access from another computer.'
}

function Install-AvailableWindowsUpdates {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Server 2025 initial setup'
    $searcher = $session.CreateUpdateSearcher()
    Write-Host 'Searching for software updates using the configured Windows Update source...'
    $search = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0")
    if ($search.ResultCode -ne 2) {
        throw "Update search did not fully succeed (result $($search.ResultCode)). Rerun updates later."
    }
    if ($search.Updates.Count -eq 0) {
        Write-Host 'No applicable non-optional software updates found.'
        return
    }
    Write-Host "Found $($search.Updates.Count) update(s). Downloads and installation may take some time."
    $resultNames = @('Not started', 'In progress', 'Succeeded', 'Succeeded with errors', 'Failed', 'Aborted')
    $restartRequired = $false
    # Install one at a time, including updates that require exclusive installation.
    for ($i = 0; $i -lt $search.Updates.Count; $i++) {
        $update = $search.Updates.Item($i)
        Write-Host "[$($i + 1)/$($search.Updates.Count)] $($update.Title)"
        if ($update.InstallationBehavior.CanRequestUserInput) {
            Write-Warning 'Skipped: this update can require interactive input. Install it manually.'
            continue
        }
        try {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $collection = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$collection.Add($update)
            if (-not $update.IsDownloaded) {
                Write-Host 'Downloading...'
                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $collection
                $download = $downloader.Download()
                if (-not $update.IsDownloaded) {
                    Write-Warning "Download incomplete (result $($download.ResultCode)); skipping this update."
                    continue
                }
            }
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $collection
            $installer.AllowSourcePrompts = $false
            $installer.ForceQuiet = $true
            if ($installer.RebootRequiredBeforeInstallation) {
                Write-Warning 'Windows requires a manual reboot before further update installation.'
                $restartRequired = $true
                break
            }
            Write-Host 'Installing...'
            $installed = $installer.Install()
            $detail = $installed.GetUpdateResult(0)
            Write-Host "Installation result: $($resultNames[[int]$detail.ResultCode]); HRESULT: $($detail.HResult)"
            if ($detail.ResultCode -ne 2) {
                Write-Warning "Update did not fully succeed: $($update.Title)"
            }
            if ($installed.RebootRequired) { $restartRequired = $true }
        } catch {
            Write-Warning "Update failed: $($update.Title): $($_.Exception.Message)"
        }
    }
    if ($restartRequired) {
        Write-Host 'Updates require a reboot. Reboot manually when ready.'
    }
    Write-Host 'Update pass finished. After a manual reboot, check again for remaining or newly applicable updates.'
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
if ($dns[0] -eq '192.168.225.201') {
    # Always put .202 second; retain other supplied servers after it.
    $dns = @('192.168.225.201', '192.168.225.202') + @(
        $dns | Select-Object -Skip 1 | Where-Object {
            $_ -ne '192.168.225.201' -and $_ -ne '192.168.225.202'
        }
    )
    Write-Host 'Primary DNS is 192.168.225.201; secondary DNS set to 192.168.225.202.'
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
Write-Host 'Enable RDP with NLA; set the selected network profile to Private; download and install non-optional software updates.'
Write-Host 'Update license terms will be accepted automatically. No automatic restart is requested.'
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

Enable-VerifiedRemoteDesktop

# netsh is built into Windows and replaces DHCP with the requested static
# configuration even when retaining the same address as the current DHCP lease.
& "$env:SystemRoot\System32\netsh.exe" interface ipv4 set address `
    "name=$interfaceIndex" source=static "address=$ip" "mask=$mask" "gateway=$gateway" store=persistent
if ($LASTEXITCODE -ne 0) {
    throw "Static IPv4 configuration failed. Inspect the adapter and backup at $backupPath. Earlier changes may already be applied."
}
Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $dns
Write-Host 'Static IPv4 and DNS settings applied.'

# Changing IP/DNS starts network identification again. Retry for up to 60 seconds,
# including cases where Windows has not published any connection profile yet.
Set-PrivateProfileWithRetry -InterfaceIndex $interfaceIndex

try {
    Install-AvailableWindowsUpdates
} catch {
    Write-Warning "Windows Update operation failed: $($_.Exception.Message)"
}

Write-Host "`nConfiguration steps finished. Review any warnings above."
Write-Host 'No reboot was requested. Reboot manually when ready to activate the new computer name and complete updates.'
