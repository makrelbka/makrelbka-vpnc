# shellcheck shell=bash
# Failover guard for vpnc: keeps traffic on the priority server and moves it to the backup
# group only when real requests stop getting answers. Pings are not used to decide that —
# a single lost probe says little, a pile of connections that sent data and got nothing
# back says a lot. Returns to the priority server only after a hold time and a few good
# probes, so a flaky server does not make traffic bounce.
#
# FAILOVER is a plain select group [PRIMARY, BACKUP]; this loop is the only thing that moves it.

GUARD_INTERVAL="${VPNC_GUARD_INTERVAL:-5}"        # seconds between samples
GUARD_STALL_COUNT="${VPNC_GUARD_STALL_COUNT:-4}"  # stalled connections that count as "network is down"
GUARD_BAD_SAMPLES="${VPNC_GUARD_BAD_SAMPLES:-3}"  # consecutive bad samples before switching
GUARD_HOLD_SEC="${VPNC_GUARD_HOLD_SEC:-300}"      # minimum time on the backup before returning
GUARD_RETURN_OK="${VPNC_GUARD_RETURN_OK:-3}"      # good probes in a row needed to return
GUARD_PROBE_EVERY="${VPNC_GUARD_PROBE_EVERY:-30}" # seconds between return probes

GUARD_RETRIES="${VPNC_GUARD_RETRIES:-4}"          # attempts to reach the priority server before giving up on it
GUARD_RETRY_TIMEOUT="${VPNC_GUARD_RETRY_TIMEOUT:-8000}"  # ms per attempt
GUARD_RETRY_PAUSE="${VPNC_GUARD_RETRY_PAUSE:-3}"  # seconds between attempts
GUARD_CONFIRM_MAX="${VPNC_GUARD_CONFIRM_MAX:-3}"  # "server answers, requests still stall" rounds before switching anyway

GUARD_PREV='{}'; GUARD_BAD=0; GUARD_CONFIRMED=0; GUARD_SINCE=0; GUARD_OK=0; GUARD_LAST_PROBE=0

guard_now() { date +%s; }
guard_sleep() { sleep "$1"; }

