#!/usr/bin/env bash
#
# Tests helm/alloy/scripts/mimir-rules-liveness-probe.sh against mock.go, a
# stand-in for the Alloy web API and for a Mimir ruler config API.
#
# Usage: make test-liveness-probe (or ./run-tests.sh)

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE=$HERE/../../helm/alloy/scripts/mimir-rules-liveness-probe.sh

TMP=$(mktemp -d)
MOCK=$TMP/mock
pid=""
# shellcheck disable=SC2329 # invoked through the trap below
cleanup() {
	stop_mock
	rm -rf "$TMP"
}
trap cleanup EXIT

failures=0
alloy=""
ruler=""
# Environment given to the next run_case, reset after every case. RULER in a
# value is replaced with the address of the ruler the mock ends up listening on.
PROBE_ENV=()

start_mock() {
	"$MOCK" "$@" >"$TMP/mock.log" 2>&1 &
	pid=$!
	for _ in $(seq 1 100); do
		alloy=$(grep -o '^alloy=.*' "$TMP/mock.log" | cut -d= -f2)
		if [[ -n $alloy ]]; then
			ruler=$(grep -o '^ruler=.*' "$TMP/mock.log" | cut -d= -f2)
			return 0
		fi
		sleep 0.05
	done
	printf 'mock did not start: %s\n' "$(cat "$TMP/mock.log")"
	return 1
}

stop_mock() {
	[[ -n $pid ]] || return 0
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	pid=""
}

check() {
	local name=$1 want=$2 rc=$3 out=$4
	if [[ $rc == "$want" ]]; then
		printf 'PASS  %-45s rc=%s | %s\n' "$name" "$rc" "${out//$'\n'/ ; }"
	else
		printf 'FAIL  %-45s rc=%s want=%s | %s\n' "$name" "$rc" "$want" "${out//$'\n'/ ; }"
		failures=$((failures + 1))
	fi
}

# run_case NAME WANT_RC [mock args...]
run_case() {
	local name=$1 want=$2 out rc entry
	local -a probe_env=()
	shift 2

	if ! start_mock "$@"; then
		check "$name" "$want" "start-failed" ""
		PROBE_ENV=()
		return
	fi
	for entry in "${PROBE_ENV[@]}"; do
		probe_env+=("${entry//RULER/http://$ruler}")
	done
	out=$(env ALLOY_URL="http://$alloy" "${probe_env[@]}" bash "$PROBE" 2>&1)
	rc=$?
	stop_mock
	PROBE_ENV=()

	check "$name" "$want" "$rc" "$out"
}

go build -C "$HERE" -o "$MOCK" . || exit 1

CREDS=(MIMIR_USERNAME=probe MIMIR_PASSWORD=s3cret)

PROBE_ENV=("${CREDS[@]}")
run_case "healthy + ruler answers" 0 \
	-component 'giantswarm=healthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + ruler answers 200" 1 \
	-component 'giantswarm=unhealthy=RULER'
# A Mimir whose ruler is down answers 502 through its gateway. Restarting Alloy
# then would fight the outage rather than the bug.
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + ruler down behind gateway (502)" 0 \
	-ruler-status 502 -component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + ruler answers 503" 0 \
	-ruler-status 503 -component 'giantswarm=unhealthy=RULER'
# The gateway answers 401 at the edge, up or down, so the probe has to
# authenticate and must not read a 401 as an answer from the ruler.
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + authenticated ruler" 1 \
	-ruler-auth 'probe:s3cret' -component 'giantswarm=unhealthy=RULER'
PROBE_ENV=(MIMIR_USERNAME=probe MIMIR_PASSWORD=wrong)
run_case "unhealthy + wrong credentials (401)" 0 \
	-ruler-auth 'probe:s3cret' -component 'giantswarm=unhealthy=RULER'
run_case "unhealthy + no credentials configured" 0 \
	-ruler-auth 'probe:s3cret' -component 'giantswarm=unhealthy=RULER'
# The ruler is queried as the tenant the component writes rules for.
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + ruler requires the tenant" 1 \
	-tenant-id 'giantswarm' -ruler-tenant 'giantswarm' -component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + ruler unreachable" 0 \
	-component 'giantswarm=unhealthy=http://127.0.0.1:1'
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + https ruler answers" 1 \
	-component 'giantswarm=unhealthy=RULER_TLS'
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + https ruler unreachable" 0 \
	-component 'giantswarm=unhealthy=https://mimir-gateway.invalid'
# Alloy frames its larger API payloads in chunks, which the probe has to decode
# before it can read the component health out of them.
PROBE_ENV=("${CREDS[@]}")
run_case "unhealthy + chunked Alloy API" 1 \
	-chunked -component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "healthy + chunked Alloy API" 0 \
	-chunked -component 'giantswarm=healthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "unknown health" 0 \
	-component 'giantswarm=unknown=RULER'
run_case "no mimir.rules.kubernetes component" 0
PROBE_ENV=("${CREDS[@]}")
run_case "two components, second one broken" 1 \
	-component 'a=healthy=RULER' \
	-component 'b=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "address with a trailing slash" 1 \
	-component 'giantswarm=unhealthy=RULER/'
PROBE_ENV=("${CREDS[@]}")
run_case "address with a hostname" 1 \
	-component 'giantswarm=unhealthy=RULER_LOCALHOST'

# An Alloy API that accepts the connection but never answers must be given up
# on rather than time the probe out, which Kubernetes counts as a failure.
before=$(date +%s)
PROBE_ENV=(HTTP_TIMEOUT=1)
run_case "hung Alloy API" 0 -hang
elapsed=$(($(date +%s) - before))
if [[ $elapsed -le 3 ]]; then
	printf 'PASS  %-45s | %ss\n' "hung Alloy API gives up on time" "$elapsed"
else
	printf 'FAIL  %-45s | %ss\n' "hung Alloy API gives up on time" "$elapsed"
	failures=$((failures + 1))
fi

# Alloy itself being down must never restart it.
out=$(ALLOY_URL="http://127.0.0.1:1" bash "$PROBE" 2>&1)
check "Alloy API down" 0 "$?" "$out"

echo
echo "failures: $failures"
exit $((failures > 0))
