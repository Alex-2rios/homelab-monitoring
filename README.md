# Homelab monitoring

Prometheus, Grafana, Alertmanager and three exporters, watching my own machines. One
`docker compose up` and you have metrics, dashboards and alerts that have been tested by actually
breaking things.

## What it watches

| Component | Port | What it gives you |
|---|---|---|
| Prometheus | 9090 | scraping, alert rule evaluation, 30 days of history |
| Grafana | 3000 | dashboards, provisioned from files rather than clicked together |
| Alertmanager | 9093 | grouping, routing, inhibition |
| node-exporter | 9100 | CPU, memory, disks, network, load |
| cAdvisor | 8081 | per container CPU and memory |
| blackbox-exporter | 9115 | HTTP and TCP probes from outside the service |

## Running it

```bash
cp .env.example .env
docker compose up -d
```

Grafana is at <http://localhost:3000>. The datasource and the dashboard come from
`grafana/provisioning`, so there is nothing to import by hand and nothing to lose if the volume
is deleted. Change `GRAFANA_PASSWORD` in `.env` before you expose it to anything.

Check the config before restarting Prometheus:

```bash
./scripts/validate.sh
```

## The dashboard

One overview dashboard, `grafana/dashboards/homelab.json`, in four sections:

- a stat row: targets up, targets down, CPU, memory, root filesystem free, uptime
- host detail: CPU by mode, memory including cache, filesystem usage, network, disk IO, load
- endpoints: probe success and probe duration for whatever is in the blackbox job
- containers: CPU and memory per container

Because it is provisioned from a file, editing it in the browser and then losing the container
does not lose the dashboard, and the diff shows up in git.

## Alerts

Eleven rules across availability, host and container health. The full table with the reasoning
behind each threshold is in [docs/alerts.md](docs/alerts.md).

The one I would point at first:

```promql
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}[6h], 24 * 3600) < 0
```

That fires when a disk is *going* to fill within a day, not once it already has. A static 90%
threshold tells you about a problem you now have to fix at 2am. This one tells you the afternoon
before.

## Proving the alerts work

```bash
./scripts/trigger-alert.sh node-exporter
```

Stops the exporter, polls the Prometheus API until the alert goes pending and then firing, checks
Alertmanager actually received it, restarts the container and confirms it clears:

```
stopping the node-exporter container

waiting for the rule to go pending, scrapes are every 15s
  pending after 30s

waiting for it to fire, the rule holds for 2m first
  firing after 120s

checking alertmanager received it
  alertmanager has the alert after 0s

starting node-exporter again

waiting for the alert to clear
  none after 30s
```

Thirty seconds to notice, two minutes to fire, thirty seconds to clear. Those numbers are the
whole reason to run the drill: now I know what the detection window actually is instead of
assuming it from the config.

I wrote this because two of my rules were silently broken. They looked correct, they parsed fine,
and they could never have fired: one matched a label the metric does not carry, and one used a
metric name that changed between exporter versions. You cannot find that by reading YAML.

## Adding a host

Metrics from another machine, once node-exporter is running on it:

```yaml
  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100", "192.168.1.50:9100"]
        labels:
          host: proxmox
```

Or from outside, without installing anything on the target, add it to the `blackbox-http` job and
you get availability, response time and certificate expiry for free.

## What I learned

- Alerts you have never fired on purpose are decoration. Testing them found two rules that could
  not have worked, and I would not have known until the night I needed them.
- `MemAvailable` and not `MemFree`. Linux fills free memory with page cache by design, so
  `MemFree` on a perfectly healthy server looks like an emergency.
- `predict_linear` over a six hour window turned a noisy static threshold into an alert that has
  never once been wrong for me. The `and` clause matters, without it a disk trending down from
  100% free triggers it.
- Inhibition rules are what make alerting survivable. Without them, one host going down produced
  six notifications, five of which were consequences of the first.
- Provisioning Grafana from files instead of clicking dashboards together means the dashboard is
  reviewable, diffable and restorable. Rebuilding a hand made dashboard from memory once was
  enough.
- On Docker Desktop, node-exporter reports the Linux VM rather than the Windows host, so the
  numbers are real but they are the VM's. On the Ubuntu box where this actually lives, the mounts
  in the compose file give it the real host.

## Next

Loki for logs next to the metrics, so an alert links to what the service was saying at the time,
and a second Prometheus scraping the first, because nobody notices when the thing that notices
things stops working.
