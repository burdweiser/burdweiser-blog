---
title: "NVIDIA GPUs in vSphere 9: Time-Slicing vs MIG Mode"
description: "A field guide for VMware architects designing on-premises AI infrastructure with NVIDIA vGPU, VMware Private AI Foundation, and the new capabilities in ESXi 9 Update 1 — and an honest take on where VCF fits versus purpose-built AI cluster tooling."
pubDate: 2026-04-22
tags: ["vmware", "nvidia", "ai infrastructure", "vcf", "esxi", "vgpu", "deep-dive"]
draft: false
---

When GPU mode selection was purely a driver configuration task — something an admin handled once and forgot — architects didn't need to think much about it. That era is over. In modern on-premises AI environments built on VMware Cloud Foundation, the choice between time-slicing and MIG mode affects workload latency, tenant isolation, NVLink fabric availability, DRS behavior, NIM microservice compatibility, and the licensing posture of your entire Private AI deployment.

This post documents the current state of NVIDIA GPU virtualization on VMware vSphere, with particular focus on what ESXi 9 and 9 Update 1 unlock compared to ESXi 8, and what all of it means for the architects who have to design these environments and justify the decisions to their teams.

## 01 — A Note on ESXi Versioning

Before going further, a terminology clarification that matters: what the community commonly calls "ESXi 9.1" is formally versioned as VMware vSphere Hypervisor ESXi 9 Update 1 (build 9.0.1.0), released September 29, 2025. ESXi 9 GA shipped June 17, 2025, followed by patch 9.0.2.0 in January 2026.

This distinction is not pedantic. Several significant GPU capabilities are gated specifically on ESXi 9 Update 1 and will not function on earlier ESXi 9.0 builds or any ESXi 8 release. The most significant of these is the new Time-Sliced MIG-Backed vGPU hybrid mode, which is the centerpiece capability this post explores.

> **Key Version Gate:** Time-sliced, MIG-backed NVIDIA vGPU support requires ESXi 9 Update 1 (9.0.1.0) or later. All ESXi 8 releases and the initial ESXi 9.0 GA build do not support this capability.

## 02 — Time-Slicing Mode: How It Actually Works

Time-slicing is the original vGPU sharing mechanism, and it remains relevant for a wide range of workloads. Understanding it precisely matters because its limitations are often overstated and its strengths are real.

A time-sliced vGPU is a vGPU that resides on a physical GPU that is not partitioned into multiple GPU instances. All time-sliced vGPUs resident on a GPU share access to the GPU's engines — including graphics, video decode, and video encode — but they do so in sequence, not in parallel. Each vGPU waits while other processes run on other vGPUs. While a process runs on a given vGPU, that vGPU has exclusive use of the GPU's engines for its time slice.

**What Time-Slicing Gets Right**

- **Maximum VM density.** A single physical GPU can host many time-sliced vGPUs, limited primarily by frame buffer allocation. This matters in environments where raw GPU count is the constraint.
- **Workload flexibility.** Time-sliced profiles support a wider variety of GPU types, including Turing (T4) and Volta (V100) GPUs in existing ESXi 8 infrastructure. Every GPU that supports NVIDIA AI Enterprise supports time-slicing.
- **NVLink peer-to-peer support.** This is the critical capability that MIG mode cannot match. Full-frame-buffer time-sliced Q-series and C-series vGPUs support NVLink P2P transfers, enabling a single VM to span multiple physical GPUs across the NVLink fabric.
- **Bursty workload efficiency.** For workloads with intermittent GPU demand — developer environments, CI/CD pipelines, light inference endpoints that process requests sporadically — time-slicing is measurably more hardware-efficient because idle slices don't waste dedicated silicon.

**Where Time-Slicing Breaks Down**

Time-slicing introduces a noisy neighbor problem that is architectural, not configurable away. Because all time-sliced vGPUs share the same physical VRAM pool with no hard boundaries, a process that allocates excessive memory can trigger out-of-memory errors for co-resident workloads. Context switching overhead grows non-linearly under concurrent sustained load — under three simultaneous heavy requests, that overhead can consume 5–15% of available compute.

