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

	Describe "find_good_commit in git mode"
		setup_git_repo() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/git_repo"
			KAB_TEST_HOST=""
			INSTALL_STRATEGY="git"
			mkdir -p "$GIT_REPO"
			(
				cd "$GIT_REPO"
				git init -q
				git config user.name test
				git config user.email test@test
				echo "init" >file
				git add file
				git commit -m "commit0" -q  # HEAD~4 (good)
				echo "c1" >>file && git commit -am "commit1" -q  # HEAD~3
				echo "c2" >>file && git commit -am "commit2" -q  # HEAD~2
				echo "c3" >>file && git commit -am "commit3" -q  # HEAD~1
				echo "c4" >>file && git commit -am "commit4" -q  # HEAD (bad)
			) >/dev/null 2>&1
		}

		cleanup_git_repo() {
			rm -rf "${SHELLSPEC_WORKDIR}/git_repo"
		}

		Before 'setup_git_repo'
		After 'cleanup_git_repo'

		It "finds the good commit via exponential search"
			# Mock commit_good: only HEAD~4 (commit0) is good
			commit_good() {
				local commit=$1
				local good_commit
				good_commit=$(git -C "$GIT_REPO" rev-parse HEAD~4)
				[[ "$commit" == "$good_commit" ]]
			}

			bad_ref=$(git -C "${SHELLSPEC_WORKDIR}/git_repo" rev-parse HEAD)
			When call find_good_commit "$bad_ref"
			The status should be success
			The variable GOOD_REF should equal "$(git -C "${SHELLSPEC_WORKDIR}/git_repo" rev-parse HEAD~4)"
			The stdout should include "Auto-discovering good commit"
			The stdout should include "Found good commit:"
		End
	End
End
