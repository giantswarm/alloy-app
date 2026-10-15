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

passes=0
failures=0
skips=0
alloy=""
ruler=""
last_out=""
# Wall time of the last probe run in milliseconds, and the ports its mock bound.
last_elapsed=0
last_ports=""
# Environment given to the next run_case, reset after every case. RULER in a
# value is replaced with the address of the ruler the mock ends up listening on.
PROBE_ENV=()
# Set to 1 to run the next run_case inside the Alloy image, reset after every case.
PROBE_IN_IMAGE=0
# The Alloy image the chart ships, run read-only like in the pod. Its bash and
# its read-only /tmp are what the probe has to live with.
ALLOY_IMAGE=${ALLOY_IMAGE:-gsoci.azurecr.io/giantswarm/alloy:$(grep -o '^appVersion: .*' "$HERE/../../helm/alloy/Chart.yaml" | cut -d' ' -f2)}

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
		passes=$((passes + 1))
	else
		printf 'FAIL  %-45s rc=%s want=%s | %s\n' "$name" "$rc" "$want" "${out//$'\n'/ ; }"
		failures=$((failures + 1))
	fi
}

# run_case NAME WANT_RC [mock args...]
run_case() {
	local name=$1 want=$2 out rc entry before
	local -a probe_env=()
	shift 2

	# A docker binary without a daemon fails the run with rc 1, which would
	# pass a case expecting 1.
	if ((PROBE_IN_IMAGE)) && ! docker info >/dev/null 2>&1; then
		printf 'SKIP  %-45s | docker is not available\n' "$name"
		skips=$((skips + 1))
		PROBE_ENV=()
		PROBE_IN_IMAGE=0
		return
	fi
	if ! start_mock "$@"; then
		check "$name" "$want" "start-failed" ""
		PROBE_ENV=()
		PROBE_IN_IMAGE=0
		return
	fi
	last_ports=$(grep -o ':[0-9]*$' "$TMP/mock.log" | tr -d : | paste -sd'|')
	probe_env=("ALLOY_URL=http://$alloy")
	for entry in "${PROBE_ENV[@]}"; do
		probe_env+=("${entry//RULER/http://$ruler}")
	done
	before=${EPOCHREALTIME/./}
	if ((PROBE_IN_IMAGE)); then
		out=$(docker run --rm --read-only --network host --entrypoint bash \
			-v "$PROBE:/probe.sh:ro" "${probe_env[@]/#/--env=}" \
			"$ALLOY_IMAGE" /probe.sh 2>&1)
	else
		out=$(env "${probe_env[@]}" bash "$PROBE" 2>&1)
	fi
	rc=$?
	last_elapsed=$(((${EPOCHREALTIME/./} - before) / 1000))
	stop_mock
	PROBE_ENV=()
	PROBE_IN_IMAGE=0

	check "$name" "$want" "$rc" "$out"
	last_out=$out
}

