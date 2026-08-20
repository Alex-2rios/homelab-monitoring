#!/usr/bin/env bash
set -uo pipefail

CONTAINER="${1:-node-exporter}"
INSTANCE="${INSTANCE:-${CONTAINER}:9100}"
ALERTNAME="${ALERTNAME:-TargetDown}"
PROM="${PROM:-http://localhost:9090}"
ALERTMANAGER="${ALERTMANAGER:-http://localhost:9093}"

query() {
    curl -s --get --data-urlencode "query=$1" "$PROM/api/v1/query"
}

alert_state() {
    local state
    for state in firing pending; do
        if query "ALERTS{alertname=\"$ALERTNAME\",instance=\"$INSTANCE\",alertstate=\"$state\"}" \
            | grep -q '"alertstate"'; then
            printf '%s' "$state"
            return 0
        fi
    done
    printf 'none'
}

in_alertmanager() {
    curl -s "$ALERTMANAGER/api/v2/alerts" | grep -q "\"alertname\":\"$ALERTNAME\""
}

wait_for() {
    local wanted="$1" limit="$2" waited=0 state
    while [ "$waited" -lt "$limit" ]; do
        state="$(alert_state)"
        if [ "$state" = "$wanted" ]; then
            printf '  %s after %ss\n' "$wanted" "$waited"
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
        printf '  %ss elapsed, state is %s\n' "$waited" "$state"
    done
    printf '  gave up waiting for %s after %ss\n' "$wanted" "$limit"
    return 1
}

if ! curl -s "$PROM/-/healthy" > /dev/null; then
    printf 'prometheus is not answering at %s\n' "$PROM" >&2
    exit 1
fi

printf 'alert drill: %s on %s\n\n' "$ALERTNAME" "$INSTANCE"

printf 'stopping the %s container\n' "$CONTAINER"
docker stop "$CONTAINER" > /dev/null

printf '\nwaiting for the rule to go pending, scrapes are every 15s\n'
wait_for pending 120

printf '\nwaiting for it to fire, the rule holds for 2m first\n'
wait_for firing 240
fired=$?

printf '\nchecking alertmanager received it\n'
waited=0
while [ "$waited" -lt 60 ]; do
    if in_alertmanager; then
        printf '  alertmanager has the alert after %ss\n' "$waited"
        break
    fi
    sleep 10
    waited=$((waited + 10))
done

printf '\nstarting %s again\n' "$CONTAINER"
docker start "$CONTAINER" > /dev/null

printf '\nwaiting for the alert to clear\n'
wait_for none 180

printf '\ndrill finished\n'
exit "$fired"
