<#
.SYNOPSIS
    Bootstraps a Windows Server 2025 Core domain controller in Azure.

.DESCRIPTION
    Run by the Custom Script Extension on first boot. Steps:
      1. Apply the Server 2025 Core hardening baseline (Harden-Server2025Core.ps1).
      2. Retrieve the DSRM password from Key Vault using the VM's *managed
         identity* (IMDS token) — no secret ever lands in Terraform state output
         or on disk in cleartext beyond this transient run.
      3. Install AD DS role and promote:
           - forest_root   : create the new forest (homelab.local).
           - additional_dc : join the existing forest as an additional DC.

.NOTES
    Secrets are delegated via Key Vault RBAC (Key Vault Secrets User on the VM's
    system-assigned identity). This script assumes outbound 443 to the vault
    through the Azure Firewall is permitted (AzureCloud NSG rule).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DomainName,
    [Parameter(Mandatory)] [string] $NetbiosName,
    [Parameter(Mandatory)] [ValidateSet('forest_root', 'additional_dc')] [string] $DcRole,
    [Parameter(Mandatory)] [string] $KeyVaultSecretName,
    [Parameter(Mandatory)] [string] $KeyVaultUri
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\Windows\Temp\dc-bootstrap.log' -Append

function Get-KeyVaultSecret {
    param([string]$VaultUri, [string]$SecretName)
    # 1. Get an AAD token for Key Vault from IMDS (managed identity).
    $imds = 'http://169.254.169.254/metadata/identity/oauth2/token' +
            '?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
    $token = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
    # 2. Read the secret.
    $url = "$VaultUri/secrets/$SecretName?api-version=7.4"
    return (Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $token" }).value
}

Write-Host "[*] Applying hardening baseline..."
& "$PSScriptRoot\Harden-Server2025Core.ps1"

Write-Host "[*] Installing AD DS role..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

Write-Host "[*] Retrieving DSRM password from Key Vault ($KeyVaultUri)..."
$dsrmPlain = Get-KeyVaultSecret -VaultUri $KeyVaultUri -SecretName $KeyVaultSecretName
$dsrm = ConvertTo-SecureString $dsrmPlain -AsPlainText -Force

Import-Module ADDSDeployment

if ($DcRole -eq 'forest_root') {
    Write-Host "[*] Promoting as FOREST ROOT for $DomainName..."
    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $NetbiosName `
        -ForestMode 'WinThreshold' `
        -DomainMode 'WinThreshold' `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $dsrm `
        -NoRebootOnCompletion:$false `
        -Force:$true
}
else {
    # Additional DC: join the existing forest. Domain admin creds are supplied
    # via a separate Key Vault secret retrieved the same way (managed identity).
    Write-Host "[*] Promoting as ADDITIONAL DC into $DomainName..."
    $daUser = "$NetbiosName\\Administrator"
    $daPass = ConvertTo-SecureString (Get-KeyVaultSecret -VaultUri $KeyVaultUri -SecretName 'domain-admin') -AsPlainText -Force
    $cred = [System.Management.Automation.PSCredential]::new($daUser, $daPass)
    Install-ADDSDomainController `
        -DomainName $DomainName `
        -Credential $cred `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $dsrm `
        -NoRebootOnCompletion:$false `
        -Force:$true
}

Stop-Transcript
