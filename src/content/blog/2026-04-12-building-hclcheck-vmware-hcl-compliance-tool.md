---
title: "Building the VMware HCL Compliance Tool That VMware and Dell Don't Provide"
description: "There is no native tool that cross-validates ESXi driver versions and firmware as a validated pair against the VMware HCL at scale. HCLCheck fills that gap by querying ESXi via PowerCLI and Dell OME via REST API simultaneously, then validating results against a local HCL reference table."
pubDate: 2026-04-12
tags: ["vmware", "powershell", "hcl", "dell", "storage"]
draft: false
---

## The Gap Nobody Talks About

VMware vSphere Lifecycle Manager exists. Dell OpenManage Enterprise exists. The VMware Hardware Compatibility Guide exists. What does not exist is a tool that takes all three simultaneously and tells you whether your current driver and firmware are a validated pair on the HCL — across every host in your environment — without manual baseline setup per cluster and without requiring you to already know which pairs are valid.

That gap is not theoretical. It causes production outages. This post explains how it happens and how HCLCheck closes it.

## Two Failure Patterns That Motivated This Tool

### The OEM Driver Problem on Fibre Channel HBAs

Dell-customized ESXi installation images bundle OEM-packaged Emulex lpfc drivers. For the Dell-branded LPe35002-M2-D 32Gb FC adapter (Subsystem ID f410), these OEM drivers are not in the VMware HCL for ESXi 8.0 U3. Only VMware inbox drivers — lpfc 14.4.0.39, 14.4.0.40, and 14.4.0.42-35vmw — are validated for that adapter on that release.

Hosts upgraded from ESXi 7.x carry forward an even older OEM lpfc 14.2.x driver. That is two major versions behind the validated inbox driver, on hardware that is actively in production, serving virtual machines over Fibre Channel fabric.

The consequence is not hypothetical. The non-validated lpfc driver on ESXi 8.0 U3 has a documented PSOD bug triggered by FC fabric FPIN (Fabric Performance Impact Notifications). FC path failures cause virtual machine pauses, stalls, and crashes. Environments running the OEM driver on upgraded hosts are running a known broken configuration that vSphere Lifecycle Manager will not flag because VLCM is checking whether the driver is current for the Dell image baseline — not whether the driver is on the VMware HCL.

### The Firmware/Driver Pair Mismatch on PERC Storage Controllers

Dell OME firmware baselines update firmware and driver components independently. The PERC H755 has two validated HCL pairings: lsi_mr3 driver 7.730.01.00-1OEM with firmware 52.30.0-6115 (preferred), and 7.728.02.00-1vmw with firmware 52.21.0-4606 (acceptable). Those are the only two validated combinations.

OME baselines were found to have updated firmware to an intermediate version — 52.26.0-5179 — without updating the driver. The version 52.26.0-5179 does not appear in the VMware HCL for any driver version. It is a real firmware version that OME will happily apply, that iDRAC will report as current, and that every Dell firmware tool will show as patched. It is also a combination that VMware has never validated.

This is the OME patching baseline gap: OME checks component versions against Dell's own baseline targets but has no knowledge that the combination must form a validated VMware HCL pair. The result is a host that is "patched" by every Dell metric and "non-compliant" by VMware's. Without a tool that checks both simultaneously, you will not catch this.

## What HCLCheck Does

HCLCheck is a PowerShell script that authenticates to vCenter via PowerCLI and to Dell OME via REST API, pulls driver and firmware data for all ESXi hosts matching a configurable prefix, validates driver-firmware pairs against a local HCL reference table, and outputs a CSV detail report, a plain text summary, and an HTML report.

The core operation is a join: ESXi driver version from the host + PERC firmware version from OME + HCL reference table = compliance result per host per component. Nothing in that pipeline requires manual baseline configuration. Nothing requires you to already know which pairs are valid. You run the script and get a list.

## Key Technical Decisions

### Two-Stage OME Device Lookup

Branch hosts are inventoried by iDRAC hostname in OME rather than ESXi hostname. A direct hostname lookup fails for these hosts. HCLCheck resolves devices by service tag first, then falls back to iDRAC hostname matching. This two-stage approach handles the common case where OME inventory was populated from iDRAC discovery rather than vCenter discovery, without requiring you to maintain a manual mapping table.

### OME Session Management

OME enforces a maximum concurrent session limit per user. Exceeding it returns a CUSR1340 error and the session creation fails silently if you are not looking for it. HCLCheck probes the existing token before creating a new session — if the token is still valid, it reuses it. Sessions are explicitly deleted when the script completes. This matters in environments where automation runs frequently or where multiple administrators share a service account.

### Parallel Firmware Fetch

