#!/usr/bin/env bash
set -euo pipefail

PVC_NAME="boltz-fs-pvc"
LOCAL_BASE="data"        # Local directory to upload
POD_NAME="pvc-uploader"  # Temporary pod name

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
        \"name\": \"shell\",
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

# Archive the local folder and extract it inside the PVC
tar -C "$LOCAL_BASE" -cf - . \
  | kubectl exec -i "$POD_NAME" -- tar -C /data -xf -

# Verify uploaded contents
kubectl exec "$POD_NAME" -- ls -lah /data

# Delete the temporary pod
kubectl delete pod "$POD_NAME"
