#!/bin/bash

Describe 'find-good-commit'
	Include ./lib.sh

	setup_log() { LOG_FILE="${SHELLSPEC_WORKDIR}/test.log"; }
	Before 'setup_log'

	Describe "generate_git_repo_from_package_list populates _rpm_releases"
		setup_rpm_list() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/rpm_repo"
			KAB_TEST_HOST=""
			KERNEL_RPM_LIST="${SHELLSPEC_WORKDIR}/rpm_list.txt"
			cat >"$KERNEL_RPM_LIST" <<'EOF'
https://example.com/kernel-core-6.16.4-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.5-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.6-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.7-100.fc41.x86_64.rpm
EOF
		}

		cleanup_rpm_list() {
			rm -rf "${SHELLSPEC_WORKDIR}/rpm_repo"
		}

		Before 'setup_rpm_list'
		After 'cleanup_rpm_list'

		It "stores releases in order"
			When call generate_git_repo_from_package_list
			The variable '_rpm_releases[0]' should equal "6.16.4-100.fc41.x86_64"
			The variable '_rpm_releases[1]' should equal "6.16.5-100.fc41.x86_64"
			The variable '_rpm_releases[2]' should equal "6.16.6-100.fc41.x86_64"
			The variable '_rpm_releases[3]' should equal "6.16.7-100.fc41.x86_64"
			The stdout should include "Generating fake git repository for RPM list..."
		End
	End
End
