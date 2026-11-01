#!/usr/bin/env bash
#
# oci-hunt.sh -- hunt an Oracle Always Free instance until one lands.
#
# Runs forever. The only thing that stops it on a normal day is success.
# Capacity misses, rate limits, network drops and transient server errors are
# all expected and retried indefinitely. It stops early only when continuing
# could not possibly work (your quota is already full, or a credential or OCID
# is wrong), and it tells you which.
#
#   ./oci-hunt.sh discover    print the OCIDs you need
#   ./oci-hunt.sh check       verify the config, make no attempts
#   ./oci-hunt.sh run         hunt until it lands
#
# Needs: the OCI CLI (authenticated), bash 4+, python3 (ships with the CLI).
#
set -uo pipefail

VERSION=1.0.0

# ----------------------------------------------------------------- config
# Everything is overridable from the environment, so the systemd unit can
# supply it all through an EnvironmentFile.

COMPARTMENT_ID="${COMPARTMENT_ID:-${OCI_TENANCY:-}}"
SUBNET_ID="${SUBNET_ID:-}"
IMAGE_ID="${IMAGE_ID:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/oci.pub}"

SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-1}"
MEM_GB="${MEM_GB:-6}"
DISPLAY_NAME="${DISPLAY_NAME:-free-instance}"

# How many attempts per day to sustain. The script measures how long each
# launch call took and sleeps the remainder, so the rate holds steady even
# though a capacity search can take anywhere from 1 to 4 minutes. This is the
# knob to turn; it is what you actually care about.
#   130/day -> an attempt every 11.1 min
#   160/day -> every  9.0 min
#    80/day -> every 18.0 min
ATTEMPTS_PER_DAY="${ATTEMPTS_PER_DAY:-130}"

# Used only when ATTEMPTS_PER_DAY=0, which switches back to a fixed sleep.
MIN_SLEEP="${MIN_SLEEP:-390}"
MAX_SLEEP="${MAX_SLEEP:-450}"

# Absolute floor on the gap between attempts, whatever the pacing says.
PACE_FLOOR="${PACE_FLOOR:-60}"

# 0 = hunt forever. Anything else caps the attempts.
MAX_TRIES="${MAX_TRIES:-0}"

# Hours between "still alive" messages. 0 disables them.
HEARTBEAT_HOURS="${HEARTBEAT_HOURS:-12}"

# An auth error is usually a stale token and clears itself. Give up only after
# this many consecutive ones.
AUTH_RETRIES="${AUTH_RETRIES:-10}"

DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/oci-hunt}"

# ------------------------------------------------------------------ output

