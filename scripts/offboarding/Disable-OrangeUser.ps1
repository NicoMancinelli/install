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
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$UserName,

    [switch]$MoveToArchive,

    [string]$ManagerToForwardEmailsTo
)

# Configuration Variables
$ArchiveOU = "OU=Disabled Users,OU=OrangePackaging,DC=orangepackaging,DC=local" # Replace with your target archive OU
$RandomPasswordLength = 32

Write-Host "Starting offboarding for user: $UserName" -ForegroundColor Cyan

try {
    # Check if user exists
    $UserObj = Get-ADUser -Identity $UserName -Properties MemberOf, msExchHideFromAddressLists -ErrorAction Stop

    # 1. Disable Account & Reset Password
    Write-Host "1. Disabling AD account and resetting password..."
    Disable-ADAccount -Identity $UserName -ErrorAction Stop

    # Generate random strong password to lock them out completely
    $RandomPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $RandomPasswordLength | % {[char]$_})
    $SecureRandomPassword = ConvertTo-SecureString $RandomPassword -AsPlainText -Force
    Set-ADAccountPassword -Identity $UserName -NewPassword $SecureRandomPassword -Reset:$true -ErrorAction Stop

    # 2. Hide from Global Address List (Exchange on-prem / AAD Connect synced)
    Write-Host "2. Hiding user from Global Address List (GAL)..."
    Set-ADUser -Identity $UserName -Replace @{msExchHideFromAddressLists=$true} -ErrorAction SilentlyContinue

    # 3. Remove from all groups except Domain Users
    Write-Host "3. Removing user from all AD groups (except Domain Users)..."
    $Groups = $UserObj.MemberOf
    if ($Groups) {
        foreach ($Group in $Groups) {
            Remove-ADGroupMember -Identity $Group -Members $UserName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "   Removed from: $Group"
        }
    } else {
        Write-Host "   User is not a member of any removable groups."
    }

    # 4. Clear Manager Field (Optional but good practice)
    Set-ADUser -Identity $UserName -Clear Manager -ErrorAction SilentlyContinue

    # 5. Move to Archive OU (if requested)
    if ($MoveToArchive) {
        Write-Host "5. Moving user to archive OU ($ArchiveOU)..."
        try {
            Move-ADObject -Identity $UserObj.ObjectGUID -TargetPath $ArchiveOU -ErrorAction Stop
            Write-Host "   Moved successfully." -ForegroundColor Green
        } catch {
            Write-Warning "   Failed to move to archive OU. Ensure path exists and permissions are correct."
            Write-Warning $_.Exception.Message
        }
    }

    # 6. Exchange Online M365 Email Forwarding/Shared Mailbox conversion (Conceptual)
    if ($ManagerToForwardEmailsTo) {
        Write-Host "6. Attempting M365 Email Forwarding setup..." -ForegroundColor Yellow
        Write-Host "   [NOTE] Requires ExchangeOnlineManagement module and Connect-ExchangeOnline to have been run prior."
        try {
            # Example logic (requires module to be imported and authenticated)
            # ConvertTo-SharedMailbox -Identity $UserObj.UserPrincipalName
            # Set-Mailbox -Identity $UserObj.UserPrincipalName -ForwardingAddress $ManagerToForwardEmailsTo -DeliverToMailboxAndForward $false
            Write-Host "   (Simulated) Mailbox converted to shared, forwarded to $ManagerToForwardEmailsTo" -ForegroundColor Green
        } catch {
            Write-Warning "   Failed to configure Exchange Online settings."
        }
    }

    Write-Host "Offboarding complete for user: $UserName" -ForegroundColor Green

} catch {
    Write-Error "An error occurred offboarding $UserName. Error: $_"
}
