#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
set -x

. ./tmt.sh

[[ -z $ARCH ]] && ARCH=$(uname -m)

if echo "${CLIENTS}" | grep -qi "${HOSTNAME}"; then
	cd "$TMT_TREE" || exit 1
	make install

	KAB_SCRIPT=/usr/local/bin/kernel-auto-bisect/kab.sh
	CONF_FILE=/usr/local/bin/kernel-auto-bisect/bisect.conf
	TEST_SCRIPT=/usr/local/bin/kernel-auto-bisect/test.sh
	KERNEL_RPM_LIST=/usr/local/bin/kernel-auto-bisect/kernel_list
	GOOD_COMMIT=6.16.4-100.fc41.${ARCH}
	BAD_COMMIT=6.16.7-100.fc41.${ARCH}

	TMT_TEST_PLAN_ROOT=${TMT_PLAN_DATA%data}
	SERVER_SSH_KEY=${TMT_TEST_PLAN_ROOT}/provision/server/id_ecdsa
	# Add $SERVERS to known host
	if [[ -f "$SERVER_SSH_KEY" ]]; then
		ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$SERVER_SSH_KEY" "${SERVERS}" "exit 0"
	else
		ssh -o StrictHostKeyChecking=accept-new "${SERVERS}" "exit 0"
	fi
	cat <<END >"$CONF_FILE"
INSTALL_STRATEGY="rpm"
TEST_STRATEGY="panic"
REBOOT_STRATEGY=
RPM_CACHE_DIR="/var/cache/kdump-bisect-rpms"
GOOD_COMMIT=$GOOD_COMMIT
BAD_COMMIT=$BAD_COMMIT
REPRODUCER_SCRIPT=$TEST_SCRIPT
KERNEL_RPM_LIST=$KERNEL_RPM_LIST
KAB_TEST_HOST=${SERVERS}
END
	if [[ -f "$SERVER_SSH_KEY" ]]; then
		echo "KAB_TEST_HOST_SSH_KEY=${SERVER_SSH_KEY}" >>"$CONF_FILE"
	fi

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
	GIT_REPO=/var/local/kernel-auto-bisect/git_repo
	MAX_WAIT_TIME=600
	wait_time=0
	cd "$GIT_REPO" || exit 1

	if [[ -f "$SERVER_SSH_KEY" ]]; then
		ssh_cmd="ssh -o IdentitiesOnly=yes -i $SERVER_SSH_KEY"
	else
		ssh_cmd="ssh"
	fi
	if $ssh_cmd "${SERVERS}" "cd $GIT_REPO && git bisect log" | grep "first bad commit" | grep -q "$BAD_COMMIT"; then
		echo "Found 1st bad commit"
	else
		exit 1
	fi
elif echo "${SERVERS}" | grep -qi "${HOSTNAME}"; then
	dnf install kdump-utils -yq
	kdumpctl reset-crashkernel --kernel=ALL
	systemctl enable --now kdump
fi