_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
info() { printf '%s%s%s %s\n' "$(_c 34)" "[$(ts)]" "$(_c 0)" "$*"; }
ok()   { printf '%s%s%s %s\n' "$(_c 32)" "[$(ts)]" "$(_c 0)" "$*"; }
warn() { printf '%s%s%s %s\n' "$(_c 33)" "[$(ts)]" "$(_c 0)" "$*"; }
err()  { printf '%s%s%s %s\n' "$(_c 31)" "[$(ts)]" "$(_c 0)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# -------------------------------------------------------------- notifying

json_escape() {
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//$'\r'/}
  v=${v//$'\n'/\\n}; v=${v//$'\t'/\\t}
  printf '%s' "$v"
}

discord() {
  [[ -n $DISCORD_WEBHOOK ]] || return 0
  curl -fsS -m 20 -H 'Content-Type: application/json' \
       -d "{\"content\":\"$(json_escape "$1")\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 \
    && info "discord notified" \
    || warn "discord notification failed (the hunt continues)"
}

# ------------------------------------------------------------------- oci

# The OCI CLI is itself written in Python, so if `oci` runs, python3 exists.
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

oci_json() {        # run an oci command, echo its stdout, keep stderr for the caller
  oci "$@" --output json 2>&1
}

# `--raw-output` does NOT unwrap a JSON array: it still prints [ "a", "b" ]
# across several lines. Reading that verbatim sends "[" as a value and the
# service rejects the whole request. Parse it properly instead.
list_ads() {
  local out
  out=$(oci_json iam availability-domain list --compartment-id "$COMPARTMENT_ID") || return 1
  python3 -I -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("data") or []
except Exception:
    sys.exit(1)
names = [r.get("name") for r in rows if r.get("name")]
if not names:
    sys.exit(1)
print("\n".join(names))
' <<<"$out"
}

# Echo the OCID of a live instance with our display name, if there is one.
find_instance() {
  local out
  out=$(oci_json compute instance list --compartment-id "$COMPARTMENT_ID" --all) || return 1
  python3 -I -c '
import json, sys
want = sys.argv[1]
try:
    rows = json.load(sys.stdin).get("data") or []
except Exception:
    sys.exit(1)
for r in rows:
    if r.get("display-name") == want and r.get("lifecycle-state") in ("RUNNING", "PROVISIONING", "STARTING"):
        print(r.get("id", ""))
        sys.exit(0)
sys.exit(1)
' "$DISPLAY_NAME" <<<"$out"
}

public_ip() {       # $1 = instance OCID; waits, the VNIC attaches a moment later
  local n ip out
  for n in $(seq 1 12); do
    out=$(oci_json compute instance list-vnics --instance-id "$1" --compartment-id "$COMPARTMENT_ID") || true
    ip=$(python3 -I -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("data") or []
except Exception:
    sys.exit(0)
for r in rows:
    if r.get("public-ip"):
        print(r["public-ip"]); break
' <<<"$out" 2>/dev/null)
    [[ -n ${ip:-} ]] && { printf '%s' "$ip"; return 0; }
    sleep 5
  done
  printf '(not assigned yet)'
}

launch() {          # $1 = availability domain
  local args=(
    --availability-domain "$1"
    --compartment-id "$COMPARTMENT_ID"
    --shape "$SHAPE"
    --image-id "$IMAGE_ID"
    --subnet-id "$SUBNET_ID"
    --ssh-authorized-keys-file "$SSH_KEY"
  )
  # Fixed shapes reject --shape-config entirely.
  [[ $SHAPE == *.Flex ]] && args+=(--shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}")
  oci compute instance launch "${args[@]}" 2>&1
}

# ------------------------------------------------------------ classifying

# Deciding what a failure means is the whole job. Getting it wrong either
# abandons a hunt that would have worked, or loops forever on something that
# never will.
CAPACITY=capacity RATELIMIT=ratelimit TRANSIENT=transient AUTH=auth FATAL=fatal

classify() {        # $1 = the CLI's combined output
  local o=${1,,}
  case $o in
    *"out of host capacity"*|*"out of capacity"*|*"insufficient capacity"*) echo "$CAPACITY" ;;
    *toomanyrequests*|*"too many requests"*|*"rate limit"*|*'"status": 429'*)  echo "$RATELIMIT" ;;
    *limitexceeded*|*quotaexceeded*|*"service limit"*)                        echo "$FATAL" ;;
    *notauthorizedornotfound*|*invalidparameter*|*cannotparserequest*|*"incorrectly formatted request"*) echo "$FATAL" ;;
    *notauthenticated*|*"authentication failed"*|*'"status": 401'*|*'"status": 403'*) echo "$AUTH" ;;
    *connectionerror*|*"connection aborted"*|*"connection reset"*|*timeout*|*"timed out"*|\
    *"max retries exceeded"*|*"temporarily unavailable"*|*"bad gateway"*|\
    *'"status": 500'*|*'"status": 502'*|*'"status": 503'*|*'"status": 504'*)  echo "$TRANSIENT" ;;
    *) echo "$TRANSIENT" ;;   # unknown: assume it may pass, never abandon the hunt
  esac
}

api_message() {     # pull the human-readable reason out of an error body
  sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$1" | head -1
}

# ----------------------------------------------------------------- config

