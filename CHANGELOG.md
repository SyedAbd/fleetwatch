# Changelog

## 1.1.0

Runs on any machine.

- Host metrics on Linux, Windows and macOS (CPU, memory, disk, uptime, load) with disk-full and memory-pressure alerts, so machines without GPUs are monitored too.
- The agent detects its environment: `nvidia-smi` on PATH or in driver locations outside it (WSL, Windows), kernel Xid events on Linux only, and host-only mode when there is no GPU.
- GPU plugins for other vendors through `--gpu-json-cmd`.
- `fleetwatch init` writes a config with fresh random tokens; `fleetwatch demo` runs a collector and simulated fleet in one command; `fleetwatch service` prints systemd, launchd or Windows Task Scheduler setup.
- `--token-file` for agents.
- CI on Linux, Windows and macOS; tagged releases publish a wheel and a multi-architecture container image.

## 1.0.0

First release: agent with durable spool, idempotent collector, rollups and retention, alert lifecycle with silences and node muting, webhook and Prometheus output, TLS, dashboard, simulator and benchmark.
