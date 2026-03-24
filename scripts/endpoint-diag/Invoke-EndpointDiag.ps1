<#
.SYNOPSIS
    Diagnoses common Windows endpoint issues for Orange Packaging IT Admins.

.DESCRIPTION
    This script provides a comprehensive diagnostic report on a local or remote Windows machine.
    It checks disk space, system uptime, pending reboots, critical services (Spooler, W32Time, wuauserv),
    and basic network connectivity. It outputs the findings as a formatted PSObject.

.PARAMETER ComputerName
    The name or IP address of the target computer. Defaults to the local computer.

.PARAMETER PingTestAddress
    An IP address or hostname to ping to verify external connectivity (Default: 8.8.8.8).

.EXAMPLE
    .\Invoke-EndpointDiag.ps1 -ComputerName "WS-SALES-01"
#>

param (
    [string]$ComputerName = $env:COMPUTERNAME,
    [string]$PingTestAddress = "8.8.8.8"
)

Write-Host "Starting Diagnostics on: $ComputerName" -ForegroundColor Cyan
Write-Host "--------------------------------------------------"

$Diagnostics = [PSCustomObject]@{
    ComputerName       = $ComputerName
    Timestamp          = Get-Date
    IsOnline           = $false
    UptimeDays         = 0
    PendingReboot      = $false
    DiskSpaceC_GBFree  = 0
    DiskSpaceC_PercentFree = 0
    CriticalServices   = @{}
    InternetConnectivity = $false
}

try {
    # 1. Test Connectivity
    if (!(Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Warning "Computer $ComputerName is offline or unreachable."
        $Diagnostics.IsOnline = $false
        return $Diagnostics
    }
    $Diagnostics.IsOnline = $true

    # Use Invoke-Command for remote execution if not local
    $Session = if ($ComputerName -ne $env:COMPUTERNAME) {
        New-PSSession -ComputerName $ComputerName -ErrorAction Stop
    } else {
        $null
    }

    $ScriptBlock = {
        param($PingTest)
        $Results = @{}

        # 2. Uptime
        try {
            $OSInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $LastBoot = $OSInfo.LastBootUpTime
            $Results.UptimeDays = [math]::Round(((Get-Date) - $LastBoot).TotalDays, 2)
        } catch { $Results.UptimeDays = -1 }

        # 3. Pending Reboot
        $Results.PendingReboot = $false
        try {
            $Reg1 = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -ErrorAction SilentlyContinue
            $Reg2 = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -ErrorAction SilentlyContinue
            if ($null -ne $Reg1 -or $null -ne $Reg2) {
                $Results.PendingReboot = $true
            }
        } catch { }

        # 4. Disk Space (C: Drive)
        try {
            $Disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $Results.DiskSpaceC_GBFree = [math]::Round($Disk.FreeSpace / 1GB, 2)
            $Results.DiskSpaceC_PercentFree = [math]::Round(($Disk.FreeSpace / $Disk.Size) * 100, 2)
        } catch {
            $Results.DiskSpaceC_GBFree = -1
            $Results.DiskSpaceC_PercentFree = -1
        }

        # 5. Critical Services
        $ServicesToCheck = @("Spooler", "W32Time", "wuauserv", "LanmanWorkstation")
        $ServiceStatus = @{}
        foreach ($Svc in $ServicesToCheck) {
            try {
                $State = (Get-Service -Name $Svc -ErrorAction SilentlyContinue).Status
                $ServiceStatus[$Svc] = if ($State) { $State } else { "Not Found" }
            } catch {
                $ServiceStatus[$Svc] = "Error Checking"
            }
        }
        $Results.CriticalServices = $ServiceStatus

        # 6. Internet Connectivity
        try {
            $Results.InternetConnectivity = Test-Connection -ComputerName $PingTest -Count 1 -Quiet -ErrorAction SilentlyContinue
        } catch {
            $Results.InternetConnectivity = $false
        }

        return $Results
    }

    # Execute
    if ($Session) {
        $RemoteResults = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $PingTestAddress
        Remove-PSSession -Session $Session
    } else {
        $RemoteResults = Invoke-Command -ScriptBlock $ScriptBlock -ArgumentList $PingTestAddress
    }

    # Populate Object
    $Diagnostics.UptimeDays = $RemoteResults.UptimeDays
    $Diagnostics.PendingReboot = $RemoteResults.PendingReboot
    $Diagnostics.DiskSpaceC_GBFree = $RemoteResults.DiskSpaceC_GBFree
    $Diagnostics.DiskSpaceC_PercentFree = $RemoteResults.DiskSpaceC_PercentFree
    $Diagnostics.CriticalServices = $RemoteResults.CriticalServices
    $Diagnostics.InternetConnectivity = $RemoteResults.InternetConnectivity

} catch {
    Write-Error "Diagnostics failed on $ComputerName. Error: $_"
}

# Output Results Nicely
Write-Host "Diagnostic Results:" -ForegroundColor Yellow
$Diagnostics | Format-List

# Return object for pipeline use
return $Diagnostics