# check_log NAME REGEX
#
# Checks the output of the last run_case matches REGEX.
check_log() {
	if grep -E -- "$2" >/dev/null <<<"$last_out"; then
		printf 'PASS  %-45s | logs %s\n' "$1" "$2"
		passes=$((passes + 1))
	else
		printf 'FAIL  %-45s | does not log %s\n' "$1" "$2"
		failures=$((failures + 1))
	fi
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
# Chunk sizes count bytes, which a UTF-8 locale would read as characters.
PROBE_ENV=("${CREDS[@]}" LC_ALL=C.UTF-8)
run_case "unhealthy + chunked UTF-8 Alloy API" 1 \
	-chunked -original-size 4096 -original-char 'é' -component 'giantswarm=unhealthy=RULER'
# A component carrying a large configuration makes the Alloy API responses
# larger than 64 KiB, which bash 5.2 would buffer in a temporary file under the
# read-only /tmp of the Alloy image.
PROBE_ENV=("${CREDS[@]}")
PROBE_IN_IMAGE=1
run_case "unhealthy + 100 KiB Alloy API in Alloy image" 1 \
	-chunked -original-size 102400 -component 'giantswarm=unhealthy=RULER'
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

# The health message tells the latch from a rule Mimir rejects, which a restart
# would not fix. Messages are the ones mimir.rules.kubernetes v1.20.0 reports,
# rendered by its Mimir client. Each entry is WANT_RC, NAME, MESSAGE.
MESSAGES=(
	1 "latch: GET rules connection refused"
	'Get "http://mimir-gateway.mimir.svc/prometheus/config/v1/rules": dial tcp 10.96.4.12:80: connect: connection refused'
	1 "latch: GET rules no such host"
	'Get "http://mimir-gateway.mimir.svc.invalid/prometheus/config/v1/rules": dial tcp: lookup mimir-gateway.mimir.svc.invalid: no such host'
	1 "latch: GET rules EOF"
	'Get "http://mimir-gateway.mimir.svc/prometheus/config/v1/rules": EOF'
	1 "latch: GET rules TLS handshake timeout"
	'Get "https://mimir.example/prometheus/config/v1/rules": net/http: TLS handshake timeout'
	1 "latch: GET rules answered 500"
	'error GET /prometheus/config/v1/rules: server returned HTTP status 500 Internal Server Error: rpc error: code = Unavailable desc = connection error'
	1 "latch: GET rules answered 502"
	'error GET /prometheus/config/v1/rules: server returned HTTP status 502 Bad Gateway: <html><head><title>502 Bad Gateway</title></head>'
	1 "latch: GET rules answered 503"
	'error GET /prometheus/config/v1/rules: server returned HTTP status 503 Service Unavailable: no healthy upstream'
	1 "latch: GET rules answered 504"
	'error GET /prometheus/config/v1/rules: server returned HTTP status 504 Gateway Timeout: <html><head><title>504 Gateway Time-out</title></head>'
	1 "latch: GET rules answered 429"
	'error GET /prometheus/config/v1/rules: server returned HTTP status 429 Too Many Requests: too many outstanding requests'
	1 "latch: GET legacy rules answered 503"
	'error GET /api/v1/rules: server returned HTTP status 503 Service Unavailable: no healthy upstream'
	# A wrong credential or prefix fails every listing, a restart included.
	0 "GET rules answered 401"
	'error GET /prometheus/config/v1/rules: unrecoverable error response: server returned HTTP status 401 Unauthorized: Unauthorized'
	0 "GET rules answered 404"
	'error GET /api/prom/config/v1/rules: unrecoverable error response: server returned HTTP status 404 Not Found: 404 page not found'
	0 "GET rules answered 200 with HTML"
	$'yaml: unmarshal errors:\n  line 1: cannot unmarshal !!str `<html> ...` into map[string][]client.MimirRuleGroup'
	# Known false negative: a body cut short during the latch is not matched.
	0 "GET rules body cut short"
	'unexpected EOF'
	0 "GET rules body connection reset"
	'read tcp 10.0.3.17:52114->172.31.4.9:8080: read: connection reset by peer'
	0 "rule rejected by Mimir (400)"
	$'1 error occurred:\n\t* error POST /prometheus/config/v1/rules/alloy%2Fmonitoring%2Fmy-rules%2F0b4e7c2a-5d1f-4a7e-9c3b-2f6d8e1a9b0c: unrecoverable error response: server returned HTTP status 400 Bad Request: {"status":"error","errorType":"bad_data","error":"per-user rules per rule group limit (limit: 20 actual: 25) exceeded"}\n\n'
	0 "rule create answered 503"
	$'1 error occurred:\n\t* error POST /prometheus/config/v1/rules/alloy%2Fmonitoring%2Fmy-rules%2F0b4e7c2a-5d1f-4a7e-9c3b-2f6d8e1a9b0c: server returned HTTP status 503 Service Unavailable: no healthy upstream\n\n'
	0 "rule create connection refused"
	$'1 error occurred:\n\t* Post "http://mimir-gateway.mimir.svc/prometheus/config/v1/rules/alloy%2Fmonitoring%2Fmy-rules%2F0b4e7c2a-5d1f-4a7e-9c3b-2f6d8e1a9b0c": dial tcp 10.96.4.12:80: connect: connection refused\n\n'
	0 "rule delete answered 404"
	$'1 error occurred:\n\t* error DELETE /prometheus/config/v1/rules/alloy%2Fmonitoring%2Fmy-rules%2F0b4e7c2a-5d1f-4a7e-9c3b-2f6d8e1a9b0c/example: unrecoverable error response: server returned HTTP status 404 Not Found: group does not exist\n\n'
	0 "rule delete connection refused"
	$'1 error occurred:\n\t* Delete "http://mimir-gateway.mimir.svc/prometheus/config/v1/rules/alloy%2Fmonitoring%2Fmy-rules%2F0b4e7c2a-5d1f-4a7e-9c3b-2f6d8e1a9b0c/example": dial tcp 10.96.4.12:80: connect: connection refused\n\n'
	0 "resync answered 504"
	$'1 error occurred:\n\t* error GET /prometheus/config/v1/rules: server returned HTTP status 504 Gateway Timeout: <html>\n\n'
	0 "resync connection refused"
	$'1 error occurred:\n\t* Get "http://mimir-gateway.mimir.svc/prometheus/config/v1/rules": dial tcp 10.96.4.12:80: connect: connection refused\n\n'
	0 "invalid PromQL"
	$'failed to convert rule group: 1 error occurred:\n\t* 0:0: group "g", rule 1, "HighErrorRate": could not parse expression: 1:51: parse error: unclosed left parenthesis\n\n'
	0 "duplicate rule group"
	$'failed to convert rule group: 1 error occurred:\n\t* 6:3: groupname: "g" is repeated in the same file\n\n'
	0 "invalid recording rule name"
	$'failed to convert rule group: 1 error occurred:\n\t* 0:0: group "g", rule 1, "bad-name": invalid recording rule name: bad-name\n\n'
	0 "k8s config error"
	'failed to get k8s config: invalid configuration: no configuration has been provided, try setting KUBERNETES_MASTER environment variable'
	0 "invalid rule selector"
	"values: Invalid value: null: for 'in', 'notin' operators, values set can't be empty"
	0 "invalid address"
	'parse "http://mimir:80 80": invalid port ":80 80" after host'
	0 "missing CA file"
	'unable to read CA cert: unable to read file /etc/mimir/ca.crt: open /etc/mimir/ca.crt: no such file or directory'
	0 "leader lookup failed"
	'unable to determine leader for mimir.rules.kubernetes.giantswarm: unknown op 3'
	0 "unexpected leadership peers"
	'unexpected peers from leadership check: []'
	0 "component evaluation failed"
	'component evaluation failed: building component: initializing component failed: failed to get k8s config: invalid configuration: no configuration has been provided, try setting KUBERNETES_MASTER environment variable'
)
for ((i = 0; i < ${#MESSAGES[@]}; i += 3)); do
	PROBE_ENV=("${CREDS[@]}")
	run_case "${MESSAGES[i + 1]}" "${MESSAGES[i]}" \
		-message "${MESSAGES[i + 2]}" \
		-component 'giantswarm=unhealthy=RULER'
done
PROBE_ENV=("${CREDS[@]}" 'UNHEALTHY_MESSAGE_PATTERN=error POST')
run_case "rule rejected, custom message pattern" 1 \
	-message $'1 error occurred:\n\t* error POST /prometheus/config/v1/rules/ns: unrecoverable error response: server returned HTTP status 400 Bad Request: bad rule' \
	-component 'giantswarm=unhealthy=RULER'

# The run deadline is internal. A PROBE_DEADLINE in the container environment
# neither fails the probe nor disables its timeout.
PROBE_ENV=("${CREDS[@]}" PROBE_DEADLINE=x)
run_case "PROBE_DEADLINE=x in the environment, healthy" 0 \
	-component 'giantswarm=healthy=RULER'
check_log "PROBE_DEADLINE=x in the environment is ignored" ": healthy$"
PROBE_ENV=("${CREDS[@]}" PROBE_DEADLINE=1)
run_case "PROBE_DEADLINE=1 in the environment, latch" 1 \
	-component 'giantswarm=unhealthy=RULER'

# check_ruler_requests NAME WANT
#
# Checks the mock of the last run_case received WANT ruler requests.
check_ruler_requests() {
	local got
	got=$(grep -c 'ruler request' "$TMP/mock.log")
	if [[ $got == "$2" ]]; then
		printf 'PASS  %-45s | %s ruler requests\n' "$1" "$got"
		passes=$((passes + 1))
	else
		printf 'FAIL  %-45s | %s ruler requests, want %s\n' "$1" "$got" "$2"
		failures=$((failures + 1))
	fi
}

# The latch freezes the health. A rule listing that fails in the running
# component shows the same message, refreshed at least every sync_interval,
# 5m0s when Alloy leaves it out. Without a ruler request for a fresh health.
PROBE_ENV=("${CREDS[@]}")
run_case "latch message, health 30s old" 0 -updated-ago 30s \
	-component 'giantswarm=unhealthy=RULER'
check_log "latch message, health 30s old is logged" ": unhealthy for (29|30|31)s, below 360s, skipping$"
check_ruler_requests "latch message, health 30s old, no ruler query" 0
PROBE_ENV=("${CREDS[@]}")
run_case "latch message, health 350s old" 0 -updated-ago 350s \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "latch message, health 370s old" 1 -updated-ago 370s \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "sync_interval 30s, health 120s old" 1 -sync-interval 30s -updated-ago 120s \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "sync_interval 30s, health 80s old" 0 -sync-interval 30s -updated-ago 80s \
	-component 'giantswarm=unhealthy=RULER'
check_log "sync_interval 30s, health 80s old is logged" ", below 90s, skipping$"
PROBE_ENV=("${CREDS[@]}")
run_case "sync_interval 1m30s, health 160s old" 1 -sync-interval 1m30s -updated-ago 160s \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "sync_interval 1.5s, health 70s old" 1 -sync-interval 1.5s -updated-ago 70s \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}" HEALTH_AGE_MARGIN=1)
run_case "sync_interval 1.5s, margin 1s, health 2s old" 0 -sync-interval 1.5s -updated-ago 2s \
	-component 'giantswarm=unhealthy=RULER'
check_log "sync_interval 1.5s is rounded up to 2s" ", below 3s, skipping$"
PROBE_ENV=("${CREDS[@]}")
run_case "sync_interval 1h0m0s, health 30m old" 0 -sync-interval 1h0m0s -updated-ago 30m \
	-component 'giantswarm=unhealthy=RULER'
check_log "sync_interval 1h0m0s, health 30m old is logged" ", below 3660s, skipping$"
PROBE_ENV=("${CREDS[@]}")
run_case "sync_interval 1h0m0s, health 2h old" 1 -sync-interval 1h0m0s -updated-ago 2h \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}" HEALTH_AGE_MARGIN=600)
run_case "margin 600s, health 400s old" 0 -updated-ago 400s \
	-component 'giantswarm=unhealthy=RULER'
check_log "margin 600s, health 400s old is logged" ", below 900s, skipping$"
# Alloy renders updatedTime in the local zone of the pod, nanoseconds included.
PROBE_ENV=("${CREDS[@]}")
run_case "health 30s old, -07:00 offset" 0 \
	-updated-time "$(TZ=America/Los_Angeles date -d '-30 sec' +%Y-%m-%dT%H:%M:%S.%N%:z)" \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "health 1h old, +05:30 offset" 1 \
	-updated-time "$(TZ=Asia/Kolkata date -d '-1 hour' +%Y-%m-%dT%H:%M:%S.%N%:z)" \
	-component 'giantswarm=unhealthy=RULER'
PROBE_ENV=("${CREDS[@]}")
run_case "health in the future" 0 -updated-ago -1h \
	-component 'giantswarm=unhealthy=RULER'
# An age that cannot be told never restarts Alloy.
for updated in 'yesterday at noon-ish' '2026-13-45T00:00:00Z'; do
	PROBE_ENV=("${CREDS[@]}")
	run_case "unparsable updatedTime ${updated}" 0 -updated-time "$updated" \
		-component 'giantswarm=unhealthy=RULER'
	check_log "unparsable updatedTime ${updated} is logged" "health update time .* could not be read, skipping$"
done
for interval in forever 5m0 500ms; do
	PROBE_ENV=("${CREDS[@]}")
	run_case "unparsable sync_interval ${interval}" 0 -sync-interval "$interval" \
		-component 'giantswarm=unhealthy=RULER'
	check_log "unparsable sync_interval ${interval} is logged" "sync_interval \"${interval}\" could not be read, skipping$"
done

# A timeout that is not a positive number of seconds is a configuration error,
# which must never restart Alloy. `timeout 0` would also disable the timeout.
for setting in HTTP_TIMEOUT=0 HTTP_TIMEOUT=abc HTTP_TIMEOUT=1.5 PROBE_TIMEOUT=0 PROBE_TIMEOUT=-5 PROBE_TIMEOUT=08 \
	HEALTH_AGE_MARGIN=0 HEALTH_AGE_MARGIN=abc HEALTH_AGE_MARGIN=08 HEALTH_AGE_MARGIN=1000000; do
	PROBE_ENV=("${CREDS[@]}" "$setting")
	run_case "invalid ${setting}" 0 \
		-component 'giantswarm=unhealthy=RULER'
	check_log "invalid ${setting} is logged" "^${setting%%=*}=.* is not"
done

# Components sharing a ruler, a tenant and the credentials share one request.
PROBE_ENV=("${CREDS[@]}")
run_case "three components share a ruler" 0 -ruler-status 503 \
	-component 'a=unhealthy=RULER' \
	-component 'b=unhealthy=RULER' \
	-component 'c=unhealthy=RULER'
check_ruler_requests "three components share a ruler, queried once" 1
PROBE_ENV=("${CREDS[@]}")
run_case "two tenants on one ruler" 0 -ruler-status 503 \
	-component 'a=unhealthy=RULER=x' \
	-component 'b=unhealthy=RULER=y' \
	-component 'c=unhealthy=RULER=x'
check_ruler_requests "two tenants on one ruler, queried twice" 2

# run_timed NAME WANT_RC MAX_SECONDS [mock args...]
#
# Runs run_case and checks the probe finished within MAX_SECONDS and left no
# request behind.
run_timed() {
	local name=$1 want=$2 max=$3 elapsed left
	shift 3
	run_case "$name" "$want" "$@"
	elapsed=$(printf '%d.%03d' $((last_elapsed / 1000)) $((last_elapsed % 1000)))
	if ((last_elapsed <= max * 1000)); then
		printf 'PASS  %-45s | %ss\n' "$name gives up on time" "$elapsed"
		passes=$((passes + 1))
	else
		printf 'FAIL  %-45s | %ss, want at most %ss\n' "$name gives up on time" "$elapsed" "$max"
		failures=$((failures + 1))
	fi
	# Killed requests may take a moment to be reaped.
	for _ in $(seq 1 10); do
		left=$(pgrep -af -- "(--http-get|s_client).*127\.0\.0\.1:($last_ports)\b")
		[[ -z $left ]] && break
		sleep 0.05
	done
	if [[ -z $left ]]; then
		printf 'PASS  %-45s |\n' "$name leaves no request behind"
		passes=$((passes + 1))
	else
		printf 'FAIL  %-45s | %s\n' "$name leaves no request behind" "${left//$'\n'/ ; }"
		failures=$((failures + 1))
	fi
}

# Requests to several hung rulers add up. The probe stops at PROBE_TIMEOUT, as
# the kubelet counts a probe timeout as a failure.
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=2 PROBE_TIMEOUT=3)
run_timed "three hung rulers" 0 4 -ruler-hang \
	-component 'a=unhealthy=RULER' \
	-component 'b=unhealthy=RULER' \
	-component 'c=unhealthy=RULER'
# Distinct tenants are distinct requests, which add up past PROBE_TIMEOUT.
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=2 PROBE_TIMEOUT=5)
run_timed "four hung tenants" 0 6 -ruler-hang \
	-component 'a=unhealthy=RULER=a' \
	-component 'b=unhealthy=RULER=b' \
	-component 'c=unhealthy=RULER=c' \
	-component 'd=unhealthy=RULER=d'
