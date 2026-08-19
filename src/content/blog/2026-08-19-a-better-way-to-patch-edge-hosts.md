---
title: "A Better Way to Patch Edge Hosts"
description: "Patching standalone ESXi hosts at branch offices is harder than it looks. Here's the web portal I built to schedule and orchestrate it across 100+ sites without breaking anything."
pubDate: "2026-08-19"
tags: ["vmware", "esxi", "vlcm", "powershell", "automation", "patching"]
draft: false
---

Most VMware patching content assumes you have a cluster. DRS moves the VMs off, the host enters maintenance mode, vLCM does its job, life is good. That's not branch-office ESXi.

At branch sites, there's one host and nowhere to move the VMs. You have a SQL server, some app VMs, and a domain controller all running on a single ESXi box connected to corporate over a WAN link. When you need to patch that host, you have to shut everything down in the right order, wait for remediation, then bring it all back up — without anyone losing data or coming in Monday morning to find the site is still down because the domain controller came up before SQL and something broke.

Do that 100 times across 100 branch sites, and you have an operational problem that the vSphere UI simply doesn't solve.

## Why the Native Tools Aren't Enough

vSphere Lifecycle Manager is solid technology. Image-based remediation works, the compliance view is useful, and the VCF integration has come a long way. But the native UI has a gap when it comes to standalone hosts at scale.

There's no scheduling — you trigger remediation manually. There's no graceful VM shutdown — if you let ESXi handle it, VMs get a hard power-off or a best-effort Tools-based shutdown with no ordering logic. There's no concept of a site-level sequence — SQL before apps before DC is something you have to manage yourself. And there's nothing to limit how many sites you tackle in parallel — without a throttle, someone will queue up all 100 at once and wonder why the WAN is saturated at 2 AM.

For a small number of sites you can work around this manually. For 100, you need a tool.

## What I Built

A web portal running on Windows Server 2025 / IIS that wraps the vCenter REST API for vLCM remediation. Operators log in, click a button to discover and inventory all standalone branch hosts, configure a batch job with a scheduled time and a site count limit, and walk away. The portal handles the rest: shutting down VMs in the right order at each site, putting the host into maintenance mode, triggering vLCM image remediation, polling for completion, exiting maintenance mode, and powering VMs back on in reverse order.

**Try the interactive demo below** — it's a fully functional frontend mock (no backend required, no vCenter connection):

<div style="border:1px solid var(--border,#ddd);border-radius:6px;overflow:hidden;margin:1.5rem 0">
  <iframe
    src="/tools/esxi-patching-portal/esxi-patching-portal.html"
    style="width:100%;height:720px;border:none;display:block"
    title="ESXi Branch Patching Portal Demo"
    loading="lazy">
  </iframe>
</div>

<p style="font-size:0.85rem;color:var(--muted,#666);margin-top:-1rem">
  Full-screen version: <a href="/tools/esxi-patching-portal/esxi-patching-portal.html" target="_blank">open in new tab ↗</a>
</p>

The demo simulates a query against a datacenter with 100 standalone hosts in a lab environment, shows the ESXi version and vLCM target image for each site, and walks through the full batch job creation wizard. The active jobs view shows what a running batch looks like — per-site state, VM power status, vLCM remediation percentage.

## The Architecture

The stack is intentionally simple:

- **Frontend:** Single HTML file, vanilla JS, no framework, no build step. IIS serves it directly.
- **API:** ASP.NET Core 8 minimal API, out-of-process on IIS.
- **Database:** SQL Server, Windows Auth only. No SQL passwords anywhere in config.
- **Job execution:** Windows Task Scheduler one-shot tasks created at submission time, running a PowerShell 7 script under a dedicated service account (`svc-esxipatch`).
- **Credentials:** DPAPI-encrypted credential file (`Export-Clixml`) for the service account's vCenter password. Decryptable only by the IIS App Pool identity on that specific machine.

One design decision worth calling out: the IIS App Pool and the job execution account are two different identities. The portal account can read inventory from SQL, create Task Scheduler jobs, and write audit records. The patching account (`svc-esxipatch`) is the only one that ever authenticates to vCenter. This means vCenter audit logs clearly show which account triggered remediation, and you can scope permissions tightly on both ends.

## VM Shutdown Ordering

The shutdown sequence is driven by a `VMType` classification stored in SQL — `DC`, `SQL`, or `APP` — with ordering values that determine when each VM is powered off and back on:

| VM Type | Shutdown Order | Power-On Order |
|---------|---------------|----------------|
| APP     | 1st (earliest) | 3rd (last)    |
| SQL     | 2nd           | 2nd            |
| DC      | Last          | 1st (first)   |

The logic: SQL servers depend on the domain controller for authentication, so the DC can't go down while SQL is still running. App VMs write to SQL, so SQL stays up until they're off. On the way back up, the DC has to be available before SQL starts, and SQL before apps can reach it.

