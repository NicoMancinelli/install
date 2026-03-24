# Orange Packaging IT Admin Toolkit

This repository contains PowerShell scripts and tools to help manage the hybrid Windows domain environment at Orange Packaging.

## Directory Structure

*   `scripts/onboarding/`: Scripts for creating new users and setting up their accounts in Active Directory and Microsoft 365.
*   `scripts/offboarding/`: Scripts for safely disabling accounts, archiving data, and removing access for departing employees.
*   `scripts/endpoint-diag/`: Tools for diagnosing and repairing common issues on Windows endpoints.

## Usage

These scripts are designed to be run by IT Administrators with the appropriate permissions in both the on-premises Active Directory and Azure AD/Microsoft 365 environments.

**Prerequisites:**

*   Active Directory PowerShell module (`RSAT-AD-PowerShell`)
*   Azure AD / Microsoft Graph PowerShell modules (depending on the specific script)
*   Appropriate administrative privileges
