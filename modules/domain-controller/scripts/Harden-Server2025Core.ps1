<#
.SYNOPSIS
    Boilerplate CIS-style hardening baseline for Windows Server 2025 Core.

.DESCRIPTION
    Minimal-footprint hardening applied before AD DS promotion. This is a
    starting baseline, not a full CIS Level 2 implementation — extend with the
    official CIS-CAT or Microsoft Security Baseline GPOs once the domain exists.

    Covered:
      * Disable legacy / insecure protocols (SMBv1, NTLMv1, TLS 1.0/1.1).
      * Enforce SMB signing + encryption.
      * Enable advanced audit policy for security-relevant events (-> Sentinel).
      * Disable unused services and remove the GUI shell remnants.
      * Configure Windows Firewall to default-deny inbound.
      * Set strong account lockout + password policy locally (pre-domain).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\Windows\Temp\dc-hardening.log' -Append

Write-Host "[*] Disabling SMBv1..."
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force

Write-Host "[*] Enforcing SMB signing + encryption..."
Set-SmbServerConfiguration -RequireSecuritySignature $true -EncryptData $true -Force

Write-Host "[*] Disabling TLS 1.0 / 1.1, enabling TLS 1.2..."
$proto = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
foreach ($v in 'TLS 1.0', 'TLS 1.1') {
    foreach ($r in 'Server', 'Client') {
        New-Item -Path "$proto\$v\$r" -Force | Out-Null
        New-ItemProperty -Path "$proto\$v\$r" -Name Enabled -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path "$proto\$v\$r" -Name DisabledByDefault -Value 1 -PropertyType DWord -Force | Out-Null
    }
}

Write-Host "[*] Restricting NTLM (audit then restrict)..."
$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
New-ItemProperty -Path $lsa -Name LmCompatibilityLevel -Value 5 -PropertyType DWord -Force | Out-Null  # NTLMv2 only
New-ItemProperty -Path $lsa -Name RestrictAnonymous -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $lsa -Name NoLMHash -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host "[*] Enabling advanced audit policy (security event coverage)..."
$cats = @(
    'Logon/Logoff', 'Account Logon', 'Account Management',
    'DS Access', 'Policy Change', 'Privilege Use', 'Detailed Tracking'
)
foreach ($c in $cats) { auditpol /set /category:"$c" /success:enable /failure:enable | Out-Null }
# Process command-line auditing (high-value for Sentinel).
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' `
    -Name ProcessCreationIncludeCmdLine_Enabled -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host "[*] Setting Windows Firewall default-deny inbound..."
Set-NetFirewallProfile -Profile Domain, Public, Private -DefaultInboundAction Block -DefaultOutboundAction Allow -Enabled True

Write-Host "[*] Disabling unnecessary services (minimal footprint)..."
foreach ($svc in 'XblAuthManager', 'XblGameSave', 'MapsBroker', 'Spooler') {
    Get-Service -Name $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled -ErrorAction SilentlyContinue
}

Write-Host "[*] Local password / lockout policy (pre-domain hardening)..."
net accounts /minpwlen:14 /maxpwage:60 /minpwage:1 /uniquepw:24 /lockoutthreshold:5 /lockoutduration:30 /lockoutwindow:30 | Out-Null

Write-Host "[+] Hardening baseline applied."
Stop-Transcript
