#!/usr/bin/env bash
set -euo pipefail

PVC_NAME="boltz-fs-pvc"
POD_NAME="pvc-downloader"

# Create a temporary pod with the PVC mounted
kubectl run "$POD_NAME" \
  --image=ubuntu:22.04 \
  --restart=Never \
  --overrides="
{
  \"spec\": {
    \"volumes\": [
      { \"name\": \"data\", \"persistentVolumeClaim\": { \"claimName\": \"$PVC_NAME\" } }
    ],
    \"containers\": [
      {
        \"name\": \"pvc-downloader\",
        \"image\": \"ubuntu:22.04\",
        \"command\": [\"sleep\", \"infinity\"],
        \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]
      }
    ]
  }
}
" >/dev/null

# Wait until the pod is ready
kubectl wait --for=condition=Ready pod/"$POD_NAME" --timeout=120s

# Create a tarball inside the pod
TMP_TAR="/tmp/results.tgz"
kubectl exec "$POD_NAME" -- \
  bash -lc "tar czf \"$TMP_TAR\" -C /data results"

# Copy the tarball to the local machine
kubectl cp "$POD_NAME:$TMP_TAR" ./results.tgz

# Extract locally
tar -xzf results.tgz
rm results.tgz

# Delete the pod
kubectl delete pod "$POD_NAME"
