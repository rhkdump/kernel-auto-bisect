#!/bin/bash
# Configuration
# Allow running from source directory or installed location
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/var/local/kernel-auto-bisect"
GIT_REPO="$WORK_DIR/git_repo"
SIGNAL_DIR="$WORK_DIR/signal"
DUMP_DIR="$WORK_DIR/dump"
# shellcheck disable=SC2034
CRIU_LOG_DIR="$WORK_DIR/criu_logs"
CHECKPOINT_SIGNAL="$SIGNAL_DIR/checkpoint_request"
RESTORE_FLAG="$SIGNAL_DIR/restore_flag"
# shellcheck disable=SC2034
PANIC_SIGNAL="$SIGNAL_DIR/panic_request"

CONFIG_FILE="$BIN_DIR/bisect.conf"
HANDLER_DIR="$BIN_DIR/handlers"
# In ssh mode, when kab runs as non-root user, main.log will be be stored in
# ~/.local/state/kernel-auto-bisect
LOG_FILE="$WORK_DIR/main.log"

# shellcheck disable=SC2034
CRIU_LOG_FILE="$WORK_DIR/criu-daemon.log"
# shellcheck disable=SC2034
BISECT_SCRIPT="$BIN_DIR/kab.sh"

# shellcheck disable=SC2034
TESTED_KERNEL=""
ORIGINAL_KERNEL=""
# shellcheck disable=SC2034
ORIGINAL_KERNEL_RELEASE=""
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
	systemd-run --unit=checkpoint-test "$BIN_DIR"/criu-daemon.sh
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

