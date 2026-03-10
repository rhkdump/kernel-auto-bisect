#!/bin/bash
# Configuration
BIN_DIR=/usr/local/bin/kernel-auto-bisect
WORK_DIR="/var/local/kernel-auto-bisect"
GIT_REPO="$WORK_DIR/git_repo"
SIGNAL_DIR="$WORK_DIR/signal"
DUMP_DIR="$WORK_DIR/dump"
# shellcheck disable=SC2034
DUMP_LOG_DIR="$WORK_DIR/dump_logs"
CHECKPOINT_SIGNAL="$SIGNAL_DIR/checkpoint_request"
RESTORE_FLAG="$SIGNAL_DIR/restore_flag"
# shellcheck disable=SC2034
PANIC_SIGNAL="$SIGNAL_DIR/panic_request"

CONFIG_FILE="$BIN_DIR/bisect.conf"
HANDLER_DIR="$BIN_DIR/handlers"
LOG_FILE="$WORK_DIR/main.log"

# shellcheck disable=SC2034
CRIU_LOG_FILE="$WORK_DIR/criu-daemon.log"
# shellcheck disable=SC2034
BISECT_SCRIPT="$BIN_DIR/kab.sh"

TESTED_KERNEL=""
ORIGINAL_KERNEL=""
GOOD_REF=""
BAD_REF=""

