# Homelab monitoring

[![ci](https://github.com/Alex-2rios/homelab-monitoring/actions/workflows/ci.yml/badge.svg)](https://github.com/Alex-2rios/homelab-monitoring/actions/workflows/ci.yml)

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

Sixteen rules across availability, host health, containers and backups. The full table with the
reasoning behind each threshold is in [docs/alerts.md](docs/alerts.md).

They are unit tested, which is the part I would actually argue for in an interview:

```bash
./scripts/validate.sh
```

That runs `promtool test rules` over `prometheus/tests/alert_tests.yml`, which feeds synthetic
time series into the real rule files and asserts what fires and when. It checks that `TargetDown`
stays quiet at three minutes and fires at five, that a healthy target never alerts at all, and
that a backup which has not succeeded in over a day is caught. An alert rule is code, and a rule
that can never fire looks exactly like one that works.

Every alert carries a `runbook_url` pointing at [docs/runbooks.md](docs/runbooks.md), so the
notification lands on a page that says what to check first and how to fix it, rather than on a
graph somebody has to interpret at three in the morning.

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

## Watching the backups

`node-exporter` reads `./textfile` as a textfile collector directory, so anything that drops a
`.prom` file there becomes a metric. My
[backup-automation](https://github.com/Alex-2rios/backup-automation) job writes one after every
run, and `prometheus/rules/backups.yml` turns it into five alerts:

| Alert | Fires when |
|---|---|
| `BackupFailed` | the job exited non zero |
| `BackupTooOld` | nothing has succeeded in over 26 hours |
| `BackupMetricsMissing` | no backup metrics exist at all |
| `BackupProducedNothing` | a run reported success and wrote zero archives |
| `BackupShrankSharply` | the backup is half the size of its weekly average |

The last two are the interesting ones. A backup job that fails loudly is easy. A backup job that
returns 0 while quietly archiving nothing is how people find out their restores are empty, a year
later.

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
- `promtool test rules` turned alerting from something I hoped was right into something CI
  checks on every push. Writing the tests also forced me to be precise about the `for` durations,
  because the test asserts the exact minute an alert is allowed to fire.
- A textfile collector is the cheapest integration point in Prometheus. Any script that can write
  a file can produce metrics, no exporter to write, no port to expose.
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

## Working on this

```bash
make help
```

The usual ones: `make up, make validate, make drill, make reload, make down`.

Every push runs the CI workflow described above. A second workflow, `security.yml`, runs weekly
and on every push: it scans the history for committed secrets with gitleaks and checks the
compose file for misconfiguration.

Dependabot opens pull requests for the GitHub Actions and the dependencies once a week.

Line endings are pinned to LF through `.gitattributes`, because half of this was written on
Windows and shell scripts with carriage returns fail on Linux in a way that is genuinely
confusing the first time.

## Next

Loki for logs next to the metrics, so an alert links to what the service was saying at the time,
and a second Prometheus scraping the first, because nobody notices when the thing that notices
things stops working.
