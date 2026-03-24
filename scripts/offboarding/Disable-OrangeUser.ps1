<#
.SYNOPSIS
    Safely disables an Active Directory user for Orange Packaging.

.DESCRIPTION
    This script automates the offboarding process for an employee. It disables their Active Directory account,
    resets their password to prevent unauthorized login, clears sensitive group memberships, and hides them from
    the Global Address List (Exchange/M365 integration). It also provides an option to move them to an archive OU.

.PARAMETER UserName
    The sAMAccountName of the user to disable.

.PARAMETER MoveToArchive
    Switch parameter to move the disabled account to an Archive/Disabled Users Organizational Unit.

.PARAMETER ManagerToForwardEmailsTo
    The UPN or email of the manager to forward emails to (if handling M365 Exchange Online). Requires ExchangeOnlineManagement module.

.EXAMPLE
    .\Disable-OrangeUser.ps1 -UserName "jsmith" -MoveToArchive -ManagerToForwardEmailsTo "manager@orangepackaging.com"

.EXAMPLE
    "jdoe", "asmith" | .\Disable-OrangeUser.ps1 -MoveToArchive -WhatIf
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param (
    [Parameter(Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, HelpMessage="sAMAccountName of the user to offboard")]
    [ValidateNotNullOrEmpty()]
    [string[]]$UserName,

    [switch]$MoveToArchive,

    [Parameter(HelpMessage="UPN or Email of the manager to receive forwarded emails")]
    [string]$ManagerToForwardEmailsTo
)

begin {
    # Configuration Variables
    $ArchiveOU = "OU=Disabled Users,OU=OrangePackaging,DC=orangepackaging,DC=local"
    $RandomPasswordLength = 32
    $LogPath = "C:\IT_Logs\Offboarding"

    # Ensure Log Directory Exists
    if (-not (Test-Path -Path $LogPath)) {
        try {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        } catch {
            Write-Warning "Could not create log directory at $LogPath. Logging will be disabled."
            $LogPath = $null
        }
    }

    $LogFile = if ($LogPath) { Join-Path $LogPath "Offboard_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log" } else { $null }
    if ($LogFile) {
        Start-Transcript -Path $LogFile -Append -NoClobber | Out-Null
        Write-Verbose "Transcript started at $LogFile"
    }
}

process {
    foreach ($User in $UserName) {
        Write-Host "`nStarting offboarding process for user: $User" -ForegroundColor Cyan
        Write-Host "========================================"

        try {
            # 0. Check if user exists
            $UserObj = Get-ADUser -Identity $User -Properties MemberOf, msExchHideFromAddressLists -ErrorAction Stop
        } catch {
            Write-Error "Could not find user '$User' in Active Directory. They may not exist or the sAMAccountName is incorrect. Skipping."
            continue # Move to next user in pipeline
        }

        if ($PSCmdlet.ShouldProcess("User: $User", "Offboard/Disable Account")) {

            # 1. Disable Account & Reset Password
            Write-Host "1. Disabling AD account and resetting password..."
            try {
                Disable-ADAccount -Identity $User -ErrorAction Stop

                # Generate random strong password to lock them out completely
                $RandomPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $RandomPasswordLength | % {[char]$_})
                $SecureRandomPassword = ConvertTo-SecureString $RandomPassword -AsPlainText -Force
                Set-ADAccountPassword -Identity $User -NewPassword $SecureRandomPassword -Reset:$true -ErrorAction Stop
                Write-Verbose "   Account disabled and password randomized."
            } catch {
                Write-Warning "   Failed to disable or reset password. Error: $_"
            }

            # 2. Hide from Global Address List (Exchange on-prem / AAD Connect synced)
            Write-Host "2. Hiding user from Global Address List (GAL)..."
            try {
                Set-ADUser -Identity $User -Replace @{msExchHideFromAddressLists=$true} -ErrorAction Stop
                Write-Verbose "   Hidden from GAL."
            } catch {
                Write-Warning "   Failed to hide from GAL. Error: $_"
            }

            # 3. Remove from all groups except Domain Users
            Write-Host "3. Removing user from all AD groups (except Domain Users)..."
            $Groups = $UserObj.MemberOf
            if ($Groups -and $Groups.Count -gt 0) {
                foreach ($Group in $Groups) {
                    try {
                        Remove-ADGroupMember -Identity $Group -Members $User -Confirm:$false -ErrorAction Stop
                        Write-Host "   Removed from: $((Get-ADGroup $Group).Name)" -ForegroundColor Yellow
                    } catch {
                        Write-Warning "   Failed to remove from group: $Group. Error: $_"
                    }
                }
            } else {
                Write-Host "   User is not a member of any removable groups."
            }

            # 4. Clear Manager Field
            Write-Host "4. Clearing Manager Field..."
            try {
                Set-ADUser -Identity $User -Clear Manager -ErrorAction Stop
                Write-Verbose "   Manager field cleared."
            } catch {
                Write-Warning "   Failed to clear Manager field. Error: $_"
            }

            # 5. Move to Archive OU (if requested)
            if ($MoveToArchive) {
                Write-Host "5. Moving user to archive OU ($ArchiveOU)..."
                try {
                    # Verify OU exists before moving
                    if (Get-ADOrganizationalUnit -Identity $ArchiveOU -ErrorAction SilentlyContinue) {
                        Move-ADObject -Identity $UserObj.ObjectGUID -TargetPath $ArchiveOU -ErrorAction Stop
                        Write-Host "   Moved successfully." -ForegroundColor Green
                    } else {
                        Write-Warning "   Archive OU '$ArchiveOU' does not exist! Cannot move user."
                    }
                } catch {
                    Write-Warning "   Failed to move to archive OU. Ensure path exists and permissions are correct. Error: $_"
                }
            } else {
                Write-Verbose "5. Move to Archive skipped (not requested)."
            }

            # 6. Exchange Online M365 Email Forwarding/Shared Mailbox conversion
            if (-not [string]::IsNullOrWhiteSpace($ManagerToForwardEmailsTo)) {
                Write-Host "6. Attempting M365 Email Forwarding setup..." -ForegroundColor Magenta
                Write-Host "   [NOTE] Requires ExchangeOnlineManagement module and active connection."
                try {
                    # Simulated Exchange Online Commands
                    if (Get-Module -ListAvailable -Name ExchangeOnlineManagement) {
                        Write-Verbose "   Exchange module detected. Simulating M365 conversion..."
                        # ConvertTo-SharedMailbox -Identity $UserObj.UserPrincipalName
                        # Set-Mailbox -Identity $UserObj.UserPrincipalName -ForwardingAddress $ManagerToForwardEmailsTo -DeliverToMailboxAndForward $false
                        Write-Host "   (Simulated) Mailbox converted to shared, forwarded to $ManagerToForwardEmailsTo" -ForegroundColor Green
                    } else {
                        Write-Warning "   ExchangeOnlineManagement module not installed/imported. Skipping M365 tasks."
                    }
                } catch {
                    Write-Warning "   Failed to configure Exchange Online settings. Error: $_"
                }
            } else {
                Write-Verbose "6. M365 Forwarding skipped (Manager not provided)."
            }

            Write-Host "Offboarding complete for user: $User" -ForegroundColor Green
        } else {
            Write-Host "Offboarding aborted for user: $User (WhatIf/Confirm)" -ForegroundColor Yellow
        }
    }
}

end {
    if ($LogFile) {
        Stop-Transcript | Out-Null
        Write-Verbose "Transcript saved to: $LogFile"
    }
}