Perhaps most critically for production operations: a fatal memory error in one time-sliced vGPU propagates to all vGPUs sharing that physical GPU, potentially triggering a GPU reset that takes down every VM sharing the device simultaneously.

## 03 — MIG Mode: Hardware-Level Partitioning

MIG is a hardware feature introduced on the NVIDIA Ampere architecture (A100, A30) and present on every subsequent data center GPU generation through Hopper (H100, H200) and Blackwell. It is not a software scheduler — it is genuine silicon-level partitioning.

When a GPU is placed in MIG mode, it is physically divided into up to seven GPU instances. Each MIG instance gets its own dedicated streaming multiprocessors, memory, memory bandwidth, and cache. The paths through the entire memory system are separated at the hardware level — on-chip crossbar ports, L2 cache banks, memory controllers, and DRAM address buses are all assigned exclusively to individual instances.

**The Performance and Isolation Guarantee**

This hardware isolation produces something time-slicing cannot: guaranteed QoS per instance. Processes on different MIG instances run in parallel — truly simultaneously on the same physical GPU — with zero contention between them. A workload saturating one MIG instance has no effect on the performance of a workload running on another instance of the same GPU.

Fault isolation is equally complete. A crash, memory overflow, or application hang in one MIG instance cannot propagate to other instances. This is a meaningful SLA consideration for multi-tenant production environments.

**The MIG Trade-Offs Architects Must Know**

- Maximum 7 instances per GPU, with fixed profile shapes. Unlike time-slicing, you cannot have 12 small workloads on one GPU — the maximum partition count is hardware-constrained.
- NVLink P2P is disabled. MIG instances are fully isolated. A workload on a MIG instance cannot communicate with workloads on MIG instances of other physical GPUs via NVLink. This is the defining architectural constraint for dense GPU system design.
- Profile reconfiguration requires instance destruction. You cannot resize an active MIG instance without destroying it and its workload. This makes MIG a configuration policy, not a live scheduling knob — though dynamic reconfiguration between workload windows is documented and practical.
- Ampere or newer only. T4, V100, and any pre-Ampere GPU in your installed base cannot use MIG, ever.

> **Operational Tip:** MIG can be used dynamically across time windows. Seven small instances during the day for parallel inference, reconfigured to one large instance at night for training, is a documented and supported pattern. Planning this reconfiguration schedule into your automation is a legitimate optimization strategy.

## 04 — The ESXi 9 Update 1 Hybrid Mode

ESXi 9 Update 1 introduces a third mode that wasn't possible in any previous ESXi release: Time-Sliced MIG-Backed vGPU. This is the architectural unlock that makes the version gate on ESXi 9 Update 1 matter for AI platform design.

The hybrid mode works by combining MIG's hardware-level spatial partitioning with time-slicing's temporal partitioning — within a single MIG instance. Multiple VMs can time-share a single MIG slice. This produces a three-tier resource model that VMware architects haven't had available before:

| Mode | Isolation | Density | NVLink P2P | ESXi Requirement |
|---|---|---|---|---|
| Full Time-Slicing | Minimum | Maximum | Supported | All versions |
| MIG-Backed vGPU | Full hardware per instance | Low (max 7) | Disabled | ESXi 9 GA+ |
| Time-Sliced MIG-Backed | Hardware between slices, time-sharing within | Medium | Disabled | ESXi 9 Update 1+ |
| GPU Passthrough | Dedicated GPU per VM | Lowest | Supported (non-NVSwitch) | All versions |

**When the Hybrid Mode Makes Sense**

The primary use cases are scenarios requiring isolation between groups of users combined with resource sharing within each group:

