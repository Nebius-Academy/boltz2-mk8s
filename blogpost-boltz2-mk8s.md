# Running Boltz-2 inference at scale in Nebius AI Cloud

## Abstract

Boltz-2 is an open-source biomolecular foundation model that predicts protein–ligand 3D structures and binding affinities with near-FEP accuracy while running orders of magnitude faster. This article shows how Nebius AI Cloud – using Managed Kubernetes, GPU node group, and shared filesystem – provides a practical, reproducible blueprint for running Boltz-2 from single-GPU experiments to scalable multi-node screening pipelines.

## Introduction

Accurately modeling biomolecular interactions is one of the central challenges in biology and drug discovery. Proteins, nucleic acids and small molecules form complex, often dynamic assemblies whose structural details determine biological function and therapeutic effect. Among these properties, binding affinity – the strength of interaction between a small molecule and its protein target – is a primary determinant of a compound’s potency and a crucial filter in hit discovery and lead optimization.

*In-silico* prediction of binding affinity remains difficult despite its importance in drug design. Atomistic approaches like free-energy perturbation (FEP) can near experimental accuracy, but their heavy compute demands and requirement for expert handling make them unsuitable for high-throughput screening. Faster heuristics such as molecular docking trade speed for precision and frequently lack the ranking power required for confident decision making. 

