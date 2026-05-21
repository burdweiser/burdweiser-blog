---
title: "macOS on ESXi 8.0 U3i: History, Current Status, and What Actually Works"
description: "A complete timeline of macOS virtualization support on VMware ESXi — from the Intel transition in 2006 through the ESXi 8.0 discontinuation — plus an honest assessment of the unofficial Unlocker path and when to use Tart or Anka instead."
pubDate: 2026-04-24
tags: ["vmware", "esxi", "macos", "virtualization", "homelab"]
draft: false
---

## The Short Answer First

macOS is not a supported guest OS on ESXi 8.0 U3i. It was never added to the ESXi 8.x compatibility guide. VMware formally discontinued macOS as a guest OS and dropped support for Apple Mac hardware starting with ESXi 8.0 — the Mac Pro 6,1 and Mac mini 6,2/7,1 were the last supported host platforms, and their support ended with ESXi 7.0.

If you're here because you want to run macOS guests on ESXi 8.0 U3i anyway — for a homelab, for CI agents, for testing — this post covers what actually works, what doesn't, and what the modern alternatives look like. But first, the history, because the current situation makes more sense with context.

---

## A Timeline of macOS Virtualization on VMware Products

### 2006 — The Intel Transition Makes It Possible

VMware Fusion, which uses a combination of paravirtualization and hardware virtualization made possible by Apple's transition to Intel processors in 2006, marked VMware's first entry into Macintosh-based x86 virtualization. Before the Intel switch, macOS ran on PowerPC hardware and x86 virtualization wasn't an option. The move to Intel changed the architecture equation completely.

The key constraint that applied from the very beginning and never changed: Apple's EULA only permitted macOS to run virtualized on Apple-branded hardware. This was always the rule — VMware building the capability and Apple licensing the use of it were two separate things.

### 2007–2012 — ESXi and Fusion Support Mature

macOS Server was the initial focus for enterprise ESXi deployments. Early versions of ESXi running on Apple Mac hardware supported macOS Server guests — Mac mini and Mac Pro systems were the physical hosts, and macOS Server ran in VMs on top of them. This was a real enterprise use case: Xcode build servers, CI/CD for iOS and macOS apps, and Apple Remote Desktop management all drove demand for virtualized macOS at scale.

VMware Fusion supports more than 100 guest operating systems, including most versions of Windows, Linux, Mac OS X, OS X, and macOS. On the desktop side, Fusion supported macOS guests on Intel Mac hardware through successive versions, allowing older macOS releases to run alongside current versions — useful for testing app compatibility and running software that dropped 32-bit support.

### 2013–2019 — The Apple Hardware Constraint Tightens

The hardware story narrowed progressively. VMware continued to support the Apple Mac Pro 6,1 (Intel Ivy-Bridge EP), the Apple Mac Mini 6,2 (Intel Ivy-Bridge-DT), and the Apple Mac Mini 7,1 (Intel Haswell-DT) as ESXi hosts. These were the specific Apple hardware models that ESXi would run on and that VMware supported for macOS guest hosting. No newer Apple hardware was added to the supported list as Apple updated its Mac lineup.

This created a progressively awkward situation: the only Apple hardware officially supported as ESXi hosts was increasingly old. Administrators running macOS CI infrastructure on ESXi were doing so on hardware that Apple itself had long since discontinued.

### 2020–2021 — Apple Silicon Changes Everything

Apple Silicon (M1, released November 2020) fundamentally altered the macOS virtualization landscape. Apple Silicon macOS guests will never be able to be supported at all on x86 VMware infrastructure — the architectures are incompatible. VMware couldn't virtualize ARM macOS on x86 hardware, and Apple's new platforms don't support x86 ESXi.

VMware Fusion 13.0 was the first version to support Apple Silicon Mac systems. Only 64-bit guest operating systems based on the Arm CPU architecture (i.e. 'arm64' or 'aarch64') will run in VMware Fusion VMs on Apple Silicon Mac systems. It is not possible to run x86 operating systems in VMware Fusion VMs on Apple Silicon Mac systems.

This split the world: Intel Macs could still run macOS guests via ESXi 7.x with VMware's blessing (on the supported hardware), but the future of Apple's platform was ARM-only, and VMware had no path to virtualize ARM macOS on any infrastructure.

