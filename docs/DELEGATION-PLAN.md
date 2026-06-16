# Delegation Plan — AD Landing Zone (Terraform / Azure)

> Produced by the **tech-lead** agent. The main build executes it; specialist
> agents author the security ruleset review, docs, and diagrams.

## Goal & definition of done

Fresh Terraform repo (azurerm) that deploys a hardened AD landing zone on Azure:
hub-and-spoke, 2 DCs (Central US + Canada Central) on Windows Server 2025 Core
forming forest `homelab.local`, Azure Firewall Premium with IDPS + forced
tunneling, strict NSGs, private-only DCs, PAW/Bastion privileged plane, Key Vault
(RBAC) for secrets, Log Analytics → Sentinel with AMA/DCRs, CAF-aligned resource
groups. **Done** = code reviewed, `terraform validate`/`plan` clean, documented
with diagrams + README.

## Resolved decisions (assumptions baked into the build)

| Question | Decision |
|----------|----------|
| Subscription model | Single subscription; CAF functions split by **resource group**. |
| State backend | Azure Storage backend (commented stub in `versions.tf`); local for PoC. |
| CIS baseline | Authored as a PowerShell hardening script applied via Custom Script Extension. |
| Budget vs. Firewall Premium | Premium retained — required for IDPS/deep packet inspection. Everything else is cost-optimized (B-series VMs, Core, no public IPs). |
| Sentinel | New Sentinel solution onboarded onto the management Log Analytics workspace. |

## Step map

| # | Specialist | Output | Status |
|---|-----------|--------|--------|
| 1 | requirements-analyst | Acceptance criteria / scope | folded into this build |
| 2 | security-architect | Topology, IP plan, RG layout, UDR forced tunneling | implemented |
| 3 | threat-modeler | Attack paths → NSG/firewall mitigations | implemented in rules |
| 4 | iam-engineer | Key Vault RBAC, managed identities, secret model | implemented |
| 5 | cloud-security-engineer | Exact NSG + firewall IDPS ruleset | implemented |
| 6–10 | implementer | Repo scaffold, networking, DC/PAW compute, DSC, monitoring | **this build** |
| 11 | test-engineer | fmt/validate/tflint/plan, checkov/tfsec | run `make validate` |
| 12–13 | code-reviewer / cloud-security-engineer | Code + security review | post-build gate |
| 14 | tech-writer | Architecture docs + diagrams + runbook | **delegated** |
| 15 | readme-specialist | Root README | **delegated** |

> No agent performs a live `terraform apply`; validation is plan-time. The actual
> cloud deploy is a manual `apply` run by the operator (see `docs/deployment.md`).
