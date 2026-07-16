#!/usr/bin/env bash
#
# norecon.sh — Subdomain enumeration + URL collection pipeline
#
# Run './norecon.sh -h' for the full help menu.
# Run './norecon.sh --check' to verify required tools are installed.
# Run './norecon.sh --install' to auto-install what can be auto-installed.
#
# See README.md for manual installation steps (amass, SubEnum, etc.)
# and requirements.txt for the full dependency list.
#
set -uo pipefail

# ---------- defaults ----------
OUTDIR=""
DOMAIN=""
DOMAIN_LIST=""
THREADS=50
RECURSIVE=false
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
GENERIC_WEBHOOK="${GENERIC_WEBHOOK:-}"
NOTIFY_ON="finish"   # finish | stage | both | none
START_STAGE=1        # start from this stage (1-7)

# out-of-scope exclusion
EXCLUDE_LIST=()       # out-of-scope domains/subdomains (repeatable via --exclude)
EXCLUDE_FILE=""       # file with one excluded pattern per line
EXCLUDE_REGEX=""      # built automatically from EXCLUDE_LIST/EXCLUDE_FILE, don't set directly

# curl/wget timeout settings (seconds) - prevents the pipeline from hanging
# forever on a slow or unreachable external service.
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=30
WGET_TIMEOUT=20

usage() {
  cat <<'EOF'
norecon.sh — Subdomain enumeration + URL collection pipeline

USAGE:
  ./norecon.sh -d <domain> [options]
  ./norecon.sh -l <domain_list_file> [options]
  ./norecon.sh --check          Verify required tools are installed
  ./norecon.sh --install        Auto-install what can be auto-installed (Go/pip tools)

TARGET SELECTION:
  -d <domain>          Single target domain (e.g. example.com)
  -l <file>            File with one domain per line (multi-domain mode)

GENERAL OPTIONS:
  -o <dir>             Output directory (default: recon_<domain>_<timestamp>)
  -r                   Enable recursive subfinder enumeration
  -t <num>             httpx threads (default: 50)
  --start-stage <num>  Start from stage N (1-7, default: 1). Skips earlier stages.
  --exclude <sub/domain>   Exclude an out-of-scope subdomain/domain from every stage
                            (repeatable, e.g. --exclude community.example.com)
  --exclude-file <file>    File with one excluded subdomain/domain per line
  -h, --help           Show this help menu

NOTIFICATIONS (webhooks):
  --discord <url>      Send notifications to a Discord webhook URL
  --slack <url>        Send notifications to a Slack incoming webhook URL
  --webhook <url>      Send notifications to a generic JSON webhook (POST {"text": "..."})
  --notify <mode>      When to notify: finish | stage | both | none (default: finish)
                          finish = one message at the end with the summary
                          stage  = a message after every stage completes
                          both   = stage messages + final summary
                          none   = disable notifications even if a webhook is set

  You can also export these instead of passing flags:
    export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
    export SLACK_WEBHOOK="https://hooks.slack.com/services/..."
    export GENERIC_WEBHOOK="https://your-endpoint.example.com/hook"

ENVIRONMENT / API KEYS (optional, improve results):
  SECURITYTRAILS_API_KEY   Used by haktrails
  C99_API_KEY               Used for subdomainfinder.c99.nl

EXAMPLES:
  ./norecon.sh -d example.com -r --discord "$DISCORD_WEBHOOK"
  ./norecon.sh -l domains.txt -t 100 --notify both --slack "$SLACK_WEBHOOK"
  ./norecon.sh -d example.com --start-stage 5
  ./norecon.sh -d example.com --exclude community.example.com --exclude staging.example.com
  ./norecon.sh -d example.com --exclude-file out_of_scope.txt
  ./norecon.sh --check
  ./norecon.sh --install
EOF
  exit 1
}