# Sleep long enough that this attempt plus its wait equals one target cycle.
# $1 = seconds the launch call just took, $2 = backoff multiplier.
compute_nap() {
  local call=$1 mult=$2 target nap jitter
  if (( ATTEMPTS_PER_DAY > 0 )); then
    target=$(( 86400 / ATTEMPTS_PER_DAY ))
    nap=$(( target - call ))
    jitter=$(( target / 20 ))          # +/-5%, so attempts do not land on a grid
    (( jitter > 0 )) && nap=$(( nap - jitter + RANDOM % (2 * jitter + 1) ))
  else
    nap=$(( RANDOM % (MAX_SLEEP - MIN_SLEEP + 1) + MIN_SLEEP ))
  fi
  nap=$(( nap * mult ))
  (( nap < PACE_FLOOR )) && nap=$PACE_FLOOR
  printf '%s' "$nap"
}

trim() { tr -d '[:space:]' <<<"${1:-}"; }

validate() {
  COMPARTMENT_ID=$(trim "$COMPARTMENT_ID")
  SUBNET_ID=$(trim "$SUBNET_ID")
  IMAGE_ID=$(trim "$IMAGE_ID")
  SHAPE=$(trim "$SHAPE")
  OCPUS=$(trim "$OCPUS")
  MEM_GB=$(trim "$MEM_GB")
  DISPLAY_NAME=$(tr -d '\r\n' <<<"$DISPLAY_NAME")

  need oci; need python3; need curl

  local v
  for v in COMPARTMENT_ID SUBNET_ID IMAGE_ID; do
    [[ -n ${!v} ]] || die "$v is not set -- run: $0 discover"
    [[ ${!v} == ocid1.* ]] || die "$v does not look like an OCID: '${!v}'"
  done
  [[ $OCPUS  =~ ^[0-9]+$ ]] || die "OCPUS must be a whole number, got '$OCPUS'"
  [[ $MEM_GB =~ ^[0-9]+$ ]] || die "MEM_GB must be a whole number, got '$MEM_GB'"
  [[ $ATTEMPTS_PER_DAY =~ ^[0-9]+$ ]] || die "ATTEMPTS_PER_DAY must be a whole number"
  (( ATTEMPTS_PER_DAY <= 500 )) || die "ATTEMPTS_PER_DAY above 500 is one attempt every 3 minutes; refusing"
  (( MIN_SLEEP >= 20 )) || die "MIN_SLEEP below 20s will get you rate limited"
  (( MIN_SLEEP <= MAX_SLEEP )) || die "MIN_SLEEP is greater than MAX_SLEEP"

  SSH_KEY="${SSH_KEY/#\~/$HOME}"
  [[ -r $SSH_KEY ]] || die "SSH public key not readable: $SSH_KEY"
  grep -q '^ssh-' "$SSH_KEY" || die "$SSH_KEY is not an SSH public key (use the .pub)"
  # A trailing blank line reads as a second, empty key and the API rejects it.
  [[ $(grep -c . "$SSH_KEY") -eq 1 ]] \
    || die "$SSH_KEY holds $(grep -c . "$SSH_KEY") keys; this wants exactly one"
}

# ------------------------------------------------------------------- state

save_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf 'attempts=%s\nmisses=%s\nstarted=%s\nlast=%s\n' \
    "$ATTEMPTS" "$MISSES" "$STARTED" "$(ts)" > "$STATE_DIR/state" 2>/dev/null || true
}

load_state() {
  ATTEMPTS=0; MISSES=0; STARTED=$(date +%s)
  [[ -r $STATE_DIR/state ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      attempts) ATTEMPTS=${v:-0} ;;
      misses)   MISSES=${v:-0} ;;
      started)  [[ ${v:-} =~ ^[0-9]+$ ]] && STARTED=$v ;;
    esac
  done < "$STATE_DIR/state"
  (( ATTEMPTS > 0 )) && info "resuming: $ATTEMPTS attempts, $MISSES capacity misses so far"
  return 0
}

# ---------------------------------------------------------------- commands

