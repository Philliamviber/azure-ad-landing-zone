# Deployment runbook: Azure AD Landing Zone

This is the operator runbook for deploying and verifying the `azure-ad-landing-zone` Terraform configuration. Follow the steps in order; the dependency graph means out-of-order applies will fail or produce incomplete state.

---

## Prerequisites

### Tools

| Tool | Minimum version | Check |
|---|---|---|
| Terraform | 1.6+ | `terraform version` |
| Azure CLI | 2.55+ | `az version` |
| PowerShell | 7.4+ (optional, for post-deploy checks) | `pwsh --version` |

### Azure permissions

The identity running `terraform apply` (user or service principal) needs:

- **Contributor** on the target subscription (to create resource groups and all resources)
- **User Access Administrator** on the subscription (to create role assignments — Key Vault Secrets Officer for deployer, Key Vault Secrets User for DC managed identities)
- Alternatively: a custom role combining both, scoped to the subscription

### Authentication

```bash
az login
az account set --subscription "<your-subscription-id>"
```

Verify the correct subscription is active:

```bash
az account show --query "{name:name, id:id, tenantId:tenantId}"
```

### Remote state backend (recommended)

The repo does not include a backend configuration. Before the first `init`, create a storage account for Terraform state and add a `backend.tf` (or pass `-backend-config` flags):

```hcl
# backend.tf (create this file — do not commit SAS keys)
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "<your_state_storage_account>"
    container_name       = "tfstate"
    key                  = "ad-landing-zone.tfstate"
  }
}
```

Create the state storage account before `init`:

```bash
az group create -n rg-tfstate -l centralus
az storage account create -n <your_state_storage_account> -g rg-tfstate -l centralus --sku Standard_LRS
az storage container create -n tfstate --account-name <your_state_storage_account>
```

### tfvars file

Create `terraform.tfvars` (do not commit this file):

```hcl
subscription_id = "<subscription-id>"
tenant_id       = "<tenant-id>"

# Optional overrides — defaults are shown in variables.tf
org_prefix       = "hlab"
environment      = "prod"
primary_location = "centralus"
secondary_location = "canadacentral"

ad_domain_name  = "homelab.local"
ad_netbios_name = "HOMELAB"

# REQUIRED: restrict this to your operator egress IP(s) before applying
allowed_paw_source_cidrs = ["<your-public-ip>/32"]
```

> **Warning:** `allowed_paw_source_cidrs` defaults to `0.0.0.0/0`. Leaving it open exposes Azure Bastion to the internet. Always set it to your operator IP(s).

### CustomScriptExtension script hosting

Before applying, host the bootstrap scripts in an accessible location for the Custom Script Extension. The `fileUris` array in `modules/domain-controller/main.tf` is intentionally empty in this repository. You must populate it with a reachable URL.

Recommended approach — private blob with SAS:

```bash
# Create a storage account in the security or management RG
az storage account create -n <scriptstorage> -g rg-hlab-security-prod-cus -l centralus --sku Standard_LRS

az storage container create -n scripts --account-name <scriptstorage>

az storage blob upload --account-name <scriptstorage> --container-name scripts \
  --file modules/domain-controller/scripts/Bootstrap-DomainController.ps1 \
  --name Bootstrap-DomainController.ps1

az storage blob upload --account-name <scriptstorage> --container-name scripts \
  --file modules/domain-controller/scripts/Harden-Server2025Core.ps1 \
  --name Harden-Server2025Core.ps1

# Generate a SAS token (time-limit to deployment window)
az storage blob generate-sas --account-name <scriptstorage> --container-name scripts \
  --name Bootstrap-DomainController.ps1 --permissions r --expiry 2026-06-16T00:00Z
```

Then set `fileUris` in `modules/domain-controller/main.tf` to the full blob URLs with SAS tokens before running `apply`.

---

## Init / plan / apply

### Step 1 — Init

```bash
cd C:\Users\pstib\azure-ad-landing-zone
terraform init
```

Expected: provider plugins download, backend initializes, no errors.

### Step 2 — Validate

```bash
terraform validate
```

### Step 3 — Plan

```bash
terraform plan -var-file="terraform.tfvars" -out=tfplan
```

Review the plan. The first apply will create approximately 60-70 resources. Key things to confirm in the plan output:

- Five resource groups at the correct regions
- `azurerm_firewall` SKU tier is `Premium` (not `Standard`)
- `azurerm_key_vault.this` has `enable_rbac_authorization = true` and `public_network_access_enabled = false`
- DC VMs have no `public_ip_address_id` on their NICs
- PAW VM has no `public_ip_address_id`
- `azurerm_virtual_network_peering` resources appear for hub↔dc1, hub↔dc2, hub↔paw (6 peering resources total)

### Step 4 — Apply

```bash
terraform apply tfplan
```

The apply will take 20-35 minutes. The longest steps are:

| Step | Approximate time |
|---|---|
| Azure Firewall Premium provisioning | 8-12 min |
| DC1 VM creation + CustomScriptExtension (AD DS install + forest creation + reboot) | 10-15 min |
| DC2 VM creation + CustomScriptExtension (additional DC join + reboot) | 8-12 min |
| Azure Bastion provisioning | 3-5 min |

DC2 is gated on DC1 by `depends_on = [module.dc1]`. The extension on DC2 will not start until DC1's extension completes successfully.

---

## Post-apply verification

### 1. Check extension status on both DCs

```bash
az vm extension show \
  --resource-group rg-hlab-identity-prod-cus \
  --vm-name vm-hlab-dc1 \
  --name dc-bootstrap \
  --query "provisioningState"

az vm extension show \
  --resource-group rg-hlab-identity-prod-cnc \
  --vm-name vm-hlab-dc2 \
  --name dc-bootstrap \
  --query "provisioningState"
```