# guard_sample LEAF PREV_JSON < connections-json  ->  {stalled, healthy, prev}
# stalled: sent data, got none, seen for 2..12 samples (older ones are just idle sockets);
# healthy: received more bytes since the previous sample. prev carries id -> {d: download, n: samples seen}.
guard_sample() {
  jq -c --arg leaf "$1" --argjson prev "$2" '
    (.connections // [] | map(select(.chains[0] == $leaf))) as $c
    | {stalled: ($c | map(select(.upload > 0 and .download == 0
                                 and (($prev[.id].n // 0) >= 2) and (($prev[.id].n // 0) <= 12))) | length),
       healthy: ($c | map(select(.download > ($prev[.id].d // 0))) | length),
       prev: ($c | map({key: .id, value: {d: .download, n: (($prev[.id].n // 0) + 1)}}) | from_entries)}'
}

# guard_probe NAME TIMEOUT_MS -> 0 when a request through that server got an answer.
guard_probe() {
  local d
  d="$(api_call GET "/providers/proxies/sub/$(uri_encode "$1")/healthcheck?url=$(uri_encode "$PROBE_URL")&timeout=$2" 2>/dev/null | jq -r '.delay // 0' 2>/dev/null || echo 0)"
  (( d > 0 ))
}

# guard_try_primary NAME — before giving up on the priority server, try to reach it for real:
# up to GUARD_RETRIES attempts with a long timeout each. One answer is enough to stay.
guard_try_primary() {
  local i
  for i in $(seq 1 "$GUARD_RETRIES"); do
    guard_probe "$1" "$GUARD_RETRY_TIMEOUT" && return 0
    (( i < GUARD_RETRIES )) && guard_sleep "$GUARD_RETRY_PAUSE"
  done
  return 1
}

guard_select() { # GROUP NAME
  api_call PUT "/proxies/$(uri_encode "$1")" "$(jq -cn --arg n "$2" '{name: $n}')" >/dev/null
}

# guard_step — one iteration; all state is in the GUARD_* globals so it can be tested.
guard_step() {
  local prim cur leaf sample stalled healthy t
  api_call GET /configs >/dev/null 2>&1 || { GUARD_PREV='{}'; return 0; }
  # Only manage the default setup: PROXY on FAILOVER. A server picked by hand is left alone.
  [[ "$(api_call GET /proxies/PROXY 2>/dev/null | jq -r '.now // empty')" == "FAILOVER" ]] || { GUARD_PREV='{}'; return 0; }
  cur="$(api_call GET /proxies/FAILOVER 2>/dev/null | jq -r '.now // empty')"
  [[ -n "$cur" ]] || return 0
  prim="$(primary_name)"
  if [[ -z "$prim" ]]; then
    # The priority server is gone from the subscription: PRIMARY is an empty (REJECT-only) group.
    if [[ "$cur" == "PRIMARY" ]]; then guard_select FAILOVER BACKUP; log "guard: priority server not in the subscription -> BACKUP"; fi
    return 0
  fi
  [[ "$(api_call GET /proxies/PRIMARY | jq -r '.now // empty')" == "$prim" ]] || guard_select PRIMARY "$prim"

  leaf="$(active_chain)"; leaf="${leaf##* → }"
  sample="$(api_call GET /connections | guard_sample "$leaf" "$GUARD_PREV")" || return 0
  GUARD_PREV="$(jq -c '.prev' <<<"$sample")"
  stalled="$(jq -r '.stalled' <<<"$sample")"; healthy="$(jq -r '.healthy' <<<"$sample")"
  if (( healthy == 0 && stalled >= GUARD_STALL_COUNT )); then GUARD_BAD=$((GUARD_BAD + 1)); else GUARD_BAD=0; fi
  (( healthy > 0 )) && GUARD_CONFIRMED=0

  t="$(guard_now)"
  if [[ "$cur" == "PRIMARY" ]]; then
    (( GUARD_BAD >= GUARD_BAD_SAMPLES )) || return 0
    if guard_try_primary "$prim"; then
      # The server itself answers, so the trouble may be elsewhere (one site, DNS): stay,
      # unless this keeps happening while nothing gets through.
      GUARD_BAD=0; GUARD_CONFIRMED=$((GUARD_CONFIRMED + 1))
      if (( GUARD_CONFIRMED < GUARD_CONFIRM_MAX )); then
        log "guard: requests stalled ($stalled) but '$prim' answers a direct attempt -> staying ($GUARD_CONFIRMED/$GUARD_CONFIRM_MAX)"
        return 0
      fi
      log "guard: '$prim' answers attempts but requests keep stalling ($GUARD_CONFIRMED rounds)"
    else
      log "guard: $GUARD_RETRIES attempts to reach '$prim' failed"
    fi
    GUARD_CONFIRMED=0
    # Re-measure the backup group once so it picks its best server before traffic lands on it.
    api_call GET "/group/BACKUP/delay?url=$(uri_encode "$PROBE_URL")&timeout=5000" >/dev/null 2>&1 || true
    guard_select FAILOVER BACKUP
    GUARD_SINCE="$t"; GUARD_OK=0; GUARD_BAD=0; GUARD_PREV='{}'
    log "guard: no replies through '$prim' ($stalled stalled connections) -> BACKUP"
    return 0
  fi

  # On the backup: re-pick if it stalls too, and go back once the priority server answers again.
  if (( GUARD_BAD >= GUARD_BAD_SAMPLES )); then
    api_call GET "/group/BACKUP/delay?url=$(uri_encode "$PROBE_URL")&timeout=5000" >/dev/null 2>&1 || true
    GUARD_BAD=0; GUARD_PREV='{}'
    log "guard: no replies through the backup either ('$leaf'), re-measuring it"
  fi
  (( t - GUARD_SINCE >= GUARD_HOLD_SEC && t - GUARD_LAST_PROBE >= GUARD_PROBE_EVERY )) || return 0
  GUARD_LAST_PROBE="$t"
  if guard_probe "$prim" 5000; then GUARD_OK=$((GUARD_OK + 1)); else GUARD_OK=0; fi
  if (( GUARD_OK >= GUARD_RETURN_OK )); then
    guard_select FAILOVER PRIMARY
    GUARD_OK=0; GUARD_PREV='{}'
    log "guard: '$prim' answers again -> PRIMARY"
  fi
}

guard_loop() {
  ensure_cmd jq curl
  log "guard started (sample every ${GUARD_INTERVAL}s)"
  while true; do
    guard_step || true
    sleep "$GUARD_INTERVAL"
  done
}