signal_checkpoint() {
	mkdir -p "$SIGNAL_DIR"

	log "Signaling daemon to checkpoint and reboot"

	if [[ $1 == reboot ]]; then
		_reboot_cmd="systemctl reboot"
		printf "sync\n %s" "${_reboot_cmd}" >"$CHECKPOINT_SIGNAL"
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

	if [[ -z $KAB_TEST_HOST ]]; then
		signal_checkpoint "reboot"
		return 0
	fi

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

do_abort() {
	log "FATAL: $1"
	log "Aborting bisection."
	reboot_to_origin_kernel
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

# Detect if a string is a kernel NVR (e.g., 5.14.0-284.el9.x86_64)
# vs a git commit hash (hex string)
is_nvr() {
	local str="$1"
	# NVRs contain dist tags like .el9, .el10, .fc41
	[[ "$str" =~ \.(el|fc)[0-9]+ ]]
}

# Convert NVR (with arch suffix) to a git tag name
# e.g., "5.14.0-670.el9.x86_64" -> "kernel-5.14.0-670.el9"
#        "6.16.5-100.fc41.x86_64" -> "kernel-6.16.5-0"
nvr_to_tag() {
	local nvr_without_arch="${1%.*}"
	local tag_name="$nvr_without_arch"

	# Fedora kernel-ark tags use "kernel-<version>-0" instead of the full
	# RPM release (e.g., kernel-6.16.5-0 not kernel-6.16.5-100.fc41)
	if [[ "$tag_name" == *.fc[0-9]* ]]; then
		local version="${tag_name%%-*}"
		tag_name="${version}-0"
	fi

	# Assuming always bisecting rt kernels newer than kernel-rt-5.14.0-284.rt14.284.el9
	echo "kernel-${tag_name}"
}

# Auto-detect GIT_REPO_URL from NVR dist tag
detect_git_repo_url() {
	local nvr=$1
	if [[ -n "$GIT_REPO_URL" ]]; then
		log "Using configured GIT_REPO_URL: $GIT_REPO_URL"
		return
	fi
	if [[ "$nvr" == *.el9.* || "$nvr" == *.el9 ]]; then
		GIT_REPO_URL="https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-9.git"
	elif [[ "$nvr" == *.el10.* || "$nvr" == *.el10 ]]; then
		GIT_REPO_URL="https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-10.git"
	elif [[ "$nvr" == *.fc*.* || "$nvr" == *.fc[0-9]* ]]; then
		GIT_REPO_URL="https://gitlab.com/cki-project/kernel-ark.git"
	else
		do_abort "Cannot auto-detect GIT_REPO_URL from NVR: $nvr. Please set GIT_REPO_URL in bisect.conf."
	fi
	log "Auto-detected GIT_REPO_URL: $GIT_REPO_URL"
}

# Transition from RPM bisect to source bisect after finding the 1st bad NVR
transition_to_source_bisect() {
	log "=== Transitioning from RPM bisect to source bisect ==="

	# HEAD is at the first bad commit in the fake repo
	local bad_nvr good_nvr
	bad_nvr=$(run_cmd_in_GIT_REPO cat k_rel)
	if ! good_nvr=$(run_cmd_in_GIT_REPO git show HEAD~1:k_rel 2>/dev/null); then
		do_abort "Cannot find the good NVR before the first bad NVR. The first entry in the RPM list may be bad."
	fi

	log "RPM bisect result: good=$good_nvr bad=$bad_nvr"

	local good_tag bad_tag
	good_tag=$(nvr_to_tag "$good_nvr")
	bad_tag=$(nvr_to_tag "$bad_nvr")
	log "Mapped to git tags: good=$good_tag bad=$bad_tag"

	# Auto-detect source repo URL
	detect_git_repo_url "$bad_nvr"

	# Save RPM bisect log before destroying the fake repo
	run_cmd_in_GIT_REPO git bisect log >"$WORK_DIR/rpm_bisect_final_log.txt"
	log "RPM bisect log saved to $WORK_DIR/rpm_bisect_final_log.txt"

	# Replace fake repo with real source repo
	run_cmd rm -rf "$GIT_REPO"
	if [[ -z $LOCAL_GIT_REPO ]] || ! setup_local_git_repo "$good_tag" "$bad_tag"; then
		log "Fetching source repo $GIT_REPO_URL (commits between $good_tag and $bad_tag)..."
		run_cmd git init "$GIT_REPO"
		run_cmd_in_GIT_REPO git remote add origin "$GIT_REPO_URL"
		# Step 1: Minimal fetch to get just the two tag objects
		if ! run_cmd_in_GIT_REPO git fetch --depth=1 origin tag "$good_tag" tag "$bad_tag"; then
			do_abort "Failed to fetch tags from source repo: $GIT_REPO_URL"
		fi
		# Step 2: Fill in commits between the two tags
		if ! run_cmd_in_GIT_REPO git fetch --shallow-exclude="$good_tag" origin tag "$bad_tag"; then
			do_abort "Failed to fetch commit range from source repo: $GIT_REPO_URL"
		fi
		# It seems there is no need to deepen by 1 because "git bisect" can start fine.
		# And "git fetch --deepen=1" somehow fails with
		#   error: RPC failed; HTTP 524 curl 22 The requested URL returned error: 524
		#   fatal: expected 'packfile'
		# # Step 3: Deepen by 1 to include the good_tag commit itself
		# run_cmd_in_GIT_REPO git fetch --deepen=1 origin
		# Withought checkout, git bisect start somehow will fail with the error
		#   "error: bad HEAD - strange symbolic ref"
		run_cmd_in_GIT_REPO git checkout "$bad_tag"
	fi

	# Resolve tags to commit hashes
	if ! GOOD_REF=$(run_cmd_in_GIT_REPO git rev-parse "$good_tag" 2>/dev/null); then
		do_abort "Git tag '$good_tag' not found in $GIT_REPO_URL"
	fi
	if ! BAD_REF=$(run_cmd_in_GIT_REPO git rev-parse "$bad_tag" 2>/dev/null); then
		do_abort "Git tag '$bad_tag' not found in $GIT_REPO_URL"
	fi

	log "Resolved source commits: good=$GOOD_REF bad=$BAD_REF"

	# Switch to git install strategy
	INSTALL_STRATEGY="git"
	_install_handler_initilized=""

	# Start new bisect
	log "Starting source bisect between $good_tag and $bad_tag"
	run_cmd_in_GIT_REPO git bisect start "$BAD_REF" "$GOOD_REF"
}

setup_criu() {
	[[ -n $KAB_TEST_HOST ]] && return 0

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
		if ! run_cmd command -v kdumpctl &>/dev/null; then
			if ! run_cmd dnf install kdump-utils -yq && ! run_cmd dnf install kexec-tools -yq; then
				log "Failed to install kdump-utils/kexec-tools!"
				exit 1
			fi
		fi

		if ! run_cmd grep -q "crashkernel" /proc/cmdline; then
			log "Setting up crashkernel via kdumpctl reset-crashkernel"
			# Assuming the system always have >=2G RAM
			run_cmd kdumpctl reset-crashkernel --kernel=ALL

			# crashkernel will only be set automatically for a newly installed
			# kernel if kdump.service is enabled
			if ! run_cmd systemctl enable kdump; then
				do_abort "KERNEL_RPM_LIST file not found."
			fi
			# kexec reboot by default inherit /proc/cmdline. So make sure
			# crashkernel exists in /proc/cmdline
			reboot_and_wait systemctl reboot
		else
			# Ensure kdump is running if crashkernel is already present
			run_cmd systemctl enable --now kdump
		fi
	fi
}

_auto_source_bisect=false
# Determine effective install strategy from config
#
# Auto mode: when INSTALL_STRATEGY is not set but KERNEL_RPM_LIST is provided,
# do RPM bisect first then automatically transition to source bisect
resolve_install_strategy() {
	# Explicit strategy takes precedence
	if [[ -n "$INSTALL_STRATEGY" ]]; then
		return
	fi

	if [[ -n "$KERNEL_RPM_LIST" ]]; then
		INSTALL_STRATEGY="rpm"
		_auto_source_bisect=true
	elif [[ -n "$GIT_REPO_URL" ]]; then
		if is_nvr "$BAD_COMMIT"; then
			INSTALL_STRATEGY="rpm"
			_auto_source_bisect=true
		else
			INSTALL_STRATEGY="git"
		fi
	fi
}

initialize() {
	local good_ref bad_ref

	load_config_and_handlers

	# In SSH mode, use a user-writable local directory for logs and reports
	# while remote paths (GIT_REPO etc.) remain unchanged
	if [[ -n $KAB_TEST_HOST && "$(id -u)" != 0 ]]; then
		NONROOT_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kernel-auto-bisect"
		mkdir -p "$NONROOT_LOG_DIR"
		LOG_FILE="$NONROOT_LOG_DIR/main.log"
	fi

	mkdir -p "$WORK_DIR"

	resolve_install_strategy

	good_ref="$GOOD_COMMIT"
	bad_ref="$BAD_COMMIT"
	# Store original kernel in memory so
	# - it will be restored when bisecting is finished or aborted
	# - "make localmodconfig" can work in case the running test kernel gets removed
	if ! ORIGINAL_KERNEL=$(get_original_kernel) || ! run_cmd test -f "$ORIGINAL_KERNEL"; then
		ORIGINAL_KERNEL=""
		do_abort "Failed to get original kernel, current running kernel may be removed"
	fi

	# shellcheck disable=SC2034
	ORIGINAL_KERNEL_RELEASE=$(run_cmd uname -r)

	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
		if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
		generate_git_repo_from_package_list
		good_ref=${release_commit_map[$GOOD_COMMIT]}
		bad_ref=${release_commit_map[$BAD_COMMIT]}
		if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then do_abort "Could not find GOOD/BAD versions in RPM list."; fi
	elif [[ "$INSTALL_STRATEGY" == "git" ]]; then
		if [[ -n $LOCAL_GIT_REPO ]] && setup_local_git_repo "$GOOD_COMMIT" "$BAD_COMMIT"; then
			true
		elif run_cmd test -d "$GIT_REPO"/.git; then
			log "$GIT_REPO already exists, reuse it"
		else
			[[ -n $GIT_REPO_BRANCH ]] && branch_arg=--branch=$GIT_REPO_BRANCH
			# shellcheck disable=SC2086 # $branch_arg can be empty
			if ! run_cmd git clone "$GIT_REPO_URL" $branch_arg "$GIT_REPO"; then
				do_abort "Failed to clone $GIT_REPO_URL"
			fi
		fi
	fi

	# Save resolved references in memory
	GOOD_REF="$good_ref"
	BAD_REF="$bad_ref"

	setup_criu
	setup_kdump
}

verify_intial_commits() {
	if [[ "$VERIFY_COMMITS" == "no" ]]; then
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

	[[ -n $https_proxy ]] && _cmd+=("https_proxy=$https_proxy")

	if [[ $1 == "-cwd" ]]; then
		_dir=$2
		_cmd+=(cd "'$_dir'" "&&")
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

# Copy LOCAL_GIT_REPO to remote KAB_TEST_HOST, or use it directly if local
#
# setup_local_git_repo [good_ref bad_ref]
#
# If good_ref and bad_ref are provided, verify they exist in the local repo.
# Returns 1 if validation fails so callers can fall back to cloning.
setup_local_git_repo() {
	local good_ref=$1 bad_ref=$2

	if [[ -n $good_ref ]]; then
		if ! git -C "$LOCAL_GIT_REPO" rev-parse "$good_ref" &>/dev/null; then
			log "WARNING: '$good_ref' not found in $LOCAL_GIT_REPO, falling back to cloning"
			return 1
		fi
		if ! git -C "$LOCAL_GIT_REPO" rev-parse "$bad_ref" &>/dev/null; then
			log "WARNING: '$bad_ref' not found in $LOCAL_GIT_REPO, falling back to cloning"
			return 1
		fi
	fi

	if [[ -n $KAB_TEST_HOST ]]; then
		local _ssh_opts=()
		if [[ -f $KAB_TEST_HOST_SSH_KEY ]]; then
			_ssh_opts+=("-i" "$KAB_TEST_HOST_SSH_KEY" -o IdentitiesOnly=yes)
		fi
		# Only copy .git dir to save bandwidth and avoid git bisect start
		# failures caused by conflicted working tree files
		log "Copying $LOCAL_GIT_REPO/.git to $KAB_TEST_HOST:$GIT_REPO/.git..."
		run_cmd mkdir -p "$GIT_REPO"
		if ! rsync -a -e "ssh ${_ssh_opts[*]}" "$LOCAL_GIT_REPO/.git/" "$KAB_TEST_HOST:$GIT_REPO/.git/"; then
			do_abort "Failed to copy $LOCAL_GIT_REPO/.git to $KAB_TEST_HOST:$GIT_REPO"
		fi
		# Somehow, running "git checkout in the copied repo failes with error
		# "fatal: detected dubious ownership in repository"
		run_cmd chown -R root:root "$GIT_REPO"
		# Reset the repo to show the sourc file. Note "git checkout" won't check out files.
		run_cmd_in_GIT_REPO git reset --hard
		# Without checkout, git bisect start somehow will fail with the error
		#   "error: bad HEAD - strange symbolic ref"
		run_cmd_in_GIT_REPO git checkout "$bad_ref"
	else
		GIT_REPO="$LOCAL_GIT_REPO"
	fi
	log "Using local git repo: $LOCAL_GIT_REPO"
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
	if [[ -z "$ORIGINAL_KERNEL" ]]; then
		log "Original kernel not set, something wrong"
		return
	fi
	set_boot_kernel "$ORIGINAL_KERNEL"
	reboot_and_wait systemctl reboot
}

finish() {
	generate_final_report
	reboot_to_origin_kernel
}
