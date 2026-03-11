#!/bin/bash

Describe 'kdump-lib'
	Include ./lib.sh

	# Assuming ssh will behave the same way as eval regarding escaping and
	# quotes, so we only to test running commands locally.

	Describe "run_cmd"
		out=hello
		It "should handle cwd with a empty space corrently"
			_dir_space=${SHELLSPEC_WORKDIR}/"a b"
			mkdir -p "$_dir_space"
			When call run_cmd -cwd "$_dir_space" echo "$out"
			The output should equal $out
		End

		It "should handle a command with && correctly"
			out1="hi "
			_dir_space=${SHELLSPEC_WORKDIR}/"a b"
			mkdir -p "$_dir_space"
			When call run_cmd -cwd "$_dir_space" echo -n "$out1" "&&" echo "$out"
			The output should include "${out1}$out"
		End

		It "should handle a command with pipe correctly"
			When call run_cmd echo "$out" "|" grep "$out"
			The output should equal "$out"
			The status should be success
		End

		It "should handle a command with spaces in the argument"
			_str_with_space="ab cd"
			When call run_cmd echo "$_str_with_space" "|" grep "$_str_with_space"
			The output should equal "$_str_with_space"
			The status should be success
		End

		# "yes '' | make localmodconfig" shouldn't be executed as
		# "yes | make localmodconfig".
		#
		# Otherwise the process will get stuck by repeatedly printing lines as
		# similar to
		# Length to try to ... (CMDLINE_LOG_WRAP_IDEAL_LEN) [1021] (NEW) y
		It "should handle a command with an empty string as argument corretly"
			three_newlines() {
				%text
				#|
				#|
				#|
			}
			When call run_cmd yes '' "|" head -3
			The output should equal "$(three_newlines)"
			The status should be success
		End

		It "should handle sed command correctly"
			_mod_name="e1000"
			_mod_str="intel/${_mod_name}.ko.xz"
			When call run_cmd echo "$_mod_str" "|" sed -n -E '"s/.*\/([a-zA-Z0-9_-]+).ko.xz/\1/p"'
			The output should equal "$_mod_name"
			The status should be success
		End

	End
End
