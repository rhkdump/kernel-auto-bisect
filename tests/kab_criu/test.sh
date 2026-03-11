#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
set -x

TMT_SLEEP_MARK=5.421379
[[ -z $ARCH ]] && ARCH=$(uname -m)

if [[ $TMT_TEST_RESTART_COUNT == 0 ]]; then
	cd "$TMT_TREE" || exit 1
	make install

	KAB_SCRIPT=/usr/local/bin/kernel-auto-bisect/kab.sh
	CONF_FILE=/usr/local/bin/kernel-auto-bisect/bisect.conf
	TEST_SCRIPT=/usr/local/bin/kernel-auto-bisect/test.sh
	KERNEL_RPM_LIST=/usr/local/bin/kernel-auto-bisect/kernel_list
	GOOD_COMMIT=6.16.4-100.fc41.${ARCH}
	BAD_COMMIT=6.16.7-100.fc41.${ARCH}

	cat <<END >"$CONF_FILE"
INSTALL_STRATEGY="rpm"
TEST_STRATEGY="panic"
REBOOT_STRATEGY=
RPM_CACHE_DIR="/var/cache/kdump-bisect-rpms"
GOOD_COMMIT=$GOOD_COMMIT
BAD_COMMIT=$BAD_COMMIT
REPRODUCER_SCRIPT=$TEST_SCRIPT
KERNEL_RPM_LIST=$KERNEL_RPM_LIST
TMT_SLEEP_MARK=$TMT_SLEEP_MARK
END

	cat <<END >$KERNEL_RPM_LIST
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.4/100.fc41/${ARCH}/kernel-core-6.16.4-100.fc41.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.5/100.fc41/${ARCH}/kernel-core-6.16.5-100.fc41.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.6/100.fc41/${ARCH}/kernel-core-6.16.6-100.fc41.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.7/100.fc41/${ARCH}/kernel-core-6.16.7-100.fc41.${ARCH}.rpm
END

	cat <<END >"$TEST_SCRIPT"
#!/bin/bash
on_test() {
    kernel_ver=\$(uname -r)
    echo \$kernel_ver
    if [[ \$kernel_ver == $GOOD_COMMIT ]]; then
        return 0
    elif [[ \$kernel_ver == $BAD_COMMIT ]]; then
        return 1
    else
        return 0
    fi
}
END

	bash -x $KAB_SCRIPT </dev/null &>/root/test.log
	# Make TMT wait for 120s the system to gets rebooted.
	# CRIU may freeze kab.sh and tmt will regard the test as finished,
	#  - If the system gets rebooted while TMT is collecting the test results,
	#    TMT will abort with "plan failed".
	#
	#  - If the system gets rebooted after TMT finishes collecting the test
	#    results, TMT will exit with "test passed"
	sleep 120
	echo "Something wrong, this line of code should never be reached"
	exit 1
else
	GIT_REPO=/var/local/kernel-auto-bisect/git_repo
	MAX_WAIT_TIME=600
	wait_time=0
	cd "$GIT_REPO" || exit 1

	until git bisect log | grep -q "first bad commit" || [[ $wait_time -ge $MAX_WAIT_TIME ]]; do
		sleep $TMT_SLEEP_MARK
		wait_time=$((wait_time + SLEEP_TIME))
	done
	if [[ $wait_time -ge $MAX_WAIT_TIME ]]; then
		echo "Failed to get 1st bad commit"
		exit 1
	fi
fi
