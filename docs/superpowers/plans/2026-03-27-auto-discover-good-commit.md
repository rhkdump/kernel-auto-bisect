# Auto-Discover Good Commit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to start bisection with only `BAD_COMMIT`, auto-discovering the good commit via exponential search.

**Architecture:** A new `find_good_commit()` function in `lib.sh` performs exponential backward search (step 1, 2, 4, 8...) through git history or the RPM list. Called from `initialize()` when `GOOD_COMMIT` is unset. An `_rpm_releases` array is added to `generate_git_repo_from_package_list()` to support index-based traversal in RPM mode.

**Tech Stack:** Bash, ShellSpec (testing)

---

### Task 1: Add `_rpm_releases` array to `generate_git_repo_from_package_list()`

**Files:**
- Modify: `lib.sh:196-220`
- Test: `spec/find_good_commit_spec.sh` (new file)

- [ ] **Step 1: Write the failing test**

Create `spec/find_good_commit_spec.sh`:

```bash
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
		End
	End
End
```

- [ ] **Step 2: Run test to verify it fails**

Run: `shellspec spec/find_good_commit_spec.sh`
Expected: FAIL — `_rpm_releases` is not populated.

- [ ] **Step 3: Add `_rpm_releases` array to `generate_git_repo_from_package_list()`**

In `lib.sh`, add `_rpm_releases=()` before the while loop and append each release inside the loop. At line 125 (near `declare -A release_commit_map`), also declare the array. The modified function:

```bash
# Add at line 126 (after declare -A release_commit_map):
_rpm_releases=()

# Inside generate_git_repo_from_package_list(), after line 218 (release_commit_map[$k_rel]=...):
		_rpm_releases+=("$k_rel")
```

Specifically, in `lib.sh`:
- After line 125 `declare -A release_commit_map`, add: `_rpm_releases=()`
- After line 218 `release_commit_map[$k_rel]=$(run_cmd_in_GIT_REPO git rev-parse HEAD)`, add: `_rpm_releases+=("$k_rel")`

- [ ] **Step 4: Run test to verify it passes**

Run: `shellspec spec/find_good_commit_spec.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh spec/find_good_commit_spec.sh
git commit -m "Add _rpm_releases array to generate_git_repo_from_package_list

Populates an ordered array of kernel releases during RPM list
processing, needed for index-based traversal in auto-discovery."
```

---

### Task 2: Implement `find_good_commit()` for git mode

**Files:**
- Modify: `lib.sh` (add function after `generate_git_repo_from_package_list`)
- Test: `spec/find_good_commit_spec.sh`

- [ ] **Step 1: Write the failing test for git mode success**

Add to `spec/find_good_commit_spec.sh`, inside the outer `Describe 'find-good-commit'` block:

```bash
	Describe "find_good_commit in git mode"
		setup_git_repo() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/git_repo"
			KAB_TEST_HOST=""
			INSTALL_STRATEGY="git"
			_good_commit_auto_discovered=""
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
			The variable _good_commit_auto_discovered should equal "true"
		End
	End
```

- [ ] **Step 2: Run test to verify it fails**

Run: `shellspec spec/find_good_commit_spec.sh`
Expected: FAIL — `find_good_commit` function not defined.

- [ ] **Step 3: Implement `find_good_commit()` in `lib.sh`**

Add after `generate_git_repo_from_package_list()` (after line 220):

```bash
# Auto-discover a good commit by exponential search backward from bad_ref.
# Tests commits at bad_ref~1, ~2, ~4, ~8, ... until one passes commit_good().
# Sets GOOD_REF and _good_commit_auto_discovered=true on success.
find_good_commit() {
	local bad_ref=$1
	local step=1
	local candidate

	log "Auto-discovering good commit (exponential search from $bad_ref)..."

	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
		# Find BAD_COMMIT index in _rpm_releases
		local bad_index=-1
		for i in "${!_rpm_releases[@]}"; do
			if [[ "${_rpm_releases[$i]}" == "$BAD_COMMIT" ]]; then
				bad_index=$i
				break
			fi
		done
		if [[ $bad_index -lt 0 ]]; then
			do_abort "BAD_COMMIT '$BAD_COMMIT' not found in RPM list."
		fi

		while (( bad_index - step >= 0 )); do
			local idx=$(( bad_index - step ))
			local release="${_rpm_releases[$idx]}"
			candidate="${release_commit_map[$release]}"
			log "Testing RPM release $release (index $idx, step $step)..."
			if commit_good "$candidate"; then
				log "Found good release: $release"
				GOOD_COMMIT="$release"
				GOOD_REF="$candidate"
				_good_commit_auto_discovered=true
				return 0
			fi
			step=$(( step * 2 ))
		done
	else
		while candidate=$(run_cmd_in_GIT_REPO git rev-parse "${bad_ref}~${step}" 2>/dev/null); do
			log "Testing commit ${bad_ref}~${step} ($candidate, step $step)..."
			if commit_good "$candidate"; then
				log "Found good commit: $candidate"
				GOOD_COMMIT="$candidate"
				GOOD_REF="$candidate"
				_good_commit_auto_discovered=true
				return 0
			fi
			step=$(( step * 2 ))
		done
	fi

	do_abort "Could not find a good commit in the available history. Please set GOOD_COMMIT manually."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `shellspec spec/find_good_commit_spec.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh spec/find_good_commit_spec.sh
