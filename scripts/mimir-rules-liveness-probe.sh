#!/usr/bin/env bash
#
# Liveness probe working around https://github.com/grafana/alloy/pull/6339
#
# When a mimir.rules.kubernetes component starts (or becomes leader) while the
# Mimir ruler is unreachable, it stays unhealthy forever and never syncs rules
# again. Restarting Alloy once the ruler is back fixes it.
#
# This probe discovers every mimir.rules.kubernetes component through the Alloy
# API, and exits non-zero as soon as one of them is unhealthy while its own
# Mimir ruler answers its readiness endpoint.
#
# Anything else (Alloy API down, no such component, ruler unreachable) exits 0:
# the probe only ever triggers a restart for the bug it works around.
#
# Only bash builtins and coreutils are used, so it runs as-is in the upstream
# Alloy image, which ships neither curl nor jq. Only plain HTTP is supported.
#
# Configuration (environment):
#   ALLOY_URL         Alloy HTTP endpoint         (default http://localhost:12345)
#   MIMIR_READY_PATH  Ruler readiness path        (default /ready)
#   MIMIR_READY_URL   Full readiness URL, used for every component instead of
#                     the one derived from its `address` argument
#   HTTP_TIMEOUT      Per request timeout seconds (default 5)

set -uo pipefail

ALLOY_URL=${ALLOY_URL:-http://localhost:12345}
MIMIR_READY_PATH=${MIMIR_READY_PATH:-/ready}
MIMIR_READY_URL=${MIMIR_READY_URL:-}
HTTP_TIMEOUT=${HTTP_TIMEOUT:-5}

log() {
	printf '%s\n' "$*"
}

# raw_http_get URL
#
# Prints the HTTP status code on the first line, the response body on the
# following ones. Returns non-zero when the request could not be completed.
raw_http_get() {
	local url=$1 rest hostport host port path line

	[[ $url == http://* ]] || return 1
	rest=${url#http://}
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
	port=${port:-80}

	exec 3<>"/dev/tcp/${host}/${port}" || return 1
	# HTTP/1.0 and identity encoding keep the response a plain, unchunked
	# body terminated by the connection close.
	printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: alloy-mimir-rules-probe\r\nAccept-Encoding: identity\r\n\r\n' \
		"$path" "$hostport" >&3 || return 1

	IFS= read -r line <&3 || return 1
	line=${line%$'\r'}
	line=${line#* }
	printf '%s\n' "${line%% *}"

	while IFS= read -r line <&3; do
		[[ -z ${line%$'\r'} ]] && break
	done
	cat <&3

	exec 3<&-
}

# Re-exec entrypoint, so that each request can be bounded by `timeout`.
if [[ ${1:-} == --http-get ]]; then
	raw_http_get "$2" 2>/dev/null
	exit $?
fi

http_get() {
	timeout "$HTTP_TIMEOUT" bash "$0" --http-get "$1"
}

# json_string_after PATTERN JSON
#
# Prints the first JSON string value matching PATTERN, which must end with the
# opening quote of that value.
json_string_after() {
	local match
	match=$(grep -o -- "$1"'[^"]*' <<<"$2")
	[[ -n $match ]] || return 1
	match=${match%%$'\n'*}
	printf '%s\n' "${match##*\"}"
}

components=$(http_get "${ALLOY_URL%/}/api/v0/web/components") || {
	log "Alloy API is unreachable, skipping check"
	exit 0
}
if [[ ${components%%$'\n'*} != 200 ]]; then
	log "Alloy API returned ${components%%$'\n'*}, skipping check"
	exit 0
fi

ids=$(grep -o '"localID":"mimir\.rules\.kubernetes\.[^"]*"' <<<"$components" | cut -d'"' -f4 | sort -u)
if [[ -z $ids ]]; then
	log "No mimir.rules.kubernetes component found"
	exit 0
fi

while read -r id; do
	detail=$(http_get "${ALLOY_URL%/}/api/v0/web/components/${id}") || {
		log "${id}: component API is unreachable, skipping"
		continue
	}
	if [[ ${detail%%$'\n'*} != 200 ]]; then
		log "${id}: component API returned ${detail%%$'\n'*}, skipping"
		continue
	fi

	health=$(json_string_after '"health":{"state":"' "$detail") || health=""
	if [[ $health != unhealthy ]]; then
		log "${id}: ${health:-unknown health}"
		continue
	fi

	ready_url=$MIMIR_READY_URL
	if [[ -z $ready_url ]]; then
		address=$(json_string_after '"name":"address","type":"attr","value":{"type":"string","value":"' "$detail") || {
			log "${id}: unhealthy but its Mimir address could not be read, skipping"
			continue
		}
		ready_url=${address%/}${MIMIR_READY_PATH}
	fi
	if [[ $ready_url != http://* ]]; then
		log "${id}: unhealthy but ${ready_url} is not a plain HTTP URL, skipping"
		continue
	fi

	ready=$(http_get "$ready_url") || {
		log "${id}: unhealthy but Mimir ruler ${ready_url} is unreachable, skipping"
		continue
	}
	if [[ ${ready%%$'\n'*} != 200 ]]; then
		log "${id}: unhealthy but Mimir ruler ${ready_url} is not ready (${ready%%$'\n'*}), skipping"
		continue
	fi

	log "${id}: unhealthy while Mimir ruler ${ready_url} is ready, Alloy needs a restart (grafana/alloy#6339)"
	exit 1
done <<<"$ids"

exit 0
