<#
.SYNOPSIS
    Performs common repairs on an Orange Packaging Windows endpoint.

.DESCRIPTION
    This script contains functions to fix common user issues like stuck print queues,
    dns resolution problems, full temp folders, and can kick off DISM/SFC scans for deeper issues.
    It can be run locally or remotely via Invoke-Command.

.PARAMETER Action
    The repair action to perform. Valid options are:
    - ClearTempFiles
    - ResetPrintSpooler
    - FlushDNS
    - RunSystemScans (DISM and SFC)

.PARAMETER ComputerName
    The name or IP address of the target computer. Defaults to the local computer.

.EXAMPLE
    .\Repair-Endpoint.ps1 -Action "ResetPrintSpooler" -ComputerName "WS-WH-02"
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("ClearTempFiles", "ResetPrintSpooler", "FlushDNS", "RunSystemScans")]
    [string]$Action,

    [string]$ComputerName = $env:COMPUTERNAME
)

Write-Host "Starting Repair Action: [$Action] on $ComputerName" -ForegroundColor Cyan
Write-Host "--------------------------------------------------"

$ScriptBlock = {
    param($RepairAction)

    switch ($RepairAction) {
        "ClearTempFiles" {
            Write-Host "Clearing Temp files from Windows\Temp and User Temp directories..."
            try {
                Remove-Item -Path "$env:windir\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "Windows Temp Cleared." -ForegroundColor Green

                # Iterate through user profiles (requires admin)
                $UserProfiles = Get-ChildItem "C:\Users"
                foreach ($Profile in $UserProfiles) {
                    $TempPath = "C:\Users\$($Profile.Name)\AppData\Local\Temp\*"
                    if (Test-Path $TempPath) {
                        Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Host "User Temp folders cleared." -ForegroundColor Green
            } catch {
                Write-Warning "Failed to clear some temp files. Files may be in use."
            }
        }

        "ResetPrintSpooler" {
            Write-Host "Resetting Print Spooler and clearing print queue..."
            try {
                Stop-Service -Name Spooler -Force -ErrorAction Stop
                Start-Sleep -Seconds 2

                # Clear PRINTERS folder
                $PrintersPath = "$env:windir\System32\spool\PRINTERS\*.*"
                if (Test-Path $PrintersPath) {
                    Remove-Item -Path $PrintersPath -Force -Recurse -ErrorAction SilentlyContinue
                }

                Start-Service -Name Spooler -ErrorAction Stop
                Write-Host "Print Spooler reset successfully." -ForegroundColor Green
            } catch {
                Write-Error "Failed to reset Print Spooler: $_"
            }
        }

        "FlushDNS" {
            Write-Host "Flushing DNS Resolver Cache and Re-registering DNS..."
            try {
                ipconfig /flushdns | Out-Null
                ipconfig /registerdns | Out-Null
                Write-Host "DNS Flushed and Re-registered." -ForegroundColor Green
            } catch {
                Write-Error "Failed to flush DNS: $_"
            }
        }

        "RunSystemScans" {
            Write-Host "Running DISM and SFC Scans (This will take a while)..." -ForegroundColor Yellow
            try {
                Write-Host "Running DISM RestoreHealth..."
                dism /online /cleanup-image /restorehealth | Out-Default

                Write-Host "Running SFC ScanNow..."
                sfc /scannow | Out-Default

                Write-Host "System Scans Completed. Check CBS.log for detailed results." -ForegroundColor Green
            } catch {
                Write-Error "Failed to run system scans: $_"
            }
        }
    }
}

try {
    if ($ComputerName -ne $env:COMPUTERNAME) {
        Write-Host "Connecting remotely to $ComputerName..."
        Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $Action
    } else {
        # Run locally
        & $ScriptBlock -RepairAction $Action
    }
    Write-Host "Repair Action [$Action] completed." -ForegroundColor Cyan
} catch {
    Write-Error "Failed to execute repair action on $ComputerName. Error: $_"
}
