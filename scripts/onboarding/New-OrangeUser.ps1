<#
.SYNOPSIS
    Creates a new Active Directory user for Orange Packaging.

.DESCRIPTION
    This script automates the process of creating a new user in the on-premises Active Directory.
    It sets standard properties, assigns a random initial password, adds the user to appropriate
    groups, and can optionally trigger an Azure AD Connect sync.

.PARAMETER FirstName
    The first name of the new user.

.PARAMETER LastName
    The last name of the new user.

.PARAMETER Department
    The department the user belongs to (e.g., "Sales", "Warehouse", "IT").

.PARAMETER JobTitle
    The job title of the new user.

.PARAMETER Manager
    The sAMAccountName of the user's manager.

.PARAMETER TriggerSync
    Switch parameter to immediately trigger an Azure AD Delta Sync after creation.

.EXAMPLE
    .\New-OrangeUser.ps1 -FirstName "John" -LastName "Doe" -Department "Sales" -JobTitle "Account Executive" -Manager "asmith" -TriggerSync
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$FirstName,

    [Parameter(Mandatory=$true)]
    [string]$LastName,

    [Parameter(Mandatory=$true)]
    [string]$Department,

    [Parameter(Mandatory=$true)]
    [string]$JobTitle,

    [Parameter(Mandatory=$false)]
    [string]$Manager,

    [switch]$TriggerSync
)

# Configuration Variables
$DomainSuffix = "orangepackaging.local" # Replace with your actual domain
$UPNSuffix = "orangepackaging.com"     # Replace with your public UPN suffix
$OUPath = "OU=Users,OU=OrangePackaging,DC=orangepackaging,DC=local" # Replace with your target OU

# Generate random secure password for initial login
$RandomPasswordLength = 16
$RandomPassword = -join ((33..38) + (48..57) + (65..90) + (97..122) | Get-Random -Count $RandomPasswordLength | % {[char]$_})
$DefaultPassword = ConvertTo-SecureString $RandomPassword -AsPlainText -Force

# Generate Account Details
$DisplayName = "$FirstName $LastName"
$sAMAccountName = ($FirstName.Substring(0,1) + $LastName).ToLower()
$UserPrincipalName = "$sAMAccountName@$UPNSuffix"

Write-Host "Starting user creation for: $DisplayName ($sAMAccountName)" -ForegroundColor Cyan

# Check if user already exists
if (Get-ADUser -Filter {sAMAccountName -eq $sAMAccountName} -ErrorAction SilentlyContinue) {
    Write-Warning "User with sAMAccountName $sAMAccountName already exists! Aborting."
    Exit
}

# Base User Properties
$UserParams = @{
    Name              = $DisplayName
    GivenName         = $FirstName
    Surname           = $LastName
    DisplayName       = $DisplayName
    sAMAccountName    = $sAMAccountName
    UserPrincipalName = $UserPrincipalName
    Path              = $OUPath
    AccountPassword   = $DefaultPassword
    Enabled           = $true
    ChangePasswordAtLogon = $true
    Department        = $Department
    Title             = $JobTitle
    Company           = "Orange Packaging"
}

try {
    # Create the user
    New-ADUser @UserParams -ErrorAction Stop
    Write-Host "Successfully created AD user: $sAMAccountName" -ForegroundColor Green

    # Set Manager if provided
    if ($Manager) {
        $ManagerObj = Get-ADUser -Identity $Manager -ErrorAction SilentlyContinue
        if ($ManagerObj) {
            Set-ADUser -Identity $sAMAccountName -Manager $ManagerObj
            Write-Host "Set manager to: $Manager"
        } else {
            Write-Warning "Could not find manager account: $Manager"
        }
    }

    # Add to standard groups based on department (Example Logic)
    $StandardGroups = @("All Employees")

    switch ($Department) {
        "Sales" { $StandardGroups += "Sales Dept" }
        "Warehouse" { $StandardGroups += "Warehouse Staff" }
        "IT" { $StandardGroups += "IT Admins" }
    }

    foreach ($Group in $StandardGroups) {
        try {
            Add-ADGroupMember -Identity $Group -Members $sAMAccountName -ErrorAction Stop
            Write-Host "Added to group: $Group"
        } catch {
            Write-Warning "Failed to add to group: $Group. Does it exist?"
        }
    }

    # Trigger AAD Sync (Requires AAD Connect module/permissions on the server running the script)
    if ($TriggerSync) {
        Write-Host "Triggering Azure AD Delta Sync..." -ForegroundColor Cyan
        try {
            Start-ADSyncSyncCycle -PolicyType Delta
            Write-Host "Sync triggered successfully." -ForegroundColor Green
        } catch {
            Write-Warning "Failed to trigger sync. Ensure ADSync module is available and you have permissions."
            Write-Warning $_.Exception.Message
        }
    }

    Write-Host "Onboarding complete for $DisplayName. Initial password is: $RandomPassword (Must change at logon)" -ForegroundColor Green

} catch {
    Write-Error "Failed to create user. Error: $_"
}