- **Shared developer tenants.** Give Team A a 40 GB MIG slice on an H100 and time-share it among three developers — they get hardware isolation from Team B's slice while sharing their allocated GPU budget.
- **Compliance-separated multi-tenancy with density.** A healthcare workload and a financial workload each get their own MIG slice for data boundary enforcement, while within each slice, multiple processing VMs time-share the compute.
- **Pipeline-stage co-location.** An ASR stage and a TTS stage can share one MIG slice via time-slicing, while the LLM inference stage gets its own isolated MIG slice — matching the resource pattern in NVIDIA's own voice AI pipeline benchmarks.

Profile naming is your signal: a profile like `nvidia_h200x-1-35c` indicates a MIG-backed profile (the middle digit), while `nvidia_h200x-35c` without the middle segment indicates time-sliced.

## 05 — Performance Impacts Compared

**The 33% Throughput Gap Under Production Load**

NVIDIA benchmark data from A100 testing quantifies the difference: MIG achieves approximately 1.00 requests per second per GPU for AI inference workloads, versus 0.76 req/s for time-slicing configurations. That 33% throughput gap matters significantly at scale when you're counting H100-hours in your own data center.

The explanation is structural. Under heavy concurrent load, time-sliced processes compete for the same memory controllers and crossbar, creating contention that slows everyone down. MIG instances have dedicated memory controllers — which is why measured MIG throughput slightly exceeds the naive linear prediction from its compute fraction, because memory bandwidth contention is eliminated entirely.

**Where Time-Slicing Has a Latency Edge**

Time-slicing shows faster individual task completion for bursty, low-concurrency workloads. In NVIDIA's voice AI pipeline tests, time-slicing achieved 144.7ms mean text-to-speech latency versus MIG's 168.2ms. However, that 23.5ms difference becomes negligible when the LLM bottleneck in the same pipeline accounts for roughly 9 seconds of total processing time. The practical conclusion: latency advantages of time-slicing evaporate under production load.

**The Fault Blast Radius Difference**

This is under-discussed in vendor documentation. Under time-slicing, a fatal error in one workload — a memory overflow, a hung CUDA process, a misconfigured model — propagates through the shared execution context to all vGPUs on that physical GPU. The result can be a GPU reset that takes down every VM sharing that device. Under MIG, that same event is fully contained within the failing instance. For architects designing multi-tenant AI platforms, this blast radius difference is a material SLA consideration.

| Dimension | Time-Slicing | MIG Mode |
|---|---|---|
| Execution model | Serial (temporal) | Parallel (spatial) |
| Memory isolation | Shared pool | Dedicated per instance |
| Noisy neighbor effect | High risk under load | Eliminated by hardware |
| Fault isolation | Failure can propagate | Instance-contained |
| Inference throughput | ~0.76 req/s (A100) | ~1.00 req/s (+33%) |
| Context switching overhead | 5–15% under sustained load | None |
| VM density | Higher | Lower (max 7 instances) |
| Optimal workload | Bursty, dev/test | Production, latency-sensitive |

## 06 — NVLink, HGX, and Dense GPU Systems

The NVLink constraint is one of the most consequential — and easiest to overlook — architectural decisions in GPU mode selection.

> **Critical Architectural Rule:** Peer-to-Peer CUDA transfers over NVLink are supported only for time-sliced vGPUs allocated all of the physical GPU's frame buffer. MIG-backed vGPUs cannot use NVLink P2P under any ESXi version. NVSwitch fabric is also not supported for vGPU on VMware vSphere.

**HGX Platform Considerations**

HGX-class servers with 8 SXM5 GPUs fully interconnected via NVLink deliver up to 900 GB/s GPU-to-GPU bandwidth via NVSwitch on the HGX baseboard. For architects planning ESXi deployments on these platforms, the mode choice translates to a hard fork:

- **Time-Slicing (Full Frame Buffer):** NVLink P2P is available. A single VM can span multiple GPUs across the NVLink mesh. The 900 GB/s NVSwitch fabric is accessible. This is what you bought this system for.
- **MIG Mode:** NVLink P2P is disabled. The NVSwitch fabric becomes invisible to vGPU workloads. You are treating this as independent smaller GPUs — and paying for the NVSwitch you can't use.

