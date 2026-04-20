---
title: "When Your Patching Tool Doesn't Know the HCL: Building HCLCheck for VMware and Dell"
description: "There is no native tool that cross-validates ESXi driver versions and firmware as a validated pair against the VMware HCL at scale. HCLCheck fills that gap — querying ESXi via PowerCLI and Dell OME via REST API simultaneously, then validating results against a local HCL reference table."
pubDate: 2026-04-16
tags: ["vmware", "powershell", "hcl", "dell", "infrastructure", "compliance", "esxi"]
draft: false
---

## The Gap Nobody Talks About

VMware vSphere Lifecycle Manager exists. Dell OpenManage Enterprise exists. The VMware Hardware Compatibility Guide exists. What does not exist is a tool that takes all three simultaneously and tells you whether your current driver and firmware are a validated pair on the HCL — across every host in your environment — without manual baseline setup per cluster and without requiring you to already know which pairs are valid.

That gap is not theoretical. It causes production outages. This post explains how it happens, what it looks like in production, and how HCLCheck closes it.

## Why vLCM and OME Both Miss This

vSphere Lifecycle Manager with the OMEVV Hardware Support Manager plugin is the closest thing VMware offers to HCL-aware patching. It can surface HCL violations — but only for hosts attached to a cluster with a configured OMEVV baseline. Standalone hosts are not covered. The baseline must be set up manually per cluster. And the validation is passive: it surfaces what's wrong after a compliance scan, but it does not prevent a patching cycle from creating an unvalidated state in the first place.

Dell OpenManage Enterprise tracks firmware versions and applies baselines, but OME has no knowledge of the VMware HCL. It knows what firmware version is current. It does not know whether that firmware version is only valid when paired with a specific driver. These are two different things, and the gap between them is where compliance failures live.

## Two Failure Patterns That Motivated This Tool

### The OEM Driver Problem on Fibre Channel HBAs

Dell-customized ESXi installation images bundle OEM-packaged Emulex lpfc drivers. For the Dell-branded LPe35002-M2-D 32Gb FC adapter (Subsystem ID f410), OEM-packaged lpfc drivers are not in the VMware HCL for ESXi 8.0 U3. Only VMware inbox drivers — lpfc 14.4.0.39, 14.4.0.40, and 14.4.0.42-35vmw — are validated for that adapter on that release.

Hosts upgraded from ESXi 7.x carry forward an even older OEM lpfc 14.2.x driver — two major versions behind the validated inbox driver, running on hardware actively serving virtual machines over Fibre Channel fabric.

The consequence: the non-validated lpfc driver on ESXi 8.0 U3 has a documented PSOD bug triggered by FC fabric FPIN (Fabric Performance Impact Notifications). When FC path events occur, hosts running the OEM driver can panic. Virtual machines pause, stall, and crash. An environment upgraded from ESXi 7.x using Dell's customized image is running this configuration by default, and vLCM will not flag it unless OMEVV is configured and the host is cluster-attached.

### The Firmware/Driver Pair Mismatch on PERC Storage Controllers

The PERC H755 has two validated HCL pairings for ESXi 8.0 U3: lsi_mr3 driver 7.730.01.00-1OEM with firmware 52.30.0-6115 (preferred), and 7.728.02.00-1vmw with firmware 52.21.0-4606 (acceptable). Those are the only two validated combinations for that controller.

OME firmware baselines update firmware and driver components independently. In practice, baselines have been observed updating H755 firmware to an intermediate version — 52.26.0-5179 — without updating the driver. The firmware version 52.26.0-5179 does not appear in the VMware HCL for any driver version. It is a real firmware version that OME will happily apply and report as current. It is also a combination VMware has never validated.

From Dell's perspective, the host is patched. From VMware's perspective, the host is in an unsupported state. Without a tool that checks both simultaneously, you will not find this during a normal patching cycle.

## What HCLCheck Does

HCLCheck is a PowerShell script that authenticates to vCenter via PowerCLI and to Dell OME via REST API, collects driver versions from ESXi hosts and firmware versions from OME, validates driver-firmware pairs against a local HCL reference table, and produces three output formats: a CSV detail report, a plain text summary, and an HTML report with a scorecard and per-host breakdown.

The core operation is a join: ESXi driver version from the host + PERC firmware version from OME + local HCL reference table = compliance status per host per component. No manual baseline configuration is required. No prior knowledge of which pairs are valid is assumed. You run the script and get a result.

## Key Technical Decisions

### Parallel Firmware Collection

The OME `InventoryDetails('deviceSoftware')` endpoint triggers a real-time iDRAC query per host. Each query takes 10 to 15 seconds. In a sequential loop across a large environment, that waiting time before any processing begins compounds quickly. HCLCheck launches up to 10 simultaneous PowerShell background jobs — each independently authenticating and calling the InventoryDetails endpoint for one host — with 90-second timeouts per job. All results are collected before the host processing loop begins.

