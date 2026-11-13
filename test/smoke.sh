#!/usr/bin/env bash
# Smoke test de la plataforma: corre contra los clusters kind que levanta bootstrap/up.sh.
# Uso: test/smoke.sh   (sale con código 1 si algún check falla)
set -uo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash en Windows: no convertir argumentos tipo /ruta a C:/Program Files/Git/...

CLOUD="kind-iot-cloud"
EDGE="kind-iot-edge"
EDGE_API="https://iot-edge-control-plane:6443"
failures=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  ${name}"
  else
    echo "FAIL  ${name}"
    failures=$((failures + 1))
  fi
}

nodes_ready() {
  kubectl --context "$1" wait --for=condition=Ready nodes --all --timeout=60s
}

argocd_ready() {
  kubectl --context "$CLOUD" -n argocd rollout status deploy/argocd-server --timeout=120s &&
    kubectl --context "$CLOUD" -n argocd rollout status deploy/argocd-repo-server --timeout=120s &&
    kubectl --context "$CLOUD" -n argocd rollout status statefulset/argocd-application-controller --timeout=120s
}

edge_registered() {
  # Argo CD descubre clusters por Secrets con este label; el label tier=edge lo usa el ApplicationSet.
  local server
  server=$(kubectl --context "$CLOUD" -n argocd get secret \
    -l argocd.argoproj.io/secret-type=cluster,tier=edge \
    -o jsonpath='{.items[0].data.server}' | base64 -d)
  [ "$server" = "$EDGE_API" ]
}

# Corre un pod efímero y devuelve sus logs. No usa `kubectl run -i --rm`: en Windows no devuelve la salida.
run_pod() {
  local ctx="$1" name="$2" image="$3"; shift 3
  kubectl --context "$ctx" delete pod "$name" --ignore-not-found >/dev/null
  kubectl --context "$ctx" run "$name" --restart=Never --image="$image" --command -- "$@" >/dev/null
  kubectl --context "$ctx" wait pod "$name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null
  local rc=$?
  kubectl --context "$ctx" logs "$name"
  kubectl --context "$ctx" delete pod "$name" --wait=false >/dev/null
  return $rc
}

edge_reachable_from_cloud() {
  # El mismo camino de red que usa Argo CD: desde un pod del cluster cloud hasta el API server del edge.
  run_pod "$CLOUD" smoke-edge-api curlimages/curl:8.17.0 \
    curl -sk --max-time 10 "${EDGE_API}/version" | grep -q '"gitVersion"'
}

echo "== Hito 1: clusters y Argo CD"
check "cloud: nodos Ready" nodes_ready "$CLOUD"
check "edge: nodos Ready" nodes_ready "$EDGE"
check "cloud: Argo CD disponible" argocd_ready
check "edge registrado en Argo CD (tier=edge)" edge_registered
check "API del edge alcanzable desde un pod del cloud" edge_reachable_from_cloud

echo
if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) fallaron"
  exit 1
fi
echo "Todos los checks pasaron"