The implication is unambiguous: HGX-class NVSwitch systems are poor candidates for MIG mode under VMware vSphere. Their primary differentiator — the high-bandwidth GPU mesh — is not accessible to MIG-backed vGPUs.

There is one additional constraint: GPU passthrough is not supported on NVIDIA systems that include NVSwitch when using VMware vSphere. On HGX systems under ESXi, vGPU is the only supported GPU access mode.

For PCIe NVLink Bridge platforms connecting pairs of PCIe-form-factor GPUs — delivering up to 600 GB/s H100 GPU-to-GPU bandwidth — the same vGPU constraint applies. Only full-frame-buffer time-sliced Q-series or C-series vGPUs support NVLink P2P. MIG disables it here too.

## 07 — ESXi 8 vs ESXi 9 Feature Delta

| Capability | ESXi 8 | ESXi 9 GA | ESXi 9 Update 1+ |
|---|---|---|---|
| MIG-backed vGPU | Not supported | Supported (vGPU 19.0+) | Supported |
| Time-Sliced MIG-Backed vGPU | Not supported | Not supported | Supported |
| vMotion stun time (vGPU) | Multiple seconds | <1 second | <1 second |
| Fast-Suspend-Resume (2x L40) | ~42 seconds | ~2 seconds | ~2 seconds |
| vGPU data channel streaming | ~10 Gbps | Up to 30 Gbps | Up to 30 Gbps |
| Device selection policies | None | Performance / Consolidation | Performance / Consolidation |
| Automated device reconfiguration | Manual | Automated | Automated |
| GPU Reservations | Not available | Tech Preview | Tech Preview |
| DRS automation level for vGPU | Partial or Manual | Partial or Manual | Partial or Manual |

The two improvements with the most practical impact are the vMotion stun time reduction and the Fast-Suspend-Resume improvement. Together, they mean GPU-enabled clusters running in VCF 9.0 can participate in live patching workflows without disruptive maintenance windows — a capability that was operationally unrealistic in ESXi 8.

## 08 — DRS Automation: What Actually Changed

**What Didn't Change**

DRS automation level must still be set to Partially Automated or Manual for any cluster running vGPU-enabled VMs. Fully Automated DRS cannot factor GPU availability, profile type, MIG configuration, or NVLink topology into its placement decisions. This means GPU cluster automation relies on operator intent rather than vSphere intelligence for workload placement.

**What's New in ESXi 9**

ESXi 9.0 introduces configurable device selection policies for enhanced vGPU devices. Architects can now choose between a performance-focused policy (distributes VFs evenly across physical devices to minimize contention) and a consolidation-focused policy (packs VFs onto fewer devices to preserve free GPUs for new workloads). This is the first mechanism in vSphere giving operators explicit control over GPU packing behavior without manual placement.

ESXi 9 also eliminates the need for administrators to manually configure devices to desired profiles prior to VM power-on or migration. Reconfiguration now happens transparently at VM lifecycle events. VCF 9.0 additionally introduces DirectPath Profile Pools (DPPs), providing a cluster-wide aggregate view of consumed and remaining vGPU capacity across all hosts — a problem that previously required manual per-host inspection.

> **Design Note:** GPU Reservations — the feature that would allow administrators to set aside GPU slots for mission-critical AI workloads — shipped as a tech preview in VCF 9.0. It is not GA. Architects designing SLA-backed GPU allocation systems should factor this maturity status into their plans.

## 09 — VMware Private AI Foundation with NVIDIA

VMware Private AI Foundation with NVIDIA became generally available in May 2024 and gained significant new capabilities in VCF 9.0. Private AI Services now include GPU Monitoring, Model Store, Model Runtime, Agent Builder, Vector Database, and Data Indexing and Retrieval.

Model Runtime supports Model Endpoint Sharing, allowing secure sharing of AI models between tenants while maintaining full data privacy for each — a single model instance scaled horizontally across the organization with each team getting separate private namespaces.

