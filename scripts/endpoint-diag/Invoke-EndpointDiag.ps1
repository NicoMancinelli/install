<#
.SYNOPSIS
    Diagnoses common Windows endpoint issues for Orange Packaging IT Admins.

.DESCRIPTION
    This script provides a comprehensive diagnostic report on a local or remote Windows machine.
    It checks disk space, system uptime, pending reboots, critical services (Spooler, W32Time, wuauserv),
    and basic network connectivity. It outputs the findings as a formatted PSObject, suitable for pipeline and CSV export.

.PARAMETER ComputerName
    The name or IP address of the target computer(s). Defaults to the local computer.

.PARAMETER PingTestAddress
    An IP address or hostname to ping to verify external connectivity (Default: 8.8.8.8).

.PARAMETER TimeoutSeconds
    How long to wait for remote operations (like CIM queries) before timing out. Defaults to 15 seconds.

.EXAMPLE
    .\Invoke-EndpointDiag.ps1 -ComputerName "WS-SALES-01"

.EXAMPLE
    "WS-SALES-01", "WS-WH-02" | .\Invoke-EndpointDiag.ps1 | Export-Csv "C:\Temp\DiagReport.csv" -NoTypeInformation

.EXAMPLE
    Get-ADComputer -Filter * -SearchBase "OU=Workstations,DC=orangepackaging,DC=local" | Invoke-EndpointDiag.ps1
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, HelpMessage="Name or IP of target computers")]
    [Alias("Name")]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter(HelpMessage="IP to test external internet connectivity against")]
    [string]$PingTestAddress = "8.8.8.8",

    [Parameter(HelpMessage="Timeout in seconds for remote queries")]
    [int]$TimeoutSeconds = 15
)

begin {
    Write-Verbose "Starting Endpoint Diagnostics Script"
    $CurrentIndex = 0
}

process {
    foreach ($Computer in $ComputerName) {
        $CurrentIndex++
        Write-Progress -Activity "Diagnosing Endpoints" -Status "Checking $Computer (Computer #$CurrentIndex)"

        Write-Host "Running Diagnostics on: $Computer" -ForegroundColor Cyan

        $Diagnostics = [PSCustomObject]@{
            ComputerName       = $Computer
            Timestamp          = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            IsOnline           = $false
            UptimeDays         = 0
            PendingReboot      = $false
            DiskSpaceC_GBFree  = 0
            DiskSpaceC_PercentFree = 0
            CriticalServices   = @{}
            InternetConnectivity = $false
            ErrorMessage       = $null
        }

        try {
            # 1. Test Connectivity
            Write-Verbose "Pinging $Computer..."
            # Note: Removed -TimeoutSeconds for backwards compatibility with Windows PowerShell 5.1
            if (-not (Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                Write-Warning "Computer '$Computer' is offline or unreachable via ICMP."
                $Diagnostics.IsOnline = $false
                $Diagnostics.ErrorMessage = "Offline/Unreachable"

                # Output to pipeline before continuing to next computer
                $Diagnostics
                continue
            }
            $Diagnostics.IsOnline = $true

            # Define ScriptBlock for remote execution via Invoke-Command
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
                        $State = (Get-Service -Name $Svc -ErrorAction Stop).Status
                        $ServiceStatus[$Svc] = $State.ToString()
                    } catch {
                        $ServiceStatus[$Svc] = "NotFound/Error"
                    }
                }
                # Flatten the dictionary into a string for easier CSV export later
                $Results.CriticalServices = ($ServiceStatus.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"

                # 6. Internet Connectivity
                try {
                    $Results.InternetConnectivity = Test-Connection -ComputerName $PingTest -Count 1 -Quiet -ErrorAction SilentlyContinue
                } catch {
                    $Results.InternetConnectivity = $false
                }

                return $Results
            }

            # Execute ScriptBlock via Invoke-Command or locally
            Write-Verbose "Collecting diagnostic data..."
            if ($Computer -ne $env:COMPUTERNAME) {
                # Use Job for timeout functionality on remote execution
                $Job = Invoke-Command -ComputerName $Computer -ScriptBlock $ScriptBlock -ArgumentList $PingTestAddress -AsJob -ErrorAction Stop
                $JobResult = Wait-Job -Job $Job -Timeout $TimeoutSeconds

                if ($Job.State -eq 'Running') {
                    Stop-Job -Job $Job
                    Write-Warning "Diagnostic collection timed out for $Computer."
                    $Diagnostics.ErrorMessage = "Timeout after $TimeoutSeconds seconds"
                    $RemoteResults = $null
                } else {
                    $RemoteResults = Receive-Job -Job $Job
                }
                Remove-Job -Job $Job -Force
            } else {
                $RemoteResults = Invoke-Command -ScriptBlock $ScriptBlock -ArgumentList $PingTestAddress
            }

            if ($null -ne $RemoteResults) {
                # Populate Object
                $Diagnostics.UptimeDays = $RemoteResults.UptimeDays
                $Diagnostics.PendingReboot = $RemoteResults.PendingReboot
                $Diagnostics.DiskSpaceC_GBFree = $RemoteResults.DiskSpaceC_GBFree
                $Diagnostics.DiskSpaceC_PercentFree = $RemoteResults.DiskSpaceC_PercentFree
                $Diagnostics.CriticalServices = $RemoteResults.CriticalServices
                $Diagnostics.InternetConnectivity = $RemoteResults.InternetConnectivity
                Write-Verbose "Data collected successfully."
            } else {
                $Diagnostics.ErrorMessage = "Failed to retrieve data"
            }

        } catch {
            Write-Warning "Diagnostics failed on $Computer. Error: $_"
            $Diagnostics.ErrorMessage = $_.Exception.Message
        }

        # Output to pipeline
        $Diagnostics
    }
}

end {
    Write-Progress -Activity "Diagnosing Endpoints" -Completed
    Write-Verbose "Endpoint Diagnostics Script Completed"
}