Both should return `"Succeeded"`. If either returns `"Failed"`, retrieve the extension log from the VM at `C:\Windows\Temp\dc-bootstrap.log` and `C:\Windows\Temp\dc-hardening.log`.

### 2. Connect to the PAW via Azure Bastion

In the Azure portal, navigate to the Bastion resource (`bas-hlab-prod-cus`) and use the native client tunnel, or use the CLI:

```bash
az network bastion rdp \
  --name bas-hlab-prod-cus \
  --resource-group rg-hlab-connectivity-prod-cus \
  --target-resource-id $(az vm show -g rg-hlab-security-prod-cus -n vm-hlab-paw-prod-cus --query id -o tsv)
```

The PAW password is in Key Vault:

```bash
az keyvault secret show \
  --vault-name kv-hlab-prod-cus \
  --name "hlab-paw-prod-cus-local-admin" \
  --query "value" -o tsv
```

### 3. Verify DC promotion

From the PAW, open a PowerShell session and WinRM into DC1:

```powershell
$dc1Cred = Get-Credential   # HOMELAB\Administrator
Enter-PSSession -ComputerName 10.20.0.4 -Credential $dc1Cred
```

Inside the session:

```powershell
# Confirm AD DS is running
Get-Service NTDS, DNS | Select-Object Name, Status

# Confirm the forest exists
Get-ADForest

# Confirm DC1 is a GC and PDC emulator
Get-ADDomainController -Identity "vm-HLABDC1"
```

Expected: `ForestMode = Windows2016Forest`, `IsGlobalCatalog = True`.

### 4. Verify replication health

From DC1 (via PSSession):

```powershell
# Show all replication partners
repadmin /showrepl

# Check for replication failures
repadmin /replsummary

# Force a manual sync cycle and verify
repadmin /syncall /AdeP
```

Expected: no errors in `/replsummary`; DC2 appears as a replication partner for the default naming contexts (`DC=homelab,DC=local`, `CN=Configuration,...`, `CN=Schema,...`).

Also verify from DC2:

```powershell
Enter-PSSession -ComputerName 10.21.0.4 -Credential $dc1Cred
repadmin /showrepl
```

### 5. Verify WinRM path through the firewall

From the PAW:

```powershell
# Test connectivity through firewall to DC1 WinRM
Test-NetConnection -ComputerName 10.20.0.4 -Port 5985
Test-NetConnection -ComputerName 10.20.0.4 -Port 5986

# Test DC2
Test-NetConnection -ComputerName 10.21.0.4 -Port 5985
```

Expected: `TcpTestSucceeded : True` for all. If any fail, check:

1. Azure Firewall policy rule `nrc-paw-to-dc-winrm` is in the correct rule collection group
2. DC NSG rules `Allow-PAW-WinRM-In` (priority 120) are applied
3. UDR on the PAW subnet points to the correct firewall private IP

### 6. Verify Key Vault secret access

From DC1 (confirm the managed identity can reach Key Vault):

```powershell
$token = (Invoke-RestMethod `
  -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' `
  -Headers @{Metadata='true'}).access_token

Invoke-RestMethod `
  -Uri "https://kv-hlab-prod-cus.vault.azure.net/secrets/hlab-dc1-dsrm?api-version=7.4" `
  -Headers @{Authorization = "Bearer $token"} | Select-Object -ExpandProperty value
```

Expected: the DSRM password value is returned without error.

### 7. Verify Sentinel data flow

In the Azure portal, navigate to Microsoft Sentinel on `log-hlab-prod-cus` and run:

```kql
SecurityEvent
| where Computer contains "DC"
| summarize count() by Computer, bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

Allow 10-15 minutes after DC promotion for the first events to arrive. If no events appear after 30 minutes, verify the AzureMonitorWindowsAgent extension status on both DCs and confirm the DCR association (`dcra-hlab-dc1`, `dcra-hlab-dc2`) is linked to the correct DCR (`dcr-windows-dc-events`).

---

## Secret rotation

Secrets are managed in Key Vault. Terraform will not attempt to change them after the initial apply (due to `ignore_changes = [admin_password]` and the fact that `random_password` results are stored in state).

To rotate a DC local admin password:

```bash
# Generate a new password externally or use Key Vault rotation
az keyvault secret set \
  --vault-name kv-hlab-prod-cus \
  --name "hlab-dc1-local-admin" \
  --value "<new-password>"
```

Then apply the new password to the VM via PowerShell (from the PAW, using existing credentials):

```powershell
$newPass = ConvertTo-SecureString "<new-password>" -AsPlainText -Force
Invoke-Command -ComputerName 10.20.0.4 -ScriptBlock {
    param($p)
    net user lzadmin $p
} -ArgumentList "<new-password>" -Credential $currentCred
```

To rotate the DSRM password, repeat the same pattern: update the Key Vault secret (`hlab-dc1-dsrm`), then apply via `ntdsutil` or `Set-ADReplicationSite` tooling from the DC.

> Terraform does not manage the VM password after first apply. The Key Vault secret value and the VM's actual password are independent after rotation — keep them in sync via the procedure above.

---

## Teardown

```bash
terraform destroy -var-file="terraform.tfvars"
```

> **Note:** The Key Vault has `purge_protection_enabled = true` and `soft_delete_retention_days = 90`. After `terraform destroy`, the vault name will be unavailable for 90 days (soft-deleted state). To reuse the same name immediately, you must purge it manually:
>
> ```bash
> az keyvault purge --name kv-hlab-prod-cus --location centralus
> ```
>
> Purge requires the **Key Vault Contributor** role and cannot be undone.

Destroy order is the reverse of apply. Azure Firewall Premium typically takes 8-12 minutes to deprovision.
