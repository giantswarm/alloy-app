#!/usr/bin/env bash
#
# Liveness probe working around https://github.com/grafana/alloy/pull/6339
#
# When a mimir.rules.kubernetes component starts (or becomes leader) while the
# Mimir ruler is unreachable, it stays unhealthy forever and never syncs rules
# again. Restarting Alloy once the ruler is back fixes it.
#
# This probe discovers every mimir.rules.kubernetes component through the Alloy
# API, and exits non-zero as soon as one of them is unhealthy with a health
# message matching UNHEALTHY_MESSAGE_PATTERN while its own Mimir ruler answers
# 200 on the ruler config API. The default pattern matches the failed rule
# listing that latches the component: a 5xx or a 429, or no answer at all.
# It never matches a rule Mimir rejects, an invalid rule, or a 4xx, which a
# restart does not fix, so a bad PrometheusRule never restarts Alloy.
#
# A rule listing that fails in the running component shows the same message,
# but the component refreshes its health at least every sync_interval, where
# the latch freezes it. A component is only a candidate once its health is
# older than its sync_interval plus HEALTH_AGE_MARGIN, which is checked before
# the ruler is queried.
#
# The ruler is queried with the same credentials and tenant as the component
# itself uses. Without them a Mimir behind a gateway answers 401 at the edge,
# whether the ruler is up or down, which tells the probe nothing. Anything but
# a 200, a 502 from a gateway whose ruler is down included, leaves Alloy alone.
# Components sharing a ruler and a tenant query it once per run.
#
# Anything else (Alloy API down, no such component, ruler unreachable) exits 0:
# the probe only ever triggers a restart for the bug it works around.
#
# One probe run never takes longer than PROBE_TIMEOUT plus a second: each
# request is bounded by what is left of it, the probe exits 0 once less than a
# second is left, and the whole run is killed and exits 0 at PROBE_TIMEOUT. Set
# PROBE_TIMEOUT at least 2 seconds below the kubelet timeoutSeconds, which
# counts a probe timeout as a failure.
#
# Only bash builtins, coreutils and openssl are used, so it runs as-is in the
# upstream Alloy image, which ships neither curl nor jq. Both http:// and
# https:// URLs are supported, the latter through `openssl s_client`.
#
# Responses are fed to grep through pipes, never here-strings: bash 5.2 writes
# a here-string over 64 KiB to a temporary file, and the Alloy container
# mounts /tmp read-only.
#
# Configuration (environment):
#   ALLOY_URL         Alloy HTTP endpoint         (default http://localhost:12345)
#   MIMIR_READY_PATH  Ruler reachability path     (default
#                     /prometheus/config/v1/rules)
#   MIMIR_USERNAME    Basic auth user for the ruler. Unset disables the check,
#   MIMIR_PASSWORD    so that Alloy is never restarted on a 401 the probe
#                     caused itself.
#   HTTP_TIMEOUT      Per request timeout seconds (default 20)
#   PROBE_TIMEOUT     Probe run timeout seconds   (default 50)
#   HEALTH_AGE_MARGIN Seconds the health must be older than the component
#                     sync_interval              (default 60)
#                     All three are whole seconds from 1 to 999999. Any other
#                     value skips the check.
#   UNHEALTHY_MESSAGE_PATTERN
#                     grep -E pattern the health message must match (default
#                     ^(error GET [^ ]*/rules: server returned HTTP status
#                     (429|5[0-9]{2}) |Get "[^"]*/rules": ), on one line)

set -uo pipefail
shopt -s extglob
# HTTP chunk sizes count bytes, which `read -N` counts as characters in a UTF-8
# locale.
export LC_ALL=C

ALLOY_URL=${ALLOY_URL:-http://localhost:12345}
MIMIR_READY_PATH=${MIMIR_READY_PATH:-/prometheus/config/v1/rules}
MIMIR_USERNAME=${MIMIR_USERNAME:-}
MIMIR_PASSWORD=${MIMIR_PASSWORD:-}
HTTP_TIMEOUT=${HTTP_TIMEOUT:-20}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-50}
HEALTH_AGE_MARGIN=${HEALTH_AGE_MARGIN:-60}
UNHEALTHY_MESSAGE_PATTERN=${UNHEALTHY_MESSAGE_PATTERN:-'^(error GET [^ ]*/rules: server returned HTTP status (429|5[0-9]{2}) |Get "[^"]*/rules": )'}