The PowerShell job script reads the VM list from SQL at execution time. If an operator has manually overridden the order for a particular VM (there's a drag-and-drop interface in the portal), that order is preserved by a `CustomOrdered` flag in the database — inventory sync refreshes everything else but leaves manually set values alone.

## The vLCM REST Call

Triggering vLCM image remediation from the REST API is one call:

```powershell
$body    = @{ commit_date = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json
$taskUri = "$vcUrl/api/esx/settings/hosts/$hostMoRef/software?action=apply"
$resp    = Invoke-RestMethod -Method Post -Uri $taskUri -Headers $headers -Body $body -ContentType 'application/json'
$taskId  = $resp  # the response body IS the task ID string
```

The `$hostMoRef` value is extracted from the PowerCLI host object:

```powershell
$hostMoRef = ($vmHost.Id -split ':')[1]   # "HostSystem:host-42" → "host-42"
```

Poll status at:

```powershell
GET /api/cis/tasks/{taskId}?action=get
```

The response includes a `progress.completed` percentage you can surface in the portal's live view. vCenter session tokens expire after 30 minutes of inactivity by default, so the job script sends a heartbeat every 20 minutes:

```powershell
Invoke-RestMethod -Method Get -Uri "$vcUrl/api/session" -Headers $headers | Out-Null
```

## Standalone-Only Host Filtering

In this lab setup, the datacenter contains both standalone hosts and some clustered hosts used for other workloads. Clustered hosts have their own patching process — this portal touches standalone hosts only. The PowerCLI filter:

```powershell
$dc       = Get-Datacenter -Name $DatacenterName -ErrorAction Stop
$allHosts = Get-VMHost -Location $dc

$standaloneHosts = $allHosts | Where-Object {
    ($_ | Get-Cluster -ErrorAction SilentlyContinue) -eq $null
}
```

The portal shows both counts in the audit log ("107 total hosts · 100 standalone loaded · 7 clustered excluded") so there's no ambiguity about what was discovered versus what was in scope.

## SQL Inventory and Audit History

Every time an operator runs the host discovery query, the portal writes two things to SQL:

1. A `QueryRuns` row with a timestamp, who ran it, and how many hosts were found.
2. A `VMInventorySnapshots` row for every VM at every site — an immutable point-in-time copy of the inventory.

Jobs are linked to the `QueryRunId` from the discovery run that preceded them. That means you can always answer "what VMs were at site X when job Y ran, and in what order were they shut down?" without relying on logs.

The live `SiteVMs` table is what jobs actually read at execution time. It's kept current by a MERGE/UPSERT that respects the `CustomOrdered` flag described above.

## Download the Scripts

If you want to build this yourself, here are the two pieces that require the most SQL/PowerShell work:

All files are in the [burdweiser/edge-patching](https://github.com/burdweiser/edge-patching) repo on GitHub.

- **[Get-HostInventory.ps1](https://github.com/burdweiser/edge-patching/raw/main/Get-HostInventory.ps1)** — the PowerCLI script that discovers standalone hosts, classifies VMs by type, and writes inventory + snapshots to SQL via MERGE. Parameterized for vCenter FQDN, datacenter name, SQL server, and credential file path.

- **[esxi-portal-schema.sql](https://github.com/burdweiser/edge-patching/raw/main/esxi-portal-schema.sql)** — complete `CREATE TABLE` script for all six tables (`QueryRuns`, `SiteVMs`, `VMInventorySnapshots`, `Jobs`, `JobSites`, `AuditLog`) plus GRANT statements for both service accounts. Send this to your DBA to run against a new database.

- **[esxi-patching-portal.html](https://burdweiser.github.io/edge-patching/esxi-patching-portal.html)** — the full portal frontend as a standalone HTML file. Opens directly in a browser — no backend or vCenter connection required.

Both files are generic — no internal hostnames, no company names, no hardcoded credentials. Swap in your own values where the comments tell you to.

## What This Doesn't Do (Yet)

A few things are still on the list:

- **Email/Teams notification on job completion.** The audit log has everything you'd want to put in a notification, it just doesn't send one yet.
- **Automatic rollback.** If vLCM remediation fails mid-job, the script flags the site as failed and moves on. There's no automatic restore-from-snapshot logic — that's a manual recovery step.
- **vCenter event attribution per-operator.** Every vCenter event shows `svc-esxipatch` as the actor because that's the account making the API calls. The portal's audit log has the submitting operator's name, but it's in SQL, not in vCenter. If native vCenter attribution matters, you'd need to use the operator's session token for the API calls instead of a service account — which gets complicated fast given token expiry.

For this use case, those are acceptable tradeoffs. If you're building something similar, they're worth knowing about before you get too far down the road.
