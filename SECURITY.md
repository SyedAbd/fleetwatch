# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's "Report a vulnerability" button on this repository's Security tab rather than in a public issue. Include the version, how to reproduce it and what an attacker could do.

## Deploying safely

- Generate a config with `fleetwatch init`. It creates random tokens and writes the file readable by its owner only. Never reuse the demo tokens from `samples/`.
- Serve HTTPS (`--tls-cert`, `--tls-key`) or put the collector behind a TLS-terminating proxy; otherwise tokens cross the network in plaintext.
- Read endpoints, the dashboard and `/metrics` are open unless `viewer_token` is set. Keep the collector on an internal network or set one.
- Give agents their token with `--token-file` (a root-only file) rather than on the command line, where other local users can see it.
- The agent runs `nvidia-smi` and reads the kernel journal, so it usually runs as root. It only ever makes outbound requests to the collector.
