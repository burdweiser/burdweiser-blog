---
title: "The Image Is Not the ISO"
description: "A field guide to vSphere Lifecycle Manager: the model shift away from baselines, the driver components you can't delete, and a remediation failure that pointed at every host except the one thing actually broken."
pubDate: 2026-05-30
tags: ["vmware", "vsphere", "esxi", "vlcm", "lifecycle-manager"]
draft: false
---

vSphere Lifecycle Manager (vLCM) retired the old Update Manager baseline workflow in favor of a declarative, image-based model. Almost all the friction administrators hit comes from carrying a baseline-era mental model into an image-era tool.

Three things trip people up the most: how vendor content actually gets into the system, why certain components look permanently stuck in the image, and how to read a remediation failure that lies about where it lives. Here is each, in the order you tend to meet them.

## Two Worlds: Baselines and ISOs, Versus Images and a Depot

Under the legacy Update Manager (VUM) model, lifecycle work was **imperative and additive**. You imported a vendor's customized ISO — for example, an OEM PowerEdge ESXi image — built an upgrade baseline from it, attached the baseline to a cluster, scanned, and remediated. Baselines were things you layered on top of whatever was already there. You could stack several, group them, and mix vendor extensions with VMware patches.

The vLCM image model is the opposite posture: **declarative and absolute**. You define one desired image for an entire cluster, and every host is driven to match it exactly — nothing more, nothing less. The image isn't assembled from ISOs. It's composed from content in a **depot**.

That distinction is the single most common stumbling block: **you cannot use an imported ISO to update a cluster that is managed by a single image.** ISOs feed the legacy baseline path only. To get vendor content into the image world, you import the vendor's **offline bundle** — a `.zip` depot — which populates the depot with the base images, add-ons, and components an image can then reference. Importing the ISO does nothing for the image.

One more rule worth internalizing: a cluster is managed by **either baselines or an image, never both**. The moment you convert a cluster to image management, every legacy baseline becomes irrelevant to that cluster. The baselines don't disappear — they live at the vCenter scope and may still serve other clusters — but they exert zero influence on an image-managed one. If you see a long list of leftover baselines after switching to image management, that list is inert for the converted cluster.

| Dimension | Update Manager (baselines) | Lifecycle Manager (image) |
|---|---|---|
| Posture | Imperative, additive — apply on top of current state | Declarative, absolute — converge to one desired state |
| Input | Customized ISO → imported, made into a baseline | Offline bundle `.zip` → loaded into the depot |
| Scope | Attach per cluster/host; baselines persist at vCenter | Defined per cluster; all hosts forced to match |
| Coexistence | Mutually exclusive — a cluster is one or the other | Mutually exclusive — a cluster is one or the other |

## What a Single Image Is Actually Made Of

A vLCM image is composed of four layers. Reading them top to bottom is the fastest way to reason about everything else, because each problem you'll hit lives in a specific layer:

1. **Base image** — the ESXi release itself (e.g., ESXi 8.0 U3i). This is the foundation everything else sits on.
2. **Vendor add-on** — the OEM customization layer from your hardware vendor, delivered as a depot bundle. This is where Dell, HPE, Cisco, and others add their management agents, drivers, and CIM providers.
3. **Firmware and drivers add-on** — the layer that coordinates hardware firmware updates. This is the only layer that depends on an **external appliance** — a Hardware Support Manager (HSM) that has to be powered on, registered, healthy, and version-matched to your platform. When you're isolating a remediation problem, this is the first layer to suspect.
4. **Additional components** — individual VIBs layered on top, either pulled from the depot or manually added for specific needs.

The first two layers are routine. Layer four is where things get sticky (next section). And layer three deserves a flag: when troubleshooting, temporarily removing the firmware/drivers add-on from the image scope is a fast way to rule out HSM connectivity as the root cause.

## The Drivers You Can't Delete (and Shouldn't Try To)

Here's a classic: hardware-specific drivers show up as "additional components" on hardware that doesn't have that device — say, a vendor NIC or Fibre Channel driver on servers with none of that vendor's adapters installed. They sit in the image, flagged, and every instinct says remove them. The image won't let you. Understanding why saves you from making it worse.

### Read the Row, Not the Name

The control next to each component tells you what it is:

- A component delivered by the **vendor add-on** shows a **trash icon** — that one you can remove.
- A **manually added** component shows a **curved revert arrow** instead. That arrow is not a delete button: it reverts your version override, it does not remove the driver.