git commit -m "Add find_good_commit() with exponential search

Walks backward through history with doubling steps to auto-discover
a good commit when GOOD_COMMIT is not specified. Supports both git
and RPM modes."
```

---

### Task 3: Add tests for git mode failure and RPM mode

**Files:**
- Test: `spec/find_good_commit_spec.sh`

- [ ] **Step 1: Add test for git mode — no good commit found**

Add inside the `Describe "find_good_commit in git mode"` block:

```bash
		It "aborts when no good commit is found"
			# Mock commit_good: everything is bad
			commit_good() { return 1; }

			bad_ref=$(git -C "${SHELLSPEC_WORKDIR}/git_repo" rev-parse HEAD)
			When run find_good_commit "$bad_ref"
			The status should be failure
			The output should include "Could not find a good commit"
			The output should include "Please set GOOD_COMMIT manually"
		End
```

- [ ] **Step 2: Add test for RPM mode — good commit found**

Add a new `Describe` block inside the outer `Describe 'find-good-commit'`:

```bash
	Describe "find_good_commit in RPM mode"
		setup_rpm_find() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/rpm_find_repo"
			KAB_TEST_HOST=""
			INSTALL_STRATEGY="rpm"
			_good_commit_auto_discovered=""
			KERNEL_RPM_LIST="${SHELLSPEC_WORKDIR}/rpm_find_list.txt"
			cat >"$KERNEL_RPM_LIST" <<'EOF'
https://example.com/kernel-core-6.16.4-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.5-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.6-100.fc41.x86_64.rpm
https://example.com/kernel-core-6.16.7-100.fc41.x86_64.rpm
EOF
			generate_git_repo_from_package_list
			BAD_COMMIT="6.16.7-100.fc41.x86_64"
		}

		cleanup_rpm_find() {
			rm -rf "${SHELLSPEC_WORKDIR}/rpm_find_repo"
		}

		Before 'setup_rpm_find'
		After 'cleanup_rpm_find'

		It "finds a good release via exponential search"
			# Mock commit_good: only 6.16.4 is good (index 0)
			commit_good() {
				local commit=$1
				[[ "$commit" == "${release_commit_map[6.16.4-100.fc41.x86_64]}" ]]
			}

			bad_ref="${release_commit_map[$BAD_COMMIT]}"
			When call find_good_commit "$bad_ref"
			The status should be success
			The variable GOOD_COMMIT should equal "6.16.4-100.fc41.x86_64"
			The variable _good_commit_auto_discovered should equal "true"
		End

		It "aborts when BAD_COMMIT is not in RPM list"
			BAD_COMMIT="6.99.0-999.fc41.x86_64"
			bad_ref="fake_ref"
			When run find_good_commit "$bad_ref"
			The status should be failure
			The output should include "not found in RPM list"
		End
	End
```

- [ ] **Step 3: Run all tests to verify they pass**

Run: `shellspec spec/find_good_commit_spec.sh`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add spec/find_good_commit_spec.sh
git commit -m "Add tests for find_good_commit failure and RPM mode"
```

---

### Task 4: Integrate `find_good_commit()` into `initialize()`

**Files:**
- Modify: `lib.sh:380-440` (the `initialize()` function)

- [ ] **Step 1: Modify `initialize()` to call `find_good_commit` when `GOOD_COMMIT` is empty**

In `lib.sh`, modify the `initialize()` function. The changes are in two areas:

**Area 1:** In the RPM branch (around line 413-418), handle missing `GOOD_COMMIT`:

Replace:
```bash
	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
		if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
		generate_git_repo_from_package_list
		good_ref=${release_commit_map[$GOOD_COMMIT]}
		bad_ref=${release_commit_map[$BAD_COMMIT]}
		if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then do_abort "Could not find GOOD/BAD versions in RPM list."; fi
```

With:
```bash
	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
		if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
		generate_git_repo_from_package_list
		bad_ref=${release_commit_map[$BAD_COMMIT]}
		if [ -z "$bad_ref" ]; then do_abort "BAD_COMMIT '$BAD_COMMIT' not found in RPM list."; fi
		if [[ -n "$GOOD_COMMIT" ]]; then
			good_ref=${release_commit_map[$GOOD_COMMIT]}
			if [ -z "$good_ref" ]; then do_abort "GOOD_COMMIT '$GOOD_COMMIT' not found in RPM list."; fi
		fi
```

**Area 2:** After the RPM/git setup block (after line 431), add the auto-discovery call:

After the closing `fi` of the RPM/git if-elif block, before `# Save resolved references in memory`, add:

```bash
	# Auto-discover good commit if not specified
	if [[ -z "$good_ref" ]]; then
		find_good_commit "$bad_ref"
		good_ref="$GOOD_REF"
	fi
```

- [ ] **Step 2: Run all tests to verify nothing is broken**

Run: `shellspec`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add lib.sh
git commit -m "Integrate find_good_commit into initialize()

When GOOD_COMMIT is not specified, auto-discovers a good commit
via exponential search after the repo is set up."
```

---

### Task 5: Update `verify_intial_commits()` to skip re-verifying auto-discovered good commit

**Files:**
- Modify: `lib.sh:442-457` (the `verify_intial_commits()` function)
- Test: `spec/find_good_commit_spec.sh`

- [ ] **Step 1: Write the failing test**

Add inside the outer `Describe 'find-good-commit'` block in `spec/find_good_commit_spec.sh`:

```bash
	Describe "verify_intial_commits skips auto-discovered good commit"
		setup_verify() {
			VERIFY_COMMITS="yes"
			GOOD_REF="good_ref_value"
			BAD_REF="bad_ref_value"
			_verify_good_called=false
			_verify_bad_called=false
		}
		Before 'setup_verify'

		It "skips good commit verification when auto-discovered"
			_good_commit_auto_discovered=true
			commit_good() {
				if [[ "$1" == "good_ref_value" ]]; then
					_verify_good_called=true
					return 0
				elif [[ "$1" == "bad_ref_value" ]]; then
					_verify_bad_called=true
					return 1
				fi
			}

			When call verify_intial_commits
			The variable _verify_good_called should equal "false"
			The variable _verify_bad_called should equal "true"
		End

		It "verifies both commits when not auto-discovered"
			_good_commit_auto_discovered=""
			commit_good() {
				if [[ "$1" == "good_ref_value" ]]; then
					_verify_good_called=true
					return 0
				elif [[ "$1" == "bad_ref_value" ]]; then
					_verify_bad_called=true
					return 1
				fi
			}

			When call verify_intial_commits
			The variable _verify_good_called should equal "true"
			The variable _verify_bad_called should equal "true"
		End
	End
```

- [ ] **Step 2: Run test to verify it fails**

Run: `shellspec spec/find_good_commit_spec.sh`
Expected: FAIL — the first test ("skips good commit verification") fails because `verify_intial_commits` still verifies both.

- [ ] **Step 3: Modify `verify_intial_commits()` in `lib.sh`**

Replace the current `verify_intial_commits()`:

```bash
verify_intial_commits() {
	if [[ "$VERIFY_COMMITS" == "no" ]]; then
		log "Skipping verifying initial commits"
		return 0
	fi

	if [[ "$_good_commit_auto_discovered" == true ]]; then
		log "Skipping GOOD commit verification (already tested during auto-discovery)"
	else
		log "Verifying initial GOOD commit"
		if ! commit_good "$GOOD_REF"; then
			do_abort "GOOD_COMMIT behaved as BAD"
		fi
	fi

	log "Verifying initial BAD commit"
	if commit_good "$BAD_REF"; then
		do_abort "BAD_COMMIT behaved as GOOD"
	fi
}
```

- [ ] **Step 4: Run all tests to verify they pass**

Run: `shellspec`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib.sh spec/find_good_commit_spec.sh
git commit -m "Skip re-verifying auto-discovered good commit

When GOOD_COMMIT was found via exponential search, it was already
tested. Only verify the BAD commit in this case."
```

---

### Task 6: Update `bisect.conf` and `README.md`

**Files:**
- Modify: `bisect.conf:43-47`
- Modify: `README.md`

- [ ] **Step 1: Update `bisect.conf` to document GOOD_COMMIT as optional**

Replace the commit boundary section in `bisect.conf`:

```bash
# === Commit/Version Boundaries ===
# BAD_COMMIT (required): The known-bad commit hash or kernel release version.
# GOOD_COMMIT (optional): The known-good commit hash or kernel release version.
#   If omitted, the tool auto-discovers a good commit by exponential search
#   backward through history (testing commits at ~1, ~2, ~4, ~8, ...).
BAD_COMMIT="<paste_bad_commit_or_version_here>"
GOOD_COMMIT=""
```

- [ ] **Step 2: Update README.md**

In the Git Mode table (around line 81), change the `GOOD_COMMIT` row description from:
`Git commit hash of the known-good commit`
to:
`Git commit hash of the known-good commit (optional; auto-discovered if omitted)`

In the RPM Mode table (around line 91), change the `GOOD_COMMIT` row description from:
`Kernel release string of the known-good version (e.g. `5.14.0-162.el9.aarch64`)`
to:
``Kernel release string of the known-good version (optional; auto-discovered if omitted)``

- [ ] **Step 3: Run all tests one final time**

Run: `shellspec`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add bisect.conf README.md
git commit -m "Document GOOD_COMMIT as optional in config and README"
```