### 2022 — ESXi 8.0 Ships, macOS Support Ends

ESXi 8.0 shipped in August 2022 with macOS entirely absent from the guest OS compatibility guide. The vSphere 8.0 release notes documented deprecated and terminated guest operating systems. macOS wasn't deprecated in ESXi 8.0 — it was simply gone. It doesn't appear in the New VM wizard. There's no macOS guest OS family to select. The virtual SMC controller behavior that enables macOS to boot is no longer exposed.

VMware ceased support of vSphere ESXi on all Apple Mac platforms. Guest OS support for the x86 variant of macOS on vSphere ESXi moved to the Deprecated support level for ESXi 7.0, and VMware committed to testing and certifying new macOS releases on vSphere ESXi 7.0 and adding these to the VCG through 7.0's End of Support phase.

### 2022–Present — ESXi 7.0 as the Last Legitimate Path

ESXi 7.0 on supported Apple hardware (Mac Pro 6,1, Mac mini 6,2/7,1) became the last formally supported configuration for macOS guests in vSphere. Support for macOS as a guest operating system will be discontinued on VMware products. ESXi 7.0 End of Support marks the end of any vendor-supported macOS guest OS story on VMware infrastructure, full stop.

ESXi 8.0 through 8.0 U3i — the current release — has never supported macOS guests. Every update release of ESXi 8.x reaffirms this. There is no roadmap item to restore it.

---

## The Unofficial Path: ESXi Unlocker on 8.0 U3i

With the official door closed, the community solution is the `esxi-unlocker` project, which patches ESXi to expose the macOS guest OS family. Here's an honest assessment of where it stands on ESXi 8.0 U3i.

### What the Unlocker Does

The Unlocker patches `vmware-vmx` and `libvmkctl` to re-enable the macOS guest type flags and virtual SMC controller behavior that VMware removed from ESXi 8.x. Without the patch, macOS simply isn't an option in the VM creation wizard. With it patched, macOS appears as a valid guest OS family.

To be clear about the scope: the Unlocker doesn't add any capability that ESXi doesn't have the underlying code for — it re-enables configuration paths that VMware chose to disable. The virtualization engine for macOS was present; the exposure of it was removed.

### Current State of the Project

The original Unlocker 4 project is archived. The maintainer stopped development and the repository is read-only. Community forks exist that have adapted the patch for ESXi 8.x, and some redistributors bundle a patched ESXi 8.0 U3i image with Unlocker and additional NIC/NVMe drivers pre-applied. These community builds exist but you're operating outside VMware's support boundary in every direction.

### How It's Done (Lab Use Only)

This is the general process community guides follow. I'm documenting it, not recommending it for anything beyond an isolated homelab:

**1 — Prepare the macOS installer ISO.** Obtain the macOS installer from the App Store, use `createinstallmedia` to build a bootable disk image, then convert that to an ISO format compatible with ESXi.

**2 — Enable SSH on the ESXi host.** In the Host Client: Host → Actions → Services → Enable Secure Shell.

**3 — Upload and run the Unlocker.** Copy a community-maintained Unlocker build compatible with ESXi 8.x to a datastore via SCP or the datastore browser. Enable the executable bits and run the unlock script as root. Reboot the host.

**4 — Create the VM with a compatibility workaround.** Set VM compatibility to ESXi 7.0 U2 — not ESXi 8.0. The Unlocker project itself notes that ESXi 7.0 U2 compatibility avoids behaviors in 8.x that cause guest failures. Set the guest OS to macOS 12 (64-bit) even if you intend to install Sonoma or Sequoia. This is the standard workaround to get the installer past initial boot.

**5 — Install macOS normally.** Attach the ISO, boot, use Disk Utility to format the virtual disk, then proceed through the macOS installer.

**6 — Skip PCI passthrough.** This is the most important operational note for ESXi 8.x specifically: PCI passthrough on macOS Sonoma guests causes immediate host PSOD. The ESXi host crashes — not the guest, the host. Every virtual machine on that host goes down. Do not configure PCI passthrough for macOS guests on ESXi 8.0. Run without it.

**7 — Install VMware Tools for macOS.** These are in maintenance-only mode per Broadcom, but still function for basic guest OS integration.

### What You Get

