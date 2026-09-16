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
# Mimir ruler answers on the ruler config API. That API is queried without
# credentials, so 401 counts as an answer: the probe needs to know that Mimir
# is up, not to read anything from it.
#
# Anything else (Alloy API down, no such component, ruler unreachable) exits 0:
# the probe only ever triggers a restart for the bug it works around.
#
# Only bash builtins, coreutils and openssl are used, so it runs as-is in the
# upstream Alloy image, which ships neither curl nor jq. Both http:// and
# https:// URLs are supported, the latter through `openssl s_client`.
#
# Configuration (environment):
#   ALLOY_URL         Alloy HTTP endpoint         (default http://localhost:12345)
#   MIMIR_READY_PATH  Ruler reachability path     (default
#                     /prometheus/config/v1/rules)
#   MIMIR_READY_URL   Full reachability URL, used for every component instead
#                     of the one derived from its `address` argument
#   HTTP_TIMEOUT      Per request timeout seconds (default 5)

set -uo pipefail
shopt -s extglob

ALLOY_URL=${ALLOY_URL:-http://localhost:12345}
MIMIR_READY_PATH=${MIMIR_READY_PATH:-/prometheus/config/v1/rules}
MIMIR_READY_URL=${MIMIR_READY_URL:-}
HTTP_TIMEOUT=${HTTP_TIMEOUT:-5}

log() {
	printf '%s\n' "$*"
}

# http_request PATH HOSTPORT
#
# Prints the raw HTTP request. HTTP/1.1 is required because ingresses commonly
# answer 426 to HTTP/1.0, and `Connection: close` terminates the response on
# the connection close rather than on a body length we would have to track.
http_request() {
	printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: alloy-mimir-rules-probe\r\nConnection: close\r\nAccept-Encoding: identity\r\n\r\n' \
		"$1" "$2"
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

# http_get URL
#
# Same output as raw_http_get, but runs it in a child process bounded by
# HTTP_TIMEOUT. Returns non-zero when the request failed or timed out.
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

# List Alloy components
components=$(http_get "${ALLOY_URL%/}/api/v0/web/components") || {
	log "Alloy API is unreachable, skipping check"
	exit 0
}
if [[ ${components%%$'\n'*} != 200 ]]; then
	log "Alloy API returned ${components%%$'\n'*}, skipping check"
	exit 0
fi

# Collect mimir.rules.kubernetes component IDs.
ids=$(grep -o '"localID":"mimir\.rules\.kubernetes\.[^"]*"' <<<"$components" | cut -d'"' -f4 | sort -u)
if [[ -z $ids ]]; then
	log "No mimir.rules.kubernetes component found"
	exit 0
fi

# Probe each component to detect if one is unhealthy while its Mimir ruler is ready.
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
	if [[ $ready_url != http://* && $ready_url != https://* ]]; then
		log "${id}: unhealthy but ${ready_url} is not an HTTP URL, skipping"
		continue
	fi

	ready=$(http_get "$ready_url") || {
		log "${id}: unhealthy but Mimir ruler ${ready_url} is unreachable, skipping"
		continue
	}
	code=${ready%%$'\n'*}
	if [[ $code != 200 && $code != 401 ]]; then
		log "${id}: unhealthy but Mimir ruler ${ready_url} did not answer (${code}), skipping"
		continue
	fi

	# Detected a mimir.rules.kubernetes component that is unhealthy while its Mimir ruler is ready.
	# This is the bug we work around, so exit non-zero to trigger an unhealthy liveness probe.
	log "${id}: unhealthy while Mimir ruler ${ready_url} answers (${code}), Alloy needs a restart (grafana/alloy#6339)"
	exit 1
done <<<"$ids"

exit 0
