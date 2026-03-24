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
    The name or IP address of the target computer(s). Defaults to the local computer.

.EXAMPLE
    .\Repair-Endpoint.ps1 -Action "ResetPrintSpooler" -ComputerName "WS-WH-02"

.EXAMPLE
    "WS-SALES-01", "WS-WH-02" | .\Repair-Endpoint.ps1 -Action "ClearTempFiles" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param (
    [Parameter(Mandatory=$true, HelpMessage="Repair action to execute")]
    [ValidateSet("ClearTempFiles", "ResetPrintSpooler", "FlushDNS", "RunSystemScans")]
    [string]$Action,

    [Parameter(Mandatory=$false, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, HelpMessage="Name or IP of target computers")]
    [Alias("Name")]
    [string[]]$ComputerName = $env:COMPUTERNAME
)

begin {
    Write-Verbose "Starting Endpoint Repair Script - Action: [$Action]"
    $CurrentIndex = 0

    # Configure appropriate timeout based on action
    $JobTimeout = if ($Action -eq "RunSystemScans") { 1800 } else { 60 }

    $ScriptBlock = {
        param($RepairAction)
        $ActionResult = @{
            Success = $false
            Message = ""
        }

        switch ($RepairAction) {
            "ClearTempFiles" {
                Write-Verbose "Clearing Temp files from Windows\Temp and User Temp directories..."
                try {
                    $ClearedCount = 0
                    $WinTemp = "$env:windir\Temp\*"
                    if (Test-Path $WinTemp) {
                        Remove-Item -Path $WinTemp -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                        $ClearedCount++
                    }

                    # Iterate through user profiles
                    $UserProfiles = Get-ChildItem "C:\Users" -ErrorAction SilentlyContinue
                    foreach ($Profile in $UserProfiles) {
                        $TempPath = "C:\Users\$($Profile.Name)\AppData\Local\Temp\*"
                        if (Test-Path $TempPath) {
                            Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                            $ClearedCount++
                        }
                    }
                    $ActionResult.Success = $true
                    $ActionResult.Message = "Temp folders cleared ($ClearedCount locations checked/cleaned)"
                } catch {
                    $ActionResult.Message = "Failed to clear some temp files. Files may be in use."
                }
            }

            "ResetPrintSpooler" {
                Write-Verbose "Resetting Print Spooler and clearing print queue..."
                try {
                    Stop-Service -Name Spooler -Force -ErrorAction Stop
                    Start-Sleep -Seconds 2

                    # Clear PRINTERS folder
                    $PrintersPath = "$env:windir\System32\spool\PRINTERS\*.*"
                    if (Test-Path $PrintersPath) {
                        Remove-Item -Path $PrintersPath -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                    }

                    Start-Service -Name Spooler -ErrorAction Stop
                    $ActionResult.Success = $true
                    $ActionResult.Message = "Print Spooler reset successfully."
                } catch {
                    $ActionResult.Message = "Failed to reset Print Spooler: $_"
                }
            }

            "FlushDNS" {
                Write-Verbose "Flushing DNS Resolver Cache and Re-registering DNS..."
                try {
                    ipconfig /flushdns | Out-Null
                    ipconfig /registerdns | Out-Null
                    $ActionResult.Success = $true
                    $ActionResult.Message = "DNS Flushed and Re-registered."
                } catch {
                    $ActionResult.Message = "Failed to flush DNS: $_"
                }
            }

            "RunSystemScans" {
                Write-Verbose "Running DISM and SFC Scans (This will take a while)..."
                try {
                    Write-Verbose "Running DISM RestoreHealth..."
                    dism /online /cleanup-image /restorehealth | Out-Null

                    Write-Verbose "Running SFC ScanNow..."
                    sfc /scannow | Out-Null

                    $ActionResult.Success = $true
                    $ActionResult.Message = "System Scans Completed. Check CBS.log for detailed results."
                } catch {
                    $ActionResult.Message = "Failed to run system scans: $_"
                }
            }
        }
        return $ActionResult
    }
}

process {
    foreach ($Computer in $ComputerName) {
        $CurrentIndex++
        Write-Progress -Activity "Repairing Endpoints" -Status "Running [$Action] on $Computer (Computer #$CurrentIndex)"

        Write-Host "Executing [$Action] on: $Computer" -ForegroundColor Cyan

        $RepairResult = [PSCustomObject]@{
            ComputerName = $Computer
            Action       = $Action
            Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Success      = $false
            Message      = ""
        }

        try {
            if ($PSCmdlet.ShouldProcess("Computer: $Computer", "Action: $Action")) {

                # Check Connectivity First
                if (-not (Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                    $RepairResult.Message = "Computer is offline or unreachable via ICMP."
                    Write-Warning "Computer '$Computer' is offline."

                    # Output to pipeline before continuing
                    $RepairResult
                    continue
                }

                if ($Computer -ne $env:COMPUTERNAME) {
                    Write-Verbose "Connecting remotely to $Computer... (Timeout: ${JobTimeout}s)"
                    # Add timeout capability
                    $Job = Invoke-Command -ComputerName $Computer -ScriptBlock $ScriptBlock -ArgumentList $Action -AsJob -ErrorAction Stop
                    $JobResult = Wait-Job -Job $Job -Timeout $JobTimeout

                    if ($Job.State -eq 'Running') {
                        Stop-Job -Job $Job
                        $RepairResult.Message = "Remote execution timed out after ${JobTimeout}s."
                        Write-Warning "Execution timed out on $Computer."
                        $RemoteReturn = $null
                    } else {
                        $RemoteReturn = Receive-Job -Job $Job
                    }
                    Remove-Job -Job $Job -Force
                } else {
                    Write-Verbose "Running locally..."
                    $RemoteReturn = & $ScriptBlock -RepairAction $Action
                }

                if ($null -ne $RemoteReturn) {
                    $RepairResult.Success = $RemoteReturn.Success
                    $RepairResult.Message = $RemoteReturn.Message

                    if ($RepairResult.Success) {
                        Write-Host "   $($RepairResult.Message)" -ForegroundColor Green
                    } else {
                        Write-Warning "   $($RepairResult.Message)"
                    }
                }

            } else {
                $RepairResult.Message = "Skipped (WhatIf/Confirm)"
                Write-Host "   Repair Action aborted (WhatIf/Confirm)" -ForegroundColor Yellow
            }
        } catch {
            $RepairResult.Message = "Critical Error: $_"
            Write-Error "Failed to execute repair action on $Computer. Error: $_"
        }

        # Output to pipeline
        $RepairResult
    }
}

end {
    Write-Progress -Activity "Repairing Endpoints" -Completed
    Write-Verbose "Endpoint Repair Script Completed"
}