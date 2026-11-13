#!/bin/bash
set -e

CLUSTER_NAME="iot-cloud"
CONTEXT="kind-${CLUSTER_NAME}"

echo "Installing KubeEdge on ${CLUSTER_NAME}..."

# 1. Install CloudCore using keadm (assumes keadm is installed or uses helm/manifests if preferred, but keadm is standard)
# For simplicity in this simulation, we will use a Helm chart or direct manifest application if keadm is tricky in scripts without user interaction.
# However, the user requested "steps", so we will provide the commands.

echo "Deploying CloudCore..."
# We will use the KubeEdge Helm charts for better management in K8s
helm repo add kubeedge https://raw.githubusercontent.com/kubeedge/kubeedge/master/build/helm
helm repo update
helm install cloudcore kubeedge/cloudcore --namespace kubeedge --create-namespace \
    --set cloudCore.modules.cloudHub.advertiseAddress={$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CLUSTER_NAME}-control-plane)} \
    --context ${CONTEXT}

echo "Waiting for CloudCore..."
kubectl wait --namespace kubeedge \
  --for=condition=ready pod \
  --selector=app=cloudcore \
  --timeout=90s \
  --context ${CONTEXT}

# 2. Get Token
TOKEN=$(kubectl get secret -n kubeedge cloudcore-secret -o jsonpath={.data.tokendata} --context ${CONTEXT} | base64 -d)
echo "Token acquired: ${TOKEN}"

# 3. Simulate Edge Node (EdgeCore)
# We will run EdgeCore in a Docker container that connects to the CloudCore
# Note: This requires the edgecore container image.
echo "Starting EdgeCore container..."

CLOUD_CORE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CLUSTER_NAME}-control-plane)

docker run -d --name iot-edge-node \
    --privileged \
    --network kind \
    -e CLOUDCOREIPS="${CLOUD_CORE_IP}" \
    -e TOKEN="${TOKEN}" \
    -e EDGENAME="iot-edge-node" \
    kubeedge/installation-package:v1.13.0 \
    bash -c "keadm join --cloudcore-ipport=${CLOUD_CORE_IP}:10000 --token=${TOKEN} --edgenode-name=iot-edge-node --kubeedge-version=1.13.0 && tail -f /dev/null"

echo "Edge Node 'iot-edge-node' started."
echo "Verify with: kubectl get nodes --context ${CONTEXT}"
