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

		It "aborts when no good commit is found"
			# Mock commit_good: everything is bad
			commit_good() { return 1; }

			bad_ref=$(git -C "${SHELLSPEC_WORKDIR}/git_repo" rev-parse HEAD)
			When run find_good_commit "$bad_ref"
			The status should be failure
			The output should include "Could not find a good commit"
			The output should include "Please set GOOD_COMMIT manually"
		End
	End

	Describe "find_good_commit in RPM mode"
		setup_rpm_find() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/rpm_find_repo"
			KAB_TEST_HOST=""
			INSTALL_STRATEGY="rpm"
			KERNEL_RPM_LIST="${SHELLSPEC_WORKDIR}/rpm_find_list.txt"
			cat >"$KERNEL_RPM_LIST" <<'EOF'
https://example.com/kernel-core-6.16.4-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.5-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.6-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.7-100.fc41.x86_64.rpm
EOF
			BAD_COMMIT="6.16.7-100.fc41.x86_64"
		}

		cleanup_rpm_find() {
			rm -rf "${SHELLSPEC_WORKDIR}/rpm_find_repo"
		}

		Before 'setup_rpm_find'
		After 'cleanup_rpm_find'

		It "finds a good release via exponential search"
			generate_git_repo_from_package_list

			# Mock commit_good: only 6.16.4 is good (index 0)
			commit_good() {
				local commit=$1
				[[ "$commit" == "${release_commit_map[6.16.4-100.fc41.x86_64]}" ]]
			}

			bad_ref="${release_commit_map[$BAD_COMMIT]}"
			When call find_good_commit "$bad_ref"
			The status should be success
			The variable GOOD_COMMIT should equal "6.16.4-100.fc41.x86_64"
			The stdout should include "Found good release: 6.16.4-100.fc41.x86_64"
		End

		It "aborts when BAD_COMMIT is not in RPM list"
			generate_git_repo_from_package_list
			BAD_COMMIT="6.99.0-999.fc41.x86_64"
			bad_ref="fake_ref"
			When run find_good_commit "$bad_ref"
			The status should be failure
			The output should include "not found in RPM list"
		End
	End
End
