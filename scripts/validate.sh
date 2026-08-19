#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROMETHEUS_IMAGE="prom/prometheus:v2.54.1"
ALERTMANAGER_IMAGE="prom/alertmanager:v0.27.0"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        export MSYS_NO_PATHCONV=1
        mount_path() { cygpath -w "$1"; }
        ;;
    *)
        mount_path() { printf '%s' "$1"; }
        ;;
esac

echo "checking prometheus config"
docker run --rm \
    -v "$(mount_path "$ROOT/prometheus"):/etc/prometheus:ro" \
    --entrypoint promtool \
    "$PROMETHEUS_IMAGE" check config /etc/prometheus/prometheus.yml

echo
echo "checking alert rules"
docker run --rm \
    -v "$(mount_path "$ROOT/prometheus"):/etc/prometheus:ro" \
    --entrypoint promtool \
    "$PROMETHEUS_IMAGE" check rules /etc/prometheus/rules/infrastructure.yml

echo
echo "checking alertmanager config"
docker run --rm \
    -v "$(mount_path "$ROOT/alertmanager"):/etc/alertmanager:ro" \
    --entrypoint amtool \
    "$ALERTMANAGER_IMAGE" check-config /etc/alertmanager/alertmanager.yml

echo
echo "everything parses"