**The NIM Constraint — The Most Important Design Fork**

NVIDIA NIM microservices cannot use MIG sharing mode. If your Private AI architecture deploys NIM for LLM inference — the primary inference runtime in the platform — the GPU hosting those NIM workloads must be in time-slicing mode. This produces a design fork:

- **NIM Inference Path → Time-Slicing.** All NIM-based inference workloads — RAG pipelines, chatbots, agentic AI — must run on time-sliced GPUs. These GPUs lose the MIG isolation guarantee but gain NIM compatibility and NVLink P2P availability.
- **Fine-Tuning / Training Path → MIG.** Isolated fine-tuning jobs, NeMo customization workloads, and multi-tenant training pipelines are well-served by MIG. These don't require NIM and benefit from deterministic performance and fault isolation.

The practical design guidance: run a time-sliced vGPU cluster for NIM inference workloads and a MIG-configured cluster for isolated training and fine-tuning — or use the Time-Sliced MIG-Backed hybrid mode on ESXi 9 Update 1 to stack both patterns within a single cluster.

Looking forward: support for NVIDIA HGX B200 Blackwell systems is expected in a future VCF release, along with NVIDIA ConnectX-7 NICs and BlueField-3 400G DPUs with DirectPath I/O for GPUDirect RDMA and GPUDirect Storage support.

## 10 — Licensing Landscape

**What's Now in VCF 9.0 Subscriptions**

VMware Private AI Services became a standard part of VCF 9.0. Customers are entitled to GPU Monitoring, Model Store, Model Runtime, Agent Builder, Vector Database, and Data Indexing with a VCF subscription starting in Broadcom's first fiscal quarter of 2026 (beginning November 2025). Enterprises already paying for VCF receive a functional on-premises AI platform at no incremental software cost for the orchestration layer.

**What Still Requires a Separate NVIDIA License**

The vGPU driver stack does not come with VCF. A separate NVIDIA AI Enterprise license is still required for the host driver VIB file for ESX hosts, the guest OS drivers, and for downloading AI container images from the NVIDIA NGC catalog — including NIM microservices and NeMo frameworks. This is a two-SKU procurement, not one.

**Procurement Summary**

- *Included in VCF 9.0 subscription:* Private AI Services (Model Store, Model Runtime, Agent Builder, Vector DB, Data Indexing), VKS GPU integration, GPU Operations metrics
- *Separate NVIDIA AI Enterprise license required:* vGPU host driver VIBs, guest OS drivers, NGC catalog access, NIM microservices entitlement, NeMo, TensorRT

## 11 — NVIDIA AI Enterprise GPU Reference

Not all NVIDIA data center GPUs support MIG — and some GPUs in common enterprise deployments will never support it.

**MIG-Capable (Blackwell):** RTX PRO 6000 Server, RTX PRO 4500 Server

**MIG-Capable (Ada Lovelace):** L40S, L40, L20, L4, L2, RTX 6000 Ada, RTX 5880 Ada, RTX 5000 Ada

**MIG-Capable (Hopper / HGX):** H200 SXM5, H100 SXM5, H100 PCIe

**MIG-Capable (Ampere):** A100 SXM4 80GB, A100 PCIe 80GB/40GB, A40, A30, A16, A10, A2

**Time-Slicing Only — No MIG (Turing & Volta):** T4, V100 SXM2, V100 PCIe

> **Installed Base Alert:** T4 and V100 GPUs are common in 3–5 year old on-premises deployments. These GPUs will never support MIG, regardless of ESXi version. If your private AI architecture requires MIG for multi-tenant isolation, a GPU hardware refresh to Ampere or newer is a prerequisite — not just an optimization.

## 12 — Observability: VCF Operations vs BCM vs Run:ai

Each platform sees the GPU infrastructure from a fundamentally different vantage point.

