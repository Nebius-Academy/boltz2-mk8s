# Boltz-2 Inference on Nebius MK8s with GPU and Shared Filesystem

This repository contains scripts and Kubernetes manifests for running **[Boltz-2](https://github.com/deepmind/boltz)** — an open-source biomolecular foundation model — on **Nebius AI Cloud** using a GPU-enabled Kubernetes (MK8s) cluster and a shared filesystem.

Boltz-2 predicts both **3D protein–ligand complex structures** and **binding affinities**, enabling fast *in silico* screening for drug discovery.

---

## Features
- Automated setup of a Nebius MK8s cluster with GPU nodes.
- Shared filesystem (PVC) for storing input and output data.
- Batch inference with parallel GPU jobs.
- Scripts for uploading input data and downloading results from PVC.