# A hung ruler shared by several components is waited for once, which leaves
# time for a later component.
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=2 PROBE_TIMEOUT=5)
run_timed "shared hung ruler, later component checked" 1 3 \
	-component 'a=unhealthy=http://SILENT' \
	-component 'b=unhealthy=http://SILENT' \
	-component 'c=unhealthy=http://SILENT' \
	-component 'd=unhealthy=RULER'
# A hung ruler may spend the whole budget, later components are not checked.
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=3 PROBE_TIMEOUT=3)
run_timed "budget spent mid-loop" 0 4 \
	-component 'a=unhealthy=http://SILENT' \
	-component 'b=unhealthy=RULER'
check_ruler_requests "budget spent mid-loop, b not checked" 0
# Neither a TLS handshake nor a connection that never answers holds the probe.
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=2 PROBE_TIMEOUT=5)
run_timed "four hung https tenants" 0 6 -ruler-hang \
	-component 'a=unhealthy=RULER_TLS=a' \
	-component 'b=unhealthy=RULER_TLS=b' \
	-component 'c=unhealthy=RULER_TLS=c' \
	-component 'd=unhealthy=RULER_TLS=d'
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=20 PROBE_TIMEOUT=3)
run_timed "https ruler hung in the handshake" 0 4 \
	-component 'giantswarm=unhealthy=https://SILENT'
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=20 PROBE_TIMEOUT=3)
run_timed "http ruler hung on connect" 0 4 \
	-component 'giantswarm=unhealthy=http://SILENT'
