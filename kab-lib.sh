#!/bin/bash
CONFIG_FILE='/etc/kernel-auto-bisect.conf'
# KAB working directory, used to store source code, downloaded rpm and etc.
KAB_WD='/root/.kab'
# path to kernel source directory
KERNEL_SRC_PATH="$KAB_WD/kernel_src"
KERNEL_RPM_LIST="$KAB_WD/kernel_rpm_list"
KERNEL_RPMS_DIR="$KAB_WD/kernel_rpms"
# mail-box to receive report
REPORT_EMAIL=''
LOG_PATH='/boot/.kernel-auto-bisect.log'
REMOTE_LOG_PATH=''
BISECT_WHAT=''
BISECT_KDUMP=NO
KEXEC_REBOOT=NO
SHALLOW_SINCE='1 year'
BAD_IF_FAILED_TO_REBOOT=YES
# remote host who will receive logs.
LOG_HOST=''

read_conf() {
	# Following steps are applied in order: strip trailing comment, strip trailing space,
	# strip heading space, match non-empty line, remove duplicated spaces between conf name and value
	[ -f "$CONFIG_FILE" ] && sed -n -e "s/#.*//;s/\s*$//;s/^\s*//;s/\(\S\+\)\s*\(.*\)/\1 \2/p" $CONFIG_FILE
}

check_config() {
	while read -r config_opt config_val; do
		eval "$config_opt"="$config_val"
	done <<<"$(read_conf)"

	if [[ $BISECT_WHAT != BUILD && $BISECT_WHAT != SOURCE ]]; then
		echo BISECT_WHAT must be chosen between SOURCE and BUILD
		exit 1
	fi

	if [[ $BISECT_WHAT == SOURCE ]]; then
		if [[ -z $KERNEL_SRC_REPO ]]; then
			echo "You need to specify the KERNEL_SRC_REPO"
			exit 1
		fi
	else
		if [[ $DISTRIBUTION != RHEL8 && $DISTRIBUTION != RHEL9 && $DISTRIBUTION != C9S ]]; then
			echo BISECT_WHAT must be chosen among RHEL8/RHEL9/C9S
			exit 1
		fi
	fi

	if [[ -z $REPRODUCER ]]; then
		echo "You need to set the path of the reproducer first."
		exit
	fi

	if [[ ! -e $REPRODUCER ]]; then
		echo "$REPRODUCER doesn't exist."
		exit 1
	fi

	# shellcheck disable=SC1090
	source "$REPRODUCER"
}

safe_cd() {
	cd "$1" || {
		echo "Failed to cd $1"
		exit 1
	}
}

LOG() {
	echo "$(date "+%b %d %H:%M:%S") - $*" >>"${LOG_PATH}"
	if [ -n "${LOG_HOST}" ]; then
		# shellcheck disable=SC2029
		ssh root@"${LOG_HOST}" "echo $(date +%b%d:%H:%M:%S) - $* >> ${REMOTE_LOG_PATH}"
	fi
}

are_you_root() {
	if [ "$(id -u)" != 0 ]; then
		echo $'\nScript can only be executed by root.\n'
		exit 1
	fi
}

is_git_repo() {
	[[ -d $1/.git ]]
}