# --- Load Config and Handlers ---
load_config_and_handlers() {
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "FATAL: Config file missing!" | tee -a "$LOG_FILE"
		exit 1
	fi
	# shellcheck disable=SC1090
	source "$CONFIG_FILE"
	# shellcheck disable=SC1090
	for handler in "${HANDLER_DIR}"/*.sh; do if [ -f "$handler" ]; then source "$handler"; fi; done
	run_cmd dnf install git -yq

	[[ -n $KAB_TEST_HOST ]] && return
	rm -rf "${DUMP_DIR:?}"/*
	# 1. setsid somehow doesn't work, checkpointing will fail with "The criu itself is within dumped tree"
	#    setsid criu-daemon.sh < /dev/null &> log_file &
	# 2. Using a systemd service to start criu-daemon.sh somehow can lead to many
	#    dump/restore issues like "can't write lsm profile"
	systemd-run --unit=checkpoint-test $BIN_DIR/criu-daemon.sh
}

safe_cd() {
	cd "$1" || {
		echo "Failed to cd $1"
		exit 1
	}
}

# --- Logging ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# --- Kernel and Grub Management ---
set_boot_kernel() {
	log "Setting default boot kernel to: $1"
	run_cmd grubby --set-default "$1"
}

get_original_kernel() {
	run_cmd grubby --info="/boot/vmlinuz-$(run_cmd uname -r)" | grep -E "^kernel=" | sed 's/kernel=//;s/"//g'
}

FIRST_SIGNALED=true
_wait_tmt_test() {
	[[ -z $TMT_SLEEP_MARK ]] && return

	if $FIRST_SIGNALED; then
		FIRST_SIGNALED=false
		return
	fi

	local _wait_time=0
	MAX_WAIT_TMT_TIME=60
	until pgrep -f "sleep $TMT_SLEEP_MARK" >/dev/null; do
		sleep 1
		((++_wait_time))
		if [[ $_wait_time -ge $MAX_WAIT_TMT_TIME ]]; then
			echo "$KAB_TMT_TEST_SLEEP_FLAG still isn't created after ${MAX_WAIT_TMT_TIME}, something wrong. Exiting!"
			exit 1
		fi
	done
}

signal_checkpoint() {
	mkdir -p "$SIGNAL_DIR"

	_wait_tmt_test

	log "Signaling daemon to checkpoint and reboot"

	if [[ $1 == reboot ]]; then
		printf "sync\n systemctl reboot" >"$CHECKPOINT_SIGNAL"
	elif [[ $1 == panic ]]; then
		printf "sync\n echo 1 > /proc/sys/kernel/sysrq\n echo c > /proc/sysrq-trigger" >"$CHECKPOINT_SIGNAL"
	fi

	# Wait for the daemon to process our request and reboot/panic the system
	# If we're still running after 10 seconds, something went wrong
	local count=0
	local MAX_WAIT=20
	while [[ ! -f "$RESTORE_FLAG" ]] && [[ $count -lt $MAX_WAIT ]]; do
		sleep 1
		count=$((count + 1))
	done

	rm -f "$RESTORE_FLAG"
	if [[ $count -ge $MAX_WAIT ]]; then
		log "ERROR: Daemon failed to process checkpoint request"
		exit 1
	fi
}

declare -A release_commit_map

# Run a command to reboot/panic the system and wait for the system to be alive
# again
reboot_and_wait() {
	local _ssh_opts _wait_time

	WAIT_REMOTE_HOST_DOWN=60
	WAIT_REMOTE_HOST_UP=300

	[[ -z $KAB_TEST_HOST ]] && do_abort "$KAB_TEST_HOST not set. Something wrong!"
	_ssh_opts=(-n -q)

	if [[ -f $KAB_TEST_HOST_SSH_KEY ]]; then
		_ssh_opts+=("-i" "$KAB_TEST_HOST_SSH_KEY" -o IdentitiesOnly=yes)
	fi

	# Avoid hanging forever after triggering kernel panic
	_ssh_opts+=(-o ChannelTimeout=session=2s)

	ssh "${_ssh_opts[@]}" "$KAB_TEST_HOST" sync
	# shellcheck disable=SC2029
	ssh "${_ssh_opts[@]}" "$KAB_TEST_HOST" "$@"

	_ssh_opts+=(-o ConnectTimeout=3)

	# Wait for remote host to go down
	_wait_time=0
	while ssh "${_ssh_opts[@]}" "$KAB_TEST_HOST" exit 2>/dev/null; do
		printf "."
		if [[ $_wait_time -gt $WAIT_REMOTE_HOST_DOWN ]]; then
			do_abort "Can still connec to remote host after ${WAIT_REMOTE_HOST_DOWN}s"
		fi
		((++_wait_time))
		sleep 1
	done

	# Wait for remote host to be alive again
	_wait_time=0
	until ssh "${_ssh_opts[@]}" "$KAB_TEST_HOST" exit 2>/dev/null; do
		printf "."
		if [[ $_wait_time -gt $WAIT_REMOTE_HOST_UP ]]; then
			do_abort "Can't connect to remote system after ${WAIT_REMOTE_HOST_UP}s"
		fi
		((++_wait_time))
		sleep 1
	done
}

prepare_reboot() {
	# try to reboot to current EFI bootloader entry next time
	run_cmd command -v rstrnt-prepare-reboot &>/dev/null && run_cmd rstrnt-prepare-reboot >/dev/null
	run_cmd sync
}

# To avoid blowing up /boot partition, remove the tested kernel
remove_test_kernel() {
	if [[ -z "$TESTED_KERNEL" ]]; then return; fi

	local kernel_to_remove="$TESTED_KERNEL"
	# Safety check: never remove the original kernel
	if [[ -z "$kernel_to_remove" ]] || [[ "/boot/vmlinuz-$(run_cmd uname -r)" == "$ORIGINAL_KERNEL" ]]; then
		log "WARNING: Skipping removal of test kernel, as it is the original kernel or undefined."
		TESTED_KERNEL=""
		return
	fi
	log "Cleaning up last tested kernel: ${kernel_to_remove}"
	case "$INSTALL_STRATEGY" in
	rpm) run_cmd rpm -e "kernel-core-${kernel_to_remove}" >/dev/null 2>&1 || log "Failed to remove kernel RPMs." ;;
	git)
		run_cmd kernel-install remove "${kernel_to_remove}"
		run_cmd rm -rf "/lib/modules/${kernel_to_remove}"
		;;
	esac
	TESTED_KERNEL=""
}

do_abort() {
	log "FATAL: $1"
	log "Aborting bisection."
	if [[ -n "$ORIGINAL_KERNEL" ]]; then
		log "Returning to original kernel."
		set_boot_kernel "$ORIGINAL_KERNEL"
	fi
	log "To perform a full cleanup of all intermediate kernels, please do so manually."
	exit 1
}

# --- RPM Mode Specific Functions ---
generate_git_repo_from_package_list() {
	log "Generating fake git repository for RPM list..."
	run_cmd rm -rf "$GIT_REPO"
	run_cmd mkdir -p "$GIT_REPO"
	run_cmd_in_GIT_REPO git init -q
	run_cmd_in_GIT_REPO git config user.name kab
	run_cmd_in_GIT_REPO git config user.email kab
	run_cmd_in_GIT_REPO touch k_url k_rel
	run_cmd_in_GIT_REPO git add k_url k_rel
	run_cmd_in_GIT_REPO git commit -m "init" >/dev/null
	while read -r _url; do
		local _str
		_str=$(basename "$_url")
		if [[ $_str == *kernel-rt-core* ]]; then
			_str=${_str#kernel-rt-core-}
		else
			_str=${_str#kernel-core-}
		fi
		local k_rel=${_str%.rpm}
		run_cmd_in_GIT_REPO bash -c "echo '$_url' >k_url"
		run_cmd_in_GIT_REPO bash -c "echo '$k_rel' >k_rel"
		run_cmd_in_GIT_REPO git commit -m "$k_rel" k_url k_rel >/dev/null
		release_commit_map[$k_rel]=$(run_cmd_in_GIT_REPO git rev-parse HEAD)
	done <"$KERNEL_RPM_LIST"
}

setup_criu() {
	if ! command -v criu; then
		if ! dnf install criu -yq; then
			log "Failed to install criu!"
			exit 1
		fi
	fi

	if ! command -v crontab; then
		if ! dnf install cronie -yq; then
			log "Failed to install cronie!"
			exit 1
		fi
		systemctl enable --now crond
	fi

	CRONTAB="$WORK_DIR/crontab"
	cat <<END >"$CRONTAB"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:$BIN_DIR
@reboot criu-daemon.sh
# It seems @reboot doesn't work reliably. So try to restart criu-damon every minute
* * * * * criu-daemon.sh
END
	crontab "$CRONTAB"
}

setup_kdump() {
	if [[ "$TEST_STRATEGY" == "panic" ]]; then
		if ! command -v kdumpctl; then
			if ! dnf install kexec-tools -yq; then
				log "Failed to install kexec-tools!"
				exit 1
			fi
		fi

		if ! grep -q "crashkernel" /proc/cmdline; then
			log "Adding crashkernel=256M to kernel arguments"
			run_cmd grubby --update-kernel=ALL --args="crashkernel=256M"

			# Ensure kdump is enabled for next boot
			systemctl enable kdump

			log "Rebooting to apply crashkernel argument..."
			signal_checkpoint "reboot"
		else
			# Ensure kdump is running if crashkernel is already present
			systemctl enable --now kdump
		fi
	fi
}

initialize() {
	local good_ref bad_ref

	load_config_and_handlers

	mkdir -p "$WORK_DIR"

	good_ref="$GOOD_COMMIT"
	bad_ref="$BAD_COMMIT"
	# Store original kernel in memory
	ORIGINAL_KERNEL=$(get_original_kernel)

	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
		if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
		generate_git_repo_from_package_list
		good_ref=${release_commit_map[$GOOD_COMMIT]}
		bad_ref=${release_commit_map[$BAD_COMMIT]}
		if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then do_abort "Could not find GOOD/BAD versions in RPM list."; fi
	elif [[ "$INSTALL_STRATEGY" == "git" ]]; then
		if run_cmd test -d $GIT_REPO/.git; then
			log "$GIT_REPO already exists, reuse it"
		else
			[[ -n $GIT_REPO_BRANCH ]] && branch_arg=--branch=$GIT_REPO_BRANCH
			if ! run_cmd git clone "$GIT_REPO_URL" "$branch_arg" $GIT_REPO; then
				do_abort "Failed to clone $GIT_REPO_URL"
			fi
		fi
	fi

	# Save resolved references in memory
	GOOD_REF="$good_ref"
	BAD_REF="$bad_ref"

	[[ -n $KAB_TEST_HOST ]] && return
	setup_criu
	setup_kdump
}

verify_intial_commits() {
	if [[ "$VERIFY_COMMITS" == "yes" ]]; then
		log "Skipping verifying initial commits"
		return 0
	fi

	log "Verifying initial GOOD commit"
	if ! commit_good "$GOOD_REF"; then
		do_abort "GOOD_COMMIT behaved as BAD"
	fi

	log "Verifying initial BAD commit"
	if commit_good "$BAD_REF"; then
		do_abort "BAD_COMMIT behaved as GOOD"
	fi
}

# --- Core Testing Functions ---
run_test() {
	local ret
	# Wrapper for the actual test strategy
	run_test_strategy
	ret=$?
	remove_test_kernel
	return $ret
}

get_current_commit() {
	run_cmd -cwd "$GIT_REPO" git rev-parse HEAD
}

# Run a command locally or remotely over ssh (optionally) in specified
# directory
#
# run_cmd [-no-escape] [-cwd work_dir] command
#
# If $1=-no-escape, it won't try to escape spaces
#
# If $1=-cwd, it will use $2 as working directory
run_cmd() {
	local _dir
	local -a _cmd
	local _ssh_opts
	local no_escape

	no_escape=false

	if [[ $1 == "-no-escape" ]]; then
		no_escape=true
		shift
	fi

	if [[ $1 == "-cwd" ]]; then
		_dir=$2
		_cmd=(cd "'$_dir'" "&&")
		shift 2
	fi

	if $no_escape; then
		_cmd+=("$@")
	else
		for _ele in "$@"; do
			if [[ "$_ele" =~ [[:space:]] || $_ele == "" ]]; then
				_cmd+=("'$_ele'")
			else
				_cmd+=("$_ele")
			fi
		done
	fi

	if [[ -n $KAB_TEST_HOST ]]; then
		# - BatchMode: avoiding waiting forever for user password
		# - n: prevent ssh from reading stdin (important for while loops)
		_ssh_opts=(-n -o BatchMode=yes)
		if [[ -f $KAB_TEST_HOST_SSH_KEY ]]; then
			_ssh_opts+=("-i" "$KAB_TEST_HOST_SSH_KEY" -o IdentitiesOnly=yes)
		fi
		# shellcheck disable=SC2029
		ssh "${_ssh_opts[@]}" "$KAB_TEST_HOST" "${_cmd[@]}"
	else
		# For simply running command locally, "$@" will a better choice than
		# eval. But to simplify testing for running commands on remote host, we
		# use eval.
		# Besides we quote $_dir and arguments with space. As a
		# result, "$@" won't work.
		#
		# Note we assume ssh behaves the same way as eval regarding escaping
		# and quotes, for example,
		#   eval cd 'ab cd'
		#   ssh HOST cd 'ab cd'
		#
		#   eval cd "$GIT_REPO" '&&' git bisect log "|" grep -q "first bad commit"
		#   ssh HOST "$GIT_REPO" '&&' git bisect log "|" grep -q "first bad commit"
		# shellcheck disable=SC2294
		eval "${_cmd[@]}"
	fi
}

run_cmd_in_GIT_REPO() {
	run_cmd -cwd "$GIT_REPO" "$@"
}

commit_good() {
	local commit="$1"
	log "Evaluating commit: $commit"

	run_install_strategy "$commit"
	run_reboot_strategy
	# Let the test handler manage multiple attempts and kernel panic
	# It will return 0 for GOOD, non-zero for BAD
	run_test
}

generate_final_report() {
	run_cmd_in_GIT_REPO git bisect log >"$WORK_DIR/bisect_final_log.txt"
	log "Final report saved to $WORK_DIR/bisect_final_log.txt"
}

reboot_to_origin_kernel() {
	set_boot_kernel "$ORIGINAL_KERNEL"
	reboot_and_wait systemctl reboot
}

finish() {
	generate_final_report
	reboot_to_origin_kernel
}
