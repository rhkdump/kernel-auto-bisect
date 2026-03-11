#!/bin/bash
#
# install_handler.sh: Contains strategies for installing kernels.
#

# install packages needed for kernel development
install_kernel_devel() {
	run_cmd dnf --setopt=install_weak_deps=False install audit-libs-devel binutils-devel clang dwarves llvm perl python3-devel elfutils-devel java-devel ncurses-devel newt-devel numactl-devel pciutils-devel perl-generators xz-devel xmlto bison openssl-devel bc openssl cpio xz tar zstd -qy
}

generate_mininal_config() {
	ORIGINAL_KERNEL_CONFIG=${ORIGINAL_KERNEL/vmlinuz/config}
	# only build kernel modules that are in-use or included in initramfs
	run_cmd lsinitrd "/boot/initramfs-$(run_cmd uname -r).img" "|" sed -n -E '"s/.*\/([a-zA-Z0-9_-]+).ko.xz/\1/p"' "|" xargs -n 1 modprobe

	run_cmd_in_GIT_REPO yes '' '|' make localmodconfig
	run_cmd_in_GIT_REPO sed -i "/rhel.pem/d" .config
	run_cmd_in_GIT_REPO sed -i "/kernel.sbat/d" .config

	# To avoid builidng bloated kernel image and modules, disable DEBUG_INFO_BTF to auto-disable CONFIG_DEBUG_INFO
	run_cmd_in_GIT_REPO ./scripts/config -d DEBUG_INFO_BTF
	run_cmd_in_GIT_REPO ./scripts/config -d DEBUG_INFO_BTF_MODULES
	run_cmd_in_GIT_REPO ./scripts/config -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT

	if [[ $TEST_STRATEGY == panic ]]; then
		# - Enable squashfs related modules so the default crashkernel value
		#   will work.
		# - Enable NFS module for nfs dumping
		run_cmd_in_GIT_REPO grep -e BLK_DEV_LOOP -e NFS -e SQUASHFS -e OVERLAY -e EROFS_FS "$ORIGINAL_KERNEL_CONFIG" ">>.config"

	fi
}

_init_install_handler() {
	[[ $INSTALL_STRATEGY != git ]] && return
	install_kernel_devel
	generate_mininal_config
}

run_install_strategy() {
	local commit_to_install=$1
	log "--- Phase: INSTALL ---"

	if [[ $_install_handler_initilized != true ]]; then
		_init_install_handler
		_install_handler_initilized=true
	fi

	local kernel_version_string

	# No need for bisect but needed for verifying initial good/bad commit
	run_cmd_in_GIT_REPO git checkout -q "$commit_to_install"

	case "$INSTALL_STRATEGY" in
	git) install_from_git "$commit_to_install" ;;
	rpm) install_from_rpm "$commit_to_install" ;;
	*) do_abort "Unknown INSTALL_STRATEGY: ${INSTALL_STRATEGY}" ;;
	esac

	kernel_version_string="$TESTED_KERNEL"
	local new_kernel_path="/boot/vmlinuz-${kernel_version_string}"
	if ! run_cmd test -f "$new_kernel_path"; then do_abort "Installed kernel not found at ${new_kernel_path}."; fi

	set_boot_kernel "$new_kernel_path"
}

no_openssl_engine() {
	run_cmd_in_GIT_REPO grep -qs OPENSSL_NO_ENGINE scripts/sign-file.c
}

_openssl_engine_workaround() {
	no_openssl_engine && return 0
	if ! CURRENT_BRANCH=$(run_cmd_in_GIT_REPO git branch --show-current); then
		do_abort "Can't get current branch"
	fi

	run_cmd_in_GIT_REPO git show "$CURRENT_BRANCH":scripts/sign-file.c ">scripts/sign-file.c"
	run_cmd_in_GIT_REPO git show "$CURRENT_BRANCH":certs/extract-cert.c ">certs/extract-cert.c"
	run_cmd_in_GIT_REPO git show "$CURRENT_BRANCH":scripts/ssl-common.h ">scripts/ssl-common.h"
	run_cmd_in_GIT_REPO cp scripts/ssl-common.h certs/
}

