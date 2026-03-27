# Auto-Discover Good Commit

## Summary

Allow users to start bisection by specifying only `BAD_COMMIT`. When `GOOD_COMMIT` is omitted, the tool automatically discovers a good commit via exponential search (walking backwards through history with doubling steps).

Works in both git source mode and RPM mode.

## Configuration

- `GOOD_COMMIT` becomes optional in `bisect.conf`. When empty or unset, auto-discovery is triggered.
- `BAD_COMMIT` remains required.

## `find_good_commit()` Function

New function in `lib.sh`. Called from `verify_intial_commits()` after
confirming the bad commit is truly bad.

### Git Mode

1. Starting from `bad_ref`, walk back using `git rev-parse bad_ref~1`, `bad_ref~2`, `bad_ref~4`, `bad_ref~8`, etc. in `$GIT_REPO`.
2. For each candidate commit, call `commit_good()` to test it.
3. Return the first commit that passes as the good ref.

### RPM Mode

1. An ordered array `_rpm_releases` is populated during `generate_git_repo_from_package_list()` to track the release ordering.
2. Find the index of `BAD_COMMIT` in `_rpm_releases`.
3. Step backwards by 1, 2, 4, 8... indices.
4. For each candidate release, look up the fake commit via `release_commit_map[$release]` and test it with `commit_good()`.
5. Return the first release/commit that passes.

### Fallback

After exponential steps are exhausted, test the first entry as a last resort
(index 0 in RPM mode, root commit in git mode) before giving up.

### Failure

If no good commit is found after exhausting available history, call `do_abort` with a message:
"Could not find a good commit in the available history. Please set GOOD_COMMIT manually."

If in RPM mode and `BAD_COMMIT` is not found in the RPM list, abort with an error.

## Integration into `verify_intial_commits()`

The verification order is:

1. Verify `BAD_REF` is actually bad (unless `VERIFY_COMMITS=no`).
2. If `GOOD_REF` is empty, call `find_good_commit` to auto-discover it.
   The discovered good commit does not need separate verification since
   the search already tested it.
3. If `GOOD_REF` was provided by the user, verify it is actually good.

## Changes to `generate_git_repo_from_package_list()`

- Populate an ordered array `_rpm_releases=()` alongside `release_commit_map` so the exponential search can walk by index.

## No Changes to `kab.sh`

`git bisect start "$BAD_REF" "$GOOD_REF"` works unchanged since the refs are populated by the time it runs.

## Testing

New spec file: `spec/find_good_commit_spec.sh`

### Test Cases

1. **Git mode - good commit found:** Small git repo, mock `commit_good` to fail on recent commits and pass on an older one, verify correct commit returned.
2. **Git mode - no good commit found:** Mock `commit_good` to always fail, verify `do_abort` called with suggestion to set `GOOD_COMMIT` manually.
3. **RPM mode - good commit found:** Set up `_rpm_releases` and `release_commit_map`, mock `commit_good`, verify correct release discovered.
4. **RPM mode - BAD_COMMIT not in list:** Verify `do_abort` called.
5. **Verify bad first, then auto-discover good:** Verify `verify_intial_commits` checks bad commit first, then calls `find_good_commit` when `GOOD_REF` is empty.
6. **Git mode - root commit fallback:** When exponential search overshoots, verify the root commit is tested as a last resort.
