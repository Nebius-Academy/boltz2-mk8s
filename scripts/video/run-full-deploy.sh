#!/usr/bin/env bash
set -euo pipefail

# 1. MK8S cluster

# 1.1 create registry, service account, MK8S cluster and node group

git clone https://github.com/Nebius-Academy/boltz2-mk8s.git
cd boltz2-mk8s

# 1.2 set environment variables

export PROJECT_ID=
export REGION_ID=
export NB_REGISTRY_ID=
export CLUSTER_ID=
export MOUNT_TAG=
export NB_REGISTRY_PATH=$(echo $NB_REGISTRY_ID | cut -d- -f2)

# 1.3 configure Nebius CLI, docker login with short-lived access token, connect `kubectl` with the cluster

nebius config set parent-id $PROJECT_ID

nebius iam get-access-token | \
  docker login cr.$REGION_ID.nebius.cloud \
    --username iam \
    --password-stdin

nebius mk8s cluster get-credentials --id $CLUSTER_ID --external

# 2. Docker container

# 2.1 build -> tag/push -> pre-pull -> check status

docker build -t boltz-runner -f docker/Dockerfile .

export BOLTZ_IMAGE=cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:v1.0.0
docker tag boltz-runner $BOLTZ_IMAGE
docker push $BOLTZ_IMAGE

envsubst '$BOLTZ_IMAGE' < scripts/video/boltz-pre-pull.yaml | kubectl apply -f -

if kubectl rollout status daemonset/boltz-pre-pull --timeout=30m; then
  echo "✅ COMPLETED"
  kubectl delete daemonset/boltz-pre-pull
else
  echo "❌ FAILED"
  exit 1
fi

# 3. mount shared filesystem & upload data

# 3.1 install Container Storage Interface driver

helm pull oci://cr.eu-north1.nebius.cloud/mk8s/helm/csi-mounted-fs-path --version 0.1.3

helm upgrade csi-mounted-fs-path ./csi-mounted-fs-path-0.1.3.tgz --install \
  --set dataDir=/mnt/$MOUNT_TAG/csi-mounted-fs-path-data/

rm csi-mounted-fs-path-0.1.3.tgz

# 3.2 mounting shared filesystem to pods

kubectl apply -f scripts/video/csi-pvc-and-pod.yaml

# 3.3 upload data

kubectl cp ./data/. my-csi-app:/data

kubectl exec -it my-csi-app -- ls -lah /data

kubectl apply -f scripts/video/boltz-cache-populate-job.yaml

kubectl exec -it my-csi-app -- ls -lah /data/.boltz

# 3.4 check status

if kubectl wait --for=condition=complete job/boltz-cache-populate --timeout=30m; then
  echo "✅ COMPLETED"
  kubectl delete job boltz-cache-populate --wait=false || true
  kubectl delete pods -l job-name=boltz-cache-populate || true
else
  echo "❌ FAILED"
  exit 1
fi

# 4. run boltz-2 and download results

# 4.1 run boltz-2

envsubst '$BOLTZ_IMAGE' < scripts/video/boltz-multi-job.yaml | kubectl apply -f -

kubectl get pods
kubectl logs jobs/boltz-runner
kubectl exec -it my-csi-app -- ls -lah /data/results

echo "Waiting for boltz-runner job to complete..."
kubectl wait --for=condition=complete job/boltz-runner --timeout=-1s
completed=$(kubectl get pods -l job-name=boltz-runner --no-headers | grep 'Completed' | wc -l)
echo "✅ COMPLETED: $completed/16 pods"

# 4.2 download results

kubectl cp my-csi-app:/data/results ./results -c my-csi-app