log()  { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[-]\033[0m $*" >&2; }

# ---------- webhook notifications ----------
# notify <event_type:stage|finish> <message>
# Backgrounded + timed out so a slow/dead webhook never blocks recon stages.
notify() {
  local event="$1"
  local msg="$2"

  [[ "$NOTIFY_ON" == "none" ]] && return 0
  if [[ "$event" == "stage" && "$NOTIFY_ON" != "stage" && "$NOTIFY_ON" != "both" ]]; then
    return 0
  fi
  if [[ "$event" == "finish" && "$NOTIFY_ON" != "finish" && "$NOTIFY_ON" != "both" ]]; then
    return 0
  fi

  if [[ -n "$DISCORD_WEBHOOK" ]]; then
    ( curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$msg" '{content: $c}')" \
        "$DISCORD_WEBHOOK" >/dev/null 2>&1 & )
  fi

  if [[ -n "$SLACK_WEBHOOK" ]]; then
    ( curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$msg" '{text: $t}')" \
        "$SLACK_WEBHOOK" >/dev/null 2>&1 & )
  fi

  if [[ -n "$GENERIC_WEBHOOK" ]]; then
    ( curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$msg" '{text: $t}')" \
        "$GENERIC_WEBHOOK" >/dev/null 2>&1 & )
  fi
}

# ---------- tool check ----------
check_tools() {
  local tools=(subfinder assetfinder amass httpx katana gospider waymore gau urlfinder anew waybackurls haktrails jq curl wget)
  local missing=()
  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done

  # SubEnum is checked separately since it may be named `subenum` or `subenum.sh`
  if ! command -v subenum >/dev/null 2>&1 && ! command -v subenum.sh >/dev/null 2>&1; then
    missing+=("subenum")
  fi

  if [ ${#missing[@]} -eq 0 ]; then
    ok "All required tools are installed."
  else
    warn "Missing tools: ${missing[*]}"
    echo
    echo "Run './norecon.sh --install' to auto-install Go/pip tools."
    echo "amass and SubEnum need manual installation - see README.md for exact steps."
    echo
    echo "Install hints (Go-based tools):"
    echo "  go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    echo "  go install -v github.com/tomnomnom/assetfinder@latest"
    echo "  go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest"
    echo "  go install -v github.com/projectdiscovery/katana/cmd/katana@latest"
    echo "  go install -v github.com/jaeles-project/gospider@latest"
    echo "  go install -v github.com/lc/gau/v2/cmd/gau@latest"
    echo "  go install -v github.com/projectdiscovery/urlfinder/cmd/urlfinder@latest"
    echo "  go install -v github.com/tomnomnom/anew@latest"
    echo "  go install -v github.com/tomnomnom/waybackurls@latest"
    echo "  go install -v github.com/hakluke/haktrails@latest"
    echo "  pip install waymore --break-system-packages"
    echo
    echo "Manual-only (see README.md):"
    echo "  amass:   brew tap owasp-amass/homebrew-amass && brew install amass"
    echo "           (or download a release binary from github.com/owasp-amass/amass/releases)"
    echo "  SubEnum: git clone https://github.com/bing0o/SubEnum.git && cd SubEnum && ./setup.sh"
  fi
}

if [[ "${1:-}" == "--check" ]]; then
  check_tools
  exit 0
fi

# ---------- auto-install (only what's safely scriptable) ----------
install_tools() {
  echo "Installing Go-based tools (requires Go installed)..."
  command -v go >/dev/null 2>&1 || { err "Go is not installed. Install Go first: https://go.dev/dl/"; exit 1; }

  go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
  go install -v github.com/tomnomnom/assetfinder@latest
  go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
  go install -v github.com/projectdiscovery/katana/cmd/katana@latest
  go install -v github.com/jaeles-project/gospider@latest
  go install -v github.com/lc/gau/v2/cmd/gau@latest
  go install -v github.com/projectdiscovery/urlfinder/cmd/urlfinder@latest
  go install -v github.com/tomnomnom/anew@latest
  go install -v github.com/tomnomnom/waybackurls@latest
  go install -v github.com/hakluke/haktrails@latest

  echo
  echo "Installing pip-based tools..."
  command -v pip >/dev/null 2>&1 || command -v pip3 >/dev/null 2>&1 || { warn "pip not found, skipping waymore"; }
  pip install waymore --break-system-packages 2>/dev/null || pip3 install waymore --break-system-packages 2>/dev/null

  echo
  ok "Go/pip tools installed (check that \$GOPATH/bin or \$HOME/go/bin is in your PATH)."
  warn "amass and SubEnum require manual installation - see README.md for exact steps."
}

if [[ "${1:-}" == "--install" ]]; then
  install_tools
  exit 0
fi

# ---------- arg parsing (supports long options) ----------
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DOMAIN="$2"; shift 2 ;;
    -l) DOMAIN_LIST="$2"; shift 2 ;;
    -o) OUTDIR="$2"; shift 2 ;;
    -r) RECURSIVE=true; shift ;;
    -t) THREADS="$2"; shift 2 ;;
    --start-stage) START_STAGE="$2"; shift 2 ;;
    --exclude) EXCLUDE_LIST+=("$2"); shift 2 ;;
    --exclude-file) EXCLUDE_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    --discord) DISCORD_WEBHOOK="$2"; shift 2 ;;
    --slack) SLACK_WEBHOOK="$2"; shift 2 ;;
    --webhook) GENERIC_WEBHOOK="$2"; shift 2 ;;
    --notify) NOTIFY_ON="$2"; shift 2 ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$DOMAIN" && -z "$DOMAIN_LIST" ]]; then
  err "You must provide either -d <domain> or -l <domain_list_file>"
  usage
