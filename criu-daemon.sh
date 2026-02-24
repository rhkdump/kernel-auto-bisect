#!/bin/bash
#
# criu-daemon.sh: External daemon for managing CRIU checkpoint/restore and reboots
# This daemon runs independently and handles the checkpoint → reboot → restore cycle
#

set -x
single_instance_lock() {
	local _lockfile

	_lockfile=/run/lock/kernel-auto-bisect-criu.lock

	EXEC_FD=200

	if ! exec 200>$_lockfile; then
		derror "Create file lock failed"
		exit 1
	fi

	flock -n "$EXEC_FD" || {
		echo "ERROR: An instance of the script is already running." >&2
		exit 1
	}
}

single_instance_lock
# shellcheck source=lib.sh
source /usr/local/bin/kernel-auto-bisect/lib.sh

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') [CRIU-DAEMON] - $1" | tee -a "$CRIU_LOG_FILE"
}

init_daemon() {
	mkdir -p "$WORK_DIR" "$DUMP_DIR" "$DUMP_LOG_DIR" "$SIGNAL_DIR"
	log "CRIU daemon started, monitoring for signals"
}

find_bisect_pid() {
	pgrep -f "$BISECT_SCRIPT" | head -n1
}

do_checkpoint() {
	local bisect_pid
	bisect_pid=$(find_bisect_pid)
	if [[ -z "$bisect_pid" ]]; then
		log "ERROR: No bisection process found to checkpoint"
		return 1
	fi

	log "Checkpointing bisection process (PID: $bisect_pid)"
	log_num=$(find "$DUMP_LOG_DIR" -name "dump*_cmd.log" 2>/dev/null | wc -l)
	((++log_num))
	dump_log=$DUMP_LOG_DIR/dump${log_num}.log
	cmd_log=$DUMP_LOG_DIR/dump${log_num}_cmd.log
	if criu dump -t "$bisect_pid" -D "$DUMP_DIR" --shell-job -v4 -o $dump_log &>$cmd_log; then
		log "Checkpoint successful"
		return 0
	else
		rm -rf "${DUMP_DIR:?}"/*
		log "ERROR: Checkpoint failed"
		return 1
	fi
}

do_restore() {
	rm -f "$CHECKPOINT_SIGNAL"
	if [ -d "$DUMP_DIR" ] && ls "$DUMP_DIR"/core-*.img 1>/dev/null 2>&1; then
		log "Restoring bisection process from checkpoint"
		# prevent "PID mismatch on restore" https://criu.org/When_C/R_fails
		unshare -p -m --fork --mount-proc

		log_num=$(find "$DUMP_LOG_DIR" -name "restore*_cmd.log" 2>/dev/null | wc -l)
		((++log_num))
		restore_log=$DUMP_LOG_DIR/retore${log_num}.log
		cmd_log=$DUMP_LOG_DIR/retore${log_num}_cmd.log
		if criu restore -v4 -D "$DUMP_DIR" --shell-job --restore-detached -o $restore_log &>$cmd_log; then
			log "Restore successful"
			touch "$RESTORE_FLAG"
			# Clean up checkpoint files after successful restore
			rm -rf "${DUMP_DIR:?}"/*
			return 0
		else
			log "ERROR: Restore failed"
			return 1
		fi
	else
		log "No checkpoint found to restore"
		return 1
	fi
}

handle_checkpoint() {
	local _cmd_file=

	_cmd_file=${CHECKPOINT_SIGNAL}_cmd

	# delete $CHECKPOINT_SIGNAL to avoid it being repeatedly consumed
	mv $CHECKPOINT_SIGNAL "$_cmd_file"
	rm -f "$CHECKPOINT_SIGNAL"

	log "Received checkpoint+panic request"
	if ! grep -e sysrq-trigger -e reboot "$_cmd_file"; then
		return 1
	fi
	if do_checkpoint; then
		log "Process request: $(<$_cmd_file)"
		bash "$_cmd_file"
		exit 0
	else
		log "Checkpoint failed"
	fi
}

main_loop() {
	while true; do
		if [[ -f "$CHECKPOINT_SIGNAL" ]]; then
			handle_checkpoint
		fi
		sleep 1
	done
}

init_daemon
do_restore
main_loop
