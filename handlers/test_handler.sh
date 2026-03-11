#!/bin/bash
#
# test_handler.sh: Contains strategies for running tests.
# This version implements the "fast reboot" logic by calling process_result directly.
#

_init_test_handler() {
	# shellcheck disable=SC1090
	source "$REPRODUCER_SCRIPT"

	if ! type setup_test &>/dev/null; then log "'setup_test' function not found"; fi
	if ! type on_test &>/dev/null; then do_abort "'on_test' function not found."; fi

	if [[ -n $KAB_TEST_HOST ]]; then
		_dir=$(dirname "$REPRODUCER_SCRIPT")
		run_cmd mkdir "$_dir"
		cp_file "$REPRODUCER_SCRIPT"
	fi
}

run_test_strategy() {
	if [[ $_test_handler_initilized != true ]]; then
		_init_test_handler
		_test_handler_initilized=true
	fi

	log "--- Phase: RUN_TEST on $(run_cmd uname -r) ---"
	[[ -z $RUNS_PER_COMMIT ]] && RUNS_PER_COMMIT=1
	case "$TEST_STRATEGY" in
	panic) run_panic_test ;;
	simple) run_simple_test ;;
	*) do_abort "Unknown TEST_STRATEGY: ${TEST_STRATEGY}" ;;
	esac
}

signal_checkpoint_panic() {
	signal_checkpoint "panic"
}

cp_file() {
	if [[ -n $KAB_TEST_HOST_SSH_KEY ]]; then
		_ssh_opts=("-i" "$KAB_TEST_HOST_SSH_KEY" -o IdentitiesOnly=yes)
	fi

	run_cmd mkdir -p "$(dirname "$1")"
	scp "${_ssh_opts[@]}" "$1" "$KAB_TEST_HOST":"$1"
}

do_panic() {

	prepare_reboot

	if [[ -n $KAB_TEST_HOST ]]; then
		reboot_and_wait "echo 1 > /proc/sys/kernel/sysrq && echo c > /proc/sysrq-trigger"
	else
		signal_checkpoint_panic
	fi
}

_handler_run_test() {
	if [[ -z $KAB_TEST_HOST ]]; then
		# shellcheck disable=SC1090
		source "$REPRODUCER_SCRIPT"
		$1
		return $?
	fi

	temp_file=$(mktemp)
	cat <<END >>"$temp_file"
source "$REPRODUCER_SCRIPT"
$1
END
	cp_file "$temp_file"
	run_cmd bash "$temp_file"
}

handler_run_test() {
	_handler_run_test on_test
}

handler_run_test_setup() {
	_handler_run_test setup_test
}

run_panic_test() {
	if ! run_cmd test -f "$REPRODUCER_SCRIPT"; then do_abort "Reproducer script not found."; fi

	RUN_COUNT=0
	# This loop will continue as long as tests are inconclusive and we have retries.
	# For panic mode, each iteration involves a reboot.
	while true; do
		if $PANIC_OCCURRED; then
			# This boot is for VERIFYING a previous panic
			log "Verifying outcome of run #${RUN_COUNT}"
			PANIC_OCCURRED=false

			# handler_run_test/on_test returning 0 means GOOD. Non-zero means BAD.
			if ! handler_run_test; then
				log "Test was bad on run #${RUN_COUNT}. Marking commit as bad."
				return 1 # BAD
			fi

			# We have retries left, so we will fall through to trigger the panic again.
			RUN_COUNT=$((RUN_COUNT + 1))

			# Test was good, which is inconclusive. Check if we should retry.
			log "Test run #${RUN_COUNT} was good (inconclusive)."
			if [ "$RUN_COUNT" -ge "$RUNS_PER_COMMIT" ]; then
				log "All ${RUNS_PER_COMMIT} runs were good. Marking commit as conclusively good."
				return 0 # GOOD
			fi

			log "Proceeding to run attempt #${RUN_COUNT}."
		fi

		# This logic is reached on the first run, or after an inconclusive run.
		log "Preparing to trigger panic for run #${RUN_COUNT}."
		if ! handler_run_test_setup; then log "WARNING: setup_test() exited non-zero."; fi

		local count=0
		while :; do
			run_cmd kdumpctl status && break
			sleep 5
			count=$((count + 5))
			if [[ $count -gt 60 ]]; then
				do_abort "kdump service not ready after 60s. Aborting."
			fi
		done

		PANIC_OCCURRED=true
		log "Triggering kernel panic NOW."
		do_panic
	done
}

run_simple_test() {
	if [ ! -f "$REPRODUCER_SCRIPT" ]; then do_abort "Reproducer script not found."; fi
	# shellcheck disable=SC1090
	source "$REPRODUCER_SCRIPT"
	if ! type on_test &>/dev/null; then do_abort "'on_test' function not found for simple mode."; fi

	log "Running simple test..."

	# on_test returning 0 means GOOD. Non-zero means BAD.
	if on_test; then
		log "Simple test passed - commit is GOOD"
		return 0 # GOOD
	else
		log "Simple test failed - commit is BAD"
		return 1 # BAD
	fi
}
