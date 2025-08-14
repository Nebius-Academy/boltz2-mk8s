# Guide: Boltz-2 Inference on Nebius MK8s with GPU and Shared Filesystem

**Boltz-2** is an open-source biomolecular foundation model for predicting both complex 3D structures and binding affinities. It enables accurate and fast *in silico* screening for drug discovery, matching the accuracy of physics-based free-energy perturbation (FEP) methods while running up to 1000x faster.

This guide explains how to set up a [Kubernetes](https://kubernetes.io/) cluster with a GPU and a shared filesystem on Nebius, and run **Boltz-2** inference.

The typical inference time is about **40–60 seconds per protein–ligand pair**, which means that with parallel execution on multiple GPUs, large batches of predictions can be completed in minutes. For example, with **16 parallel GPU tasks**, you can process around **1,000 pairs per hour**.

---

## 1. Prepare your environment

### Install the CLIs and tools

In this guide, you will run commands in your terminal to create and manage **Nebius AI Cloud** resources.  
First, install the required CLIs and tools using the copy-and-paste commands provided in the following steps.

<details>
<summary>Ubuntu (x86-64)</summary>

```bash
sudo apt-get install jq
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
nebius profile create
```
</details> 

<details>
<summary>Ubuntu (ARM64)</summary>

```bash
sudo apt-get install jq
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
nebius profile create
```
</details>

<details>
<summary>macOS (Apple silicon)</summary>

```bash
brew install jq
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
brew install helm
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
nebius profile create
```
</details>

<details>
<summary>macOS (Intel)</summary>

```bash
brew install jq
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
brew install helm
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
nebius profile create
```
</details>

<br>

These commands will install the following tools:

- **[`kubectl`](https://kubernetes.io/docs/tasks/tools/#kubectl)** — the Kubernetes command-line interface.
- **[`jq`](https://jqlang.org/download/)** — a lightweight JSON processor, used here to parse JSON output from the Nebius AI Cloud CLI and extract resource IDs for other commands.
- **[`helm`](https://helm.sh/docs/intro/install/)** — a package manager for Kubernetes that simplifies deployment and management of applications by packaging them into reusable charts.
- **[Nebius AI Cloud CLI](https://docs.nebius.com/cli/quickstart)** — the command-line interface for managing all Nebius AI Cloud resources.

The last command, `nebius profile create`, opens the Nebius AI Cloud web console sign-in screen in your browser. Sign in to complete the initialization.

Run the following commands to verify that all required tools are installed correctly:

```bash
kubectl version --client
helm version
nebius --version
```

After that, save your project ID in the CLI configuration:

1. Copy your **Project ID** from the [Project settings](https://console.nebius.com/settings/) page in the web console.
2. Run the following command, replacing `<project_ID>` with your actual project ID:
```bash
nebius config set parent-id <project_ID>
```

> **Note:** In the [Project settings](https://console.nebius.com/settings/) page, you can also create new projects. Click the project name in the top navigation bar, select **Create project**, set a name and parameters, and save. Each project will have its own unique **Project ID**.

---

## 2. Create a cluster and set up a PersistentVolumeClaim

In Kubernetes, a **PersistentVolumeClaim** (PVC) is a request for persistent storage.  
It allows pods to share and retain data independently of their lifecycle.

In this tutorial, the PVC named `boltz-fs-pvc` serves as a shared filesystem for all **Boltz-2** jobs, storing both the **input data** (YAMLs, MSAs) and the **prediction results**.

### Set up variables for cluster configuration

```bash
FS_NAME="boltz-fs"
CLUSTER_NAME="boltz-cluster"
NODE_GROUP_NAME="boltz-nodegroup"
NODE_USERNAME="user"
```

### Get the default subnet ID

The cluster’s control plane and nodes will use IP addresses from the default subnet.

```bash
export NB_SUBNET_ID=$(nebius vpc subnet list --format json | jq -r '.items[0].metadata.id')
```

### Create a network SSD filesystem

**Parameters:**
- `--size-gibibytes 32` — total storage capacity of the shared filesystem (**32 GiB**).
- `--block-size-bytes 4096` — block size (**4 KiB**), a common default for general-purpose workloads.

```bash
export NB_FS_ID=$(nebius compute filesystem create \
  --name "$FS_NAME" \
  --size-gibibytes 32 \
  --type network_ssd \
  --block-size-bytes 4096 \
  --format json | jq -r ".metadata.id")
```

### Create a cluster

```bash
export NB_CLUSTER_ID=$(nebius mk8s cluster create \
  --name "$CLUSTER_NAME" \
  --control-plane-subnet-id "$NB_SUBNET_ID" \
  '{"spec": { "control_plane": { "endpoints": {"public_endpoint": {}}}}}' \
  --format json | jq -r '.metadata.id')
```

### Generate a kubeconfig for kubectl

This command downloads and configures the **kubeconfig** file so that `kubectl` can connect to your newly created cluster. The `--external` flag ensures that the public control plane endpoint is used, and `--force` overwrites any existing configuration for this cluster.

```bash
nebius mk8s cluster get-credentials --id "$NB_CLUSTER_ID" --external --force
```

### Create a user with SSH access and auto-mount the shared filesystem

First, ensure you have an SSH public key.  
If you already have `~/.ssh/id_ed25519.pub`, you can skip this step.  
If not, generate one with:

```bash
ssh-keygen -t ed25519 -C <your_email@example.com>
```

Next, define the **cloud-init** configuration:

```bash
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
CLOUD_INIT=$(cat <<EOF
users:
  - name: $NODE_USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $SSH_KEY
runcmd:
  - mkdir -p /mnt/data
  - mount -t virtiofs csi-storage /mnt/data
  - echo "csi-storage /mnt/data virtiofs defaults,nofail 0 2" >> /etc/fstab
EOF
)
```

**Notes:**
- **`csi-storage`** — the mount tag assigned when the Nebius filesystem was created, it specifies which shared filesystem to mount
- **`virtiofs`** — the filesystem type used for high-performance, low-latency sharing between the node and network storage
- the `/etc/fstab` entry ensures that the filesystem is automatically re-mounted if the node restarts

### Create a node group and add it to the cluster

```bash
nebius mk8s node-group create \
  --name "$NODE_GROUP_NAME" \
  --parent-id "$NB_CLUSTER_ID" \
  --fixed-node-count 2 \
  --template-filesystems "[{\"attach_mode\": \"READ_WRITE\", \"mount_tag\": \"csi-storage\", \"existing_filesystem\": {\"id\": \"$NB_FS_ID\"}}]" \
  --template-cloud-init-user-data "$CLOUD_INIT" \
  --template-resources-platform "gpu-l40s-d" \
  --template-resources-preset "2gpu-64vcpu-384gb" \
  --template-boot-disk-type network_ssd \
  --template-boot-disk-size-bytes 68719476736 \
  --template-network-interfaces "[{\"public_ip_address\": {}, \"subnet_id\": \"$NB_SUBNET_ID\"}]" \
  --template-gpu-settings-drivers-preset cuda12
```

**What this does:**
- creates a **GPU node group** with exactly two nodes (`--fixed-node-count 2`)
- attaches the **shared filesystem** created earlier (`mount_tag: csi-storage`)
- configures nodes using the **`CLOUD_INIT`** script
- uses the **`gpu-l40s-d`** platform with:
  - 2x **NVIDIA L40S** GPUs  
  - 64 vCPUs  
  - 384 GB RAM
- preconfigures **CUDA 12** GPU drivers (`--template-gpu-settings-drivers-preset cuda12`)
- boots from a **network SSD** with a **64 GiB** disk size

### Install the CSI driver

This installs the `csi-mounted-fs-path` driver, which allows Kubernetes to mount the shared filesystem into pods.

```bash
helm pull oci://cr.eu-north1.nebius.cloud/mk8s/helm/csi-mounted-fs-path --version 0.1.3
helm upgrade csi-mounted-fs-path ./csi-mounted-fs-path-0.1.3.tgz --install --set dataDir="/mnt/data/csi-mounted-fs-path-data/"
```

### Create a PersistentVolumeClaim

Create a `PersistentVolumeClaim` named `boltz-fs-pvc` that requests **32 GiB** of shared storage using the `csi-mounted-fs-path-sc` StorageClass. This PVC will be used as a shared filesystem between **Boltz-2** jobs.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: boltz-fs-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 32Gi
  storageClassName: csi-mounted-fs-path-sc
EOF
```

**Notes:**
- `storageClassName: csi-mounted-fs-path-sc` — instructs Kubernetes to use the CSI driver installed in step 8 (`csi-mounted-fs-path`)
- this driver is configured to mount the shared filesystem created earlier

### Check the status

Run the following commands to verify that your cluster nodes and the PersistentVolumeClaim are ready:

```bash
kubectl get nodes
kubectl get pvc
```

---

## 3. Upload input data to the PVC

All input files for **Boltz-2** are stored in the `data/` directory on your local machine. This directory contains **16 subdirectories** (`yamls_001` ... `yamls_016`) with prediction input YAML files, and one `msa/` directory with multiple sequence alignments:

```
data/
├── yamls_001/
├── yamls_002/
├── ...
├── yamls_016/
└── msa/
```

The `scripts/upload_data_to_pvc.sh` script uploads the contents of your local `data/` directory to the PVC `boltz-fs-pvc`.

```bash
chmod +x scripts/upload_data_to_pvc.sh
scripts/upload_data_to_pvc.sh
```

---

## 4. Pre-pull the Boltz runner image and download the model cache

This step:

1. Runs the **Boltz** image pre-pull DaemonSet on all nodes.
2. Runs the **model cache download** job to populate the PVC.
3. Waits for both to complete.
4. Deletes the temporary resources.

```bash
kubectl apply -f scripts/boltz-pre-pulling-job.yaml & PID1=$!

kubectl apply -f scripts/boltz-cache-download-job.yaml & PID2=$!

wait $PID1
kubectl rollout status daemonset/boltz-pre-pulling --timeout=30m \
|| { echo "❌ boltz-pre-pulling failed"; exit 1; }
kubectl delete -f scripts/boltz-pre-pulling-job.yaml

wait $PID2
kubectl wait --for=condition=complete job/boltz-cache-download --timeout=30m \
|| { echo "❌ boltz-cache-download failed"; exit 1; }
kubectl delete job boltz-cache-download
```

> **Note:** `PID1` and `PID2` store the process IDs of the background tasks (`boltz-pre-pulling-job.yaml` and `boltz-cache-download-job.yaml`). This allows them to run in parallel and ensures the script waits for each to complete before proceeding.

---

## 5. Run batch predictions

The file `scripts/boltz-multi-job.yaml` defines a Kubernetes **indexed job** that runs **16 parallel Boltz prediction tasks** (`yamls_001`–`yamls_016`) on GPUs.  
Each batch corresponds to one of the `yamls_XXX` directories, and Kubernetes automatically schedules them across the available GPU nodes. For each batch, a separate **pod** is created, which reads the input YAMLs from the PVC `boltz-fs-pvc` and writes the prediction results back to the same PVC.

```bash
kubectl apply -f scripts/boltz-multi-job.yaml
```

To check the status of the batch prediction pods, run:

```bash
kubectl get jobs
kubectl get pods
```

---

## 6. Download results and delete nodes

The `scripts/download_results_from_pvc.sh` script:

1. Creates a temporary pod with the `boltz-fs-pvc` PVC mounted.
2. Archives the `results` directory from the PVC.
3. Copies the archive to the local machine.
4. Extracts it into a local directory.
5. Deletes the temporary pod.

Before downloading the results, the script waits for the **indexed Kubernetes job** `boltz-runner` to finish all 16 parallel tasks. The following command counts how many pods have completed successfully to confirm the run:

```bash
echo "⏳ Waiting for boltz-runner job to complete..."
kubectl wait --for=condition=complete job/boltz-runner --timeout=-1s
completed=$(kubectl get pods -l job-name=boltz-runner --no-headers | grep 'Completed' | wc -l)
echo "✅ $completed/16 pods completed."

chmod +x scripts/download_results_from_pvc.sh
scripts/download_results_from_pvc.sh

kubectl delete job boltz-runner --ignore-not-found
export NB_NODE_GROUP_ID=$(nebius mk8s node-group get-by-name \
  --parent-id $NB_CLUSTER_ID \
  --name "$NODE_GROUP_NAME" \
  --format json | jq -r '.metadata.id')
helm uninstall csi-mounted-fs-path
nebius mk8s node-group delete --id $NB_NODE_GROUP_ID
```

---

## 7. Clean up (optional)

Use the following commands to remove all remaining resources created in this guide.  
> **Warning:** This will permanently delete the PVC, the shared filesystem, and the Kubernetes cluster. Before deleting resources, make sure all results are downloaded.

```bash
kubectl delete pvc boltz-fs-pvc
nebius compute filesystem delete --id "$NB_FS_ID"
nebius mk8s cluster delete --id "$NB_CLUSTER_ID"
```