generate_git_repo_from_package_list() {
	local _package_list

	_package_list=$KERNEL_RPM_LIST
	repo_path=$KERNEL_SRC_PATH

	if [[ -d $repo_path ]]; then
		rm -rf $repo_path
	fi

	mkdir -p $repo_path
	safe_cd "$repo_path"

	git init
	# configure name and email to make git happy
	git config user.name kernel-auto-bisect
	git config user.email kernel-auto-bisect

	touch kernel_url kernel_release
	git add kernel_url kernel_release
	git commit -m "init" >/dev/null

	while read -r _url; do
		echo "$_url" >kernel_url
		_str=$(basename "$_url")
		_str=${_str#kernel-core-}
		kernel_release=${_str%.rpm}
		echo "$kernel_release" >kernel_release
		git commit -m "$kernel_release" kernel_release kernel_url
		release_commit_map[$kernel_release]=$(git rev-parse HEAD)
	done <"$_package_list"
}

# install packages needed for kernel development
install_kernel_devel() {
	dnf --setopt=install_weak_deps=False install audit-libs-devel binutils-devel clang dwarves llvm perl python3-devel elfutils-devel java-devel ncurses-devel newt-devel numactl-devel pciutils-devel perl-generators xz-devel xmlto bison openssl-devel bc openssl cpio xz tar zstd -qy
}

# Only call a function if it's defined
call_func() {
	local _func=$1
	declare -F "$_func" && $_func
}

generate_mininal_config() {
	# only build kernel modules that are in-use or included in initramfs
	lsinitrd "/boot/initramfs-$(uname -r).img" | sed -n -E "s/.*\/([a-zA-Z0-9_-]+).ko.xz/\1/p" | xargs -n 1 modprobe

	yes '' | make localmodconfig
	sed -i "/rhel.pem/d" .config

	# To avoid builidng bloated kernel image and modules, disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT to auto-disable CONFIG_DEBUG_INFO
	./scripts/config -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT

	# enable squashfs so the default crashkernel value will work
	# squashfs depends on overlay and loop module
	if [[ $BISECT_KDUMP == YES ]]; then
		./scripts/config -m SQUASHFS
		./scripts/config -m OVERLAY_FS
		./scripts/config -m BLK_DEV_LOOP
		for _opt in SQUASHFS_FILE_DIRECT SQUASHFS_DECOMP_MULTI_PERCPU SQUASHFS_COMPILE_DECOMP_MULTI_PERCPU SQUASHFS_XATTR SQUASHFS_ZLIB SQUASHFS_LZ4 SQUASHFS_LZO SQUASHFS_XZ SQUASHFS_ZSTD; do
			./scripts/config -e "$_opt"
		done
	fi
}

# When the system memory is too smaller, gcc could be killed.
#
# Assuming the threshold is 2024M, give a warning if it's below the
# threshold.
check_memory() {
	mem_warning_threshold=2024
	total_memory=$(free -m | awk '/^Mem:/{print $2}')
	swap_memory=$(free -m | awk '/^Swap:/{print $2}')

	total_with_swap=$((total_memory + swap_memory))
	if [ "$total_with_swap" -lt "$mem_warning_threshold" ]; then
		LOG "Memory smaller than ${mem_warning_threshold}M. You may need to add a swap partition if the building aborts with the error 'gcc: fatal error: Killed signal terminated program cc1'"
	fi
}

# For kdump issues, make sure kexec-tools has been installed and kdump.serice
# will work
check_kdump_service() {

	if [[ $BISECT_KDUMP == NO ]]; then
		return
	fi

	if ! dnf install kexec-tools -q -y; then
		LOG "Failed to install kexec-tools"
		exit 1
	fi

	if ! systemctl enable kdump; then
		LOG "Failed to enable kdump.service"
		exit 1
	fi

	# make sure the kernel-install will set up the crashkernel kernel parameter
	# automatically
	if ! grep -q -s crashkernel= /etc/kernel/cmdline; then
		echo -n " crashkernel=$(kdumpctl get-default-crashkernel)" >>/etc/kernel/cmdline
	fi
}

initiate() {
	check_memory

	if [ -e "/boot/.kernel-auto-bisect.undergo" ]; then
		echo '
        
There might be another operation undergoing, delete any file named
'.kernel-auto-bisect.*' in /boot directory and run this script again.

'
		exit 1
	fi

	if ! rpm --quiet -q git && ! dnf install git -yq; then
		echo "Failed to install git, abort!"
	fi

	check_kdump_service

	[ ! -d $KAB_WD ] && mkdir -p "$KAB_WD"

	if [[ $BISECT_WHAT == BUILD ]]; then
		dnf install wget python -qy
		safe_cd "$KAB_WD"
		python /usr/bin/generate_rhel_kernel_rpm_list.py "$DISTRIBUTION" "$(uname -m)" >"$KERNEL_RPM_LIST"
		declare -A release_commit_map
		generate_git_repo_from_package_list
		safe_cd $KERNEL_SRC_PATH
		mkdir $KERNEL_RPMS_DIR
		_good_commit=${release_commit_map[$1]}
		_bad_commit=${release_commit_map[$2]}
	else
		_good_commit=$1
		_bad_commit=$2

		if is_git_repo $KERNEL_SRC_PATH; then
			read -r -p "$KERNEL_SRC_PATH exists, do you want to reuse it? y/n " ans
			if [ "$ans" == "n" ]; then
				rm -rf "$KERNEL_SRC_PATH"
			fi
		fi

		if ! is_git_repo $KERNEL_SRC_PATH; then
			_shallow_since=''
			if [[ -n $SHALLOW_SINCE ]]; then
				_shallow_since="--shallow-since=$SHALLOW_SINCE"
			fi
			# skip SSL certificate verification to workaround code.engineering.redhat.com
			if git -c http.sslVerify=false clone "$KERNEL_SRC_REPO" "$KERNEL_SRC_PATH" "$_shallow_since"; then
				echo "Failed to clone the kernel, abort"
				exit 1
			fi
		fi

		safe_cd "$KERNEL_SRC_PATH"

		if ! install_kernel_devel; then
			echo "Failed to install the packages for building kernel, abort"
			exit 1
		fi

		generate_mininal_config
	fi

	LOG starting kab

	if [ -z "${LOG_HOST}" ]; then
		echo "you can check logs in /boot/.kernel-auto-bisect.log"
	else
		echo "or at /var directory in ${LOG_HOST}"
		ssh-keygen
		ssh-copy-id -f root@"${LOG_HOST}"
		LOG using remote log
	fi

	call_func before_bisect

	touch "/boot/.kernel-auto-bisect.undergo"

	if git bisect reset; then
		LOG bisect restarting
	else
		LOG "Failed to run 'git bisect', you may need to run 'git checkout -f master'"
		exit 1
	fi
	git bisect start
	LOG good at "$1"
	LOG bad at "$2"

	if ! git bisect good "$_good_commit"; then
		LOG "Pleasure make sure good commit $_good_commit is valid"
		exit 1
	fi

	if ! git bisect bad "$_bad_commit"; then
		LOG "Pleasure make sure bad commit $_bad_commit is valid"
		exit 1
	fi
}

# To speed-up building, only build kernel modules that are in-use or included in initrd
compile_install_kernel() {
	CURRENT_COMMIT=$(git rev-parse --short HEAD)
	LOG building kernel: "${CURRENT_COMMIT}"

	./scripts/config --set-str CONFIG_LOCALVERSION -"${CURRENT_COMMIT}"

	if ! yes $'\n' | make -j"$(grep -c '^processor' /proc/cpuinfo)" || ! make modules_install -j || ! make install; then
		LOG "failed to build kernel"
		exit
	fi

	LOG kernel building complete
	# notice that next reboot should use new kernel
	grubby --set-default "/boot/vmlinuz-$(uname -r)"
	krelease=$(make kernelrelease)
	reboot_to_kernel_once "$krelease"
}

# use grub2-reboot to reboot to the new kernel only once
# so in case we can still go back to a good kernel if the new kernel goes rogue e.g. it may hang
reboot_to_kernel_once() {
	kernel_release=$1

	if [[ $KEXEC_REBOOT == YES ]]; then
		return
	fi

	# note older grubby doesn't accept "--info $kernel_release"
	index=$(grubby --info /boot/vmlinuz-"$kernel_release" | sed -nE "s/index=([[:digit:]])/\1/p")
	if ! grub2-reboot "$index"; then
		LOG "Failed to set $kernel_release as default entry for the next boot only"
		exit
	fi
}

get_default_kernel() {
	grubby --info=DEFAULT | sed -En 's/^kernel="(.*)"/\1/p'
}

install_kernel_rpm() {
	# dnf will make the newly installed kernel as default boot entry
	local _default_kernel

	_default_kernel=$(get_default_kernel)
	kernel_release=$(<kernel_release)
	url=$(<kernel_url)
	for name in kernel kernel-core kernel-modules kernel-modules-core; do
		url_dl=$(sed -En "s/kernel-core/$name/p" <<<"$url")
		wget -c "$url_dl" -P "$KERNEL_RPMS_DIR"
	done

	if dnf install $KERNEL_RPMS_DIR/kernel-*${kernel_release}.rpm -qy; then
		# restore the default boot entry
		grubby --set-default "$_default_kernel"
		reboot_to_kernel_once "$kernel_release"
		LOG "Installed kernel $kernel_release successfully"
	else
		LOG "Failed to install kernel $kernel_release"
		exit 1
	fi
}

install_kernel() {
	if [[ $BISECT_WHAT == SOURCE ]]; then
		compile_install_kernel
	elif [[ $BISECT_WHAT == BUILD ]]; then
		install_kernel_rpm
	fi
}

remove_kernel_rpm() {
	# Current running kernel is marked as protected and dnf won't remove it.
	# So use rpm instead.
	rpm -e "kernel-core-$1" "kernel-modules-$1" "kernel-modules-core-$1" "kernel-$1"
}

# clean up old kernel to prevent
cleanup_kernel() {
	local _kernel_release=$1

	if [[ $BISECT_WHAT == BUILD ]]; then
		remove_kernel_rpm "$_kernel_release"
	else
		/usr/bin/kernel-install remove "$_kernel_release"
		rm -rf "/usr/lib/modules/${_kernel_release}"
	fi
}

TRY_REBOOT_FILE=/boot/.kernel-auto-bisect.reboot
set_try_reboot_indicator() {
	touch $TRY_REBOOT_FILE
}

did_we_try_reboot() {
	[[ -e $TRY_REBOOT_FILE ]]
}

clean_try_reboot_indicator() {
	rm -f "$TRY_REBOOT_FILE"
}

REBOOT_SUCCESS_FILE=/boot/.kernel-auto-bisect.rebooted
is_reboot_successful() {
	[[ -e $REBOOT_SUCCESS_FILE ]]
}

clean_reboot_status() {
	rm -f $REBOOT_SUCCESS_FILE
}

set_reboot_status() {
	if [[ $(uname -r) == "$(get_kernel_release)" ]]; then
		touch $REBOOT_SUCCESS_FILE
	fi
}

success_string=''
detect_good_bad() {
	local _result=BAD
	local _old_kernel_release

	_old_kernel_release=$(get_kernel_release)

	if is_reboot_successful; then
		clean_reboot_status

		pushd "$PWD"
		if on_test; then
			_result=GOOD
		fi
		popd
	else
		if [[ $BAD_IF_FAILED_TO_REBOOT == NO ]]; then
			LOG "Booted kernel is not the new kernel, abort!"
			exit 1
		fi
	fi

	if [[ $_result == GOOD ]]; then
		LOG good
		success_string=$(git bisect good | grep "is the first bad commit")
	else
		LOG bad
		success_string=$(git bisect bad | grep "is the first bad commit")
	fi

	cleanup_kernel "$_old_kernel_release"
}

can_we_stop() {
	if [ -z "$success_string" ]; then
		return 1 # not yet
	else
		# use git bisect log to get more readable output so the commit
		# subject is also contained
		success_string=$(git bisect log | grep "first bad commit")
		# removing starting "# "
		success_string=${success_string:2}
		return 0 # yes, we can stop
	fi
}

# Make sure GRUB EFI can be started automatically
#
# IA-64 needs nextboot set and some ARM machines starts EFI Shell first which
# only exits with manual console access
#
# Code adapted from
# https://gitlab.com/redhat/centos-stream/tests/kernel/kernel-tests/-/blob/main/kdump/include/lib.sh#L501
prepare_reboot() {
	if [ -e "/usr/sbin/efibootmgr" ]; then
		EFI=$(efibootmgr -v | grep BootCurrent | awk '{ print $2}')
		if [ -n "$EFI" ]; then
			LOG "Updating efibootmgr next boot option to $EFI according to BootCurrent"
			efibootmgr -n "$EFI"
		elif [[ -z "$EFI" && -f /root/EFI_BOOT_ENTRY.TXT ]]; then
			os_boot_entry=$(</root/EFI_BOOT_ENTRY.TXT)
			LOG "Updating efibootmgr next boot option to $os_boot_entry according to EFI_BOOT_ENTRY.TXT"
			efibootmgr -n "$os_boot_entry"
		else
			LOG "Could not determine value for BootNext!"
		fi
	fi
}

kexec_reboot() {
	local _release _kpath _kargs
	if _release=$(get_kernel_release); then
		_kpath=/boot/vmlinuz-$_release
		_kargs="$_kpath --initrd=/boot/initramfs-${_release}.img"

		if ! kexec -s -l $_kargs --reuse-cmdline || ! systemctl kexec; then
			LOG "failed to kexec reboot $_kpath, abort!"
			exit 1
		fi
	else
		LOG "Failed to the kernel version for kexec rebooting, abort!"
		exit 1
	fi
}

try_reboot_to_new_kernel() {
	# real test happens after reboot
	LOG rebooting
	set_try_reboot_indicator
	prepare_reboot
	sync
	if [[ $KEXEC_REBOOT == YES ]]; then
		kexec_reboot
	else
		reboot
	fi
}

success_report() {
	# sending email
	echo "$success_string" | esmtp "$REPORT_EMAIL"
}

enable_service() {
	systemctl enable kernel-auto-bisect
	LOG kab service enabled
}

disable_service() {
	systemctl disable kernel-auto-bisect
	LOG kab service disabled
}

# utilities for testing kdump
trigger_pannic() {
	kdump_status=$(kdumpctl status)
	LOG "${kdump_status}"

	count=0
	while ! kdumpctl status; do
		sleep 5
		count=$((count + 5))
		if [[ $count -gt 60 ]]; then
			LOG "Something is wrong. Please fix it and trigger panic manually"
			exit
		fi
	done

	LOG "${kdump_status}"
	echo 1 >/proc/sys/kernel/sysrq
	echo c >/proc/sysrq-trigger
}

# Trigger kernel panic only when
#   1. Bisecting kdump kernel bug
#   2. The booted kernel is the new kernel
try_panic_kernel() {
	if [[ $BISECT_KDUMP == YES ]] && is_reboot_successful; then
		LOG triggering panic
		sync
		trigger_pannic
	fi
}

# get kernel release
get_kernel_release() {
	local _release

	if [[ $(pwd) != "$KERNEL_SRC_PATH" ]]; then
		LOG "get_kernel_release should have $KERNEL_SRC_PATH as PWD, abort!"
		exit 1
	fi

	if [[ $BISECT_WHAT == SOURCE ]]; then
		_release=$(make kernelrelease)
	else
		_release=$(cat kernel_release)
	fi

	echo -n "$_release"
}
