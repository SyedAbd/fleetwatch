# fleetwatch

Self-hosted monitoring for GPU servers and ordinary computers, built from the Python standard library alone: a **node agent**, an **ingest collector** with time-series storage, a **rules engine** that turns telemetry and kernel errors into alerts, and a **live dashboard**.

It answers the on-call question for a GPU cloud, *which of my machines need attention right now, and why?*, and works just as well for a single laptop or a home lab. Linux, Windows and macOS; with or without GPUs.

```bash
pip install "git+https://github.com/<owner>/fleetwatch"
fleetwatch demo --open          # a simulated GPU fleet with failures, in your browser, in one command
```

**Documentation:** [How it works](docs/how-it-works.md) · [Setup guide](docs/setup.md) (from one laptop to GPU servers) · [Configuration reference](docs/configuration.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

<table>
  <tr>
    <td align="center"><img src="docs/dashboard-overview.jpg" width="250" alt="Fleet overview: nodes ranked worst first, open alerts, recently resolved"></td>
    <td align="center"><img src="docs/node-thermal-runaway.jpg" width="250" alt="Node detail: GPU 2 temperature climbing while the other seven stay flat"></td>
    <td align="center"><img src="docs/node-missing-gpu.jpg" width="250" alt="Node detail: 7 of 8 GPUs reporting and two Xid 79 events"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Fleet view.</b> Machines ranked worst first with GPU, memory and disk columns, and every alert explained in plain language.</sub></td>
    <td align="center"><sub><b>Thermal runaway.</b> GPU 2 climbs to 96 C (red) while its seven neighbours stay flat; the host line shows OS, CPU, memory and disk.</sub></td>
    <td align="center"><sub><b>GPU off the bus.</b> 7/8 GPUs (GPU 5 is gone from the grid) and the Xid 79 events that explain it.</sub></td>
  </tr>
</table>

Captured from `fleetwatch demo`, a real collector fed by the built-in fleet simulator (see [Testing](#testing) for what that does and does not prove).

## Platform support

| | Linux | Windows | macOS |
|---|---|---|---|
| Collector, dashboard, API | yes | yes | yes |
| Host metrics: CPU, memory, disk, uptime | yes | yes | yes (CPU as load average) |
| NVIDIA GPU metrics | yes | yes | no NVIDIA drivers on current macOS |
| Other GPU vendors | through a JSON plugin command | same | same |
| Kernel Xid / NVSwitch error triage | yes | no (Linux kernel log only) | no |
| Run as a service | systemd | Task Scheduler | launchd |

The agent detects all of this by itself and prints what it found when it starts.

```
$ fleetwatch status --server http://127.0.0.1:8765
NODE         STATUS    GPUS  TEMP  POWER  CPU  MEM  DISK  SEEN  ALERTS
gpu-node-08  CRITICAL  8/8   96C   4385W  45%  37%  44%   1s    1
gpu-node-09  CRITICAL  7/8   62C   3893W  45%  39%  46%   1s    2
gpu-node-10  CRITICAL  8/8   62C   4503W  46%  36%  45%   1s    2
gpu-node-11  CRITICAL  8/8   62C   4440W  45%  37%  47%   174s  1
gpu-node-14  CRITICAL  8/8   62C   4377W  45%  40%  99%   1s    1
gpu-node-12  WARNING   8/8   61C   4341W  44%  39%  46%   1s    1
gpu-node-01  OK        8/8   61C   4352W  44%  37%  46%   1s    0
...
  CRITICAL temp_high|gpu-node-08|gpu2: 96C for 3 samples (limit 88C)
  CRITICAL gpu_missing|gpu-node-09|: 7 of 8 GPUs reporting (missing: gpu5)
  CRITICAL xid|gpu-node-09|0000:8b:00: RMA: Xid 79 x2 (GPU fell off the bus). Drain, power-cycle the host, check lspci; RMA if it recurs.
  CRITICAL ecc|gpu-node-10|gpu1: uncorrected ECC errors rose from 0 to 26 in the last hour
  CRITICAL stale|gpu-node-11|: no report for 3m
  CRITICAL disk|gpu-node-14|/: / is 99% full of 3840 GB
  WARNING  pcie|gpu-node-12|gpu1: PCIe link is x8, expected x16
```

## Architecture

```
  GPU node                                        collector                         you
 ┌────────────────────┐                   ┌──────────────────────────┐
 │ agent              │   HTTP(S) POST    │ validate  -> idempotent  │   dashboard  (/)
 │  nvidia-smi ──┐    │  /api/v1/ingest   │ ingest (node, seq)       │   REST API   (/api/v1/*)
 │  kernel log ──┼─►spool ──────────────► │   │                      │   Prometheus (/metrics)
 │  (Xid events) │ (disk queue,           │   ├─ samples (raw, 48h)  │   webhook    (alert changes)
 └───────────────┘  retries, backoff)     │   ├─ 5-min rollups (30d) │
                                          │   ├─ events              │
                                          │   └─ rules engine ─► alerts (open/resolved, silences)
                                          └──────────────────────────┘
```

Each report carries GPU metrics (temperature, power, utilisation, memory, clocks, PCIe link, uncorrected ECC) and any new NVIDIA Xid / NVSwitch SXid kernel errors.

## Design decisions

**Delivery is at-least-once, and ingestion is idempotent.** The agent writes every report to a durable on-disk spool before sending it, and deletes it only after the collector acknowledges. If the acknowledgement is lost in transit, the agent resends, the collector recognises `(node, seq)` and answers `duplicate`, and nothing is stored twice. Sequence numbers never go backwards and never restart below the clock, so even a wiped state file cannot make new reports look like old duplicates. Events have a second, independent de-duplication key.

**Outages do not lose data or block on poison.** Reports queue in order during an outage and drain oldest first when the collector returns. A report the collector will never accept (HTTP 400) is quarantined instead of blocking newer ones; an auth failure stops the flush but keeps the queue; the spool has a size cap that drops the oldest and counts what it dropped. Retries use exponential backoff with jitter so a fleet does not stampede a recovering collector.

**Storage is bounded.** Raw samples are kept for 48 hours, then only 5-minute rollups (average and max) for 30 days. A raw sample is deleted only after it has been rolled up, and deletion happens in small batches so clean-up never holds the write lock long enough to stall ingestion. Late-arriving data (from a long outage) invalidates the affected rollup buckets, which are recomputed from raw data on the next pass. SQLite runs in WAL mode.

**Restarting the collector does not page anyone.** Agents that could not reach the collector back off (up to a minute), so right after a restart every node looks silent. The collector waits out that window before judging staleness, and bursts of alert changes are coalesced into a single webhook message. Measured: a 10-minute outage and restart of a 30-node fleet used to page 30 healthy nodes as stale in 60 messages; it now sends none.

**Alerts have a lifecycle, not just a state.** Each problem has a stable key (`rule|node|device`). An alert opens once, updates in place, escalates when it gets worse, and resolves when the condition clears. Notifications fire only on those transitions, batched into one webhook message, so a flapping GPU does not page anyone fifty times. Alerts can be silenced with an expiry; a silenced alert stays visible but stays quiet, and the silence survives the alert resolving and reopening.

**Rules avoid the classic false alarms.**
- Temperature alerts need several consecutive hot samples, not one spike.
- "Rising temperature" uses a least-squares slope over a time window, so it works at any reporting interval.
- PCIe *generation* is only checked under load, because idle GPUs legitimately drop to a lower generation to save power. Link *width* is always checked.
- Application-class Xids (13, 31, 43) are recorded but do not alert: they usually mean a user's job crashed, not broken hardware. Repeats of a critical Xid escalate to an RMA verdict.
- A node that stops reporting raises a `stale` alert, and its other alerts are left untouched rather than silently resolved.
- Missing GPUs are detected by comparing against the highest count the node has ever reported (or a configured `expected_gpus`).
- A node with a wrong clock is not turned away. Its timestamps are clamped to the collector's clock so its data is kept, and a `clock` warning says how far off it is. Skew is measured from the agent's send time, so a backlog replayed after an outage never looks like a bad clock.
- Identical errors logged in the same second are counted separately, so two rapid Xid 79 lines still add up to the RMA verdict they should instead of collapsing into one.

**One misbehaving component cannot take ingestion down.** Webhooks are delivered from a background thread with a bounded queue, so a hanging Slack endpoint costs ingestion nothing (measured: 0.00 s, against 2.02 s before the change); a malformed webhook URL or a crashing notifier is logged and ignored instead of failing the report. The collector caps concurrent connections and answers the excess with a fast `503 Retry-After`, so a flood of stalled clients cannot exhaust threads; stalled uploads are cut off with a `408`. Anything malformed gets a `400` with a reason and is never a 500.

**Performance was measured, not assumed.** A first benchmark on a fresh database looked excellent, which was misleading: with a realistic amount of history loaded, ingest throughput dropped about tenfold and the 99th-percentile latency reached 44 ms, because several queries scanned a node's whole history instead of seeking. The fixes were an index on `(node, ts)` with the query pinned to it, an index on `ts` for rollups and pruning, fetching only the window each rule needs, recording each node's known GPUs on the node row, a larger page cache, and a higher WAL checkpoint threshold. Regression tests now assert the query plans so this cannot quietly return. See [Capacity](#capacity).

**The collector is also a Prometheus target**, so it slots into an existing Grafana/Alertmanager setup: per-GPU gauges, `fleetwatch_alert{...}` per open alert, and ingest counters. Example alert rules are in `deploy/prometheus-alerts.yml`.

## Quick start

```bash
fleetwatch init --out fleetwatch.json                                   # config with random tokens
fleetwatch serve --config fleetwatch.json                               # collector + dashboard on :8765
fleetwatch agent --server http://127.0.0.1:8765 --token <agent-token>   # on each machine to watch
fleetwatch status --server http://127.0.0.1:8765
```

Then open http://127.0.0.1:8765/. The [setup guide](docs/setup.md) covers watching several computers, running as a service on Linux, Windows or macOS, GPU servers, HTTPS, Slack and Grafana, and troubleshooting. Every option is in the [configuration reference](docs/configuration.md).

## Capacity

`fleetwatch bench` generates synthetic load, optionally pre-loading hours of history so the numbers reflect a collector that has been running for a while, not a fresh one.

Measured on a Windows laptop (Python 3.10, SQLite, single process, database on a local SSD):

| Scenario | History loaded | Ingest latency p50 / p95 / p99 | Maintenance tick | Fleet view | `/metrics` |
|---|---|---|---|---|---|
| 100 nodes x 8 GPUs, in-process | 1.15M samples (193 MB) | 1.1 / 1.4 / 1.8 ms | 0.10 s | 6 ms | 6 ms |
| 500 nodes x 8 GPUs, in-process | 2.88M samples (488 MB) | 1.0 / 1.4 / 2.3 ms | 0.55 s | 28 ms | 30 ms |
| 200 nodes, real HTTP, 8 concurrent clients | 0.77M samples (130 MB) | 15 / 34 / 113 ms (includes queueing) | 0.16 s | 11 ms | 12 ms |
| *100 nodes, before the fixes above* | 1.15M samples | 2.8 / 3.8 / 44 ms | 0.33 s | 92 ms | 104 ms |

In-process throughput ranged from roughly 270 to 820 reports/s across runs on this shared laptop while per-report latency stayed at about 1 ms, so treat a single-threaded ceiling of around 1,000 reports/s as the upper bound and the latency as the reliable figure. A 500-node fleet reporting every 15 seconds is only about 33 reports/s. Growth beyond the 500 nodes I measured is extrapolation: the maintenance tick (which re-evaluates every node) and storage, not ingest, are what would limit a single collector first.

**Storage.** Measured: a raw GPU sample costs about 168 bytes and a 5-minute rollup row about 80 bytes.

| Fleet (8 GPUs/node, 15 s reports) | 48 h of raw samples | 30 days of rollups |
|---|---|---|
| 100 nodes | 9.2M samples, about 1.5 GB | 6.9M rows, about 0.6 GB |
| 500 nodes | 46M samples, about 7.7 GB | 35M rows, about 2.8 GB |

Raw data dominates. Set `retention.raw_hours` to 6 and a 500-node fleet needs about 1 GB of raw storage; the rollups keep the long-term shape.

**Pruning** removes about ten minutes of expired samples per pass in steady state (around 160,000 rows for 500 nodes). Deletion ran at roughly 18,000 to 130,000 rows per second depending on database size. A one-off 2.4-million-row clean-up of a pre-loaded database took about two minutes, in batches, which is not a steady-state event.

## Security model

- Three roles: **agent** tokens may only ingest; the **admin** token may silence alerts and reset a node's expected GPU count; an optional **viewer** token protects every read endpoint, dashboard data and `/metrics` (pass `Authorization: Bearer ...` or `?token=`).
- Tokens are compared in constant time. The collector refuses to start without tokens unless you pass `--insecure`.
- Built-in TLS (1.2 or newer) with certificate and hostname verification on the agent side. Without `--tls-cert`, traffic including tokens is plaintext, so only run that on a trusted network or behind a TLS-terminating proxy.
- Request bodies are size-limited (413), reports are strictly validated (types, ranges, lengths, clock skew) and malformed ones are rejected with a reason instead of stored.
- The dashboard builds its DOM with text nodes, so node names and alert text from agents cannot inject markup.
- Read endpoints are open unless you set a viewer token, because the intended deployment is an internal network. The dashboard passes `?token=` from its own URL to the API.

## API

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /api/v1/ingest` | agent | submit a report |
| `GET /api/v1/fleet` | viewer | every node, status, alerts |
| `GET /api/v1/nodes/{node}` | viewer | GPUs, recent kernel events, alerts |
| `GET /api/v1/nodes/{node}/history?gpu=0&metric=temp&hours=6` | viewer | time series (raw for short ranges, rollups for long ones) |
| `GET /api/v1/alerts?state=open` | viewer | alert list |
| `POST /api/v1/alerts/silence` | admin | `{"key": ..., "minutes": ...}` |
| `POST /api/v1/nodes/{node}/reset-gpus` | admin | accept the current GPU count as normal |
| `POST /api/v1/nodes/{node}/mute` | admin | `{"minutes": ...}`, silence all alerts on the node |
| `POST /api/v1/nodes/{node}/forget` | admin | delete the node and all its data |
| `GET /metrics`, `GET /healthz`, `GET /` | viewer / none / none | Prometheus, liveness, dashboard |

Command line: `serve`, `agent`, `simulate`, `status`, `alerts`, `silence`, `mute`, `forget`, `bench`, `init-config`. `status` exits 0, 1 or 2 for ok, warning or critical, so it can drive another monitoring system.

## Testing

```bash
python -m unittest discover -s tests -v      # 229 tests, about 25 to 40 seconds
```

- **Unit tests** for protocol validation, verdict logic, config, storage (idempotency, rollups, late data, retention) and every rule, using synthetic time series.
- **Fault-injection tests** for the agent: outages, lost acknowledgements, rejected reports, auth failures, corrupt spool files, restarts.
- **End-to-end tests** with a real agent talking HTTP, and HTTPS against a real certificate, to a real collector, including a stalled TLS client.
- **Scenario tests** run a simulated fleet through the full stack and assert each failure (thermal runaway, GPU falling off the bus, ECC degradation, PCIe downgrade, a silent node, application crashes) raises exactly the right alerts while healthy nodes raise none.
- **Performance regression tests** check the query plans and the batched pruning.
- **Hostile-input tests** send malformed `Content-Length` headers, 50,000-deep JSON, integers with 400 digits, lone-surrogate strings, control characters, out-of-range query parameters and bad silence requests over real sockets, and expect a clean 4xx every time. A seeded fuzzer also throws thousands of randomly corrupted reports at validation and storage and requires that nothing other than a validation error ever escapes.
- **Resilience tests** cover a hanging webhook, a crashing notifier, a connection flood, a stalled upload, and the clock-skew, same-second-event and kernel-log timestamp cases.
- **Soak and stress runs** (scripted outside the suite): 24 concurrent writers plus readers and maintenance against a file database stored every report exactly once with zero errors; a simulated day of 40 nodes kept raw storage flat at the retention window and open alerts flat; a restart preserved state and still recognised duplicates; a 5,000-line Xid storm drained completely with no duplicates.

Testing caught real bugs along the way: the rising-temperature rule could never fire at a 15-second reporting interval, the simulator reused sequence numbers between runs, the first benchmark hid a tenfold slowdown that only appears with history loaded, twelve hostile inputs produced 500 errors or unhandled exceptions, a slow webhook stalled ingestion, nodes with a clock more than ten minutes off were silently discarded, and identical same-second Xids undercounted towards an RMA.

### Verified on real hardware and Linux

- **Real GPU:** the agent's exact `nvidia-smi` query ran against an NVIDIA GeForce RTX 4050 Laptop GPU (driver 592.00, Ubuntu 24.04 under WSL2). All twelve fields are valid on that driver, the output parsed and validated, and `[N/A]` values such as ECC on a consumer card are handled. A real agent then reported to a real collector once and in continuous mode.
- **Real kernel log pipeline:** a clearly labelled test Xid line was written to the kernel log (`/dev/kmsg`), recorded by journald, read by the agent through its own `journalctl` query as an unprivileged user, stored with its original timestamp and turned into the correct DRAIN alert. A second agent run did not send it again.
- **Linux:** the full test suite passes on Ubuntu 24.04 (Python 3.12) as well as Windows (Python 3.10). The systemd units pass `systemd-analyze verify` apart from the binary not being installed on the test machine. The code parses as Python 3.9 syntax; the 3.9 run itself happens in CI.

### Limits

fleetwatch has run against one real GPU and a real kernel log, but **not yet on a datacenter cluster**. Data-centre-only behaviour (ECC error counts on H100-class cards, NVLink and NVSwitch errors, genuine Xid storms) has only been exercised through the simulator and NVIDIA's documented formats. Link width is hardware-specific (the laptop GPU above runs at x8), so set `pcie_min_width` to match your servers. After a collector restart, a node that really died is flagged once the grace period ends, about three minutes with default settings. The Xid catalog is a triage aid, not a substitute for NVIDIA's documentation. The Prometheus rules are examples that have not been run against a live Prometheus. It is a single-collector design on SQLite: there is no high availability, and scaling past the low thousands of nodes would mean sharding collectors or moving to a dedicated time-series database. The dashboard has been viewed in one browser. An Xid storm is delivered newest first at up to 500 events per report, so a 5,000-line storm takes about a dozen reporting cycles to arrive in full (the alert fires on the first). If an agent's clock is wrong and its local state is also lost, events it re-sends get fresh clamped timestamps and can be stored twice.
