#!/bin/bash
set -e

CLUSTER_NAME="iot-cloud"
CONTEXT="kind-${CLUSTER_NAME}"

echo "Installing ArgoCD on ${CLUSTER_NAME}..."

# Create namespace
kubectl create namespace argocd --context ${CONTEXT} --dry-run=client -o yaml | kubectl apply --context ${CONTEXT} -f -

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --context ${CONTEXT}

echo "Waiting for ArgoCD server to be ready..."
kubectl wait --namespace argocd \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=90s \
  --context ${CONTEXT}

# Patch ArgoCD Server to be accessible via NodePort (for local simulation)
# In production, use Ingress
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}' --context ${CONTEXT}

echo "ArgoCD installed successfully."
echo "Initial Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --context ${CONTEXT} | base64 -d
echo ""
echo "Access ArgoCD via NodePort or Ingress."
