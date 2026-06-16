# ADR 0002: Key Vault RBAC delegation over access policies

**Status:** Accepted  
**Date:** 2026-06-15  
**Deciders:** Platform/security team

---

## Context

The landing zone generates secrets at deployment time (DC local admin passwords, DSRM passwords, PAW admin password) using Terraform's `random_password` resource. These secrets must be stored durably, made available to VMs at bootstrap time without appearing in Terraform state outputs or environment variables, and audited for every access.

Azure Key Vault offers two authorization models:

**Access policies (legacy model):** Vault-level permissions granted to a service principal or managed identity. An access policy grants a principal rights across all secrets (or keys/certificates) in the vault — there is no per-secret scoping. Access policies are vault-level objects stored inside the Key Vault resource itself, which means they are not visible in Azure RBAC role assignments and are harder to audit with tools like `az role assignment list` or Azure Policy.

**RBAC authorization (modern model):** Standard Azure RBAC role assignments on the Key Vault resource (or individual secret/key child resources). Access policies are disabled entirely when `enable_rbac_authorization = true`. Roles are managed through ARM and appear in the standard RBAC audit trail. Role assignments can be scoped to a specific secret resource ID, enabling least-privilege per-secret delegation.

The landing zone has three distinct principal types that need secret access:

1. **The deploying Terraform identity** — needs to create and update secrets (write). Uses `Key Vault Secrets Officer` on the vault scope.
2. **DC1 managed identity** — needs to read its own local admin secret, its DSRM secret, and write the `domain-admin` secret. Currently granted `Key Vault Secrets User` on the vault scope (read-only).
3. **DC2 managed identity** — needs to read its own local admin secret, its DSRM secret, and the `domain-admin` secret seeded by DC1.

Under the access policy model, each of these would require a vault-level access policy. Per-secret scoping is not possible. Under RBAC, the `Key Vault Secrets User` role can in principle be scoped to individual `azurerm_key_vault_secret` resource IDs, though the current implementation scopes it to the vault for simplicity.

---

## Decision

Key Vault is configured with `enable_rbac_authorization = true`. Vault access policies are disabled. All access is granted via Azure RBAC role assignments:

- `Key Vault Secrets Officer` → deploying principal (object ID from `data.azurerm_client_config.current`) — scoped to the vault
- `Key Vault Secrets User` → DC1 system-assigned managed identity — scoped to the vault
- `Key Vault Secrets User` → DC2 system-assigned managed identity — scoped to the vault
- `Key Vault Secrets User` → PAW system-assigned managed identity — scoped to the vault (for future extension)

Role assignments are created by `azurerm_role_assignment` resources in the respective modules (`key-vault/main.tf` for the deployer, `domain-controller/main.tf` for the DC identities).

The vault has `public_network_access_enabled = false` and `network_acls.default_action = "Deny"` with `bypass = "AzureServices"`. VMs reach the vault over the Microsoft backbone using the `AzureServices` bypass, not over the public internet or a private endpoint. All secret access events are logged to Log Analytics via the `AuditEvent` diagnostic category.

---

## Consequences

**Positive:**

- Role assignments appear in `az role assignment list` and in Azure Activity Log, giving a single, standard audit trail for "who can access what" across all Azure resources. There is no separate access-policy audit path to maintain.
- Azure Policy can enforce that no vault in the subscription uses access policies (`deny` on `enable_rbac_authorization = false`). This is straightforward with RBAC mode; enforcing least-privilege access policies at scale is much harder.
- The `Key Vault Secrets User` role is read-only (get + list on secrets). The DC managed identities cannot create, update, or delete secrets, which limits the blast radius if a DC is compromised. Under the access policy model, a misconfigured policy might grant write access inadvertently.
- RBAC role assignments are ARM resources and are thus visible to Terraform's plan/apply cycle. Access policies are embedded in the vault resource and are easier to drift from desired state.
- Diagnostic category `AuditEvent` captures every secret get/set/delete with the caller's identity, enabling Sentinel to alert on unexpected secret access patterns (e.g., a DC reading the other DC's DSRM secret).

**Negative / trade-offs:**

- The `User Access Administrator` (or equivalent) permission is required on the subscription to create role assignments. This is a higher privilege than the `Contributor` role alone. In organizations with strict separation of IAM and resource management, this requires coordination with the IAM team.
- The current implementation scopes both DC managed identities to the vault rather than to individual secrets. A DC can read any secret in the vault, not just its own. This is acceptable for a lab but should be tightened for production by scoping the `Key Vault Secrets User` role to the specific secret resource IDs (e.g., `${azurerm_key_vault_secret.dsrm.id}` instead of `var.key_vault_id`).
- `purge_protection_enabled = true` means a `terraform destroy` followed by a re-apply with the same vault name will fail for 90 days. Operators must either purge the soft-deleted vault manually (`az keyvault purge`) or use a different vault name between iterations.
