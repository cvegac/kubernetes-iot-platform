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

MQTT_IMAGE="eclipse-mosquitto:2.1.2-alpine"

app_healthy() {
  local app="$1"
  kubectl --context "$CLOUD" -n argocd wait "application/${app}" \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s &&
    kubectl --context "$CLOUD" -n argocd wait "application/${app}" \
      --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
}

edge_to_cloud_message() {
  # Camino de un ESP32 real: publica en el broker del edge y el bridge lo reenvía al broker del cloud.
  local msg="temp=21.5 id=$RANDOM"
  kubectl --context "$CLOUD" delete pod smoke-sub --ignore-not-found >/dev/null
  kubectl --context "$CLOUD" run smoke-sub --restart=Never --image="$MQTT_IMAGE" --command -- \
    mosquitto_sub -h mqtt.mqtt.svc -t 'sensors/#' -C 1 -W 60 >/dev/null
  kubectl --context "$CLOUD" wait pod smoke-sub --for=condition=Ready --timeout=120s >/dev/null || return 1
  run_pod "$EDGE" smoke-pub "$MQTT_IMAGE" \
    mosquitto_pub -h mqtt.mqtt.svc -t sensors/esp32-01/temperature -m "$msg" -q 1 >/dev/null
  kubectl --context "$CLOUD" wait pod smoke-sub --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s >/dev/null
  local got
  got=$(kubectl --context "$CLOUD" logs smoke-sub)
  kubectl --context "$CLOUD" delete pod smoke-sub --wait=false >/dev/null
  [ "$got" = "$msg" ]
}

echo
echo "== Hito 2: GitOps y MQTT edge -> cloud"
check "Argo CD: root-app Synced/Healthy" app_healthy root-app
check "Argo CD: broker en cloud Synced/Healthy" app_healthy mqtt-cloud
check "Argo CD: broker en edge (ApplicationSet) Synced/Healthy" app_healthy mqtt-iot-edge
check "mensaje publicado en edge llega al cloud por el bridge" edge_to_cloud_message

API_GROUP="iot.cvegac.github.io"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"

crds_established() {
  kubectl --context "$CLOUD" wait --for=condition=Established --timeout=120s \
    "crd/edgegateways.${API_GROUP}" "crd/topicroutes.${API_GROUP}"
}

registry_points_to_edge() {
  # El EdgeGateway del registro tiene que nombrar al cluster que Argo CD conoce como edge.
  [ "$(kubectl --context "$CLOUD" -n iot-system get edgegateway iot-edge -o jsonpath='{.spec.cluster}')" = iot-edge ]
}

# Server-side dry-run: valida contra el schema y las reglas CEL del API server sin persistir nada.
accepted() {
  kubectl --context "$CLOUD" apply --dry-run=server -f "$1"
}

expected_error() {
  sed -n 's/^# expect: //p' "$1"
}

rejected() {
  local file="$1" expect out
  expect="$(expected_error "$file")"
  [ -n "$expect" ] || return 1
  out="$(kubectl --context "$CLOUD" apply --dry-run=server -f "$file" 2>&1)" && return 1
  grep -qF -- "$expect" <<<"$out"
}

route_gateway_immutable() {
  local out
  out="$(kubectl --context "$CLOUD" -n iot-system patch topicroute sensors-telemetry --type merge \
    -p '{"spec":{"gateway":"otro-gateway"}}' --dry-run=server 2>&1)" && return 1
  grep -qF "gateway is immutable" <<<"$out"
}

echo
echo "== Hito 3: API propia (CRDs EdgeGateway y TopicRoute)"
check "CRDs Established" crds_established
check "Argo CD: iot-api Synced/Healthy" app_healthy iot-api
check "registro: EdgeGateway iot-edge apunta al cluster iot-edge" registry_points_to_edge
for f in "$FIXTURES"/valid/*.yaml; do
  check "acepta $(basename "$f")" accepted "$f"
done
for f in "$FIXTURES"/invalid/*.yaml; do
  check "rechaza $(basename "$f") -> \"$(expected_error "$f")\"" rejected "$f"
done
check "rechaza cambiar el gateway de una TopicRoute existente" route_gateway_immutable

echo
if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) fallaron"
  exit 1
fi
echo "Todos los checks pasaron"