[Boltz-2](https://www.biorxiv.org/content/10.1101/2025.06.14.659707v1) is a structural-biology foundation model that combines high-quality structure prediction and affinity estimation. It uses a co-folding trunk for protein–ligand complex prediction, a dedicated affinity module (PairFormer + prediction heads), and controllability features – e.g., conditioning on experimental method (X-ray / NMR / MD), pocket/distance steering, and multimeric templates – to improve robustness. These advances let Boltz-2 produce structure and affinity outputs that align well with experiments while running orders of magnitude faster than FEP, enabling high-throughput ranking and screening of hundreds of thousands of compounds per day on parallel high-performance computing.

Boltz-2 already works in real pipelines: retrospective and prospective tests show it helps hit-to-lead optimization, large-scale hit discovery, and generative design loops that are later validated with targeted FEP. It produces experimentally relevant hypotheses at scales that were previously impractical for physics-based methods. However, model advances alone don’t solve the engineering problems of production inference. At scale, Boltz-2 depends on large, low-latency datasets – ligand libraries, the Chemical Component Dictionary (CCD), MSA caches, and the like – so you need solid operational patterns: efficient data locality and caching, parallel job orchestration with GPU-aware scheduling, fault tolerance and reproducibility for long runs, and cost-aware lifecycle management to avoid idle expensive resources.

Drawing on the companion [tutorial](https://github.com/dashabalashova/boltz2-mk8s/blob/main/tutorial.md) (which contains tested, runnable commands and manifests), this article focuses on the infrastructure and workflow patterns required to run Boltz-2 reliably at scale on Nebius AI Cloud. Specifically, we cover: cluster orchestration and job scheduling; [Managed Service for Kubernetes®](https://nebius.com/services/managed-kubernetes) to reduce operational burden; GPU node groups sized for Boltz-2’s memory and throughput; and a shared filesystem for centralized model caches, ligand libraries, and outputs. The remainder of the article translates Boltz-2’s scientific requirements into a concrete operational blueprint you can reuse for both exploratory experiments and production-grade screening pipelines.

---

## Resource requirements and scaling

Boltz-2 has about 1 billion trainable parameters. In addition to the model weights, it requires a large cache (ligand libraries and Canonical Components Dictionary).  

Running inference needs GPUs with high memory capacity. For this benchmark we use [NVIDIA L40S](https://www.nvidia.com/en-us/data-center/l40s/) cards with 48GB VRAM: ~11 GB for structure prediction and ~7–8 GB for affinity prediction. That leaves spare capacity for batching and multiple concurrent jobs.

Assuming ~40–60 seconds per protein–ligand prediction, 16 GPUs running in parallel would yield on the order of 1,000 predictions per hour (≈960–1,440 depending on per-prediction runtime). This is why we run Boltz-2 on a multi-node Kubernetes cluster instead of a single GPU VM. For small workloads (just a few molecules), a standalone GPU VM or Jupyter session is sufficient. At scale, however, Kubernetes orchestration and shared storage become essential.

---

## Managed Service for Kubernetes®

Kubernetes is the backbone of distributed AI in Nebius AI Cloud. It ensures that all components – compute nodes, storage volumes, and jobs – are orchestrated automatically.  

For Boltz-2 inference, Kubernetes handles:

- Job scheduling – distributing protein–ligand tasks evenly across GPUs  
- Resilience – if a pod fails, it is automatically restarted  
- Parallelism – hundreds of inference jobs can run concurrently  
- Resource management – GPU, CPU, and RAM allocations are tracked cluster-wide  

Without orchestration, researchers would need to manually launch and monitor hundreds of jobs. Kubernetes makes large-scale biomolecular inference manageable and predictable.

Nebius provides Managed Service for Kubernetes® – a fully managed control plane that takes away the operational overhead of setting up, patching, and scaling clusters.  

Why it matters for Boltz-2:  
- No need to manually install GPU drivers – they come preconfigured  
- Node groups can be created with one command and scaled up or down depending on workload  
- Security and IAM are integrated with the cloud platform  

This allows research teams to focus on drug discovery experiments rather than infrastructure plumbing.

---

## Infrastructure and workflow

This section describes the compute and data platform required to run Boltz-2 at scale on Nebius AI Cloud, and the repeatable workflow for packaging, launching, and cleaning up inference runs. For tested, runnable commands and Kubernetes manifests see the companion [tutorial](https://github.com/dashabalashova/boltz2-mk8s/blob/main/tutorial.md).

### GPU node groups with NVIDIA L40S

Inference runs on GPU node groups – collections of worker nodes equipped with NVIDIA L40S GPUs. Each node in our configuration has:  
- 2× L40S GPUs  
- 64 vCPUs  
- 384 GB RAM  
- 64 GB fast SSD boot disk  

These specifications ensure that the model and its cache fit comfortably, while leaving room for parallel batches. GPU node groups are billed only while active, so it’s recommended to delete them after finishing jobs.

### Shared filesystem for large datasets

A critical enabler is the shared filesystem, mounted across all nodes. Boltz-2 requires:  
- Ligand libraries  
- Canonical Components Dictionary  
- Multiple sequence alignments (MSAs)  
- Input YAML batch files  

With a shared filesystem:  
- All nodes can read from the same dataset without duplicating it locally  
- Prediction results are written back to a common location  
- Workflows remain synchronized, even across dozens of nodes  

In Nebius AI Cloud this is implemented with a network SSD filesystem, attached through the CSI driver and exposed to Kubernetes as a PersistentVolumeClaim (PVC).

### Workflow overview

Running Boltz-2 on Nebius follows a simple, repeatable workflow:
1. Set up the environment – install CLI tools to manage cloud resources.
2. Package the model runner – build a container image with Boltz-2 code and dependencies, push it to Nebius Container Registry.
3. Create Kubernetes cluster with GPU nodes – launch a Managed Kubernetes cluster with a GPU node group. Attach a shared filesystem.
4. Upload input data – place YAML job batches and MSAs into the shared PVC.
5. Pre-load model cache – pre-download ligand libraries and CCD data into the shared filesystem.
6. Run inference jobs – launch multiple parallel jobs via Kubernetes, each processing a batch of inputs.
7. Collect results – gather predictions (structures and affinities) from the shared filesystem.
8. Clean up resources – delete GPU node groups, PVCs, and registries to stop billing.

---

## Conclusion

Boltz-2 makes high-throughput, experimentally relevant *in silico* drug screening practical when paired with the right platform and operational patterns. Using Managed Kubernetes to orchestrate GPU node groups and a shared filesystem for centralized model caches and ligand libraries provides a reliable, scalable, and cost-aware foundation. The workflow we present is reproducible and directly applicable to both exploratory experiments and production-grade screening pipelines.
