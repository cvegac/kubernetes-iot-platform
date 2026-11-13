#!/usr/bin/env bash
# Borra los dos clusters de la plataforma.
set -euo pipefail

for name in iot-cloud iot-edge; do
  kind delete cluster --name "$name"
done
