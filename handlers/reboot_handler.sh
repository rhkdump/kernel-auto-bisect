#!/bin/bash
#
# reboot_handler.sh: Contains strategies for rebooting the system.
#

run_reboot_strategy() {
	prepare_reboot

	[[ -z $REBOOT_STRATEGY ]] && REBOOT_STRATEGY=reboot
	case "$REBOOT_STRATEGY" in
	reboot) do_full_reboot ;;
	kexec) do_kexec_reboot ;;
	*) do_abort "Unknown REBOOT_STRATEGY: ${REBOOT_STRATEGY}" ;;
	esac
}

kab_reboot() {
	reboot_and_wait systemctl reboot
}

signal_checkpoint_reboot() {
	signal_checkpoint "reboot"
}

do_full_reboot() {
	log "Strategy: Performing full reboot"
	if [[ -n $KAB_TEST_HOST ]]; then
		kab_reboot
	else
		log "Will use CRIU to restore the program"
		signal_checkpoint_reboot
	fi
}

do_kexec_reboot() {
	if [[ -z $KAB_TEST_HOST ]]; then
		log "Strategy: kexec not supported with CRIU checkpointing, using full reboot..."
		do_full_reboot
		return
	fi

	log "Strategy: Performing kexec reboot (fast reboot)"
	if ! kexec_load_kernel "$TESTED_KERNEL"; then
		log "Falling back to full reboot"
		kab_reboot
		return
	fi
	kab_kexec
}
