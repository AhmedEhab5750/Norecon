# Norecon

A bash-based subdomain enumeration and URL collection pipeline for bug bounty
hunting and authorized security testing. Chains together passive sources,
active enumeration tools, and web archive mining into a single automated run -
with live host probing, URL collection, outdated CMS detection, out-of-scope
filtering, and optional Discord/Slack/webhook notifications.

## What it does

```
Passive sources (crt.sh, urlscan.io, OTX, jldc.me, shrewdeye.app, netlas.io, rapiddns.io, ...)
        ↓
Active tools (subfinder, assetfinder, amass)
        ↓
Web archive (CDX API + waybackurls)
        ↓
Merge + dedupe subdomains  →  drop out-of-scope hosts (--exclude)
        ↓
httpx - probe for live hosts  →  re-check out-of-scope hosts
        ↓
URL collection (katana, gospider, gau, urlfinder, waymore)  →  katana crawl-scope + final URL filter
        ↓
Tech stack detection (flags outdated Joomla/Drupal/WordPress)
        ↓
Webhook notification (Discord / Slack / generic) - optional
```

## Quick start

```bash
chmod +x norecon.sh
./norecon.sh --check          # see what's missing on your system
./norecon.sh --install        # auto-install what can be auto-installed
# see "Manual installs" below for amass + SubEnum
./norecon.sh -d example.com -r --discord "$DISCORD_WEBHOOK"
```

Full help menu:
```bash
./norecon.sh -h
```

## Usage

```bash
./norecon.sh -d <domain> [options]              # single target
./norecon.sh -l <domain_list_file> [options]    # multiple targets
./norecon.sh --check                            # dependency check
./norecon.sh --install                          # auto-install Go/pip tools
```

| Flag | Description |
|---|---|
| `-d <domain>` | Single target domain |
| `-l <file>` | File with one domain per line |
| `-o <dir>` | Output directory (default: `recon_<domain>_<timestamp>`) |
| `-r` | Enable recursive subfinder enumeration |
| `-t <num>` | httpx threads (default: 50) |
| `--start-stage <num>` | Start from stage N (1-7, default: 1). Skips earlier stages. |
| `--exclude <sub/domain>` | Exclude an out-of-scope subdomain/domain (repeatable) |
| `--exclude-file <file>` | File with one excluded subdomain/domain per line |
| `--discord <url>` | Discord webhook for notifications |
| `--slack <url>` | Slack webhook for notifications |
| `--webhook <url>` | Generic JSON webhook (`POST {"text": "..."}`) |
| `--notify <mode>` | `finish` \| `stage` \| `both` \| `none` (default: `finish`) |
| `-h`, `--help` | Full help menu |

### Stage breakdown (for --start-stage)

1. Passive subdomain sources (crt.sh, urlscan.io, otx, jldc.me, shrewdeye, netlas.io, rapiddns.io, haktrails, subenum)
2. Active enumeration (subfinder, assetfinder, amass)
3. Web archive collection (CDX API, waybackurls)
4. Merge and dedupe subdomains — out-of-scope exclusions applied here
5. httpx probing - detect live hosts — out-of-scope hosts re-filtered here too
6. URL collection (katana, gospider, waymore, gau, urlfinder) — katana crawl-scope excludes out-of-scope hosts, final merged URL list is re-filtered
7. Tech stack detection (CMS detection - Joomla/Drupal/WordPress)

### Examples

Single domain, run all stages (default):
```bash
./norecon.sh -d example.com
```

Single domain, recursive subfinder, enable Discord notifications:
```bash
./norecon.sh -d example.com -r --discord "$DISCORD_WEBHOOK"
```

Skip stage 1-4 (already have subdomains), jump to httpx probing:
```bash
./norecon.sh -d example.com --start-stage 5
```

Only run URL collection (stage 6):
```bash
./norecon.sh -d example.com --start-stage 6
```

Only run tech detection (stage 7):
```bash
./norecon.sh -d example.com --start-stage 7
```

Multi-domain scan with stage notifications:
```bash
./norecon.sh -l domains.txt -t 100 --notify both --slack "$SLACK_WEBHOOK"
```

Exclude one or more out-of-scope subdomains from every stage:
```bash
./norecon.sh -d example.com --exclude community.example.com --exclude staging.example.com
```

Exclude a whole list of out-of-scope subdomains/domains from a file:
```bash
./norecon.sh -d example.com --exclude-file out_of_scope.txt
```

You can also export webhook URLs instead of passing flags every time:
```bash
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
export SLACK_WEBHOOK="https://hooks.slack.com/services/..."
```

