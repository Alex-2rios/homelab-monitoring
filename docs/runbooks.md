# Runbooks

One section per alert. Every alert in this repo carries a `runbook_url` annotation pointing here,
so whoever gets the notification lands on the page that tells them what to do rather than on a
graph they have to interpret at 3am.

The format is deliberately the same every time: what it means, what to check first, how to fix
it, and when it is fine to ignore.

---

## TargetDown

**Means:** Prometheus has not been able to scrape a target for two minutes. The exporter, the
service or the network between them is gone.

**Check first:**

```bash
curl -s "http://localhost:9090/api/v1/targets?state=active" | jq '.data.activeTargets[] | select(.health!="up") | {job: .labels.job, url: .scrapeUrl, error: .lastError}'
docker compose ps
```

`lastError` on the target usually says it outright: `connection refused` means the process is
gone, `context deadline exceeded` means it is up but too slow or hung, and `no such host` means
DNS, which in a compose stack normally means the container was recreated on a new network.

**Fix:** restart the exporter, then work out why it stopped. If it is a container,
`docker compose logs <service> --tail 100` almost always has the answer.

**Ignore when:** you took the host down on purpose. Silence it in Alertmanager for the duration
rather than letting it fire, otherwise you get used to seeing it red.

---

## EndpointDown

**Means:** a blackbox probe failed for three minutes. The service does not answer from outside,
which is a different question from whether the process is running.

**Check first:**

```bash
curl -s "http://localhost:9115/probe?module=http_2xx&target=https://example.com&debug=true"
```

The debug output shows the whole probe: DNS resolution, the TCP connect, the TLS handshake and
the HTTP response. Whichever stage fails is the layer to look at.

**Fix:** depends on the stage. DNS failures are usually the resolver, connect failures usually
the firewall, TLS failures usually an expired or untrusted certificate, and a 5xx means the
application itself.

**Ignore when:** never on its own. If `TargetDown` is also firing for the same host, the
inhibition rule already suppresses this one and the host is the real problem.

---

## EndpointSlow

**Means:** the probe has taken more than two seconds for ten minutes. Not down, just slow enough
that users notice.

**Check first:** `probe_http_duration_seconds` broken down by phase in Grafana. It splits into
resolve, connect, tls and processing, which tells you whether it is the network or the
application.

**Fix:** if processing dominates, the application is the problem. If connect or tls dominates,
look at the network path and whether TLS session resumption is working.

**Ignore when:** the target is a public site over an internet link you do not control. That is
what the ten minute window is already trying to filter out.

---

## CertificateExpiringSoon

**Means:** a TLS certificate expires in less than 21 days.

**Check first:**

```bash
echo | openssl s_client -connect host:443 -servername host 2>/dev/null | openssl x509 -noout -subject -dates
```

**Fix:** renew it. If certbot is supposed to be doing this automatically, then the real problem
is that renewal is broken, and the certificate is only the symptom:
`systemctl status certbot.timer` and `certbot renew --dry-run`.

**Ignore when:** you are deliberately letting a lab certificate expire. Otherwise treat three
weeks as the last comfortable moment to act.

---

## HostHighCpu

**Means:** CPU above 85 percent for ten minutes.

**Check first:**

```bash
top -b -n 1 | head -20
```

and the CPU by mode panel in Grafana. High `system` usually means IO or network, high `iowait`
means the disk is the real bottleneck, and high `user` is genuinely a process doing work.

**Fix:** find the process. If it is legitimate work that just takes a while, the alert is doing
its job and you acknowledge it. If it is a runaway loop, restart the service and look at what it
was doing.

**Ignore when:** during a known batch job, a backup window or a large build.

---

## HostHighMemory

**Means:** less than 10 percent of memory is available. This uses `MemAvailable`, so page cache
is already accounted for.

**Check first:**

```bash
free -h
ps aux --sort=-%mem | head -10
```

**Fix:** usually one process. If nothing stands out and the number climbs steadily over days,
you are looking at a leak, and the interesting graph is memory over the last week rather than
the last hour.

**Ignore when:** on a host that deliberately runs close to full, for example one big database
that has been given most of the RAM on purpose. Raise the threshold for that host instead of
ignoring the alert.

---

## HostDiskSpaceLow

**Means:** a filesystem is under 15 percent free.

**Check first:**

```bash
df -h
du -xh / 2>/dev/null | sort -rh | head -20
journalctl --disk-usage
docker system df
```

**Fix:** in my experience it is one of three things: journal logs that were never capped, Docker
images and volumes nobody cleaned up, or an application log without rotation.
`journalctl --vacuum-size=500M` and `docker system prune` handle the first two.

**Ignore when:** an archive volume that is meant to sit nearly full. Exclude that mountpoint in
the rule rather than muting the alert.

---

## HostDiskWillFill

**Means:** based on the last six hours of growth, this filesystem hits zero within a day. It is
the alert that gives you an afternoon instead of an emergency.

