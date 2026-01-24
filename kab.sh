#!/bin/bash
#
# kab.sh:  kernel-auto-bisect (kab)
#
# Uses CRIU (Checkpoint Restore in Userspace) to restore the process for reboot or kernel panic
#
# shellcheck source=lib.sh
source /usr/local/bin/kernel-auto-bisect/lib.sh

do_start() {
	initialize
	verify_intial_commits
	log "Starting git bisect process"
	run_cmd_in_GIT_REPO git bisect start "$BAD_REF" "$GOOD_REF"

	main_bisect_loop
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
	finish
}

do_start
