#!/bin/bash
#
# kab.sh:  kernel-auto-bisect (kab)
#
# Uses CRIU (Checkpoint Restore in Userspace) to restore the process for reboot or kernel panic
#
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Reboot to original kernel so kab can be restarted safely
trap 'ret=$?; reboot_to_origin_kernel; exit $ret' SIGINT

do_start() {
	initialize
	verify_intial_commits
	log "Starting git bisect process"
	run_cmd_in_GIT_REPO git bisect start "$BAD_REF" "$GOOD_REF"

	main_bisect_loop

	if [[ "$_auto_source_bisect" == true ]]; then
		transition_to_source_bisect
		main_bisect_loop
	fi

	finish
}

should_continue_bisect() {
	! run_cmd_in_GIT_REPO git bisect log "|" grep -q "first bad commit"
}

main_bisect_loop() {
	while should_continue_bisect; do
		local commit
		commit=$(get_current_commit)
		log "--- Testing bisect commit: $commit ---"

		if commit_good "$commit"; then
			log "Marking $commit as GOOD"
			if ! run_cmd_in_GIT_REPO git bisect good "$commit"; then
				do_abort "Failed to run 'git bisect good $commit'"
			fi
		else
			log "Marking $commit as BAD"
			if ! run_cmd_in_GIT_REPO git bisect bad "$commit"; then
				do_abort "Failed to run 'git bisect bad \"$commit\"'"
			fi
		fi
	done
}

do_start