cmd_discover() {
  need oci; need python3
  local t="${COMPARTMENT_ID:-${OCI_TENANCY:-}}"
  if [[ -z $t ]]; then
    t=$(oci_json iam compartment list --limit 1 | python3 -I -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("data") or []
    print(rows[0].get("compartment-id", "") if rows else "")
except Exception:
    pass
') || true
  fi
  [[ -n $t ]] || die "could not determine your tenancy -- set COMPARTMENT_ID or OCI_TENANCY"

  echo; echo "COMPARTMENT_ID=$t"; echo
  echo "# availability domains (all are tried in rotation)"
  list_ads | sed 's/^/  /' || echo "  (none -- check COMPARTMENT_ID)"

  echo; echo "# subnets -- you want a PUBLIC one"
  oci_json network subnet list --compartment-id "$t" --all | python3 -I -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("data") or []
except Exception:
    rows = []
if not rows:
    print("  (none -- create a VCN with the console wizard first)")
for r in rows:
    kind = "PRIVATE (no public IP)" if r.get("prohibit-public-ip-on-vnic") else "public"
    print("  SUBNET_ID=" + str(r.get("id", "")))
    print("      " + str(r.get("display-name", "")) + "  [" + kind + "]")
' || true

  echo; echo "# newest Ubuntu 22.04 image for $SHAPE"
  oci_json compute image list --compartment-id "$t" --shape "$SHAPE" \
      --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
      --sort-by TIMECREATED --sort-order DESC --limit 1 | python3 -I -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("data") or []
except Exception:
    rows = []
for r in rows:
    print("  IMAGE_ID=" + str(r.get("id", "")))
    print("      " + str(r.get("display-name", "")))
' || true
  echo
}

cmd_check() {
  validate
  ok "config looks sane"
  info "shape      $SHAPE  ${OCPUS} OCPU / ${MEM_GB} GB"
  info "name       $DISPLAY_NAME"
  info "ssh key    $SSH_KEY"
  if (( ATTEMPTS_PER_DAY > 0 )); then
    info "pacing     $ATTEMPTS_PER_DAY attempts/day -- one every $(( 86400 / ATTEMPTS_PER_DAY / 60 )) min"
  else
    info "pacing     fixed ${MIN_SLEEP}-${MAX_SLEEP}s between attempts"
  fi
  info "max tries  $( ((MAX_TRIES==0)) && echo "unlimited -- hunts until it lands" || echo "$MAX_TRIES")"

  local ads; ads=$(list_ads) || die "could not list availability domains -- are your credentials valid?"
  ok "credentials work. availability domains:"
  sed 's/^/    /' <<<"$ads"

  local have
  if have=$(find_instance); then
    ok "an instance named '$DISPLAY_NAME' already exists: $have"
    info "a run would exit immediately"
  else
    info "no instance named '$DISPLAY_NAME' yet -- a run would start hunting"
  fi
}

cmd_run() {
  validate
  load_state

  local have
  if have=$(find_instance); then
    ok "'$DISPLAY_NAME' already exists ($have) -- nothing to do"
    return 0
  fi

  mapfile -t ADS < <(list_ads) \
    || die "could not list availability domains -- check your credentials and COMPARTMENT_ID"
  ((${#ADS[@]})) || die "no availability domains returned"

  ok "hunting for $SHAPE ${OCPUS}/${MEM_GB}GB as '$DISPLAY_NAME'"
  info "rotating: ${ADS[*]}"
  info "$( ((MAX_TRIES==0)) && echo "no attempt limit -- this stops when it lands" || echo "stopping after $MAX_TRIES attempts")"
  if (( ATTEMPTS_PER_DAY > 0 )); then
    info "pacing to $ATTEMPTS_PER_DAY attempts/day -- one every $(( 86400 / ATTEMPTS_PER_DAY / 60 )) min"
  else
    info "fixed sleep ${MIN_SLEEP}-${MAX_SLEEP}s between attempts"
  fi
  discord ":mag: OCI hunt started for \`${DISPLAY_NAME}\` (${SHAPE} ${OCPUS}/${MEM_GB}GB). You will hear from me when it lands."

  local i=0 backoff=1 auth_fails=0 last_beat=$SECONDS
  local ad out verdict msg nap

  while :; do
    if (( MAX_TRIES > 0 && ATTEMPTS >= MAX_TRIES )); then
      warn "reached MAX_TRIES=$MAX_TRIES"
      discord ":hourglass: OCI hunt stopped after $ATTEMPTS attempts ($MISSES capacity misses). No instance."
      return 2
    fi

    ad="${ADS[$(( i++ % ${#ADS[@]} ))]}"
    ATTEMPTS=$(( ATTEMPTS + 1 ))
    local call_started=$SECONDS
    out=$(launch "$ad")
    local call_took=$(( SECONDS - call_started ))

    if grep -q '"id"' <<<"$out" && grep -qi 'ocid1.instance' <<<"$out"; then
      local iid ip ssh_line
      iid=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\(ocid1\.instance[^"]*\)".*/\1/p' <<<"$out" | head -1)
      ok "LANDED in $ad after $ATTEMPTS attempts ($MISSES capacity misses)"
      ok "id  $iid"
      ip=$(public_ip "$iid")
      if [[ $ip == ocid* || $ip == *[0-9].[0-9]* ]]; then
        ok "ip  $ip"
        ok "ssh ubuntu@$ip"
        ssh_line="\`ssh -i <your key> ubuntu@${ip}\`"
      else
        warn "no public IP yet -- check the console in a minute"
        ssh_line="no public IP yet; check the console"
      fi
      save_state
      discord ":white_check_mark: **Instance landed**
name: ${DISPLAY_NAME}
where: ${ad}
shape: ${SHAPE} ${OCPUS} OCPU / ${MEM_GB} GB
after: ${ATTEMPTS} attempts, ${MISSES} capacity misses
ip: ${ip}
${ssh_line}"
      return 0
    fi

    verdict=$(classify "$out")
    msg=$(api_message "$out")

    case $verdict in
      "$CAPACITY")
        MISSES=$(( MISSES + 1 )); backoff=1; auth_fails=0
        info "attempt $ATTEMPTS  $ad  out of capacity (miss $MISSES)"
        ;;
      "$RATELIMIT")
        backoff=$(( backoff * 2 )); (( backoff > 8 )) && backoff=8
        auth_fails=0
        warn "attempt $ATTEMPTS  rate limited -- backing off ${backoff}x"
        ;;
      "$AUTH")
        auth_fails=$(( auth_fails + 1 ))
        warn "attempt $ATTEMPTS  auth failed ($auth_fails/$AUTH_RETRIES): ${msg:-no detail}"
        if (( auth_fails >= AUTH_RETRIES )); then
          err "$AUTH_RETRIES consecutive auth failures -- credentials look broken, not stale"
          discord ":warning: OCI hunt stopped: $AUTH_RETRIES auth failures in a row. Check the API key and fingerprint."
          return 3
        fi
        backoff=2
        ;;
      "$FATAL")
        err "unrecoverable: ${msg:-$(head -5 <<<"$out")}"
        err "retrying cannot fix this -- fix the config and start again"
        discord ":octagonal_sign: OCI hunt stopped after $ATTEMPTS attempts.
\`${msg:-request rejected}\`
This is not a capacity problem, so it will not clear on its own."
        return 3
        ;;
      *)
        backoff=1; auth_fails=0
        warn "attempt $ATTEMPTS  transient: ${msg:-$(head -3 <<<"$out" | tr '\n' ' ')}"
        ;;
    esac

    save_state

    if (( HEARTBEAT_HOURS > 0 && SECONDS - last_beat >= HEARTBEAT_HOURS * 3600 )); then
      last_beat=$SECONDS
      discord ":hourglass_flowing_sand: Still hunting \`${DISPLAY_NAME}\` -- ${ATTEMPTS} attempts, ${MISSES} capacity misses, $(( ( $(date +%s) - STARTED ) / 3600 ))h in. No instance yet."
    fi

    nap=$(compute_nap "$call_took" "$backoff")
    info "call took ${call_took}s, sleeping ${nap}s  (cycle $(( call_took + nap ))s)"
    sleep "$nap"
  done
}

# ------------------------------------------------------------------- main

on_signal() {
  warn "stopping on signal after $ATTEMPTS attempts ($MISSES capacity misses)"
  save_state
  exit 0
}
ATTEMPTS=0; MISSES=0; STARTED=$(date +%s)
trap on_signal TERM INT

case "${1:-run}" in
  discover) cmd_discover ;;
  check)    cmd_check ;;
  run)      cmd_run ;;
  version)  echo "oci-hunt $VERSION" ;;
  *)        die "usage: $0 {discover|check|run|version}" ;;
esac
