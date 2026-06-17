#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. ../test_lib.sh

[[ -z $ARCH ]] && ARCH=$(uname -m)

if echo "${SERVERS}" | grep -qi "${HOSTNAME}"; then
	exit 0
fi

if ! echo "${CLIENTS}" | grep -qi "${HOSTNAME}"; then
	echo "Something wrong, can't find test client"
	exit 1
fi

TARGET_HOST="${SERVERS}"

TMT_TEST_PLAN_ROOT=${TMT_PLAN_DATA%data}
SERVER_SSH_KEY=${TMT_TEST_PLAN_ROOT}/provision/server/id_ecdsa

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

if [[ -f "$SERVER_SSH_KEY" ]]; then
	ssh_opts+=(-o IdentitiesOnly=yes -i $SERVER_SSH_KEY)
fi

# ssh_cmd wrapper to handle local and remote execution
ssh_cmd() {
	ssh "${ssh_opts[@]}" "$TARGET_HOST" "$@"
	return $?
}

copy_xtrace_log() {
	scp "${ssh_opts[@]}" "${TARGET_HOST}:${XTRACE_LOG}" "$XTRACE_LOG"
}

if ! ssh_cmd "cd $TMT_TREE && make install"; then
	echo "Failed to install KAB on ${SERVERS}"
	exit 1
fi

KAB_SCRIPT=/usr/local/bin/kernel-auto-bisect/kab.sh
CONF_FILE=/usr/local/bin/kernel-auto-bisect/bisect.conf
TEST_SCRIPT=/usr/local/bin/kernel-auto-bisect/test.sh
KERNEL_RPM_LIST=/usr/local/bin/kernel-auto-bisect/kernel_list
GIT_REPO=/var/local/kernel-auto-bisect/git_repo
GOOD_COMMIT=6.16.4-100.fc41.${ARCH}
BAD_COMMIT=6.16.7-100.fc41.${ARCH}

# 1. Prepare Target
echo "Waiting for target ($TARGET_HOST) to be ready..."
until ssh_cmd "test -f $KAB_SCRIPT"; do
	sleep 5
done

cat <<END | ssh_cmd "cat >$CONF_FILE"
INSTALL_STRATEGY="rpm"
TEST_STRATEGY="panic"
REBOOT_STRATEGY=
RPM_CACHE_DIR="/var/cache/kdump-bisect-rpms"
BAD_COMMIT=$BAD_COMMIT
REPRODUCER_SCRIPT=$TEST_SCRIPT
KERNEL_RPM_LIST=$KERNEL_RPM_LIST
END

cat <<END | ssh_cmd "cat >$KERNEL_RPM_LIST"
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.4/100.fc41/${ARCH}/kernel-core-6.16.4-100.fc41.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.5/100.fc41/${ARCH}/kernel-core-6.16.5-100.fc41.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.6/100.fc41/${ARCH}/kernel-core-6.16.6-100.fc41.${ARCH}.rpm
https://kojipkgs.fedoraproject.org/packages/kernel/6.16.7/100.fc41/${ARCH}/kernel-core-6.16.7-100.fc41.${ARCH}.rpm
END

cat <<END | ssh_cmd "cat >$TEST_SCRIPT"
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

# For idempotence
ssh_cmd "rm -rf $GIT_REPO"

# 2. Start kab.sh on Target if not already running and no checkpoint exists
if ! ssh_cmd "pgrep -f $KAB_SCRIPT" >/dev/null 2>&1 && ! ssh_cmd "ls /var/local/kernel-auto-bisect/dump/core-*.img" >/dev/null 2>&1; then
	echo "Starting kab.sh..."
	ssh_cmd "setsid bash -x $KAB_SCRIPT </dev/null &>$XTRACE_LOG &"
fi

# 3. Wait for result
MAX_WAIT_TIME=600 # 10 minutes
wait_time=0
MAIN_LOG_REMOTE=/var/local/kernel-auto-bisect/main.log
MAIN_LOG_LOCAL=/tmp/kab-main.log
printed_lines=0

while [[ $wait_time -lt $MAX_WAIT_TIME ]]; do
	# Try to check if finished
	output=$(ssh_cmd "git -C $GIT_REPO bisect log 2>/dev/null | grep 'first bad commit' | grep -q '$BAD_COMMIT'")
	ret=$?

	if [[ $ret -eq 0 ]]; then
		copy_xtrace_log
		exit 0
	fi

	# Rsync the remote log and print only new lines
	rsync -a "${ssh_opts[@]}" "${TARGET_HOST}:${MAIN_LOG_REMOTE}" "$MAIN_LOG_LOCAL" 2>/dev/null
	current_total=$(wc -l <"$MAIN_LOG_LOCAL" 2>/dev/null || echo 0)
	if [[ $current_total -gt $printed_lines ]]; then
		tail -n +$((printed_lines + 1)) "$MAIN_LOG_LOCAL"
		printed_lines=$current_total
	fi
	sleep 10
	wait_time=$((wait_time + 10))
done

copy_xtrace_log
echo "Failed to get 1st bad commit within $MAX_WAIT_TIME seconds"
exit 1
