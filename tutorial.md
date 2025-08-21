# Guide: Boltz-2 inference on Managed Service for Kubernetes® cluster with shared filesystem

[Boltz-2](https://github.com/jwohlwend/boltz) is an open-source biomolecular foundation model for predicting both complex 3D structures and binding affinities. It enables accurate and fast *in silico* screening for drug discovery, matching the accuracy of physics-based free-energy perturbation (FEP) methods while running up to 1000x faster.

This guide explains how to set up a Managed Service for a [Kubernetes](https://kubernetes.io/) cluster and a shared filesystem in Nebius AI Cloud, and run Boltz-2 inference.

**Resource requirements, scaling and cost**

Boltz-2 is a large biomolecular foundation model with about 1 billion trainable parameters. In addition to the weights, it requires a substantial model cache (ligand libraries, Canonical Components Dictionary data). Running inference requires powerful GPUs with high memory capacity: in this guide, we use NVIDIA L40S GPUs with 48 GB of VRAM, which provide both sufficient capacity and high throughput. In practice, GPU memory usage is moderate compared to the total card size: structure prediction requires ~11 GB and affinity prediction ~7-8 GB, leaving spare capacity on the L40S for batching, parallel jobs, and stable large-scale runs.

The typical Boltz-2 inference time is 40-60 seconds per protein–ligand pair. With multiple GPUs, throughput scales almost linearly: for example, 16 parallel tasks yield ~1,000 pairs per hour. This is why the guide provisions a multi-node GPU cluster rather than a single GPU. For small workloads (a few molecules), a single GPU VM is sufficient, and inference can be run directly from Jupyter or the command line. Kubernetes becomes useful at scale — hundreds or thousands of pairs — where parallel execution and shared storage simplify management.

GPU nodes incur costs as soon as they are created and running, and charges stop only after the node group is deleted. Storage (filesystems, PVCs) and container registries also accumulate charges while they exist. Be sure to delete all resources (see [Clean up](#8-clean-up-optional)) when finished to avoid unnecessary costs.

**General note on applicability**

This guide is written for Boltz-2, but the majority of the workflow is actually model-agnostic and can be reused for other machine learning models running on Kubernetes. Steps such as setting up the environment and installing CLI tools, creating a GPU-enabled Kubernetes cluster with a shared filesystem, uploading data to the PVC, pre-pulling container images, launching inference jobs in parallel, collecting results, and cleaning up cloud resources are all universal.

What is specific to Boltz-2 are the details of the Dockerfile and runner image (since they depend on the Boltz-2 codebase and dependencies), the input data (YAML batches and MSA files), the model cache (Canonical Components Dictionary and ligand libraries), and the particular Kubernetes job YAMLs provided in the repository.

For any other model, you would keep the same general structure of the workflow, but adapt these model-specific pieces: the container build, the input and output data format, how weights or caches are downloaded, and the exact resource requirements.

**Reference** 
```
@article{Passaro2025.06.14.659707,
    title = {Boltz-2: Towards Accurate and Efficient Binding Affinity Prediction},
    author = {Passaro, Saro and Corso, Gabriele and Wohlwend, Jeremy and Reveiz, Mateo and Thaler, Stephan and Somnath, Vignesh Ram and Getz, Noah and Portnoi, Tally and Roy, Julien and Stark, Hannes and Kwabi-Addo, David and Beaini, Dominique and Jaakkola, Tommi and Barzilay, Regina},
	title = {Boltz-2: Towards Accurate and Efficient Binding Affinity Prediction},
    year = {2025},
    doi = {10.1101/2025.06.14.659707},
    journal = {bioRxiv}
}
```

---

## 1. Prepare your environment

In this section, you will install and configure all the necessary command-line tools to manage Nebius AI Cloud resources and the Kubernetes cluster from your local environment.

### Install command line interfaces and tools

Install the required command line interfaces (CLIs) and tools using the copy-and-paste commands provided in the following steps:

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

- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) — the Kubernetes command-line interface.
- [jq](https://jqlang.org/download/) — a lightweight JSON processor, used here to parse JSON output from the Nebius AI Cloud CLI and extract resource IDs for other commands.
- [helm](https://helm.sh/docs/intro/install/) — a package manager for Kubernetes that simplifies deployment and management of applications by packaging them into reusable charts.
- [Nebius AI Cloud CLI](https://docs.nebius.com/cli/quickstart) — the command-line interface for managing all Nebius AI Cloud resources.

The last command, `nebius profile create`, opens the Nebius AI Cloud web console sign-in screen in your browser. Sign in to complete the initialization.

Run the following commands to verify that all the required CLIs and tools are installed correctly:

```bash
kubectl version --client
jq --version
helm version
nebius version
```

After that, save your project ID in the CLI configuration:

1. Copy your project ID from the [Project settings](https://console.nebius.com/settings/) page in the web console.
2. Run the following command, replacing `<PROJECT_ID>` with your actual project ID:
```bash
nebius config set parent-id <PROJECT_ID>
```

Note: in the [Project settings](https://console.nebius.com/settings/) page, you can also create new projects. Click the project name in the top navigation bar, select **Create project**, set a name and parameters, and save. Each project will have its own unique project ID.

---

## 2. Build and push Boltz-2 runner image

In this section, you will package a Boltz-2 runner code into a Docker image, upload it to the Container Registry, and make it available for deployment in Kubernetes.

Run the following command from the project root to build the Docker image defined in `docker/Dockerfile`:

```bash
sudo docker build -t boltz-runner -f docker/Dockerfile .
```

Set the Region from the [Project settings](https://console.nebius.com/settings/) page into `<REGION_ID>`. Then create a new registry, tag `boltz-runner` Docker image with the correct registry path, and push it.

```bash
export REGION_ID=<REGION_ID>
export NB_REGISTRY_PATH=$(nebius registry create \
  --name boltz-registry \
  --format json | jq -r ".metadata.id" | cut -d- -f 2)
docker tag boltz-runner:latest \
  cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:latest
docker push cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:latest
```

---

## 3. Create cluster and set up PersistentVolumeClaim

In this section, you will create a GPU-enabled Kubernetes cluster and set up a shared network filesystem. A PersistentVolumeClaim (PVC) named `boltz-fs-pvc` will provide persistent storage for all Boltz-2 jobs, allowing pods to share and retain both the input data (YAMLs, MSAs) and the prediction results across their lifecycle.

### Set up variables for cluster configuration

```bash
FS_NAME="boltz-fs"
CLUSTER_NAME="boltz-cluster"
NODE_GROUP_NAME="boltz-nodegroup"
SA_NAME="boltz-sa"
NODE_USERNAME="user"
```

### Get default subnet ID

The cluster’s control plane and nodes will use IP addresses from the default subnet.

```bash
export NB_SUBNET_ID=$(nebius vpc subnet list --format json | jq -r '.items[0].metadata.id')
```

### Create network SSD filesystem

**Parameters:**
- `--size-gibibytes 32` — total storage capacity of the shared filesystem (**32 GiB**).
- `--block-size-bytes 4096` — block size (**4 KiB**), a common default for general-purpose workloads.

```bash
export NB_FS_ID=$(nebius compute filesystem create \
  --name $FS_NAME \
  --size-gibibytes 32 \
  --type network_ssd \
  --block-size-bytes 4096 \
  --format json | jq -r ".metadata.id")
```

### Create cluster

```bash
export NB_CLUSTER_ID=$(nebius mk8s cluster create \
  --name $CLUSTER_NAME \
  --control-plane-subnet-id $NB_SUBNET_ID \
  '{"spec": { "control_plane": { "endpoints": {"public_endpoint": {}}}}}' \
  --format json | jq -r '.metadata.id')
```

### Generate kubeconfig for kubectl

This command downloads and configures the kubeconfig file so that `kubectl` can connect to your newly created cluster. The `--external` flag ensures that the public control plane endpoint is used, and `--force` overwrites any existing configuration for this cluster.

```bash
nebius mk8s cluster get-credentials --id $NB_CLUSTER_ID --external --force
```

### Create user with SSH access and auto-mount shared filesystem

First, ensure you have an SSH public key. If you already have `~/.ssh/id_ed25519.pub`, you can skip this step. If not, generate one with:

```bash
ssh-keygen -t ed25519 -C <your_email@example.com>
```

Next, define the `cloud-init` configuration:

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

Notes:
- `csi-storage` — the mount tag assigned when the filesystem was created, it specifies which shared filesystem to mount;
- `virtiofs` — the filesystem type used for high-performance, low-latency sharing between the node and network storage;
- `/etc/fstab` entry ensures that the filesystem is automatically re-mounted if the node restarts.

### Create service account

Create a service account for the node group and grant it editor permissions by adding it to the Editor IAM group.

Copy Editor Group ID from the [IAM](https://console.nebius.com/iam/) page in the web console and replace `<EDITOR_GROUP_ID>` with it to add the service account to that group.

```bash
NB_SA_ID=$(nebius iam service-account create \
  --name $SA_NAME --format json | jq -r '.metadata.id')

nebius iam group-membership create \
  --parent-id <EDITOR_GROUP_ID> \
  --member-id $NB_SA_ID
```

### Create node group and add it to cluster

```bash
nebius mk8s node-group create \
  --name $NODE_GROUP_NAME \
  --parent-id $NB_CLUSTER_ID \
  --fixed-node-count 2 \
  --template-filesystems "[{\"attach_mode\": \"READ_WRITE\", \"mount_tag\": \"csi-storage\", \"existing_filesystem\": {\"id\": \"$NB_FS_ID\"}}]" \
  --template-service-account-id $NB_SA_ID \
  --template-cloud-init-user-data "$CLOUD_INIT" \
  --template-resources-platform "gpu-l40s-d" \
  --template-resources-preset "2gpu-64vcpu-384gb" \
  --template-boot-disk-type network_ssd \
  --template-boot-disk-size-bytes 68719476736 \
  --template-network-interfaces "[{\"public_ip_address\": {}, \"subnet_id\": \"$NB_SUBNET_ID\"}]" \
  --template-gpu-settings-drivers-preset cuda12
```

What it does:
- creates the GPU node group with exactly two nodes (`--fixed-node-count 2`);
- attaches the shared filesystem created earlier (`mount_tag: csi-storage`);
- configures nodes using the `CLOUD_INIT` script;
- uses the `gpu-l40s-d` platform with:
  - 2x NVIDIA L40S GPUs;
  - 64 vCPUs;
  - 384 GB RAM;
- boots from the network SSD with 64 GiB disk size (`--template-boot-disk-size-bytes 68719476736`), this disk stores the OS, Docker images, temporary files, and any data not placed in shared storage;
- preconfigures CUDA 12 GPU drivers (`--template-gpu-settings-drivers-preset cuda12`).

### Install CSI driver

Install the `csi-mounted-fs-path` driver, which allows Kubernetes to mount the shared filesystem into pods.

```bash
helm pull oci://cr.eu-north1.nebius.cloud/mk8s/helm/csi-mounted-fs-path --version 0.1.3
helm upgrade csi-mounted-fs-path ./csi-mounted-fs-path-0.1.3.tgz --install --set dataDir="/mnt/data/csi-mounted-fs-path-data/"
```

### Create PersistentVolumeClaim

Create a PersistentVolumeClaim named `boltz-fs-pvc` that requests 32 GiB of shared storage using the `csi-mounted-fs-path-sc` StorageClass. This PVC will be used as a shared filesystem between Boltz-2 jobs.

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

Notes:
- `storageClassName: csi-mounted-fs-path-sc` instructs Kubernetes to use the CSI driver (`csi-mounted-fs-path`);
- this driver is configured to mount the shared filesystem created earlier.

### Check status

Run the following commands to verify that your cluster nodes and the PVC are ready:

```bash
kubectl get nodes
kubectl get pvc
```

---

## 4. Upload input data to shared filesystem

In this section, you will copy all local Boltz-2 input files (YAMLs and MSAs) into the shared filesystem so they are accessible to all jobs in the cluster. All input files for Boltz-2 are stored in the `data/` directory on your local machine. This directory contains 16 subdirectories (`yamls_001` ... `yamls_016`) with prediction input YAML files, and one `msa/` directory with a multiple sequence alignment:

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

## 5. Pre-pull Boltz-2 runner image and download model cache

In this section, you will prepare all cluster nodes for running Boltz-2 by pre-pulling the Docker image and downloading the model cache into the shared filesystem, ensuring faster job startup.

The code:

1. Runs the Boltz-2 image pre-pull DaemonSet on all nodes.
2. Runs the `boltz-cache-download` job to populate the PVC.
3. Waits for both to complete.
4. Deletes the temporary resources.

```bash
export BOLTZ_IMAGE="cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:latest"
envsubst '${BOLTZ_IMAGE}' < scripts/boltz-pre-pulling-job.yaml | kubectl apply -f - & PID1=$!
kubectl apply -f scripts/boltz-cache-download-job.yaml & PID2=$!

wait $PID1
kubectl rollout status daemonset/boltz-pre-pulling --timeout=30m \
|| { echo "❌ boltz-pre-pulling failed"; exit 1; }
envsubst '${BOLTZ_IMAGE}' < scripts/boltz-pre-pulling-job.yaml | kubectl delete -f -

wait $PID2
kubectl wait --for=condition=complete job/boltz-cache-download --timeout=30m \
|| { echo "❌ boltz-cache-download failed"; exit 1; }
kubectl delete job boltz-cache-download
```

Note: `PID1` and `PID2` store the process IDs of the background tasks (`boltz-pre-pulling-job.yaml` and `boltz-cache-download-job.yaml`). This allows them to run in parallel and ensures the script waits for each to complete before proceeding.

---

## 6. Run predictions

In this section, you will launch multiple GPU-powered Boltz-2 prediction jobs in parallel, each processing a separate batch of input YAMLs from the shared filesystem and saving results back to it.

The file `scripts/boltz-multi-job.yaml` defines a Kubernetes indexed job `boltz-runner` that runs 16 Boltz prediction tasks (`yamls_001`–`yamls_016`) on GPUs. Each batch corresponds to one of the `yamls_XXX` directories, and Kubernetes automatically schedules them across the available GPU nodes. For each batch, a separate pod is created, which reads the input YAMLs from the PVC `boltz-fs-pvc` and writes the prediction results back to the same PVC.

```bash
envsubst '${BOLTZ_IMAGE}' < scripts/boltz-multi-job.yaml | kubectl apply -f -
```

To check the status of the batch prediction pods, run:

```bash
kubectl get jobs
kubectl get pods
```

---

## 7. Download results and delete nodes

In this section, you will wait for all Boltz-2 prediction jobs to finish, download the results from the PVC to your local machine, and then delete the `boltz-runner` job.

The `scripts/download_results_from_pvc.sh` script:

1. Creates a temporary pod with the `boltz-fs-pvc` PVC mounted.
2. Archives the `results` directory from the PVC.
3. Copies the archive to the local machine.
4. Extracts it into a local directory.
5. Deletes the temporary pod.

Before downloading the results, the script waits for the indexed Kubernetes job `boltz-runner` to finish all 16 parallel tasks. The following command waits until completion and counts how many pods finished successfully:

```bash
echo "Waiting for boltz-runner job to complete..."
kubectl wait --for=condition=complete job/boltz-runner --timeout=-1s
completed=$(kubectl get pods -l job-name=boltz-runner --no-headers | grep 'Completed' | wc -l)
echo "✅ $completed/16 pods completed."

chmod +x scripts/download_results_from_pvc.sh
scripts/download_results_from_pvc.sh

kubectl delete job boltz-runner --cascade=foreground
```

---

## 8. Clean up (optional)

In this section, you will delete all Nebius and Kubernetes resources created during the tutorial, including GPU nodes, PVC, shared filesystem, cluster, service account, and container registry.

Use the following commands to remove all remaining resources created in this guide. This will permanently delete the PVC, shared filesystem, and Kubernetes cluster. Before deleting resources, make sure all results are downloaded.

```bash
export NB_NODE_GROUP_ID=$(nebius mk8s node-group get-by-name \
  --parent-id $NB_CLUSTER_ID \
  --name $NODE_GROUP_NAME \
  --format json | jq -r '.metadata.id')
helm uninstall csi-mounted-fs-path
nebius mk8s node-group delete --id $NB_NODE_GROUP_ID
kubectl delete pvc boltz-fs-pvc
nebius compute filesystem delete --id $NB_FS_ID
nebius mk8s cluster delete --id $NB_CLUSTER_ID
nebius iam service-account delete --id $NB_SA_ID
```

To delete a registry, first remove all container images inside it — otherwise deletion will fail. Go to [Nebius Container Registry](https://console.eu.nebius.com/registry), open the registry you want to delete, navigate to the Docker container images section and delete all images. Return to the registry view and delete the registry itself.
