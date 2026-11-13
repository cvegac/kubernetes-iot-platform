#!/usr/bin/env bash
# Levanta la plataforma completa en local: cluster cloud + cluster edge (kind) y Argo CD en cloud
# con el edge registrado. Idempotente: se puede correr varias veces.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "${ROOT}/bootstrap/versions.env"

CLOUD="iot-cloud"
EDGE="iot-edge"

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "Falta '$bin' en el PATH" >&2; exit 1; }
done

create_cluster() {
  local name="$1" config="$2"
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "Cluster ${name} ya existe"
  else
    kind create cluster --config "$config" --image "$KIND_NODE_IMAGE" --wait 120s
  fi
}

echo "==> Clusters"
create_cluster "$CLOUD" "${ROOT}/bootstrap/kind/cloud.yaml"
create_cluster "$EDGE" "${ROOT}/bootstrap/kind/edge.yaml"

echo "==> Argo CD ${ARGOCD_CHART_VERSION} en ${CLOUD}"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --kube-context "kind-${CLOUD}" --namespace argocd --create-namespace \
  --values "${ROOT}/gitops/argocd/values.yaml" --wait --timeout 5m

echo "==> Registrando ${EDGE} en Argo CD"
# --internal: dirección del API server dentro de la red docker "kind", que es la que ven los pods del cloud.
kubeconfig="$(mktemp)"
trap 'rm -f "$kubeconfig"' EXIT
kind get kubeconfig --name "$EDGE" --internal >"$kubeconfig"
field() { kubectl --kubeconfig "$kubeconfig" config view --raw -o jsonpath="{$1}"; }
server="$(field '.clusters[0].cluster.server')"
config=$(printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' \
  "$(field '.clusters[0].cluster.certificate-authority-data')" \
  "$(field '.users[0].user.client-certificate-data')" \
  "$(field '.users[0].user.client-key-data')")

# Las credenciales nunca van a git: el Secret se genera acá, en cada bootstrap.
kubectl --context "kind-${CLOUD}" -n argocd create secret generic "cluster-${EDGE}" \
  --from-literal=name="$EDGE" --from-literal=server="$server" --from-literal=config="$config" \
  --dry-run=client -o yaml |
  kubectl --context "kind-${CLOUD}" label --local -f - -o yaml \
    argocd.argoproj.io/secret-type=cluster tier=edge |
  kubectl --context "kind-${CLOUD}" apply -f -

cat <<EOF

Listo. Contextos: kind-${CLOUD}, kind-${EDGE}
UI de Argo CD:  kubectl --context kind-${CLOUD} -n argocd port-forward svc/argocd-server 8080:80
Usuario admin, contraseña:
  kubectl --context kind-${CLOUD} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
EOF
