# Alert rules

Sixteen rules in four groups. Every one of them exists because it answers a question I actually
had, not because it looked good on a dashboard.

## Availability

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `TargetDown` | `up == 0` | 2m | critical |
| `EndpointDown` | a blackbox probe fails | 3m | critical |
| `EndpointSlow` | probe duration above 2 s | 10m | warning |
| `CertificateExpiringSoon` | TLS certificate expires in under 21 days | 1h | warning |

`TargetDown` covers "Prometheus cannot scrape it". `EndpointDown` covers "the service does not
answer from outside". They are different failures: an exporter can be perfectly scrapeable while
the application behind it returns 500 to every user.

Three weeks of certificate warning is deliberate. Long enough to renew without rushing, short
enough that the alert is not permanently firing and therefore permanently ignored.

## Host

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `HostHighCpu` | CPU above 85% | 10m | warning |
| `HostHighMemory` | memory above 90% | 10m | warning |
| `HostDiskSpaceLow` | a filesystem under 15% free | 15m | warning |
| `HostDiskWillFill` | projected to hit zero within 24h | 30m | critical |
| `HostUnexpectedReboot` | uptime under 5 minutes | 1m | info |

`HostDiskWillFill` is the one that earns its keep:

```promql
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}[6h], 24 * 3600) < 0
and on (instance, mountpoint)
(node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100 < 30
```

`predict_linear` fits a line to the last six hours and extrapolates a day forward. A static
threshold either shouts at you about a disk that has sat at 80% for a year, or stays quiet while
a runaway log file eats 40 GB in an afternoon. The second condition keeps it from firing on a
disk that is briefly trending down but still 90% empty.

Memory uses `MemAvailable` rather than `MemFree`. Linux uses free memory for page cache, so
`MemFree` on a healthy server looks alarming and means nothing.

## Containers

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `ContainerRestartLoop` | more than 2 restarts in 15 minutes | 5m | warning |
| `ContainerHighMemory` | above 90% of its memory limit | 10m | warning |

`restart: unless-stopped` hides crashes very effectively. A container that dies every 30 seconds
and comes straight back looks fine in `docker ps`, and the restart counter is the only thing that
gives it away.

## Backups

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `BackupFailed` | the job exited non zero | 5m | critical |
| `BackupTooOld` | no successful run in over 26 hours | 15m | critical |
| `BackupMetricsMissing` | no backup metrics exist at all | 30m | warning |
| `BackupProducedNothing` | a successful run wrote zero archives | 15m | warning |
| `BackupShrankSharply` | under half the weekly average size | 1h | warning |

These read a textfile collector file written by my backup job, so no exporter is involved. The
job writes `/var/lib/node_exporter/textfile_collector/backup_homelab.prom` and node exporter
picks it up on the next scrape.

26 hours rather than 24 gives a nightly job room for the randomised delay on its timer without
alerting every time it starts a few minutes late.

`BackupProducedNothing` and `BackupShrankSharply` are the two that catch the failure mode nobody
plans for. A job that crashes is obvious. A job that exits 0 having archived an empty directory,
because someone renamed the path it backs up, looks perfectly healthy right up until the restore.

```promql
backup_last_run_bytes < 0.5 * avg_over_time(backup_last_run_bytes[7d]) and backup_last_run_bytes > 0
```

## Routing and noise control

Alertmanager groups by `alertname` and `instance`, so one host going down produces one
notification instead of six.

Two inhibition rules do the real work:

- when `TargetDown` fires for an instance, warnings and info alerts for that same instance are
  suppressed. If a host is unreachable, being told its CPU metric is stale is not news.
- a critical alert suppresses the matching warning for the same alertname and instance, so you do
  not get both severities for one problem.

`repeat_interval` is 1 hour for critical and 24 hours for info. Anything that repeats more often
than that trains you to ignore it.

## Testing that they actually fire

```bash
./scripts/trigger-alert.sh node-exporter
```

The script stops the exporter, watches the Prometheus API until the alert goes pending and then
firing, confirms Alertmanager received it, restarts the container and waits for it to resolve.
On my machine: pending at 30 s, firing at 120 s, in Alertmanager immediately, cleared 30 s after
the exporter came back.

An alert rule that has never fired is a hypothesis, not a safety net. Writing this script found
two mistakes: a rule matching a label the metric does not carry, and the first version of the
script itself, which parsed the `/api/v1/alerts` JSON with `grep` and reported "no alert" for
five minutes while the alert was firing perfectly well. Querying `ALERTS{alertstate="firing"}`
through the query API instead of scraping JSON by hand is both shorter and correct.

## Unit testing the rules

Breaking things on purpose is the honest test, but it takes four minutes and needs the stack
running. The faster check runs the rules against synthetic time series:

```bash
./scripts/validate.sh
```

That includes `promtool test rules prometheus/tests/alert_tests.yml`, which feeds made up series
into the real rule files and asserts exactly what fires and when:

- `TargetDown` is silent at 3 minutes and firing at 5, which is the `for: 2m` hold time proving
  itself rather than being assumed
- a target that never goes down produces no alert at all, because a rule that fires on healthy
  input is worse than no rule
- a filesystem at 12 percent free alerts, one at 60 percent does not
- a backup whose last success is more than 26 hours old alerts, a recent one does not
- with no backup metrics present at all, `BackupMetricsMissing` fires

The annotations are asserted too, so a rule cannot quietly start rendering
`{{ $labels.instance }}` as an empty string without a test failing.

## Validating the config before restarting anything

`./scripts/validate.sh` also runs `promtool check config`, `promtool check rules` and
`amtool check-config` inside throwaway containers. Prometheus refuses to start on a bad rule
file, so it is worth catching before it takes the whole stack down. The same three checks plus
the unit tests run in CI on every push.
