#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k

. ../test_lib.sh

[[ -z $ARCH ]] && ARCH=$(uname -m)

if echo "${CLIENTS}" | grep -qi "${HOSTNAME}"; then
	cd "$TMT_TREE" || exit 1
	# Run from source directory - no make install needed

	KAB_SCRIPT=$TMT_TREE/kab.sh
	CONF_FILE=$TMT_TREE/bisect.conf
	TEST_SCRIPT=$TMT_TREE/test.sh
	GIT_REPO_URL=https://gitlab.com/cki-project/kernel-ark.git
	REMOTE_GIT_REPO=/var/local/kernel-auto-bisect/git_repo

	TMT_TEST_PLAN_ROOT=${TMT_PLAN_DATA%data}
	if [ -z "$SERVER_SSH_KEY" ]; then
		SERVER_SSH_KEY=${TMT_TEST_PLAN_ROOT}/provision/server/id_ecdsa
	fi
	ssh_args=(-o BatchMode=yes -o IdentitiesOnly=yes)
	if [[ -f $SERVER_SSH_KEY ]]; then
		ssh_args+=(-i "$SERVER_SSH_KEY")
	fi
	ssh_args+=("root@${SERVERS}")
	# Add $SERVERS to known host
	if ! ssh -o StrictHostKeyChecking=accept-new "${ssh_args[@]}" "exit 0"; then
		echo "Failed to connect"
		exit 1
	fi

	LOCAL_REPO=~/local_linux_repo
	[[ -z $KAB_LOCAL_GIT_REPO ]] && git clone "$GIT_REPO_URL" --depth=4 "$LOCAL_REPO"

	GOOD_COMMIT=$(git -C "$LOCAL_REPO" log -1 --pretty=format:'%h' HEAD~3)
	BAD_COMMIT=$(git -C "$LOCAL_REPO" log -1 --pretty=format:'%h' HEAD)

	cat <<END >"$CONF_FILE"
INSTALL_STRATEGY="git"
TEST_STRATEGY="panic"
GIT_REPO_URL=$GIT_REPO_URL
LOCAL_GIT_REPO=$LOCAL_REPO
BAD_COMMIT=$BAD_COMMIT
REPRODUCER_SCRIPT=$TEST_SCRIPT
KAB_TEST_HOST=root@${SERVERS}
END

	if [[ -f "$SERVER_SSH_KEY" ]]; then
		echo "KAB_TEST_HOST_SSH_KEY=${SERVER_SSH_KEY}" >>"$CONF_FILE"
	fi

	cat <<END >"$TEST_SCRIPT"
#!/bin/bash
on_test() {
    kernel_ver=\$(uname -r)
    echo \$kernel_ver
    if [[ \$kernel_ver == *$GOOD_COMMIT* ]]; then
        return 0
    elif [[ \$kernel_ver == *$BAD_COMMIT* ]]; then
        return 1
    else
        return 0
    fi
}
END

	bash -x "$KAB_SCRIPT" </dev/null 2>"$XTRACE_LOG"
	KAB_EXIT=$?

	LOCAL_STATE_DIR=~/.local/state/kernel-auto-bisect

	if [[ $KAB_EXIT -ne 0 ]]; then
		echo "FAIL: kab.sh failed as non-root user (exit=$KAB_EXIT)"
		cat "$XTRACE_LOG"
		cat "$LOCAL_STATE_DIR/main.log" 2>/dev/null
		exit 1
	fi
	echo "kab.sh ran successfully as non-root user"

	# Verify 1: Bisect found the first bad commit on the remote
	if ssh "${ssh_args[@]}" "cd $REMOTE_GIT_REPO && git bisect log" | grep "first bad commit" | grep -q "$BAD_COMMIT"; then
		echo "Found 1st bad commit"
	else
		echo "FAIL: bisect did not find the first bad commit"
		exit 1
	fi

	# Verify 2: Logs were written to user-writable location (not /var/local/)
	if [[ -f "$LOCAL_STATE_DIR/main.log" ]]; then
		echo "Logs written to user-writable location: $LOCAL_STATE_DIR"
	else
		echo "FAIL: Logs not found at $LOCAL_STATE_DIR/main.log"
		exit 1
	fi

fi
