# ADR 0001: Hub-spoke forced tunneling through Azure Firewall Premium for DPI

**Status:** Accepted  
**Date:** 2026-06-15  
**Deciders:** Platform/security team

---

## Context

The landing zone hosts Active Directory domain controllers in two separate Azure spoke VNets (DC1 in Central US / 10.20.0.0/24, DC2 in Canada Central / 10.21.0.0/24) and a privileged-access workstation (PAW) in a third spoke (10.30.0.0/24). These spokes need IP connectivity between them for:

- AD replication (DRSUAPI over RPC/DCOM, LDAP, Kerberos, DNS, NTP) between DC1 and DC2
- WinRM and RDP from the PAW to both DCs for operator management

Standard Azure VNet peering connects two VNets at Layer 3. In a naive hub-spoke design, spoke VNets are peered with a hub and with each other, allowing direct spoke-to-spoke traffic that bypasses any central inspection point. This means AD replication traffic and management traffic would flow peer-to-peer with no visibility and no ability to enforce signature-based intrusion detection.

The alternative — routing all inter-spoke traffic through the hub firewall — requires that:
1. Spokes peer only with the hub (no direct spoke-to-spoke peering).
2. Each spoke subnet has a User Defined Route (UDR) with a 0.0.0.0/0 default route pointing to the firewall private IP as the next hop (`VirtualAppliance`).
3. Hub-side peering enables `allow_forwarded_traffic = true` so the firewall can relay traffic between spokes.

The firewall tier chosen must support deep packet inspection (DPI) and signature-based intrusion detection/prevention (IDPS). Azure Firewall Standard does not include IDPS. Azure Firewall Premium does.

---

## Decision

All spoke-to-spoke traffic — including inter-DC AD replication and PAW-to-DC management sessions — is forced through **Azure Firewall Premium** at the hub, using a UDR with `0.0.0.0/0 → VirtualAppliance → <firewall_private_ip>` applied to every spoke subnet.

Spokes do **not** peer with each other. The peering submodule (`modules/networking-hub/peering`) creates only hub↔spoke pairs.

The firewall policy is configured with:
- `intrusion_detection.mode = "Deny"` — IDPS actively blocks matching signatures (not just alerts)
- `threat_intelligence_mode = "Deny"` — known-malicious IPs/domains are blocked
- An explicit allow-only rule collection for the AD port set (TCP/UDP) between DC subnets
- An explicit allow for WinRM/RDP from the PAW subnet to DC subnets
- Implicit deny-all for everything else (no broad permit rules)

NSGs on each spoke subnet enforce the same port scoping as an independent second layer; traffic that an NSG blocks never reaches the firewall.

---

## Consequences

**Positive:**

- All DC-to-DC replication traffic passes through the IDPS engine. Anomalous replication patterns (e.g., unexpected DRSUAPI callers, unusual replication frequency) can be detected and blocked at the firewall before they reach the DCs.
- The firewall's diagnostic logs (`allLogs`) stream to Log Analytics, giving Sentinel visibility into every allowed and denied flow between spokes.
- The forced-tunnel model means adding future spokes (e.g., a workload VNet) automatically subjects them to the same inspection without architectural changes — just a new UDR and peering.
- PAW-to-DC WinRM sessions are inspected, not just port-gated.

**Negative / trade-offs:**

- Azure Firewall Premium costs significantly more than Standard. For a homelab this is the dominant monthly cost item. There is no way to get IDPS without Premium.
- AD replication latency increases slightly because every replication packet must traverse the hub firewall. In practice this is negligible for a two-DC lab setup (sub-millisecond added round-trip within Azure backbone), but it would need measurement in a production high-replication-volume environment.
- The UDR 0.0.0.0/0 default route also forces Azure platform service traffic (Key Vault, Azure Monitor) through the firewall. The NSG outbound rule `Allow-Azure-Platform-Out` permits TCP 443 to the `AzureCloud` service tag, and the firewall must not have a rule blocking it. This is accounted for in the current policy (no deny rule covers `AzureCloud:443`), but it is a dependency to maintain when updating firewall rules.
- If the firewall is unavailable (maintenance, misconfiguration), spoke-to-spoke connectivity is lost entirely. There is no fallback path. This is intentional for a security-first design but means the firewall is a hard dependency for DC replication.