fi

# ---------- build the out-of-scope exclusion regex ----------
# EXCLUDE_FILE is read relative to the CWD at invocation time, i.e. before
# we cd into OUTDIR below - so a relative path like "out_of_scope.txt"
# refers to the directory norecon.sh was launched from.
if [[ -n "$EXCLUDE_FILE" ]]; then
  if [[ -f "$EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      line="$(echo "$line" | tr -d '[:space:]')"
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      EXCLUDE_LIST+=("$line")
    done < "$EXCLUDE_FILE"
  else
    warn "--exclude-file '$EXCLUDE_FILE' not found, ignoring"
  fi
fi

if [[ ${#EXCLUDE_LIST[@]} -gt 0 ]]; then
  for pat in "${EXCLUDE_LIST[@]}"; do
    [[ -z "$pat" ]] && continue
    esc=$(echo "$pat" | tr 'A-Z' 'a-z' | sed 's/\./\\./g')
    if [[ -n "$EXCLUDE_REGEX" ]]; then
      EXCLUDE_REGEX="${EXCLUDE_REGEX}|(^|\\.)${esc}\$"
    else
      EXCLUDE_REGEX="(^|\\.)${esc}\$"
    fi
  done
fi

DATE_TAG=$(date +%Y%m%d_%H%M%S)
if [[ -z "$OUTDIR" ]]; then
  if [[ -n "$DOMAIN" ]]; then
    OUTDIR="recon_${DOMAIN}_${DATE_TAG}"
  else
    OUTDIR="recon_multi_${DATE_TAG}"
  fi
fi

mkdir -p "$OUTDIR"/{raw,subs,urls,httpx,tech}
cd "$OUTDIR" || exit 1

# build the list of target domains we iterate over for per-domain sources
# (moved BEFORE the first notify call so the "started for: ..." message
# actually has targets.txt to read from)
if [[ -n "$DOMAIN" ]]; then
  echo "$DOMAIN" > targets.txt
else
  cp "../$DOMAIN_LIST" targets.txt 2>/dev/null || cp "$DOMAIN_LIST" targets.txt
fi

TARGETS_FILE="targets.txt"

log "Output directory: $(pwd)"
if [[ -n "$EXCLUDE_REGEX" ]]; then
  log "Out-of-scope exclusions active: ${EXCLUDE_LIST[*]}"
fi
notify "stage" "🚀 norecon.sh started for: $(cat targets.txt 2>/dev/null | tr '\n' ' ')"

# =========================================================
# STAGE 1 — Passive subdomain sources (per-domain APIs)
# =========================================================

if [[ $START_STAGE -le 1 ]]; then

fetch_urlscan() {
  local d="$1"
  log "urlscan.io -> $d"
  curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    "https://urlscan.io/api/v1/search/?q=domain:$d&size=10000" \
    | jq -r '.results[]?.page.domain' 2>/dev/null \
    | grep -i "\.$d\$\|^$d\$" >> raw/urlscan.txt
}

fetch_otx() {
  local d="$1"
  log "otx.alienvault.com -> $d"
  curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    "https://otx.alienvault.com/api/v1/indicators/domain/$d/passive_dns" \
    | jq -r '.passive_dns[]?.hostname' 2>/dev/null >> raw/otx.txt
}

fetch_jldc() {
  local d="$1"
  log "jldc.me -> $d"
  curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    "https://jldc.me/anubis/subdomains/$d" \
    | jq -r '.[]?' 2>/dev/null >> raw/jldc.txt
}

fetch_crtsh() {
  local d="$1"
  log "crt.sh -> $d"
  # crt.sh can be slow/flaky and return very large JSON for big orgs -
  # give it a longer max-time than the other sources.
  curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 \
    "https://crt.sh/?q=%25.$d&output=json" \
    | jq -r '.[]?.name_value' 2>/dev/null \
    | sed 's/\*\.//g' >> raw/crtsh.txt
}

fetch_c99() {
  local d="$1"
  if [[ -n "${C99_API_KEY:-}" ]]; then
    log "subdomainfinder.c99.nl -> $d"
    curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      "https://api.c99.nl/subdomainfinder?key=${C99_API_KEY}&domain=$d&json" \
      | jq -r '.subdomains[]?.subdomain' 2>/dev/null >> raw/c99.txt
  else
    warn "Skipping c99.nl (set C99_API_KEY to enable)"
  fi
}

fetch_shrewdeye() {
  local d="$1"
  log "shrewdeye.app -> $d"
  wget -q --timeout="$WGET_TIMEOUT" --tries=1 \
    "https://shrewdeye.app/domains/${d}.txt" -O "raw/shrewdeye_${d}.txt"
  if [[ -s "raw/shrewdeye_${d}.txt" ]]; then
    cat "raw/shrewdeye_${d}.txt" >> raw/shrewdeye.txt
  fi
  rm -f "raw/shrewdeye_${d}.txt"
}

fetch_haktrails() {
  local d="$1"
  if command -v haktrails >/dev/null 2>&1 && [[ -n "${SECURITYTRAILS_API_KEY:-}" ]]; then
    log "securitytrails (haktrails) -> $d"
    echo "$d" | haktrails subdomains >> raw/haktrails.txt 2>/dev/null
  else
    warn "Skipping haktrails (install it + set SECURITYTRAILS_API_KEY to enable)"
  fi
}

fetch_subenum() {
  local d="$1"
  local bin=""
  if command -v subenum >/dev/null 2>&1; then
    bin="subenum"
  elif command -v subenum.sh >/dev/null 2>&1; then
    bin="subenum.sh"
  elif [[ -x "./subenum.sh" ]]; then
    bin="./subenum.sh"
  fi

  if [[ -n "$bin" ]]; then
    log "SubEnum -> $d"
    "$bin" -d "$d" -r -o "raw/subenum_${d}.txt" 2>/dev/null
    [[ -s "raw/subenum_${d}.txt" ]] && cat "raw/subenum_${d}.txt" >> raw/subenum.txt
  else
    warn "Skipping SubEnum (not found - see README.md to install)"
  fi
}

log "=== STAGE 1: passive per-domain sources ==="
while read -r d; do
  [[ -z "$d" ]] && continue
  fetch_urlscan "$d"
  fetch_otx "$d"
  fetch_jldc "$d"
  fetch_crtsh "$d"
  fetch_c99 "$d"
  fetch_shrewdeye "$d"
  fetch_haktrails "$d"
  fetch_subenum "$d"
done < "$TARGETS_FILE"
notify "stage" "✅ Stage 1 done: passive per-domain sources collected"

fi  # END STAGE 1

# =========================================================
# STAGE 2
# =========================================================

if [[ $START_STAGE -le 2 ]]; then

log "=== STAGE 2: subfinder / assetfinder / amass ==="

if [[ -n "$DOMAIN" ]]; then
  log "subfinder -> $DOMAIN"
  if $RECURSIVE; then
    subfinder -d "$DOMAIN" -all -recursive -o raw/subfinder.txt
  else
    subfinder -d "$DOMAIN" -all -o raw/subfinder.txt
  fi

  log "assetfinder -> $DOMAIN"
  echo "$DOMAIN" | assetfinder --subs-only >> raw/assetfinder.txt

  log "amass -> $DOMAIN"
  amass enum -passive -d "$DOMAIN" -o raw/amass.txt
else
  log "subfinder -dL $DOMAIN_LIST"
  if $RECURSIVE; then
    subfinder -dL "$TARGETS_FILE" -all -recursive -o raw/subfinder.txt
  else
    subfinder -dL "$TARGETS_FILE" -all -o raw/subfinder.txt
  fi

  log "assetfinder (looped) -> $TARGETS_FILE"
  while read -r d; do
    [[ -z "$d" ]] && continue
    echo "$d" | assetfinder --subs-only >> raw/assetfinder.txt
  done < "$TARGETS_FILE"

  log "amass (looped) -> $TARGETS_FILE"
  while read -r d; do
    [[ -z "$d" ]] && continue
    amass enum -passive -d "$d" -o - >> raw/amass.txt
  done < "$TARGETS_FILE"
fi
notify "stage" "✅ Stage 2 done: subfinder / assetfinder / amass complete"

fi  # END STAGE 2

# =========================================================
# STAGE 3 — Web Archive (CDX + waybackurls)
# =========================================================

if [[ $START_STAGE -le 3 ]]; then

log "=== STAGE 3: web archive ==="
while read -r d; do
  [[ -z "$d" ]] && continue
  log "web.archive.org CDX -> $d"
  wget -q --timeout="$WGET_TIMEOUT" --tries=1 -O - \
    "https://web.archive.org/cdx/search/cdx?url=${d}&matchType=domain&fl=original&collapse=urlkey" \
    >> raw/cdx_raw.txt
done < "$TARGETS_FILE"

if command -v waybackurls >/dev/null 2>&1; then
  log "waybackurls (bulk) -> $TARGETS_FILE"
  cat "$TARGETS_FILE" | waybackurls | tee raw/wayback.txt > /dev/null
else
  warn "waybackurls not found, skipping"
fi

# extract hostnames from the raw archive URL dumps -> contributes to subdomain list
cat raw/cdx_raw.txt raw/wayback.txt 2>/dev/null \
  | grep -oP '(?<=://)[^/]+' \
  | sed 's/:.*//' \
  >> raw/archive_hosts.txt
notify "stage" "✅ Stage 3 done: web archive collection complete"

fi  # END STAGE 3

# =========================================================
# STAGE 4 — Merge & dedupe subdomains
# =========================================================

if [[ $START_STAGE -le 4 ]]; then

log "=== STAGE 4: merge + dedupe subdomains ==="

cat raw/urlscan.txt raw/otx.txt raw/jldc.txt raw/crtsh.txt raw/c99.txt \
    raw/shrewdeye.txt raw/haktrails.txt raw/subenum.txt \
    raw/subfinder.txt raw/assetfinder.txt raw/amass.txt \
    raw/archive_hosts.txt 2>/dev/null \
  | sed 's/^\*\.//' \
  | tr 'A-Z' 'a-z' \
  | grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' \
  | sort -u > subs/subs_all_raw.txt

# filter to only hosts belonging to one of our target domains (avoid noise from unrelated hosts)
> subs/subsnew.txt
while read -r d; do
  [[ -z "$d" ]] && continue
  grep -E "(^|\.)$(echo "$d" | sed 's/\./\\./g')\$" subs/subs_all_raw.txt >> subs/subsnew.txt
done < "$TARGETS_FILE"

cat subs/subsnew.txt | anew subs/subsnew_deduped.txt > /dev/null
mv subs/subsnew_deduped.txt subs/subsnew.txt
sort -u -o subs/subsnew.txt subs/subsnew.txt

# drop out-of-scope subdomains/domains before they ever reach later stages
if [[ -n "$EXCLUDE_REGEX" ]]; then
  grep -viE "$EXCLUDE_REGEX" subs/subsnew.txt > subs/subsnew.tmp || true
  mv subs/subsnew.tmp subs/subsnew.txt
  ok "Applied out-of-scope exclusions to subsnew.txt: ${EXCLUDE_LIST[*]}"
fi

ok "Total unique subdomains: $(wc -l < subs/subsnew.txt)"
notify "stage" "✅ Stage 4 done: $(wc -l < subs/subsnew.txt) unique subdomains found"

fi  # END STAGE 4

# =========================================================
# STAGE 5 — Probe live hosts (httpx)
# =========================================================

if [[ $START_STAGE -le 5 ]]; then

log "=== STAGE 5: httpx probing ==="
cat subs/subsnew.txt | httpx -silent -threads "$THREADS" -o httpx/httpx.txt

# safety net in case an excluded host got into subsnew.txt some other way
# (e.g. subsnew.txt was supplied/edited manually before this stage ran)
if [[ -n "$EXCLUDE_REGEX" && -f httpx/httpx.txt ]]; then
  grep -viE "$EXCLUDE_REGEX" httpx/httpx.txt > httpx/httpx.tmp || true
  mv httpx/httpx.tmp httpx/httpx.txt
fi

ok "Live hosts: $(wc -l < httpx/httpx.txt)"
notify "stage" "✅ Stage 5 done: $(wc -l < httpx/httpx.txt) live hosts found"

fi  # END STAGE 5

# =========================================================
# STAGE 6 — URL collection (katana, gospider, waymore, gau, urlfinder)
# =========================================================

if [[ $START_STAGE -le 6 ]]; then

log "=== STAGE 6: URL collection ==="

if [[ -s httpx/httpx.txt ]]; then
  log "katana"
  if [[ -n "$EXCLUDE_REGEX" ]]; then
    katana -list httpx/httpx.txt -cos "$EXCLUDE_REGEX" -o urls/katana.txt
  else
    katana -list httpx/httpx.txt -o urls/katana.txt
  fi

  log "gospider"
  gospider -S httpx/httpx.txt -o /dev/null \
    | sed -n 's/.*\(https:\/\/[^ ]*\)].*/\1/p' >> urls/gospider.txt

  log "gau"
  cat httpx/httpx.txt | gau --o urls/gau.txt

  log "urlfinder"
  urlfinder -list httpx/httpx.txt -all -o urls/urlfinder.txt
else
  warn "httpx/httpx.txt is empty, skipping crawler stages"
fi

if command -v waymore >/dev/null 2>&1; then
  while read -r d; do
    [[ -z "$d" ]] && continue
    log "waymore -> $d"
    waymore -i "$d" -mode U -oU "urls/waymore_${d}.txt"
  done < "$TARGETS_FILE"
  cat urls/waymore_*.txt 2>/dev/null >> urls/waymore.txt
else
  warn "waymore not found, skipping"
fi

cat urls/katana.txt raw/cdx_raw.txt urls/gospider.txt urls/waymore.txt urls/gau.txt urls/urlfinder.txt 2>/dev/null \
  > urls/urls_combined.txt
cat urls/urls_combined.txt | anew urls/allurls.txt > /dev/null
sort -u -o urls/allurls.txt urls/allurls.txt
rm -f urls/urls_combined.txt

# gospider/gau/urlfinder/waymore/CDX all pull from sources that don't respect
# katana's -cos, so re-filter the merged URL list as a final backstop
if [[ -n "$EXCLUDE_REGEX" && -f urls/allurls.txt ]]; then
  grep -viE "$EXCLUDE_REGEX" urls/allurls.txt > urls/allurls.tmp || true
  mv urls/allurls.tmp urls/allurls.txt
fi

ok "Total unique URLs: $(wc -l < urls/allurls.txt)"
notify "stage" "✅ Stage 6 done: $(wc -l < urls/allurls.txt) unique URLs collected"

fi  # END STAGE 6

# =========================================================
# STAGE 7 — Tech stack detection (outdated CMS)
# =========================================================

if [[ $START_STAGE -le 7 ]]; then

log "=== STAGE 7: tech stack detection ==="
cat subs/subsnew.txt | httpx -silent -title -tech-detect -status-code -o tech/tech_full.txt
grep -i "Joomla\|Drupal\|WordPress" tech/tech_full.txt > tech/cms_hits.txt || true

ok "CMS matches saved to tech/cms_hits.txt ($(wc -l < tech/cms_hits.txt 2>/dev/null || echo 0) hits)"
notify "stage" "✅ Stage 7 done: tech detection complete ($(wc -l < tech/cms_hits.txt 2>/dev/null || echo 0) CMS hits)"

fi  # END STAGE 7

# =========================================================
# Summary
# =========================================================
SUB_COUNT=$(wc -l < subs/subsnew.txt 2>/dev/null || echo 0)
LIVE_COUNT=$(wc -l < httpx/httpx.txt 2>/dev/null || echo 0)
URL_COUNT=$(wc -l < urls/allurls.txt 2>/dev/null || echo 0)
CMS_COUNT=$(wc -l < tech/cms_hits.txt 2>/dev/null || echo 0)

echo
ok "================ DONE ================"
echo "  Subdomains:       $(pwd)/subs/subsnew.txt"
echo "  Live hosts:       $(pwd)/httpx/httpx.txt"
echo "  All URLs:         $(pwd)/urls/allurls.txt"
echo "  Tech detect:      $(pwd)/tech/tech_full.txt"
echo "  CMS hits:         $(pwd)/tech/cms_hits.txt"
echo "======================================="

FINAL_MSG="🏁 Recon finished for $(cat targets.txt 2>/dev/null | tr '\n' ' ')
Subdomains: $SUB_COUNT | Live hosts: $LIVE_COUNT | URLs: $URL_COUNT | CMS hits: $CMS_COUNT
Output dir: $(pwd)"
notify "finish" "$FINAL_MSG"
