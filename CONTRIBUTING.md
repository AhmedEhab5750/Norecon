# Contributing to Norecon

Contributions are welcome — whether that's a bug fix, a new passive source,
better webhook support, or just improved docs.

## How to contribute

1. Fork the repo and create a branch off `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes. Keep the script bash-compatible and avoid adding heavy
   dependencies where a lighter approach works.
3. Test your changes locally:
   ```bash
   bash -n recon.sh        # syntax check
   ./recon.sh --check      # confirm dependency detection still works
   ./recon.sh -d example.com  # functional test
   ```
4. Commit with a clear message and open a Pull Request describing:
   - What changed and why
   - Any new dependencies introduced (update `requirements.txt` and README)
5. Submit the PR against `main`.

## Reporting bugs / requesting features

Open an issue with:
- What you expected to happen
- What actually happened (include relevant output/error messages)
- Your OS, bash version, and tool versions if relevant

## Code style

- Use `set -uo pipefail` at the top.
- Prefer clear variable names and inline comments over cleverness.
- Keep functions small and single-purpose where practical.
- Update the README when adding flags, env vars, or new sources/tools.

## Scope

This repo intentionally favors a simple, hackable bash script over a heavier
framework. If a contribution significantly changes that philosophy (e.g.
rewriting in Python, adding a large dependency tree), please open an issue to
discuss first.