**Check first:** what started growing six hours ago.

```bash
find /var/log -type f -mmin -360 -size +50M
docker ps --format '{{.Names}}' | xargs -I{} sh -c 'echo -n "{} "; docker logs {} 2>&1 | wc -c'
```

**Fix:** stop the growth first, reclaim space second. Truncating a log that something is still
writing to buys you an hour and no more.

**Ignore when:** you are in the middle of a restore or a large copy that you know will finish.
The `and` clause in the rule already suppresses it when the disk is over 30 percent free.

---

## HostUnexpectedReboot

**Means:** uptime is under five minutes.

**Check first:**

```bash
last -x reboot | head -5
journalctl -b -1 -e
```

The last few lines of the previous boot tell you whether it was a clean shutdown, a kernel panic
or the power going out.

**Fix:** nothing to fix if it was planned. If it was not, check for a thermal shutdown, a failing
power supply or an out of memory kill that took the system down.

**Ignore when:** you rebooted it. It is severity `info` for exactly that reason.

---

## ContainerRestartLoop

**Means:** more than two restarts in fifteen minutes. `restart: unless-stopped` hides crashes
very well, and this is what makes them visible.

**Check first:**

```bash
docker ps --filter "name=<name>" --format '{{.Status}}'
docker logs <name> --tail 100
docker inspect <name> --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
```

**Fix:** exit code 137 with `OOMKilled: true` means it hit its memory limit, so either the limit
is too low or the container leaks. Any other exit code means read the logs.

**Ignore when:** you are actively redeploying that service.

---

## ContainerHighMemory

**Means:** a container is above 90 percent of its own memory limit. The OOM killer is next.

**Check first:** `docker stats --no-stream` and the container memory panel in Grafana.

**Fix:** raise the limit if the workload genuinely needs it, otherwise find out why it grew. A
container that creeps up to its limit over days and gets killed every night is leaking.

**Ignore when:** a JVM or similar runtime that is configured to use its whole heap on purpose.

---

## BackupFailed

**Means:** the backup job exited non zero. The exit code says which part failed.

| Code | What failed |
|---|---|
| 1 | configuration missing or invalid |
| 2 | an archive failed verification |
| 3 | another run held the lock |
| 4 | a configured source does not exist |
| 5 | the second copy failed or its target is not mounted |
| 6 | the offsite push failed |

**Check first:**

```bash
systemctl status backup.service
journalctl -u backup.service -n 100
cat /srv/backups/<job>.state
```

**Fix:** by code. 4 usually means a path was renamed, 5 usually means the USB disk is not
mounted, 6 usually means the SSH key or the remote host. Fix it and run `backup.sh` by hand
rather than waiting for tonight.

**Ignore when:** never. This is the alert the whole backup repo exists for.

---

## BackupTooOld

**Means:** nothing has succeeded in more than 26 hours. Either the job is failing every night or
it is not running at all.

**Check first:**

```bash
systemctl list-timers 'backup*'
systemctl status backup.timer
```

If `BackupFailed` is not also firing, the job is not running rather than failing, which usually
means a disabled timer or a host that was off.

**Fix:** re-enable the timer, or run the job manually and then work out why it stopped.

**Ignore when:** the machine was deliberately off for more than a day. `Persistent=true` on the
timer will catch the missed run up on the next boot.

---

## BackupMetricsMissing

**Means:** there are no backup metrics at all. Nothing is writing to the textfile collector.

**Check first:**

```bash
ls -la /var/lib/node_exporter/textfile_collector/
curl -s http://localhost:9100/metrics | grep backup_
```

**Fix:** either the job has never run on this host, or `METRICS_DIR` in `backup.conf` points
somewhere the job cannot write. The backup log says so explicitly when that happens.

**Ignore when:** on a host that is not supposed to run backups. Scope the rule to the hosts that
are instead.

---

## BackupProducedNothing

**Means:** a run reported success and wrote zero archives. This is the quiet failure that looks
healthy from every angle except this one.

**Check first:**

```bash
grep SOURCES /etc/backup/backup.conf
ls -la <each source path>
```

**Fix:** almost always a path that was renamed or an exclude pattern that grew too broad.

**Ignore when:** never. A backup that produces nothing is the same as no backup, and it is the
kind that gets discovered during a restore.

---

## BackupShrankSharply

**Means:** the latest backup is less than half the size of the weekly average.

**Check first:**

```bash
ls -lh /srv/backups/ | tail -20
```

**Fix:** compare the file listing of the last good archive against the new one:
`tar -tzf old.tar.gz | sort > /tmp/old && tar -tzf new.tar.gz | sort > /tmp/new && diff /tmp/old /tmp/new | head`.
What is missing usually names the problem.

**Ignore when:** you genuinely deleted a lot of data, or changed the excludes on purpose. Expect
it to fire once after that and then settle as the weekly average catches up.