The OME InventoryDetails endpoint triggers a real-time iDRAC query per host. Each query takes 10 to 15 seconds. In a sequential loop across 83 hosts, that is 15 minutes of wait time before any processing begins. HCLCheck launches up to 10 simultaneous PowerShell background jobs, each independently calling the InventoryDetails deviceSoftware endpoint for one host, with 90-second timeouts. All results are collected before the host processing loop begins. In practice this reduces the firmware collection phase from 15 minutes to under 2 minutes for an 80-host environment.

The parallel approach also sidesteps the session limit and connection-drop issues that affect sequential calls against a single OME session. Each background job manages its own authentication independently.

### PERC Pair Validation

HCLCheck validates driver and firmware as a combined unit rather than independently. A driver that is on the HCL with a different firmware version is not a pass — it is a partial match that is explicitly distinguished from a confirmed compliant pair. When firmware data is unavailable from OME (host offline, iDRAC unreachable, OME inventory stale), the script marks the result as FW-UNVERIFIED rather than NON-COMPLIANT. The distinction matters operationally: NON-COMPLIANT requires remediation, FW-UNVERIFIED requires investigation first.

### InstanceId-Based Component Filtering

OME inventory includes firmware for every server component — individual disks with build label versions like BJ07, BOSS SSDs, backplanes, NICs, PSUs. Naively iterating over all firmware entries and matching on device name strings produces false positives and misidentifications. HCLCheck uses the InstanceId field pattern to identify RAID controller entries specifically: 301_C_RAID for H755, 401_C_RAID for H965. BOSS entries and disk bay entries are explicitly excluded by pattern. This is more reliable than device name matching, which varies by firmware version and OME release.

### Targeted Rescan Mode

After remediation, you do not want to rescan 80 hosts to verify 5. HCLCheck accepts a configurable host list that limits scope to a specific subset. This is not a major feature but it is the difference between a tool you run once to find problems and a tool you run continuously to verify fixes.

## Results from Production

Scanning 83 ESXi 8.x branch standalone hosts produced the following results:

**23 hosts compliant.** Both PERC driver and firmware matched a validated HCL pair.

**51 hosts with PERC H755 firmware 52.26.0-5179.** This firmware version is not in the VMware HCL for any driver version. Both driver and firmware require updating to reach a validated pair.

**1 host with correct firmware but outdated driver.** Firmware was at the target version; driver had not been updated. Driver update only required.

**2 Dell T640 servers flagged for manual verification.** BOSS SSD firmware entries share an InstanceId prefix with PERC controllers on this platform. The script correctly identifies the ambiguity and flags it rather than producing a false result.

**4 hosts with PERC H965 driver sub-revision 8.11.1.0.0.0-1OEM.** This driver version is not listed in the VMware HCL. Upgrade to the validated 8.14 driver/firmware pair required.

**2 hosts with H965 driver updated but firmware remaining at 8.11.2.** The driver was remediated without updating firmware. The pair is not validated. Firmware update only required.

In the clustered environment, 3 production clusters were running non-validated OEM lpfc FC HBA drivers. Active VM stalls were observed on one cluster during a fabric event. One SQL Server Always On cluster was running an ESXi 7.x era lpfc driver on ESXi 8.0 U3 — a driver two major versions behind the validated inbox version, on a cluster running availability group workloads over Fibre Channel.

None of these findings would have surfaced from VLCM alone, OME alone, or a manual HCL lookup without knowing specifically what to look for.

## What This Tool Is Not

HCLCheck is not a remediation tool. It does not patch anything. It produces a compliance report that tells you what needs to change and why — the remediation is still a manual or VLCM-based process. It is also not a real-time monitoring tool. It is a point-in-time scan that you run after a patching cycle, after an upgrade, or on a schedule you define.

The local HCL reference table is a structured data file that you maintain. It ships with entries for the hardware configurations tested during development. If your environment includes hardware not in the default table, you add it. The schema is straightforward: driver version, firmware version, adapter or controller model, and a validated flag. Extending it requires reading the VMware HCL for your specific hardware and transcribing the validated pairs — which is the manual work you would have done anyway, now done once and encoded rather than repeated every audit cycle.

## Get the Tool

HCLCheck is available on GitHub. If you are running Dell hardware on ESXi 8.0 U3 and you have not validated your driver/firmware pairs against the HCL, run this before your next patching cycle.

If your environment includes hardware beyond PERC H755, H965, and Emulex lpfc adapters, extend the HCL reference table and submit a pull request. Every validated pair you add makes the tool more useful for the next engineer running it against similar hardware.

The gap between "patched according to the vendor" and "validated according to VMware" is real, it is common, and it causes outages. A script that closes that gap for your environment in under two minutes is worth the setup time.

**GitHub:** [github.com/burdweiser/hclcheck](https://github.com/burdweiser/hclcheck)
