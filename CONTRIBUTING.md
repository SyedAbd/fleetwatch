# Contributing

Thanks for helping. fleetwatch has one hard rule: **the standard library only**. Anyone should be able to copy it onto a locked-down server and run it, so pull requests must not add runtime dependencies.

## Getting started

```bash
git clone <your fork>
cd fleetwatch
python -m unittest discover -s tests -v     # the whole suite, about half a minute
python -m fleetwatch demo                   # see your change in the dashboard
```

Python 3.9 is the oldest supported version; CI runs Linux, Windows and macOS on 3.9 and 3.12.

## What helps most

- **GPU plugins for other vendors.** The agent accepts any command that prints a JSON list of GPUs (see "Other GPU vendors" in the README). Plugins for AMD (`rocm-smi`), Intel (`xpu-smi`) or Apple silicon are very welcome, ideally with a recorded sample of the tool's output as a test fixture.
- **Real-world output samples.** If parsing fails on your driver or kernel, a sanitised copy of the `nvidia-smi` or kernel log output that broke it is the most useful bug report there is.
- **Xid catalog corrections**, with a link to NVIDIA's documentation.

## Pull requests

- Add or update tests for behaviour you change; new rules should come with a simulator scenario if they can.
- Keep comments for the non-obvious "why", in the existing style.
- Run the full test suite before opening the request.
