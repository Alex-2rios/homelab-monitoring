#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="${DASHBOARD:-$ROOT/grafana/dashboards/homelab.json}"
PROM="${PROM:-http://localhost:9090}"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) DASHBOARD="$(cygpath -w "$DASHBOARD")" ;;
esac

if ! curl -sf "$PROM/-/healthy" > /dev/null; then
    echo "prometheus is not answering at $PROM, start the stack first" >&2
    exit 1
fi

mapfile -t expressions < <(python - "$DASHBOARD" <<'PY'
import json
import sys

dashboard = json.load(open(sys.argv[1], encoding="utf-8"))
seen = []

for panel in dashboard.get("panels", []):
    for target in panel.get("targets", []):
        expr = target.get("expr", "").strip()
        if expr and expr not in seen:
            seen.append(expr)

for expr in seen:
    print(expr.replace("\n", " "))
PY
)

if [ "${#expressions[@]}" -eq 0 ]; then
    echo "no queries found in $DASHBOARD" >&2
    exit 1
fi

echo "checking ${#expressions[@]} dashboard queries against $PROM"
echo

failed=0

for expr in "${expressions[@]}"; do
    body="$(curl -s --get --data-urlencode "query=$expr" "$PROM/api/v1/query")"
    status="$(printf '%s' "$body" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')"

    if [ "$status" = "success" ]; then
        printf '  [ ok ]   %s\n' "${expr:0:88}"
    else
        error="$(printf '%s' "$body" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')"
        printf '  [FAIL]   %s\n' "${expr:0:88}"
        printf '           %s\n' "$error"
        failed=$((failed + 1))
    fi
done

echo
if [ "$failed" -gt 0 ]; then
    echo "$failed of ${#expressions[@]} queries did not parse"
    exit 1
fi

echo "all ${#expressions[@]} queries parse against the running prometheus"
