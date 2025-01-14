#!/bin/bash
. /root/vars.sh
ls ./include.sh &>/dev/null || { echo "include.sh not found"; exit 1; }
PWD_DIR="$(dirname $(realpath $0))"
. $PWD_DIR/include.sh
LOG "Boot mode: $BOOT_MODE"
function apt {
	LOG "EXE: apt $@"
	local TODO=$1
	shift
	[[ "$#" != "0" ]] && for pack in "$@";do
		DEBIAN_FRONTEND=noninteractive command apt -y -u -o Dpkg::Options::="--force-confdef" --allow-downgrades --allow-remove-essential --allow-change-held-packages --allow-change-held-packages --allow-unauthenticated $TODO "$pack"
	done || DEBIAN_FRONTEND=noninteractive command apt -y -u -o Dpkg::Options::="--force-confdef" --allow-downgrades --allow-remove-essential --allow-change-held-packages --allow-change-held-packages --allow-unauthenticated $TODO
}
function get_grub_cfg {
        ls /boot/grub/grub.cfg > /dev/null 2>&1 && GRUB_CFG=/boot/grub/grub.cfg
        ls /boot/grub2/grub.cfg > /dev/null 2>&1 && GRUB_CFG=/boot/grub2/grub.cfg
        ls /boot/grub.cfg > /dev/null 2>&1 && GRUB_CFG=/boot/grub.cfg
	[[ "$BOOT_MODE" == "EFI" ]] && ls -1 /boot/efi/EFI/*/grub.cfg &>/dev/null && GRUB_CFG=$(ls -1 /boot/efi/EFI/*/grub.cfg | tail -n1)
	LOG "grub.cfg: [$GRUB_CFG]"
}
function find_os {
	which grub2-mkconfig > /dev/null 2>&1 && grub="grub2"
	which grub-mkconfig > /dev/null 2>&1 && grub="grub"
	LOG "Grub: [$grub]"
	grep -iE "alma.*linux|rocky.*linux|centos|cloud.*linux|rhel" /etc/*rel* > /dev/null && { rhel_config_boot; return 0; }
	grep -iE "ubuntu|debian" /etc/*rel* > /dev/null && { deb_config_boot; return 0; }
	ERR "OS" "Current distro is not supported"
}
function raid_setup {
        ls /dev/md* > /dev/null && {
	yum install -y mdadm
	apt install mdadm
	echo 'DEVICE /dev/nvme[0-9]n[0-9] /dev/hd*[0-9] /dev/sd*[0-9]' > /etc/mdadm.conf
	mdadm --detail --scan >> /etc/mdadm.conf
	mkdir -p /etc/mdadm
	cat /etc/mdadm.conf > /etc/mdadm/mdadm.conf
        update-initramfs -u
	dpkg-reconfigure mdadm
	for id in $(grep UUID /etc/mdadm.conf | cut -d'=' -f3); do
		GRUB_MD_UUID+="rd.md.uuid=$id "
	done
	}
}
function rhel_config_boot {
	LOG "Configuring boot on RHEL type system..."
	while IFS='\n' read -r line; do
		[[ $line =~ ^#.*$ || -z $line ]] && continue || line=$(echo $line | awk {'print $2'})
		LOG "Creating directory: $line"
		mkdir -p $line
	done < /etc/fstab
	LOG "Mouting fstab"
	mount -a
if [[ "$BOOT_MODE" == "EFI" ]];then
	echo '$GRUB_MD_UUID root=LABEL=/ ro crashkernel=auto' > /etc/kernel/cmdline
	grep -v 'GRUB_CMDLINE_LINUX' /etc/default/grub > /etc/default/grub.new
	echo 'GRUB_CMDLINE_LINUX="$GRUB_MD_UUID root=LABEL=/ ro crashkernel=auto"' >> /etc/default/grub.new
	cat /etc/default/grub.new > /etc/default/grub
	rm -f /etc/default/grub.new
	LOG "Installing: efibootmgr shim grub-efi grub-tools"
	yum -y install efibootmgr shim grub*-*efi*x64* grub*-tools dracut
	LOG "Reinstalling efibootmgr shim grub*-*efi grub-tools*"
	yum -y reinstall efibootmgr shim grub*-*efi* grub*-tools
	LOG "Kernel-core reinstall"
	yum -y reinstall kernel-core
	LOG "Regenerating dracut"
	dracut --regenerate-all --force
	LOG "Making grub-install"
	DEB "$grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --force"
	LOG "Making grub-config"
	get_grub_cfg
        DEB "$grub-mkconfig -o /boot/grub2/grub.cfg || $grub-mkconfig -o $GRUB_CFG"
	LOG "Done"
elif [[ "$BOOT_MODE" == "LEGACY" ]]; then
        date
else
        echo "Unkwon BOOTMODE"
fi
}
function deb_config_boot {
	echo "Ubuntu/Debian boot config"
	apt update
	if [[ "$BOOT_MODE" == "EFI" ]];then
	        grep -v 'GRUB_CMDLINE_LINUX' /etc/default/grub > /etc/default/grub.new
	        echo 'GRUB_CMDLINE_LINUX="$GRUB_MD_UUID root=LABEL=/ ro crashkernel=auto"' >> /etc/default/grub.new
	        cat /etc/default/grub.new > /etc/default/grub
		apt install grub*-efi-amd64* grub*-efi grub-common efibootmgr shim dracut
		apt reinstall grub*-efi-amd64* grub*-efi grub-common efibootmgr shim dracut
	        LOG "Making grub-install"
	        DEB "$grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --force"
	        LOG "Making grub-config"
	        get_grub_cfg
	        DEB "$grub-mkconfig -o /boot/grub2/grub.cfg || $grub-mkconfig -o $GRUB_CFG"
		LOG "Regenerating dracut"
	        dracut --regenerate-all --force

	elif [[ "$BOOT_MODE" == "LEGACY" ]]; then
		date
	else
		ERR "BOOT" "Unkwon BOOTMODE"
	fi
}
function fix_boot {
	[[ "$BOOT_MODE" == "EFI" ]] && echo -e "$DEB_CMD" | grep 'grub.*install' | grep -v '[0]' > /dev/null 2>&1 && {
		echo "Failed grub-install detected. Adding boot-entry on my own..."
		BOOT_ENTRY=$(ls -1 /boot/efi/EFI/ | grep -v BOOT)
		[[ "$(echo $BOOT_ENTRY | wc -l)" != "1" ]] && { echo "Detected more than 2 boot entry:"; echo -e "$BOOT_ENTRY"; echo "Choose 1 entry: "; IN BOOT_ENTRY; }
		DEL_ID=$(efibootmgr | grep -i $BOOT_ENTRY)
		DEL_ID=${DEL_ID#Boot}
		DEL_ID=${DEL_ID%\*}
		LOG "Deleting $DEL_ID from EFI boot entry"
		efibootmgr -b $DEL_ID -B
		local DRIVE="${EFI_DRIVE:0:-1}"
		[[ $DRIVE == *nvme* ]] && local DRIVE="${EFI_DRIVE:0:-1}"
		local PART="${EFI_DRIVE: -1}"
		local GRUBEFI=$(ls -1 /boot/efi/EFI/$BOOT_ENTRY/grub*efi | awk -F'/' {'print $NF'})
		LOG "EXE: efibootmgr --create --disk /dev/$DRIVE --part $PART --label $BOOT_ENTRY --loader \EFI\\$BOOT_ENTRY\\$GRUBEFI"
		efibootmgr --create --disk /dev/$DRIVE --part $PART --label "$BOOT_ENTRY" --loader "\EFI\\$BOOT_ENTRY\\$GRUBEFI"
	}
}
function general_post_config {
	LOG "Enabling rc-local.service"
	systemctl disable rc-local.service
	DEB "systemctl enable rc-local.service"
	LOG "Disabling SELinux"
	grep -v 'SELINUX=' /etc/sysconfig/selinux > /etc/sysconfig/selinux.tmp
	echo 'SELINUX=disabled' > /etc/sysconfig/selinux
	cat /etc/sysconfig/selinux.tmp >> /etc/sysconfig/selinux
	rm -f /etc/sysconfig/selinux.tmp
	setenforce 0
	chmod 600 /etc/ssh/*key
	LOG "Setting hostname"
	echo "$NEWHOSTNAME" > /etc/hostname
	local GW=$(echo $NEW_IP | awk -F '.' {'print $1"."$2"."$3".1"'})
	IPUnder=$(echo $NEW_IP | sed 's!\.!_!g')
	IPMinus=$(echo $NEW_IP | sed 's!\.!-!g')
	LOG "Replacing IP"
	grep -lRs 'DefaultReplaceGateway' /etc | xargs sed -i 's!'DefaultReplaceGateway'!'"$GW"'!g'
	grep -lRs 'DefaultIPReplaceDots' /etc | xargs sed -i 's!'DefaultIPReplaceDots'!'"$NEW_IP"'!g'
	grep -lRs 'DefaultIPReplaceUnder' /etc | xargs sed -i 's!'DefaultIPReplaceUnder'!'"$IPUnder"'!g'
	grep -lRs 'DefaultIPReplaceMinus' /etc | xargs sed -i 's!'DefaultIPReplaceMinus'!'"$IPMinus"'!g'
	grep -lRs 'DefaultIFACE' /etc | xargs sed -i 's!'DefaultIFACE'!'"$NEW_IFACE"'!g'
	LOG "Changing root password"
	echo "$PASS" | passwd --stdin --force root || printf "$PASS\n$PASS" | passwd root
	[[ "$BOOT_MODE" == "EFI" ]] && { LOG "Checking EFI GUID in EFI boot list"; efibootmgr -v | grep "$EFI_GUID" > /dev/null 2>&1 || ERR "BOOT" "EFI GUID [$EFI_GUID] not found in EFI boot list"; }
	echo -e "${GREEN}IP:${BLUE} $NEW_IP"
	echo -e "${GREEN}HOSTNAME:${BLUE} $NEWHOSTNAME"
	echo -e "${GREEN}PASSWORD:${BLUE} $PASS ${NORM}"
	rm -f /root/deploy.sh /root/chroot.sh /root/vars.sh
}
raid_setup
find_os
general_post_config
fix_boot
DEBP