# Set by ruler_get for the requests that go to Mimir rather than to Alloy, and
# read back by http_request in the child process it re-execs.
PROBE_AUTH=${PROBE_AUTH:-}
PROBE_TENANT=${PROBE_TENANT:-}

log() {
	printf '%s\n' "$*"
}

# http_request PATH HOSTPORT
#
# Prints the raw HTTP request. HTTP/1.1 is required because ingresses commonly
# answer 426 to HTTP/1.0, and `Connection: close` terminates the response on
# the connection close rather than on a body length we would have to track.
http_request() {
	local extra=""

	if [[ -n $PROBE_AUTH ]]; then
		extra+="Authorization: Basic $(printf '%s' "${MIMIR_USERNAME}:${MIMIR_PASSWORD}" | base64 -w0)"$'\r\n'
	fi
	if [[ -n $PROBE_TENANT ]]; then
		extra+="X-Scope-OrgID: ${PROBE_TENANT}"$'\r\n'
	fi

	printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: alloy-mimir-rules-probe\r\nConnection: close\r\nAccept-Encoding: identity\r\n%s\r\n' \
		"$1" "$2" "$extra"
}

# http_exchange SCHEME HOST PORT HOSTPORT PATH
#
# Sends the request and prints the raw response, status line and headers
# included. Returns non-zero when the connection could not be made.
http_exchange() {
	local scheme=$1 host=$2 port=$3 hostport=$4 path=$5

	if [[ $scheme == https ]]; then
		http_request "$path" "$hostport" |
			openssl s_client -quiet -connect "${host}:${port}" -servername "$host" 2>/dev/null
		return $?
	fi

	exec 3<>"/dev/tcp/${host}/${port}" || return 1
	http_request "$path" "$hostport" >&3 || return 1
	cat <&3
	exec 3<&-
}

