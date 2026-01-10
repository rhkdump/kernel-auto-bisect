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
	GIT_REPO_URL=https://gitlab.com/cki-project/kernel-ark.git
	GIT_REPO=/var/local/kernel-auto-bisect/git_repo

	TMT_TEST_PLAN_ROOT=${TMT_PLAN_DATA%data}
	if [ -z $SERVER_SSH_KEY ]; then
		SERVER_SSH_KEY=${TMT_TEST_PLAN_ROOT}/provision/server/id_ecdsa
	fi
	ssh_args=(-o BatchMode=yes -o IdentitiesOnly=yes)
	if [[ -f $SERVER_SSH_KEY ]]; then
		ssh_args+=(-i "$SERVER_SSH_KEY")
	fi
	ssh_args+=(${SERVERS})
	# Add $SERVERS to known host
	if ! ssh -o StrictHostKeyChecking=accept-new "${ssh_args[@]}" "exit 0"; then
		echo "Failed to connect"
		exit 1
	fi

	if ! ssh "${ssh_args[@]}" test -d "$GIT_REPO/.git"; then
		if ! ssh "${ssh_args[@]}" "git clone $GIT_REPO_URL --depth=4 $GIT_REPO"; then
			echo "Failed to clone $GIT_REPO_URL"
			exit 1
		fi
	fi

	if ! GOOD_COMMIT=$(ssh "${ssh_args[@]}" "cd $GIT_REPO && git log -1 --pretty=format:'%h' HEAD~3"); then
		echo "Failed to get initial good commit"
		exit 1
	fi
	if ! BAD_COMMIT=$(ssh "${ssh_args[@]}" "cd $GIT_REPO && git log -1 --pretty=format:'%h' HEAD"); then
		echo "Failed to get initialbad commit"
		exit 1
	fi

	cat <<END >"$CONF_FILE"
INSTALL_STRATEGY="git"
TEST_STRATEGY="panic"
GIT_REPO_URL=$GIT_REPO_URL
GIT_REPO=$GIT_REPO
GOOD_COMMIT=$GOOD_COMMIT
BAD_COMMIT=$BAD_COMMIT
REPRODUCER_SCRIPT=$TEST_SCRIPT
KAB_TEST_HOST=${SERVERS}
KAB_TEST_HOST_SSH_KEY=${SERVER_SSH_KEY}
END

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

	bash -x $KAB_SCRIPT </dev/null &>/root/test.log

	if ssh -o IdentitiesOnly=yes -i "$SERVER_SSH_KEY" "${SERVERS}" "cd $GIT_REPO && git bisect log" | grep -q "first bad commit"; then
		echo "Found 1st bad commit"
	else
		exit 1
	fi

elif echo "${SERVERS}" | grep -qi "${HOSTNAME}"; then
	dnf install kdump-utils -yq
	kdumpctl reset-crashkernel --kernel=ALL
	systemctl enable --now kdump
fi