The real tell is the **struck-through version** beside a component. A crossed-out `-vmw` version means that driver is part of the platform base image — it's **inbox**. Inbox components cannot be removed from a cluster image at all, which is exactly why there is no trash icon to begin with.

### Why "Reverting" Backfires

If a host is running a **newer** inbox driver than the base image ships, clicking revert pins the **older** base version into the image. On the next remediation, the manager flags an unsupported downgrade — frequently the very error you were trying to escape. You don't clean anything; you re-create the problem.

An unused NIC driver is harmless. A storage driver is not automatically idle — if a "stuck" component is a Fibre Channel driver and you do have FC storage, it's load-bearing. Confirm the device genuinely isn't present before treating any driver as dead weight:

```bash
esxcli storage core adapter list
esxcli network nic list
```

### The Honest Verdict

An inbox driver for an absent device is **inert**. It loads nothing, claims nothing, and costs nothing but a cosmetic "manually added" label in the UI. The only way to truly excise it is to build a custom base image without the component — a fragile path that complicates every future upgrade and is effectively unsupported once you've hand-stripped a base image. For drivers that do nothing, that trade is never worth it.

## The Remediation That Wasn't Where It Looked

The setup: a valid image, and remediation that fails anyway. The frustrating part is that the error **evolves** as you chase it — each fix peels back a layer and reveals a more specific message underneath.

### The Tell

This is the diagnostic lesson worth keeping: **a true per-host defect stays on its host. A failure that migrates host-to-host after each fix isn't living in the hosts — it's living in something shared.**

The shared thing is the vCenter Update Manager service and its staging cache. Repeated failed remediations can leave that service holding corrupt or transient staging artifacts in cache. Every subsequent run reuses the poisoned cache and dies during staging — on whichever host it reaches first. Cleaning individual host VIBs was real work, but it was never the thing blocking the run.

```bash
vmon-cli -r updatemgr
```

This restarts the Update Manager service, flushing the transient staging cache and forcing a clean rebuild. Re-run remediation afterward. It's non-disruptive to running hosts — it only bounces a management service.

### Don't Conflate the Two Fixes

The checksum-mismatch error is real and has its own resolution: it's a checksum mismatch between a component installed on the host and the image in the depot, surfaced when the manager recomputes checksums during staging. Removing a genuinely stale host VIB — an old, manually installed host-client package, for instance — and letting remediation reinstall the image's version resolves that specific case. But if the same mismatch error immediately appears on the next host after you clear it from the first, you haven't fixed it — you've confirmed it's not a host artifact. That's the cache. Run `vmon-cli -r updatemgr`.

### Order of Operations

**1 — Restart the service first.**
When a staging error recurs on the next host after you fix the first, run `vmon-cli -r updatemgr` and retry. It's cheap and non-disruptive — do it before any host surgery.

**2 — Then read the real log.**
If it still fails, open `/var/log/lifecycle.log` on the failing host and read the final `InstallationError` line. That names the actual VIB-level cause — space, a bootbank lock, a leftover staging file, or a checksum mismatch.

**3 — Fix a stale VIB as its own problem.**
A checksum mismatch that does **not** migrate is a genuine host artifact. Remove the offending VIB and let remediation reinstall the image's version on that host.

## What to Keep

**ISO ≠ image.** ISOs feed baselines; offline-bundle ZIPs feed the depot. Importing an ISO will never update an image-managed cluster.

**One or the other.** A cluster is managed by baselines or an image, never both. Leftover baselines linger at vCenter scope and don't touch an image cluster.

**Layer 3 is external.** The firmware/drivers add-on is the only layer needing a healthy external HSM appliance. When isolating a failure, remove it first.

**Inert ≠ removable.** Struck-through version plus a revert arrow means an inbox component. It can't be deleted and shouldn't be reverted — and it's harmless if the device is absent.

**Migrating = shared.** An error that moves to the next host after each fix points at the vCenter service and cache, not a host. Restart `updatemgr` before touching anything.

**Logs over UI.** The UI error summary is a wrapper. The host's `lifecycle.log` holds the truth — go there for the VIB-level cause.

---

*Versions, build numbers, and add-on identifiers above are illustrative. Confirm behavior against the documentation for your specific vCenter and ESXi build before acting in production.*
