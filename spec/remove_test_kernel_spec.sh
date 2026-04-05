#!/bin/bash

Describe 'remove_test_kernel'
	Include ./lib.sh
	Include ./handlers/install_handler.sh

	setup_env() {
		LOG_FILE="${SHELLSPEC_WORKDIR}/test.log"
		ORIGINAL_KERNEL="/boot/vmlinuz-5.14.0-100.el9.x86_64"
		ORIGINAL_KERNEL_RELEASE="5.14.0-100.el9.x86_64"
		TESTED_KERNEL=""
		INSTALL_STRATEGY="git"
		_commands_run=""
	}

	Before 'setup_env'

	# Suppress log output
	log() { :; }

	# Mock run_cmd to capture commands instead of executing them
	run_cmd() {
		if [[ "$1" == "uname" && "$2" == "-r" ]]; then
			echo "5.14.0-200.el9.x86_64"
			return 0
		fi
		if [[ "$1" == "kernel-install" ]]; then
			_commands_run+="kernel-install ${*}; "
			return 0
		fi
		if [[ "$1" == "rm" ]]; then
			_commands_run+="rm ${*}; "
			return 0
		fi
		return 0
	}

	Describe "when kernel_to_remove is empty"
		It "returns immediately without doing anything"
			TESTED_KERNEL=""
			When call remove_test_kernel ""
			The status should be success
			The variable _commands_run should equal ""
		End
	End

	Describe "safety check"
		It "skips removal when kernel_to_remove is the original kernel"
			TESTED_KERNEL="5.14.0-100.el9.x86_64"
			When call remove_test_kernel
			The variable TESTED_KERNEL should equal ""
			The variable _commands_run should equal ""
		End

		It "skips removal of original kernel even if ORIGINAL_KERNEL path is unusual"
			ORIGINAL_KERNEL="/boot/boot/vmlinuz-5.14.0-100.el9.x86_64"
			TESTED_KERNEL="5.14.0-100.el9.x86_64"
			When call remove_test_kernel
			The variable TESTED_KERNEL should equal ""
			The variable _commands_run should equal ""
		End
	End

	Describe "git strategy removal"
		It "calls kernel-install remove and rm for the kernel"
			INSTALL_STRATEGY="git"
			do_remove() {
				remove_test_kernel "5.14.0-200.el9.x86_64"
				echo "cmds=$_commands_run"
				echo "tested=$TESTED_KERNEL"
			}
			When call do_remove
			The line 1 should include "kernel-install"
			The line 1 should include "rm"
			The line 2 should equal "tested="
		End
	End

	Describe "rpm strategy removal"
		It "queries each kernel subpackage via rpm"
			INSTALL_STRATEGY="rpm"
			_rpm_queried=""
			run_cmd() {
				if [[ "$1" == "uname" && "$2" == "-r" ]]; then
					echo "5.14.0-200.el9.x86_64"
					return 0
				fi
				if [[ "$1" == "rpm" && "$2" == "-q" ]]; then
					_rpm_queried+="$3 "
					return 0
				fi
				if [[ "$1" == "rpm" && "$2" == "-e" ]]; then
					return 0
				fi
				return 0
			}
			do_rpm_remove() {
				remove_test_kernel "5.14.0-300.el9.x86_64"
				echo "queried=$_rpm_queried"
				echo "tested=$TESTED_KERNEL"
			}
			When call do_rpm_remove
			The line 1 should include "kernel-core-5.14.0-300.el9.x86_64"
			The line 1 should include "kernel-modules-5.14.0-300.el9.x86_64"
			The line 2 should equal "tested="
		End
	End

	Describe "default kernel_to_remove"
		It "uses TESTED_KERNEL when no argument given"
			TESTED_KERNEL="5.14.0-999.el9.x86_64"
			do_default() {
				remove_test_kernel
				echo "cmds=$_commands_run"
				echo "tested=$TESTED_KERNEL"
			}
			When call do_default
			The line 1 should include "kernel-install"
			The line 2 should equal "tested="
		End
	End
End