_undo_openssl_engine_workaround() {
	no_openssl_engine && return 0

	run_cmd_in_GIT_REPO git checkout -- scripts/sign-file.c
	run_cmd_in_GIT_REPO git checkout -- certs/extract-cert.c
	if ! run_cmd_in_GIT_REPO git checkout -- scripts/ssl-common.h "&>/dev/null"; then
		run_cmd_in_GIT_REPO rm -f scripts/ssl-common.h
	fi
	run_cmd_in_GIT_REPO rm -f certs/ssl-common.h
}

install_from_git() {
	local commit_to_install=$1
	log "Strategy: install_from_git for commit ${commit_to_install}"

	# No need for bisect but needed for verifying initial good/bad commit
	run_cmd_in_GIT_REPO git checkout -q "$commit_to_install"

	_commit_short_id=$(run_cmd_in_GIT_REPO git rev-parse --short "$commit_to_install")
	_openssl_engine_workaround
	run_cmd_in_GIT_REPO ./scripts/config --set-str CONFIG_LOCALVERSION "-${_commit_short_id}"
	_build_log=/var/log/build_${_commit_short_id}.log
	# To prevent OOM on small-RAM systems, by default use the number of CPU
	# cores as number of jobs
	[[ -z $MAKE_JOBS ]] && MAKE_JOBS=$(run_cmd nproc)
	if ! run_cmd_in_GIT_REPO yes "" '|' make -j"${MAKE_JOBS}" ">${_build_log}" '2>&1'; then do_abort "Build failed."; fi

	if ! run_cmd_in_GIT_REPO make modules_install -j ">${_build_log}" '2>&1'; then
		_undo_openssl_engine_workaround
		do_abort "Failed to install kernel modules"
	fi

	if ! run_cmd_in_GIT_REPO make install ">>${_build_log}" "2>&1"; then
		_undo_openssl_engine_workaround
		do_abort "Failed to install kernel."
	fi
	_undo_openssl_engine_workaround
	_kernelrelease_str=$(run_cmd_in_GIT_REPO make -s kernelrelease)
	_dirty_str=-dirty
	run_cmd grep -qe "$_dirty_str$" "${_build_log}" && ! grep -qe "$_dirty_str$" <<<"$_kernelrelease_str" && _kernelrelease_str+=$_dirty_str
	TESTED_KERNEL="$_kernelrelease_str"
}

install_from_rpm() {
	local commit_to_install=$1
	log "Strategy: install_from_rpm for commit ${commit_to_install}"

	if ! run_cmd command -v wget; then
		run_cmd dnf install wget -yq
	fi

	local core_url
	core_url=$(run_cmd_in_GIT_REPO cat k_url)
	local base_url
	base_url=$(run_cmd_in_GIT_REPO dirname "$core_url")
	local release
	release=$(run_cmd_in_GIT_REPO cat k_rel)
	# shellcheck disable=SC2153
	local rpm_cache_dir="$RPM_CACHE_DIR"
	run_cmd mkdir -p "$rpm_cache_dir"
	local rpms_to_install=()

	if run_cmd_in_GIT_REPO grep -qs kernel-rt-core k_url; then
		_kernel_name_prefix=kernel-rt
	else
		_kernel_name_prefix=kernel
	fi
	for pkg in core modules modules-core modules-extra; do
		local rpm_filename="${_kernel_name_prefix}-${pkg}-${release}.rpm"
		local rpm_path="${rpm_cache_dir}/${rpm_filename}"
		local rpm_url="${base_url}/${rpm_filename}"
		if ! run_cmd test -f "$rpm_path"; then
			log "Downloading ${rpm_filename}..."
			if ! run_cmd wget --no-check-certificate -q -O "$rpm_path" "$rpm_url"; then
				run_cmd rm -f "$rpm_path"
				log "Download failed. Ignore the error"
			else
				rpms_to_install+=("$rpm_path")
			fi
		else
			rpms_to_install+=("$rpm_path")
		fi
	done

	if ! run_cmd dnf install -y "${rpms_to_install[@]}" >"/var/log/install.log" 2>&1; then do_abort "RPM install failed."; fi
	TESTED_KERNEL="$release"
	[[ $_kernel_name_prefix == kernel-rt ]] && TESTED_KERNEL+=+rt
}
