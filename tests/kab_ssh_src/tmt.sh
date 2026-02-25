#!/bin/bash
assign_server_roles() {
	if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f "${TMT_TOPOLOGY_BASH}" ]; then
		# assign roles based on tmt topology data
		# shellcheck source=/dev/null
		. "${TMT_TOPOLOGY_BASH}"

		if [[ $(grep -Ec "TMT_GUESTS\[.*role\]" "${TMT_TOPOLOGY_BASH}") -gt 1 ]]; then
			export SERVERS=${TMT_GUESTS[server.hostname]}
			export CLIENTS=${TMT_GUESTS[client.hostname]}
		fi

		export HOSTNAME=${TMT_GUEST[hostname]}
	fi
}

assign_server_roles