### Optional API keys (improve coverage)
```bash
export SECURITYTRAILS_API_KEY="..."   # enables haktrails (securitytrails.com)
export C99_API_KEY="..."               # enables subdomainfinder.c99.nl
export NETLAS_API_KEY="..."             # enables netlas.io domain search
```
Without these set, the relevant sources are skipped with a warning - nothing breaks.
`rapiddns.io` needs no API key and always runs as part of Stage 1.

## Out-of-scope filtering (`--exclude` / `--exclude-file`)

Bug bounty programs commonly carve out specific subdomains or domains as
out-of-scope. `--exclude` (repeatable) and `--exclude-file` (one pattern per
line, `#` comments and blank lines ignored) let you list those up front so
they're kept out of every stage that could otherwise reintroduce them:

- **Stage 4** — excluded hosts are stripped from `subs/subsnew.txt` right
  after it's built, so they never get probed or crawled at all.
- **Stage 5** — `httpx/httpx.txt` is re-filtered as a safety net, in case
  `subsnew.txt` was supplied or edited manually before this stage ran.
- **Stage 6** — katana is passed `-cos <regex>` (crawl-out-of-scope), so it
  won't follow links into an excluded host even if it discovers them while
  crawling an in-scope page. The final merged `urls/allurls.txt` (which also
  pulls from gospider, gau, urlfinder, waymore, and the CDX archive - none of
  which respect katana's crawl scope) is re-filtered as a last backstop.

Matching is domain-boundary-aware (`community.example.com` won't accidentally
match `notcommunity.example.com`), and patterns are matched case-insensitively.

If no `--exclude`/`--exclude-file` is given, none of this filtering runs and
the pipeline behaves exactly as before.

Example `out_of_scope.txt`:
```
community.example.com
old-blog.example.com
# staging is a separate VDP, not this program
staging.example.com
```

## Output structure

```
recon_<domain>_<timestamp>/
├── targets.txt           # resolved list of domains scanned
├── raw/                  # raw per-source output
├── subs/subsnew.txt      # FINAL deduped subdomain list (out-of-scope hosts removed)
├── httpx/httpx.txt       # live hosts (out-of-scope hosts removed)
├── urls/allurls.txt      # FINAL deduped URL list (out-of-scope hosts removed)
└── tech/
    ├── tech_full.txt     # full httpx -tech-detect output
    └── cms_hits.txt      # filtered Joomla/Drupal/WordPress matches
```

## Installation

### Auto-installable (`./norecon.sh --install`)
Requires Go and Python3/pip already on your system. Installs: subfinder,
assetfinder, httpx, katana, gospider, gau, urlfinder, anew, waybackurls,
haktrails, waymore.

After installing, make sure Go's bin dir is on your `PATH`:
```bash
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc
source ~/.bashrc
```

### Manual installs (no clean package path)

**amass** - no reliable `go install` target on current major versions:
```bash
brew tap owasp-amass/homebrew-amass
brew install amass
```
Or download a release binary from
[github.com/owasp-amass/amass/releases](https://github.com/owasp-amass/amass/releases)
and move it into your `PATH`.

**SubEnum** - standalone bash script with its own dependency installer:
```bash
git clone https://github.com/bing0o/SubEnum.git
cd SubEnum
chmod +x setup.sh
./setup.sh
sudo mv subenum.sh /usr/bin/subenum
```

See [requirements.txt](./requirements.txt) for the full dependency checklist.

## Webhook notifications

**Getting a Discord webhook URL:** Server Settings - Integrations - Webhooks - New Webhook.

**Getting a Slack webhook URL:** [api.slack.com/apps](https://api.slack.com/apps) -
Create New App - Incoming Webhooks - Add New Webhook to Workspace.

**Generic webhook:** any endpoint accepting `POST {"text": "..."}` (e.g. your
own listener, n8n, Zapier, Make).

Control notification frequency with `--notify`:
- `finish` (default) - one message at the end with the run summary
- `stage` - a message after every stage completes
- `both` - both
- `none` - disable even if a webhook URL is set

## Notes

- `-r` enables subfinder's recursive enumeration flag.
- Single domain (`-d`) and multi-domain (`-l`) modes run the identical
  pipeline - multi-domain loops per-domain sources and passes the list
  directly to tools supporting `-dL`.
- `--start-stage` is useful when re-running recon on a target where you already have
  subdomains and just want to collect new URLs or run tech detection.
- `--exclude-file` is read relative to the directory you launch `norecon.sh`
  from (not the output directory), so a relative path keeps working
  regardless of `-o`.

## Disclaimer

This tool is intended for use only against systems and assets you are
explicitly authorized to test - for example, targets in scope of a bug bounty
or VDP program you're enrolled in, or infrastructure you own. See
[DISCLAIMER.md](./DISCLAIMER.md) for the full statement.

## Contributing

Issues and PRs welcome - see [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

[MIT](./LICENSE)
