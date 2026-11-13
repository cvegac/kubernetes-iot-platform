#!/bin/bash
set -e

CLUSTER_NAME="iot-cloud"

echo "Creating Cloud Cluster ($CLUSTER_NAME) using kind..."

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed. Please install it first."
    exit 1
fi

# Create cluster config with Ingress support AND KubeEdge ports
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  # KubeEdge CloudCore Ports
  - containerPort: 10000
    hostPort: 10000
    protocol: TCP
  - containerPort: 10001
    hostPort: 10001
    protocol: TCP
  - containerPort: 10002
    hostPort: 10002
    protocol: TCP
  - containerPort: 10003
    hostPort: 10003
    protocol: TCP
  - containerPort: 10004
    hostPort: 10004
    protocol: TCP
EOF

echo "Cloud Cluster created successfully!"
echo "Context: kind-${CLUSTER_NAME}"

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml --context kind-${CLUSTER_NAME}

echo "Waiting for Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s \
  --context kind-${CLUSTER_NAME}

echo "Setup complete."