**VCF Operations 9.0** sees the GPU infrastructure from the hypervisor layer. It provides cluster-wide DirectPath Profile Pool capacity views, GPU utilization per VM, frame buffer usage, and vGPU profile allocation. One important constraint: NVIDIA DCGM is not supported inside vGPU guest VMs or on hosts running the NVIDIA AI Enterprise vGPU Manager. SM utilization, memory bandwidth, tensor core activity, and per-process GPU metrics are not accessible via standard DCGM-based tooling in a vGPU deployment.

**NVIDIA Base Command Manager** operates at the cluster and job scheduling layer with full DCGM visibility — SM utilization, memory bandwidth, tensor core activity, NVLink throughput, and per-job attribution. Now available free with optional enterprise support. Trade-off: BCM has no VMware awareness. It doesn't understand vSphere HA, vMotion, DRS, or cluster lifecycle events.

**Run:ai on VCF** adds workload-aware scheduling intelligence that neither VCF Operations nor BCM provides in a vSphere context. It deploys via VKS clusters with GPU Operator, exposes NVIDIA DCGM profiling metrics enriched with workload-level attribution, and includes gang scheduling for distributed training, preemption policies, fair-share scheduling between teams, and per-namespace GPU quotas.

| Capability | VCF Operations 9.0 | Base Command Manager | Run:ai on VCF |
|---|---|---|---|
| vSphere HA/DRS integration | Native | None | Partial |
| MIG capacity planning | DPP view | Full | Full |
| SM / Tensor Core metrics (vGPU env) | Limited | Full (bare metal) | With DCGM |
| Per-job GPU attribution | No | Job level | Per-pod/workload |
| Multi-tenant quota enforcement | No | Slurm integration | Native |
| Gang scheduling for training | No | Slurm integration | Native |
| vMotion GPU stun visibility | Yes | No | No |
| Deployment model | Included in VCF | Free + support | Licensed overlay |

The practical recommendation: VCF Operations alone is not sufficient for production AI infrastructure observability. Plan for Run:ai or a DCGM-integrated observability stack alongside VCF Operations — covering the infrastructure layer with VCF and the workload layer with an overlay.

## 13 — VKS + Private AI vs BCM + Run:ai: An Honest Take

Both paths are legitimate — but they serve fundamentally different organizational realities, and choosing the wrong one creates friction that compounds over time.

**The Case For VKS + Private AI Services**

The enterprise that should choose VMware Private AI Services with VKS is the one where the AI infrastructure team and the platform infrastructure team are the same people, or are deeply accountable to each other. For organizations that don't have a dedicated GPU cluster operations team — a VMware platform team that now has AI workloads pushed onto them — the question isn't "which tool gives data scientists the best GPU scheduling experience?" It's "which tool doesn't require my vSphere admin to learn an entirely new operational paradigm?"

VKS with Private AI Services answers that question. SDDC Manager, vCenter, VCF Operations, Lifecycle Manager — the same workflows already in use for non-AI workloads extend to the GPU cluster. There is no second operational silo. Private AI Services also now bundle with VCF 9.0 subscriptions, making the orchestration layer a $0 incremental cost for existing VCF customers.

Mixed workloads are an underappreciated advantage. Most enterprise private clouds aren't dedicated AI clusters — they run business applications alongside LLM workloads. VKS on VCF treats the GPU cluster as a citizen of the broader private cloud with the same NSX networking, vSAN storage policies, and DRS cluster. Run:ai doesn't know your broader application landscape exists.

**The Case For BCM + Run:ai**

The enterprise that should choose BCM and Run:ai is one where the AI team is a distinct, sophisticated organization — data scientists, MLOps engineers, and an AI platform team accustomed to Slurm, DCGM dashboards, gang scheduling policies, and GPU quota management. These users will find VCF's GPU scheduling capabilities immature today. GPU Reservations in tech preview, no fully automated DRS for GPU clusters, no native gang scheduling — the maturity gap is real.

If training workloads dominate over inference, BCM and Run:ai on bare metal or with DirectPath I/O are meaningfully better. VCF Private AI is architecturally oriented toward inference and model serving. For large-scale multi-node distributed training requiring gang scheduling across dozens of GPUs with NVLink topology awareness and preemption queuing, VCF's DRS model was not designed for this.

