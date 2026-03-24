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
    The department the user belongs to. Validated against a predefined list.

.PARAMETER JobTitle
    The job title of the new user.

.PARAMETER Manager
    The sAMAccountName of the user's manager.

.PARAMETER TriggerSync
    Switch parameter to immediately trigger an Azure AD Delta Sync after creation.

.EXAMPLE
    .\New-OrangeUser.ps1 -FirstName "John" -LastName "Doe" -Department "Sales" -JobTitle "Account Executive" -Manager "asmith" -TriggerSync

.EXAMPLE
    .\New-OrangeUser.ps1 -FirstName "Jane" -LastName "Smith" -Department "IT" -JobTitle "Helpdesk Analyst" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param (
    [Parameter(Mandatory=$true, HelpMessage="First name of the user")]
    [ValidateNotNullOrEmpty()]
    [string]$FirstName,

    [Parameter(Mandatory=$true, HelpMessage="Last name of the user")]
    [ValidateNotNullOrEmpty()]
    [string]$LastName,

    [Parameter(Mandatory=$true, HelpMessage="Department of the user")]
    [ValidateSet("Sales", "Warehouse", "IT", "HR", "Finance", "Management")]
    [string]$Department,

    [Parameter(Mandatory=$true, HelpMessage="Job title of the user")]
    [ValidateNotNullOrEmpty()]
    [string]$JobTitle,

    [Parameter(Mandatory=$false, HelpMessage="sAMAccountName of the manager")]
    [string]$Manager,

    [switch]$TriggerSync
)

# Configuration Variables
$DomainSuffix = "orangepackaging.local"
$UPNSuffix = "orangepackaging.com"
$OUPath = "OU=Users,OU=OrangePackaging,DC=orangepackaging,DC=local"
$LogPath = "C:\IT_Logs\Onboarding"

# Ensure Log Directory Exists
if (-not (Test-Path -Path $LogPath)) {
    try {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    } catch {
        Write-Warning "Could not create log directory at $LogPath. Logging will be disabled."
        $LogPath = $null
    }
}

# Start Logging
$LogFile = if ($LogPath) { Join-Path $LogPath "Onboard_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log" } else { $null }
if ($LogFile) {
    Start-Transcript -Path $LogFile -Append -NoClobber | Out-Null
}

Write-Verbose "Generating Account Details"
$DisplayName = "$FirstName $LastName"
$sAMAccountName = ($FirstName.Substring(0,1) + $LastName).ToLower()
# Sanitize sAMAccountName (remove spaces, special chars, ensure max 20 length)
$sAMAccountName = $sAMAccountName -replace '[^a-zA-Z0-9]', ''
if ($sAMAccountName.Length -gt 20) { $sAMAccountName = $sAMAccountName.Substring(0, 20) }

$UserPrincipalName = "$sAMAccountName@$UPNSuffix"

# Generate random secure password for initial login
$RandomPasswordLength = 16
$RandomPassword = -join ((33..38) + (48..57) + (65..90) + (97..122) | Get-Random -Count $RandomPasswordLength | % {[char]$_})
$DefaultPassword = ConvertTo-SecureString $RandomPassword -AsPlainText -Force

Write-Host "Starting user creation for: $DisplayName ($sAMAccountName)" -ForegroundColor Cyan

try {
    # Check if user already exists
    if (Get-ADUser -Filter {sAMAccountName -eq $sAMAccountName} -ErrorAction SilentlyContinue) {
        Write-Error "User with sAMAccountName '$sAMAccountName' already exists! Aborting."
        return
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

    if ($PSCmdlet.ShouldProcess("Active Directory User: $sAMAccountName", "Create User")) {
        # Create the user
        New-ADUser @UserParams -ErrorAction Stop
        Write-Host "Successfully created AD user: $sAMAccountName" -ForegroundColor Green

        # Set Manager if provided
        if (-not [string]::IsNullOrWhiteSpace($Manager)) {
            try {
                $ManagerObj = Get-ADUser -Identity $Manager -ErrorAction Stop
                Set-ADUser -Identity $sAMAccountName -Manager $ManagerObj -ErrorAction Stop
                Write-Host "Set manager to: $($ManagerObj.Name)"
            } catch {
                Write-Warning "Could not find manager account or set manager: '$Manager'. Ensure the sAMAccountName is correct."
            }
        }

        # Add to standard groups based on department
        $StandardGroups = @("Domain Users", "All Employees")

        switch ($Department) {
            "Sales"      { $StandardGroups += "Sales Dept" }
            "Warehouse"  { $StandardGroups += "Warehouse Staff" }
            "IT"         { $StandardGroups += "IT Admins", "Local Admins" }
            "HR"         { $StandardGroups += "HR Dept", "Management" }
            "Finance"    { $StandardGroups += "Finance Dept" }
            "Management" { $StandardGroups += "Management" }
        }

        foreach ($Group in $StandardGroups) {
            if ($Group -ne "Domain Users") { # Usually Primary Group, implicitly added
                try {
                    # Verify Group Exists before adding
                    if (Get-ADGroup -Identity $Group -ErrorAction SilentlyContinue) {
                        Add-ADGroupMember -Identity $Group -Members $sAMAccountName -ErrorAction Stop
                        Write-Verbose "Added to group: $Group"
                    } else {
                        Write-Warning "Group '$Group' does not exist in Active Directory. Skipping."
                    }
                } catch {
                    Write-Warning "Failed to add to group: $Group. Error: $_"
                }
            }
        }

        # Trigger AAD Sync
        if ($TriggerSync) {
            Write-Host "Triggering Azure AD Delta Sync..." -ForegroundColor Cyan
            try {
                # Test if module exists first
                if (Get-Module -ListAvailable -Name ADSync) {
                    Start-ADSyncSyncCycle -PolicyType Delta -ErrorAction Stop
                    Write-Host "Sync triggered successfully." -ForegroundColor Green
                } else {
                    Write-Warning "ADSync module is not available on this machine. Sync cannot be triggered."
                }
            } catch {
                Write-Warning "Failed to trigger sync. Ensure you have permissions on the AAD Connect server."
                Write-Verbose $_.Exception.Message
            }
        }

        Write-Host "`n--- ONBOARDING COMPLETE ---" -ForegroundColor Green
        Write-Host "Display Name: $DisplayName"
        Write-Host "Username:     $sAMAccountName"
        Write-Host "UPN:          $UserPrincipalName"
        Write-Host "Password:     $RandomPassword" -ForegroundColor Yellow
        Write-Host "(User MUST change password at next logon)`n"
    }

} catch {
    Write-Error "A critical error occurred during user creation: $_"
} finally {
    if ($LogFile) {
        Stop-Transcript | Out-Null
        Write-Verbose "Log saved to: $LogFile"
    }
}
