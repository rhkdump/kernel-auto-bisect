#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k

. ../test_lib.sh

[[ -z $ARCH ]] && ARCH=$(uname -m)

if echo "${CLIENTS}" | grep -qi "${HOSTNAME}"; then
	cd "$TMT_TREE" || exit 1
	make install

	KAB_SCRIPT=/usr/local/bin/kernel-auto-bisect/kab.sh
	CONF_FILE=/usr/local/bin/kernel-auto-bisect/bisect.conf
	TEST_SCRIPT=/usr/local/bin/kernel-auto-bisect/test.sh
	KERNEL_RPM_LIST=/usr/local/bin/kernel-auto-bisect/kernel_list
	WORK_DIR=/var/local/kernel-auto-bisect
	GIT_REPO=$WORK_DIR/git_repo
	GOOD_COMMIT=6.19.2-300.fc44.${ARCH}
	BAD_COMMIT=6.19.8-200.fc43.${ARCH}

	TMT_TEST_PLAN_ROOT=${TMT_PLAN_DATA%data}
	SERVER_SSH_KEY=${TMT_TEST_PLAN_ROOT}/provision/server/id_ecdsa
	# Add $SERVERS to known host
	if [[ -f "$SERVER_SSH_KEY" ]]; then
		ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$SERVER_SSH_KEY" "${SERVERS}" "exit 0"
	else
		ssh -o StrictHostKeyChecking=accept-new "${SERVERS}" "exit 0"
	fi

	# Note: INSTALL_STRATEGY is intentionally omitted to trigger auto mode
	# Note: GIT_REPO_URL is intentionally omitted to test auto-detection from NVR
	cat <<END >"$CONF_FILE"
TEST_STRATEGY="panic"
REBOOT_STRATEGY=
RPM_CACHE_DIR="/var/cache/kdump-bisect-rpms"
GOOD_COMMIT=$GOOD_COMMIT
BAD_COMMIT=$BAD_COMMIT
REPRODUCER_SCRIPT=$TEST_SCRIPT
KERNEL_RPM_LIST=$KERNEL_RPM_LIST
KAB_TEST_HOST=${SERVERS}
END

	if [[ -n $KAB_LOCAL_GIT_REPO ]]; then
		echo "LOCAL_GIT_REPO=$KAB_LOCAL_GIT_REPO" >>$CONF_FILE
	fi

	if [[ -f "$SERVER_SSH_KEY" ]]; then
		echo "KAB_TEST_HOST_SSH_KEY=${SERVER_SSH_KEY}" >>"$CONF_FILE"
	fi

	cat <<END >$KERNEL_RPM_LIST
https://kojipkgs.fedoraproject.org/packages/kernel/6.19.2/300.fc44/${ARCH}/kernel-core-6.19.2-300.fc44.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.19.6/200.fc43/${ARCH}/kernel-core-6.19.6-200.fc43.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.19.7/200.fc43/${ARCH}/kernel-core-6.19.7-200.fc43.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.19.8/200.fc43/${ARCH}/kernel-core-6.19.8-200.fc43.${ARCH}.rpm
END

	# During RPM phase: BAD_COMMIT NVR returns 1 (bad), everything else 0 (good).
	# During source phase: uname -r won't match any NVR, so returns 0 (good),
	# and bisect converges to the bad tag commit as the first bad commit.
	cat <<END >"$TEST_SCRIPT"
#!/bin/bash
on_test() {
    kernel_ver=\$(uname -r)
    echo \$kernel_ver
    if [[ \$kernel_ver == $BAD_COMMIT ]]; then
        return 1
    else
        return 0
    fi
}
END

	bash -x $KAB_SCRIPT </dev/null 2>"$XTRACE_LOG"

	if [[ -f "$SERVER_SSH_KEY" ]]; then
		ssh_cmd="ssh -o IdentitiesOnly=yes -i $SERVER_SSH_KEY"
	else
		ssh_cmd="ssh"
	fi

	# Verify 1: RPM bisect log was saved and found the first bad NVR
	if grep -q "first bad commit" "$WORK_DIR/rpm_bisect_final_log.txt"; then
		echo "RPM bisect completed successfully"
	else
		echo "FAIL: RPM bisect log missing or incomplete"
		exit 1
	fi

	# Verify 2: Source bisect completed and found the first bad commit
	if $ssh_cmd "${SERVERS}" "cd $GIT_REPO && git bisect log" | grep -q "first bad commit"; then
		echo "Source bisect completed successfully"
	else
		echo "FAIL: Source bisect did not find the first bad commit"
		exit 1
	fi

	# Verify 3: GIT_REPO is now a real source repo (not the fake RPM repo)
	if $ssh_cmd "${SERVERS}" "test -f $GIT_REPO/Makefile"; then
		echo "GIT_REPO contains kernel source tree"
	else
		echo "FAIL: GIT_REPO does not contain kernel source"
		exit 1
	fi

fi