And if maximum-throughput training efficiency is the primary objective, vGPU adds overhead. For workloads where you're measuring ROI in H100-hours, that overhead has a real cost.

> Most enterprises will start with VCF because that's where their existing investment and operational muscle is, and they'll add Run:ai on top of VKS when their AI workloads mature enough to demand it. That's probably the honest answer to where many enterprises land: VCF as the platform substrate, with Run:ai layered on when the AI team grows sophisticated enough to require it. The most pragmatic answer isn't either/or — it's sequenced adoption.

## 14 — Decision Framework

Work through these questions in order — each answer gates the next.

**Step 1 — What generation is your GPU hardware?**

If you have T4 or V100 GPUs, your mode choice is made: time-slicing only. No amount of ESXi upgrading changes this. If MIG isolation is architecturally required, a hardware refresh to Ampere or newer is a prerequisite.

**Step 2 — Do your workloads require NVLink peer-to-peer GPU communication?**

If yes — large model training, multi-GPU inference, any workload that explicitly spans multiple physical GPUs via NVLink — you must use time-sliced vGPU with full-frame-buffer profiles. MIG disables NVLink P2P without exception. This is the first question to ask when designing for HGX-class systems.

**Step 3 — Is NVIDIA NIM your primary inference runtime?**

If yes, your NIM cluster must be on time-sliced GPUs. MIG is not compatible with NIM as of VCF 9.0. If you have separate training or fine-tuning workloads that don't use NIM, those can be MIG-configured independently.

**Step 4 — Do you have strict multi-tenant isolation requirements?**

If you're running workloads from different business units, regulatory domains, or security classifications on shared infrastructure, MIG's hardware isolation is the right answer. Time-slicing's shared execution context does not provide the data boundary guarantees regulated industries require between tenants.

**Step 5 — Are you on ESXi 9 Update 1?**

If yes, and you answered yes to both Step 3 and Step 4, the Time-Sliced MIG-Backed hybrid mode is available to you. You can partition a GPU with MIG for inter-tenant isolation and run NIM-compatible time-sliced workloads on a separate partition of the same GPU.

| Workload Profile | Recommended Mode | Key Reason |
|---|---|---|
| NIM-based LLM inference (RAG, chatbot) | Time-Slicing | NIM incompatible with MIG |
| Multi-GPU distributed training (NVLink required) | Time-Slicing (full frame buffer) | NVLink P2P requires full FB |
| Multi-tenant production inference (isolated) | MIG-Backed vGPU | Hardware isolation, fault containment |
| Isolated fine-tuning / NeMo customization | MIG-Backed vGPU | Deterministic performance |
| Mixed team sharing + compliance isolation | Time-Sliced MIG-Backed (ESXi 9.1+) | Hardware boundary between groups |
| Developer environments, CI/CD, light inference | Time-Slicing | Density, flexibility, bursty workloads |
| HGX scale-up, maximum training throughput | Consider bare metal + Run:ai | NVSwitch constraints, vGPU overhead |

The GPU mode decision in vSphere is no longer a driver configuration detail. It determines which workloads you can run, which hardware capabilities you can access, which licensing model applies, and how effectively your platform team can operate the environment day-to-day. ESXi 9 and 9 Update 1 have meaningfully expanded the design space — the Time-Sliced MIG-Backed hybrid mode in particular opens architectural patterns that weren't possible before — but the underlying constraints around NVLink, NIM compatibility, and DRS automation maturity remain relevant design inputs that need to be on the whiteboard early.

---

*VMware, vSphere, VCF, and related marks are trademarks of Broadcom Inc. NVIDIA, H100, H200, MIG, NVLink, NVSwitch, AI Enterprise, and related marks are trademarks of NVIDIA Corporation. All product capabilities described reflect publicly available documentation current as of April 2026. Verify against vendor documentation for production planning.*