The parallel approach also avoids OME's session limit problem. Sequential calls against a single OME session can trigger CUSR1340 (maximum concurrent sessions exceeded) if other automation is running. Background jobs each manage their own authentication independently.

### OME Session Management

HCLCheck probes the existing session token before creating a new one. If the token is still valid, it reuses it. If not, it creates a new session. Sessions are explicitly deleted when the script completes. This matters in environments where multiple administrators or automation tasks share a service account — orphaned sessions accumulate against the per-user session limit.

### Two-Stage Device Lookup

In many environments, branch hosts are inventoried by iDRAC hostname in OME rather than ESXi hostname. A direct hostname lookup against OME fails for these hosts. HCLCheck resolves devices by service tag first, then falls back to iDRAC hostname matching. This handles the common case where OME inventory was populated through iDRAC discovery rather than vCenter discovery, without requiring a manually maintained mapping table.

### PERC Pair Validation and FW-UNVERIFIED

HCLCheck validates driver and firmware as a combined unit. A driver that is on the HCL with a different firmware version is not a pass — it is flagged as NON-COMPLIANT with the specific mismatch noted. When firmware data is unavailable from OME (host offline, iDRAC unreachable, OME inventory stale), the result is marked FW-UNVERIFIED rather than NON-COMPLIANT. The distinction is operationally important: NON-COMPLIANT means a confirmed invalid state that requires remediation. FW-UNVERIFIED means the driver is valid but the firmware could not be confirmed — investigate OME or iDRAC directly before scheduling remediation.

### InstanceId-Based Component Filtering

OME inventory includes firmware entries for every server component: individual drives with build label versions like BJ07, BOSS SSDs, backplanes, NICs, PSUs. Matching PERC entries by device name strings is unreliable — naming varies across firmware versions and OME releases. HCLCheck uses the InstanceId field pattern to identify RAID controller entries specifically: `301_C_RAID` for H755 controllers, `401_C_RAID` for H965 controllers. BOSS and disk bay entries are explicitly excluded by InstanceId prefix. On certain server platforms, the BOSS SSD InstanceId shares a prefix with the PERC controller — the script detects this ambiguity and flags those hosts for manual verification rather than producing a false result.

## What Production Runs Found

When run against a production environment, HCLCheck surfaced several compliance issues that had gone undetected through normal patching processes.

On the PERC H755 side: the majority of affected hosts were running firmware 52.26.0-5179 paired with driver 7.728.02.00-1vmw — firmware that does not appear in the VMware HCL for any driver version, placing those hosts in a technically unsupported state. One host had firmware correctly updated to the 52.30.0-6115 target but the driver had not been updated to match, creating a mismatched pair from the same root cause operating in reverse.

On the PERC H965 side: several hosts were running driver sub-revision 8.11.1.0.0.0-1OEM. The VMware HCL lists 8.11.0.0.0 as valid; the .1 sub-revision is not listed and is therefore unvalidated. Two additional hosts had the driver updated to 8.14.2 but firmware remaining at 8.11.2, producing another unvalidated pair from the same independent-update pattern.

On the FC HBA side: multiple production clusters were found running non-validated OEM lpfc drivers. Active virtual machine stalls were observed on one cluster during a fabric event. One cluster running SQL Server Always On workloads was found to have an ESXi 7.x era lpfc 14.2.x driver on ESXi 8.0 U3 — the highest-priority finding given the data integrity risk from potential VM crashes on a cluster with availability group databases.

None of these findings were surfaced by existing OME baseline reports or vLCM compliance checks.

## The HCL Reference Table

The script ships with validated pairs for the Emulex LPe35002-M2-D FC HBA, PERC H755, and PERC H965 — the hardware configurations present during development. The `$hclReference` hashtable at the top of the script is the part most likely to need updating as VMware publishes new validated combinations and as you add hardware not covered by the default entries.

The schema is straightforward: adapter or controller type, driver version, and for PERC entries, the paired firmware version. Adding a new entry requires looking up your hardware on the VMware HCL, finding the validated driver and firmware version pair for your ESXi release, and adding a matching entry to the table. That is the manual work you would have done as part of an audit anyway — done once and encoded rather than repeated each cycle.

## Get the Tool

The full script is available on GitHub. It includes the HCL reference table for the Emulex LPe35002-M2-D FC HBA, PERC H755, and PERC H965. Extend the `$hclReference` table for your own hardware combinations.

**[HCLCheck on GitHub →](https://github.com/burdweiser/hclcheck)**

If your environment includes controllers or adapters beyond the default entries, add the validated pairs for your hardware and submit a pull request. Every validated pair you add makes the tool more useful for the next engineer who runs it against similar hardware. The VMware HCL is updated regularly — new validated combinations appear with each ESXi update cycle, and the reference table needs to keep pace.

The gap between "patched according to the vendor" and "validated according to VMware" is real, it is common, and it causes production incidents. Running this script after each patching cycle closes that gap in a few minutes.