# parse_response
#
# Reads a raw HTTP response on stdin, prints the status code on the first line
# and the body on the following ones.
parse_response() {
	local line chunked=0

	IFS= read -r line || return 1
	line=${line%$'\r'}
	line=${line#* }
	printf '%s\n' "${line%% *}"

	while IFS= read -r line; do
		line=${line%$'\r'}
		[[ -z $line ]] && break
		[[ ${line,,} == transfer-encoding:*chunked* ]] && chunked=1
	done

	((chunked)) || {
		cat
		return 0
	}

	# HTTP/1.1 servers may frame the body in chunks, each announced by its
	# hexadecimal length and closed by a CRLF, and the body by a zero length.
	local size chunk
	while IFS= read -r line; do
		line=${line%$'\r'}
		size=${line%%;*}
		[[ $size == +([0-9a-fA-F]) ]] || break
		size=$((16#$size))
		((size)) || break
		IFS= read -r -N "$size" chunk
		printf '%s' "$chunk"
		IFS= read -r line
	done
}

# raw_http_get URL
#
# Prints the HTTP status code on the first line, the response body on the
# following ones. Returns non-zero when the request could not be completed.
raw_http_get() {
	local url=$1 scheme rest hostport host port path

	case $url in
	http://*)
		scheme=http
		rest=${url#http://}
		;;
	https://*)
		scheme=https
		rest=${url#https://}
		;;
	*)
		return 1
		;;
	esac
	case $rest in
	*/*)
		hostport=${rest%%/*}
		path=/${rest#*/}
		;;
	*)
		hostport=$rest
		path=/
		;;
	esac
	host=${hostport%%:*}
	port=${hostport#"$host"}
	port=${port#:}
	if [[ -z $port ]]; then
		[[ $scheme == https ]] && port=443 || port=80
	fi

	http_exchange "$scheme" "$host" "$port" "$hostport" "$path" | parse_response
}

# Re-exec entrypoint, so that each request can be bounded by `timeout`.
# Otherwise, if the connection hangs, the probe would never return and Kubernetes would restart Alloy for the wrong reason.
if [[ ${1:-} == --http-get ]]; then
	raw_http_get "$2" 2>/dev/null
	exit $?
fi

# A bad setting leaves Alloy alone, like any other failure of the probe. Bash
# arithmetic reads 08 as octal, and `timeout 0` never times out.
for setting in HTTP_TIMEOUT PROBE_TIMEOUT HEALTH_AGE_MARGIN; do
	if [[ ! ${!setting} =~ ^[1-9][0-9]{0,5}$ ]]; then
		log "${setting}=${!setting} is not a whole number of seconds between 1 and 999999, skipping check"
		exit 0
	fi
done

# Re-exec the run under `timeout`, which kills it, requests included, should
# anything hang past PROBE_TIMEOUT. Running out of time is never a failure.
# The run gets its deadline, in microseconds since the epoch, as an argument
# rather than from the environment, which the container could set.
if [[ ${1:-} == --run ]]; then
	PROBE_DEADLINE=$2
else
	timeout -k 1 "$PROBE_TIMEOUT" bash "$0" --run $((${EPOCHREALTIME/./} + PROBE_TIMEOUT * 1000000))
	rc=$?
	case $rc in
	0 | 1) exit $rc ;;
	124 | 137) log "Probe timeout of ${PROBE_TIMEOUT}s reached, skipping check" ;;
	*) log "Probe exited with ${rc}, skipping check" ;;
	esac
	exit 0
fi

# check_time_left
#
# Sets request_timeout to HTTP_TIMEOUT, capped to what is left of PROBE_TIMEOUT.
# Exits 0 once less than a second is left, before the kubelet times the probe
# out. EPOCHREALTIME counts microseconds, where SECONDS only counts whole ones.
check_time_left() {
	local left=$((PROBE_DEADLINE - ${EPOCHREALTIME/./}))
	if ((left < 1000000)); then
		log "Probe timeout of ${PROBE_TIMEOUT}s reached, skipping check"
		exit 0
	fi
	((left < HTTP_TIMEOUT * 1000000)) || left=$((HTTP_TIMEOUT * 1000000))
	printf -v request_timeout '%d.%06d' $((left / 1000000)) $((left % 1000000))
}

# http_get URL
#
# Same output as raw_http_get, but runs it in a child process bounded by
# request_timeout, which check_time_left sets. `timeout` kills the whole child
# process group, openssl included. Returns non-zero when the request failed or
# timed out.
http_get() {
	timeout -k 1 "$request_timeout" bash "$0" --http-get "$1" 2>/dev/null
}

# ruler_get URL TENANT
#
# Same as http_get, with the credentials and the tenant the component uses.
ruler_get() {
	PROBE_AUTH=1 PROBE_TENANT=$2 timeout -k 1 "$request_timeout" bash "$0" --http-get "$1" 2>/dev/null
}

# json_string_after PATTERN JSON
#
# Prints the first JSON string value matching PATTERN, which must end with the
# opening quote of that value. Escaped quotes and backslashes are decoded.
json_string_after() {
	local match
	match=$(printf '%s' "$2" | grep -o -- "$1"'\([^"\\]\|\\.\)*')
	[[ -n $match ]] || return 1
	match=${match%%$'\n'*}
	match=${match:${#1}}
	match=${match//\\\"/\"}
	printf '%s\n' "${match//\\\\/\\}"
}

# duration_seconds DURATION
#
# Prints a Go duration the way Alloy renders it (5m0s, 30s, 1h0m0s, 1.5s) in
# whole seconds, rounded up. Returns non-zero on any other form.
duration_seconds() {
	[[ -n $1 && $1 =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)(\.[0-9]+)?s)?$ ]] || return 1
	printf '%d\n' $((10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0} + (${#BASH_REMATCH[7]} > 0)))
}

# List Alloy components
check_time_left
components=$(http_get "${ALLOY_URL%/}/api/v0/web/components") || {
	log "Alloy API is unreachable, skipping check"
	exit 0
}
if [[ ${components%%$'\n'*} != 200 ]]; then
	log "Alloy API returned ${components%%$'\n'*}, skipping check"
	exit 0
fi

# Collect mimir.rules.kubernetes component IDs.
ids=$(printf '%s' "$components" | grep -o '"localID":"mimir\.rules\.kubernetes\.[^"]*"' | cut -d'"' -f4 | sort -u)
if [[ -z $ids ]]; then
	log "No mimir.rules.kubernetes component found"
	exit 0
fi

# Ruler status codes by ruler URL and tenant. Components sharing both, and the
# credentials that are the same for all, query the ruler once per run.
declare -A ruler_codes=()

# Probe each component to detect if one is unhealthy while its Mimir ruler is ready.
while read -r id; do
	# Read the component detail, which carries its health and its arguments.
	check_time_left
	detail=$(http_get "${ALLOY_URL%/}/api/v0/web/components/${id}") || {
		log "${id}: component API is unreachable, skipping"
		continue
	}
	if [[ ${detail%%$'\n'*} != 200 ]]; then
		log "${id}: component API returned ${detail%%$'\n'*}, skipping"
		continue
	fi

	# A component that is not unhealthy is left alone.
	health=$(json_string_after '"health":{"state":"' "$detail") || health=""
	if [[ $health != unhealthy ]]; then
		log "${id}: ${health:-unknown health}"
		continue
	fi

	# Only the failed rule listing latches the component, a rejected rule does not.
	message=$(json_string_after '"health":{"state":"unhealthy","message":"' "$detail") || message=""
	if ! printf '%s\n' "$message" | grep -E -- "$UNHEALTHY_MESSAGE_PATTERN" >/dev/null; then
		log "${id}: unhealthy but its health message does not match the latch, skipping: ${message}"
		continue
	fi

	# The latch freezes the health, which the running component refreshes at
	# least every sync_interval. Alloy leaves sync_interval out at its 5m0s
	# default.
	updated_time=$(json_string_after '"updatedTime":"' "$detail") || updated_time=""
	if [[ -z $updated_time ]] || ! updated=$(date -d "$updated_time" +%s 2>/dev/null); then
		log "${id}: unhealthy but its health update time \"${updated_time}\" could not be read, skipping"
		continue
	fi
	sync_interval=$(json_string_after '"name":"sync_interval","type":"attr","value":{"type":"string","value":"' "$detail") || sync_interval=5m0s
	if ! interval=$(duration_seconds "$sync_interval"); then
		log "${id}: unhealthy but its sync_interval \"${sync_interval}\" could not be read, skipping"
		continue
	fi
	age=$((${EPOCHREALTIME%.*} - updated))
	threshold=$((interval + HEALTH_AGE_MARGIN))
	if ((age <= threshold)); then
		log "${id}: unhealthy for ${age}s, below ${threshold}s, skipping"
		continue
	fi

	# The ruler is queried with the credentials and the tenant of the component.
	if [[ -z $MIMIR_USERNAME ]]; then
		log "${id}: unhealthy but no Mimir credentials are configured, skipping"
		continue
	fi
	tenant=$(json_string_after '"name":"tenant_id","type":"attr","value":{"type":"string","value":"' "$detail") || tenant=""

	# The ruler URL comes from the component `address`.
	address=$(json_string_after '"name":"address","type":"attr","value":{"type":"string","value":"' "$detail") || {
		log "${id}: unhealthy but its Mimir address could not be read, skipping"
		continue
	}
	ready_url=${address%/}${MIMIR_READY_PATH}
	if [[ $ready_url != http://* && $ready_url != https://* ]]; then
		log "${id}: unhealthy but ${ready_url} is not an HTTP URL, skipping"
		continue
	fi

	# Only a 200 proves the ruler is back. Anything else leaves Alloy alone.
	key=${ready_url}$'\n'${tenant}
	if [[ -z ${ruler_codes[$key]+set} ]]; then
		check_time_left
		ready=$(ruler_get "$ready_url" "$tenant") || ready=unreachable
		ruler_codes[$key]=${ready%%$'\n'*}
	fi
	code=${ruler_codes[$key]}
	if [[ $code == unreachable ]]; then
		log "${id}: unhealthy but Mimir ruler ${ready_url} is unreachable, skipping"
		continue
	fi
	if [[ $code != 200 ]]; then
		log "${id}: unhealthy but Mimir ruler ${ready_url} did not answer (${code}), skipping"
		continue
	fi

	# Detected a mimir.rules.kubernetes component that is unhealthy while its Mimir ruler is ready.
	# This is the bug we work around, so exit non-zero to trigger an unhealthy liveness probe.
	log "${id}: unhealthy while Mimir ruler ${ready_url} answers 200, Alloy needs a restart (grafana/alloy#6339)"
	exit 1
done < <(printf '%s\n' "$ids")

exit 0