# A single request never outlives PROBE_TIMEOUT.
PROBE_ENV=("${CREDS[@]}" HTTP_TIMEOUT=20 PROBE_TIMEOUT=2)
run_timed "hung ruler, short probe timeout" 0 3 -ruler-hang \
	-component 'giantswarm=unhealthy=RULER'

# Less than a second left is not enough for a request: `timeout` must never be
# given 0, which disables it, nor a negative duration.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/timeout.log"
exec $(command -v timeout) "\$@"
EOF
chmod +x "$TMP/bin/timeout"
PROBE_ENV=("${CREDS[@]}" "PATH=$TMP/bin:$PATH" HTTP_TIMEOUT=20 PROBE_TIMEOUT=2)
run_timed "less than a second left" 0 3 -alloy-delay 1.5s \
	-component 'giantswarm=unhealthy=RULER'
check_log "less than a second left is logged" "Probe timeout of 2s reached"
if awk '{ d = $1 == "-k" ? $3 : $1; if (d < 1) bad = 1 } END { exit bad }' "$TMP/timeout.log"; then
	printf 'PASS  %-45s | %s\n' "timeout is never given less than 1s" "$(paste -sd, "$TMP/timeout.log")"
	passes=$((passes + 1))
else
	printf 'FAIL  %-45s | %s\n' "timeout is never given less than 1s" "$(paste -sd, "$TMP/timeout.log")"
	failures=$((failures + 1))
fi

# An Alloy API that accepts the connection but never answers must be given up
# on rather than time the probe out, which Kubernetes counts as a failure.
before=$(date +%s)
PROBE_ENV=(HTTP_TIMEOUT=1)
run_case "hung Alloy API" 0 -hang
elapsed=$(($(date +%s) - before))
if [[ $elapsed -le 3 ]]; then
	printf 'PASS  %-45s | %ss\n' "hung Alloy API gives up on time" "$elapsed"
	passes=$((passes + 1))
else
	printf 'FAIL  %-45s | %ss\n' "hung Alloy API gives up on time" "$elapsed"
	failures=$((failures + 1))
fi

# Alloy itself being down must never restart it.
out=$(ALLOY_URL="http://127.0.0.1:1" bash "$PROBE" 2>&1)
check "Alloy API down" 0 "$?" "$out"

echo
echo "passes: $passes"
echo "failures: $failures"
echo "skips: $skips"
exit $((failures > 0))