A working macOS guest on ESXi 8.0 U3i: yes, with the above process. Stability comparable to ESXi 7.x: no. The combination of an archived unofficial patch, an ESXi version the patch wasn't designed for, and Apple EULA constraints (which apply unless you're on Apple hardware) adds up to a configuration that requires careful management.

One PSOD scenario worth emphasizing: passthrough aside, macOS Sonoma and Sequoia guests have been reported to trigger host panics more readily than older macOS versions on ESXi 8.x. Run snapshots aggressively and treat the host as dedicated to this purpose — don't co-locate workloads you can't afford to lose.

---

## Running Claude Agents in a macOS ESXi Guest

If the goal is running Claude Code, Claude Desktop, or API-based Claude agents on macOS in a VM, the technical requirements are modest.

Claude Code requires macOS 13 or later, 4 GB RAM minimum, an x64 or ARM64 processor, and an internet connection. No local model weights, no GPU requirement — it's a network client connecting to Anthropic's API. A working macOS 13+ guest with 4–8 GB of allocated RAM and two vCPUs meets every requirement. Claude Cowork is the one case where macOS specifically matters: it's macOS-only, so a macOS guest is the only path to running it on non-Mac hardware.

That said, ESXi 8.0 with Unlocker is a poor foundation for agent workloads you depend on. A host PSOD from an unexpected passthrough event or a fragile macOS guest state takes down every agent simultaneously. For light lab use or occasional testing, a macOS guest on ESXi 8.0 works. For anything you'd call production, the modern alternatives below are the right answer.

---

## Modern Alternatives: Tart and Anka

If your actual goal is macOS CI agents, build farms, or Claude agent pools on macOS, the current landscape has moved away from ESXi entirely for this use case. Two tools dominate:

**Tart** is an open-source macOS and Linux virtualization toolset built by Cirrus Labs. It runs on Apple Silicon using Apple's Virtualization framework — no hypervisor patches, no EULA complications, first-class performance because it's using Apple's own virtualization stack. It's designed for CI/CD: fast VM boot, OCI-compatible image distribution, and easy integration with GitHub Actions or any CI system. It's free and actively maintained.

**Anka** is Veertu's commercial macOS virtualization platform, also Apple Silicon native. It adds a management layer on top of Tart's core: a node controller, VM registry, build queue, multi-host distribution, and an API for orchestrating agent pools at scale. It's what CI shops use when they outgrow the single-machine model. Anka is licensed per host.

For running Claude Code agents specifically: Tart on a single Mac Studio or Mac mini M-series gives you multiple macOS VMs with genuine isolation, near-native performance, and no host stability concerns. Anka makes sense when you're managing a fleet of Mac hosts and need centralized VM image management and scheduling.

Neither has anything to do with ESXi. The macOS CI and agent world has moved to bare-metal Apple Silicon hosts running Apple's own virtualization stack, and both Tart and Anka are built for exactly that.

---

## Decision Guide

| Situation | Recommended Path |
|---|---|
| Production macOS guest on ESXi | Not viable on ESXi 8.x — use ESXi 7.0 on supported Apple hardware until 7.0 EOS, then migrate |
| Homelab macOS guest, no passthrough | Unlocker on ESXi 8.0 U3i — works, fragile, eyes open |
| macOS CI/build agents at any scale | Tart or Anka on Apple Silicon Mac hardware |
| Claude Cowork or Claude Code on macOS VM | Mac mini or Mac Studio → Tart → macOS guest |
| ESXi 8.x, just need Claude Code | Run Claude Code on Linux or Windows — both are natively supported |

The macOS on ESXi story ends at ESXi 7.0 on 2013-era Apple hardware. Everything beyond that is unofficial, fragile, or both. The community has made it work on ESXi 8.x, but the investment in getting it stable and keeping it stable is substantial for a setup that offers no TAC support, no vMotion reliability guarantees, and a host PSOD risk that doesn't exist in the same way on any other guest OS.

If macOS virtualization matters for your workloads, Apple Silicon + Tart or Anka is where the capability actually lives now.

---

*VMware, vSphere, and ESXi are trademarks of Broadcom Inc. Apple, macOS, Mac, and Apple Silicon are trademarks of Apple Inc. All product capabilities described reflect publicly available documentation and community reports current as of April 2026.*
