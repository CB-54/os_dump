#!/bin/bash
WPASS="--user=setup --password='http_auth_pass'"
ls ./include.sh &>/dev/null || { echo "include.sh not found"; exit 1; }
PWD_DIR="$(dirname $(realpath $0))"
. $PWD_DIR/include.sh
get_drive_list() {
	DRIVE_LIST=$(lsblk -o NAME,TYPE -rn | grep -E "disk|raid" | sort | uniq | awk {'print $1'})
}
get_drive_list
USAGE=$(cat << EOF

Usage:
   $0 [options]

Utility for deploying OS templates.

Options:
	General:
	--show-templates			show all templates and exit
	--show-drives				print information about drives and exit
	--show-ifaces				print information about network interfaces and exit
	-S | --show-all				print info about drives, network inerfaces and templates and exit
	-h | --help				show this help and exit
	-v | --verbose				use verbose output
	
	Drive:
	-Z [Drive] | --wipe [Drive]		Wipe all data on drive and exit. Example: sda, nvme0n1, hdb
		enter -Z raid to delete all RAID

	Post setup:
	-p | --panel [PANEL] 			Run script to install control panel. Avalible panels: [cpanel, cwp, plesk, da, cyberpanel]
	-u | --update				Run update
	--custom [PATH] 			Run custom shell script. Use LiveCD/Rescue path to file (not inside chroot)
		File must be plain text (bash script) without entering executing file '#!/bin/bash'
		Script will be executed inside chroot.

Comments:
	1. Post setup scripts runs are via rc-local in first boot.
	2. Post setup script execute order depends on their option order. Meaning (-p cwp -u) and (-u -p cwp) are not same.
EOF
)



function wipe_disk {
	echo $1 | grep -i raid &> /dev/null && {
		local RAID_PARTS=$(lsblk -rn -o name | grep md -B1 | grep -E "[s,v,h]d[a-z]|nvme[0-9]n[0-9]")
		LOG "Deleting all RAIDs"
		mdadm --stop /dev/md*
		for i in $RAID_PARTS; do
			LOG "Removing $i from RAID"
			mdadm --zero-superblock /dev/$i
		done
		partprobe /dev/[h,s,v]d[a-z]
		partprobe /dev/nvme[0-9]n[0-9]
		return 0
	       	}
	echo $1 | grep -E "md[0-9]|[s,v,h]d[a-z]|nvme[0-9]n[0-9]" > /dev/null || { WARN "WIPEDISK" "Device [$1] is not RAID/VD/HDD/SSD/NVMe. Exiting..."; return 0; }
	while [[ "$(mount | grep $1)" ]]; do
		LOG "Trying to unmount $1"
		umount -f /dev/${1}*
		sleep 2
	done
	WARN "WIPEFS" "Wiping all data on disk /dev/$1"
	LOG "Removing labels, fs and flags from $1"
	[[ $1 == *nvme* ]] && local PDRIVE=${1}p || local PDRIVE=$1
	[[ $1 == *md* ]] && local PDRIVE=${1}p || local PDRIVE=$1
	for i in {1..64}; do
		tune2fs -L "" /dev/${PDRIVE}${i} &>/dev/null
		parted /dev/$1 set $i boot off &>/dev/null 
		parted /dev/$1 set $i esp off &>/dev/null
		parted /dev/$1 set $i lvm off &>/dev/null
		parted /dev/$1 set $i raid off &>/dev/null
		parted /dev/$1 set $i swap off &>/dev/null
		wipefs -f -a /dev/${PDRIVE}${i} 1>/dev/null 2>&1
	done
	LOG "Wiping fs on /dev/$1"
	wipefs -a -f /dev/$1 
	sleep 2
	LOG "Destroying GPT and MBR data structures"
	sgdisk -Z /dev/$1 
	sleep 2
	LOG "Updating partition info for kernel"
	partprobe /dev/$1
	kpartx -u /dev/$1
	systemctl daemon-reload
	LOG "Wiping disk /dev/$1 complete"
}
function set_boot_mode {
	ls /sys/firmware/efi/ > /dev/null 2>/dev/null || { WARN "SETBOOT" "Current system booted in ${BLUE}Legacy${NORM} mode. Boot mode set to ${BLUE}LEGACY.$NORM"; WARN "SETBOOT" "Boot in ${GREEN}EFI$NORM mode to be able to set the ${GREEN}EFI$NORM boot mode"; BOOT_MODE=LEGACY; return 0; }
	echo "Please choose boot mode:
	1) Legacy
	2) EFI"
	LOOP=1
	while [[ "$LOOP" == "1" ]]; do
		IN1 BOOT_MODE
		case "$BOOT_MODE" in
			1)
			BOOT_MODE=LEGACY
			PART_TABLE=MBR
			LOOP=0
			;;
			2)
			BOOT_MODE=EFI
			PART_TABLE=GPT
			LOOP=0
			;;
			*)
			echo "Option [$BOOT_MODE] is not valid. Try again: "
			;;
		esac
	done
	LOG "Boot mode set as: $BOOT_MODE"
	rm -f /root/*_disk_map && LOG "All /root/*_disk_map files are deleted"
}
function set_part_table { #DRIVE
	LOG "Setting partition table $PART_TABLE for /dev/$1"
	local DRIVE=$1
	echo $PART_TABLE | grep -i mbr > /dev/null && echo "label: dos" | sfdisk /dev/$DRIVE && LOG "Label set as MBR"
	echo $PART_TABLE | grep -i gpt > /dev/null && echo "label: gpt" | sfdisk /dev/$DRIVE && LOG "Label set as GPT"
	partprobe /dev/$1 
}

function make_boot {
	local PART_TABLE=$(parted /dev/$BOOT_DRIVE <<<"print" 2>/dev/null | grep 'Partition Table' | awk {'print $NF'})
	local DRIVE=$BOOT_DRIVE
	LOG "Boot mode: [$BOOT_MODE] Boot drive: [$BOOT_DRIVE] Boot drive partition table: [$PART_TABLE]"
	if [[ "$BOOT_MODE" == "EFI" ]];then
		echo "$PART_TABLE" | grep -i msdos > /dev/null && ERR "SETBOOT" "Partition table MBR and EFI boot mode incompatible" && exit 1		
		LOG "Creating EFI partition"
		sleep 1
		echo ",256MiB,U,*" | sfdisk /dev/$DRIVE 
		echo EFI > /root/efi_disk_map
		[[ $DRIVE == *nvme* ]] && local DRIVE=${DRIVE}p
		sleep 1
		LOG "Making FAT32 for /dev/${DRIVE}1"
		mkfs.fat -F32 /dev/${DRIVE}1
		EFI_DRIVE=${DRIVE}1
#		EFI_GUID=$(lsblk -o NAME,PARTUUID | grep "$EFI_DRIVE" | awk {'print $2'})
		EFI_GUID=$(blkid $EFI_DRIVE | awk -F'"' {'print $(NF-1)'})
	elif [[ "$DRIVE" == "$BOOT_DRIVE" ]] && [[ "$BOOT_MODE" == "LEGACY" ]];then 
		echo "$PART_TABLE" | grep -i gpt > /dev/null && ERR "SETBOOT" "Partition table GPT and Legacy boot mode incompatible" && exit 1
		echo "LEGACY"
	fi
	partprobe /dev/$1
	BOOT_IS_CREATED=1
}
function make_swap {
	local SWAP_PARTS=$(lsblk -rno NAME,parttypename | grep 'Linux.*swap' | awk {'print $1'})
	local SWAP_COUNT=1
	rm -f /root/swap_fstab
	LOG "SWAP partitions: $SWAP_PARTS"
	for sp in $SWAP_PARTS; do
		LOG "EXE: mkswap --force -L SWAP$SWAP_COUNT /dev/${sp}"
		mkswap --force -L SWAP$SWAP_COUNT /dev/${sp}
		echo "SWAP$SWAP_COUNT" >> /root/swap_fstab
		((SWAP_COUNT++))
	done
}

function make_raid { #Dev1 Dev2 Lvl Boot
	local RAID_LEVEL RAID_DEV_1 RAID_DEV_2 RAID_IS_BOOT
	echo -e "${BLUE}Enter RAID level [0,1]:$NORM "
	IN1 RAID_LEVEL
	echo -e "${BLUE}Enter two block devices to create RAID-${RAID_LEVEL}"
	echo -e "It must be two block devices separated by space bar"
	echo -e "You can create new partitions on EXT4 mapping tool"
	echo -e "Examples: sda sdb, sdb1 sdc1, sdb2 sda5"
	echo -e "Type 0 to exit RAID mapping tool"
	echo -e "Avalible options: ${GREEN}"
	lsblk -no name,size,type,parttypename | grep -viE "swap|efi" | grep -E "part|disk"
	IN RAID_DEV_1 RAID_DEV_2
	[[ "$RAID_DEV_1" == "0" ]] && return 0
	ls /dev/$RAID_DEV_1 &>/dev/null || { WARN "RAID" "Block device $RAID_DEV_1 doesnt exist"; continue; }
	ls /dev/$RAID_DEV_2 &>/dev/null || { WARN "RAID" "Block device $RAID_DEV_2 doesnt exist"; continue; }
	echo -e "${BLUE}Enter Y if this RAID will be used for /boot partition:${NORM} "
	IN1 RAID_IS_BOOT
	[[ "${RAID_IS_BOOT,,}" == "y" ]] && local BOOT_VAR="--metadata=0.90"
	LOG "Zeroing superblock on [$RAID_DEV_1 $RAID_DEV_2]"
	mdadm --zero-superblock --force $RAID_DEV_1 $RAID_DEV_2
	local RAIDN=$(( $(lsblk -r | grep raid | awk {'print $1'} | sort | uniq | tail -n1 | grep -Eo "[0-9]" | tr -d '\n') + 1 ))
	LOG "Creating RAID-$RAID_LEVEL /dev/md${RAIDN} on [$RAID_DEV_1 $RAID_DEV_2]"
	mdadm  --create /dev/md${RAIDN} $BOOT_VAR --level=$RAID_LEVEL --raid-devices=2 /dev/$RAID_DEV_1 /dev/$RAID_DEV_2 <<<"y"
}




function make_default {
	local SWAPSIZE=2
	local RAMSIZE=$(free -g | grep Mem | awk {'print $2'})
	[[ $RAMSIZE -ge 4 ]] && local SWAPSIZE=4
	[[ $RAMSIZE -ge 16 ]] && local SWAPSIZE=8
	[[ $RAMSIZE -ge 64 ]] && local SWAPSIZE=16
	[[ $RAMSIZE -ge 128 ]] && local SWAPSIZE=32
	echo -e "${GREEN}Avalible templates:
	1) /boot - 1GiB, SWAP - ${SWAPSIZE}GiB, / - rest avalible space
	2) RAID-1: [/boot - 1GiB], SWAP - ${SWAPSIZE}GiB, RAID-1: [/ - rest avalible space]
	0) Exit$NORM"
	IN1 DEF_IN
	rm -f /root/*_disk_map
	case "$DEF_IN" in
		1)
			echo -e "${BLUE}Enter main drive name [sda]: $GREEN"
			lsblk -o name,size,type,model,serial | grep -E "NAME|disk"
			local DRIVE
			IN DRIVE
			DRIVE=${DRIVE:-sda}
			[[ $DRIVE == *nvme* ]] && local PDRIVE=${DRIVE}p || local PDRIVE=$DRIVE
			BOOT_DRIVE=$DRIVE
			wipe_disk $DRIVE
			set_part_table $DRIVE
			make_boot
			LOG "Making partition on $DRIVE"
			echo ",1GiB,L" | sfdisk /dev/$DRIVE --append --no-reread 
			echo ",${SWAPSIZE}GiB,S" | sfdisk /dev/$DRIVE --append --no-reread 
			echo ",,L" | sfdisk /dev/$DRIVE --append --no-reread 
			[[ "$BOOT_MODE" == "EFI" ]] && local PARTN=2 || local PARTN=1 
			partprobe /dev/$DRIVE
			sleep 3
			LOG "Setting EXT4 on $DRIVE"
			mkfs.ext4 -F -L /boot /dev/$PDRIVE$PARTN && echo "/boot" >> /root/ext4_disk_map 
			(( PARTN+=2 ))
			mkfs.ext4 -F -L / /dev/$PDRIVE$PARTN && echo "/" >> /root/ext4_disk_map 
		;;
		2)
			echo -e "${BLUE}Enter two drive name separated by spacebar [sda sdb]: $GREEN"
                        lsblk -o name,size,type,model,serial | grep -E "NAME|disk"
                        local DRIVE1 DRIVE2
                        IN DRIVE1 DRIVE2
			DRIVE1=${DRIVE1:-sda}
			DRIVE2=${DRIVE2:-sdb}
			[[ $DRIVE1 == *nvme* ]] && local PDRIVE1=${DRIVE1}p || local PDRIVE1=$DRIVE1
			[[ $DRIVE2 == *nvme* ]] && local PDRIVE2=${DRIVE2}p || local PDRIVE2=$DRIVE2
			BOOT_DRIVE=$DRIVE1
			wipe_disk $DRIVE1
			wipe_disk $DRIVE2
			set_part_table $DRIVE1
			set_part_table $DRIVE2
			make_boot
			[[ "$BOOT_MODE" == "EFI" ]] && local PARTN=3 || local PARTN=2
			LOG "Making partition on $DRIVE1 and $DRIVE2"
			echo ",$(( $SWAPSIZE / 2 ))GiB,S" | sfdisk /dev/$DRIVE1 --append --no-reread 
			echo ",$(( $SWAPSIZE / 2 ))GiB,S" | sfdisk /dev/$DRIVE2 --append --no-reread 
			echo ",1GiB,L" | sfdisk /dev/$DRIVE1 --append --no-reread 
			echo ",1GiB,L" | sfdisk /dev/$DRIVE2 --append --no-reread
			echo ",,L" | sfdisk /dev/$DRIVE1 --append --no-reread 
			echo ",,L" | sfdisk /dev/$DRIVE2 --append --no-reread 
			partprobe /dev/$DRIVE1
			partprobe /dev/$DRIVE2
			sleep 3
			LOG "Creating RAID 1 on $PDRIVE1$PARTN and ${PDRIVE2}2 for /boot"
			mdadm  --create /dev/md0 --metadata=0.90 --level=1 --raid-devices=2 /dev/$PDRIVE1$PARTN /dev/${PDRIVE2}2 <<<"y" 
			(( PARTN++ ))
			sleep 2
			LOG "Creating RAID 1 on $PDRIVE1$PARTN and ${PDRIVE2}3 for /"
			mdadm  --create /dev/md1 --level=1 --raid-devices=2 /dev/$PDRIVE1$PARTN /dev/${PDRIVE2}3 <<<"y" 
			sleep 2
			LOG "Setting EXT4 on md0"
			mkfs.ext4 -F -L /boot /dev/md0 && echo "/boot" >> /root/ext4_disk_map 
			LOG "Setting EXT4 on md1"
			mkfs.ext4 -F -L / /dev/md1 && echo "/" >> /root/ext4_disk_map 

		;;
		*)
			echo "Exiting..."
			;;
	esac
	echo -e "${BLUE}Mapping $DRIVE$DRIVE1 $DRIVE2 complete:$NORM"
	lsblk -o name,size,fssize,fstype,label,parttypename,partflags,model | grep -E "$DRIVE|$DRIVE1|$DRIVE2|md[0-9]"
}

function disk_part {
	get_drive_list
	DRIVE_LIST_COUNT=$(echo $DRIVE_LIST | tr ' ' '\n' | wc -l)
	if [[ "$DRIVE_LIST_COUNT" == "1" ]];then
		SEL_DRIVE=$DRIVE_LIST
		LOG "$SEL_DRIVE set as boot device" && BOOT_DRIVE=$SEL_DRIVE 
	else
		print_drive_info
		echo -e "${BLUE}Select disk drive ${GREEN}[${DRIVE_LIST//$'\n'/ }]:${NORM} "
		LOOP=1
		while [[ $LOOP == 1 ]]; do
			IN SEL_DRIVE
			echo $DRIVE_LIST | grep -E "^$SEL_DRIVE | $SEL_DRIVE$| $SEL_DRIVE " > /dev/null && LOOP=0 || echo "Entered value [$SEL_DRIVE] is not correct, try again."
		done
		unset BOOT_DRIVE_INPUT
		[[ $SEL_DRIVE != md* ]] && echo "Make $SEL_DRIVE as boot drive? [Y/N]" && IN1 BOOT_DRIVE_INPUT
		[[ "${BOOT_DRIVE_INPUT,,}" == "y" ]] && echo "$SEL_DRIVE set as boot device" && BOOT_DRIVE=$SEL_DRIVE 
	fi
	LOG "Selected drive: $SEL_DRIVE"
	echo -e "${RED}All data on $GREEN/dev/$SEL_DRIVE$RED will be lost. Proceeding in 5 seconds...
	Hit CTRL+C NOW to prevent data loss!"
	sleep 5
	wipe_disk $SEL_DRIVE
	set_part_table $SEL_DRIVE
	[[ "$BOOT_IS_CREATED" != "1" ]] && [[ -n "$BOOT_DRIVE" ]] && make_boot
	echo -e "${BLUE}Enter partition type name and size separated by spacebar.
	Allowed suffixes for size:
		KiB, MiB, GiB, TiB. ${RED}[!]CASE SENSITIVE[!]${BLUE}
		By default used GiB
	Type 0 in size to allocate remaining disk space.
	Allowed  partition type name:
		L - Linux partition type (can be used for EXT4, RAID); 
		R - Linux RAID auto detection;
		S - swap area; 
	Examples:
		L 5
		l 1024MiB
		s 0
	Type ${GREEN}0$BLUE to complete disk partitioning.$NORM"
	[[ $SEL_DRIVE == *nvme* ]] && local PDRIVE=${SEL_DRIVE}p || local PDRIVE=$SEL_DRIVE
	until [[ "$PART_TYPE" == "0" ]]; do
		[[ "$PART_TABLE" == "MBR" ]] && [[ "$PART_NUM" == "3" ]] && { echo ",,Ex" | sfdisk /dev/$SEL_DRIVE --append --no-reread; PART_NUM=4; }
		echo -ne "${GREEN}Disk space left on $SEL_DRIVE: "
		parted /dev/${SEL_DRIVE} <<<"print free" | grep "Free Space" | tail -n1 | awk {'print $3'}
		local PART_TYPE PART_SIZE
		IN PART_TYPE PART_SIZE
		[[ "$PART_TYPE" == "0" ]] && continue
		echo $PART_TYPE | grep -iE "^L$|^S$" &>/dev/null || { WARN "DP" "Partition type [$PART_TYPE] is not correct."; continue; }
		echo $PART_SIZE | grep -E "GiB$|MiB$|KiB$|TiB$|^0$" &>/dev/null || PART_SIZE=$(echo "$(echo $PART_SIZE | grep -o [0-9] | tr -d '\n')GiB")
		[[ "$PART_SIZE" == "0" ]] && { echo ",,${PART_TYPE^^}" | sfdisk /dev/$SEL_DRIVE --append --no-reread; PART_TYPE="0"; } || echo ",${PART_SIZE},${PART_TYPE^^}" | sfdisk /dev/$SEL_DRIVE --append --no-reread 
		PART_NUM=$(lsblk -ro name,type | grep part | grep $SEL_DRIVE | tail -n1 | awk {'print $1'} | grep -o [0-9] | tr -d '\n')
		echo "PartNum: $PART_NUM"
		[[ $SEL_DRIVE != md* ]] && wipefs /dev/${PDRIVE}${PART_NUM}




	done
	echo -e "${GREEN}$SEL_DRIVE${BLUE} ${BLUE}mapping complete:${NORM}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,parttypename,uuid | grep -E "$SEL_DRIVE|NAME"
}

function ext4 {
	echo -e "${BLUE}Enter mountpoint and block device separated by spacebar."
	echo -e "${BLUE}Examples: /boot sda1, /backup sdc, /var/lib/mysql sda3" 
	echo -e "${BLUE}Type ${GREEN}0$BLUE to complete EXT4 mapping."
	echo -e "${BLUE}Avalible block devices:${GREEN}"
	lsblk -o NAME,SIZE,TYPE,parttypename | grep -viE "swap$|EFI|loop|rom"
	echo -e "$NORM"
	local LABEL PART
	until [[ "$LABEL" == "0" ]]; do
		IN LABEL PART
		[[ "$LABEL" == "0" ]] && continue
		ls /dev/$PART &>/dev/null || { WARN "EXT4" "/dev/$LABEL doesnt exist"; continue; }
		LOG "EXE: mkfs.ext4 -F -L $LABEL /dev/$PART"
		mkfs.ext4 -F -L $LABEL /dev/$PART && echo "$LABEL" >> /root/ext4_disk_map && LOG "$LABEL added to disk map"
	done

}

function make_fstab {
	LOG "Creating fstab file from /root/*_disk_map*"
	rm -f /root/new_fstab*
	cat /root/*_disk_map* > /root/all_disk_map_tmp
	grep '^/$' /root/all_disk_map_tmp > /root/all_disk_map
	grep '^/boot$' /root/all_disk_map_tmp >> /root/all_disk_map
	grep '^EFI$' /root/all_disk_map_tmp >> /root/all_disk_map
	grep -vE '^/$|^EFI$|^/boot$' /root/all_disk_map_tmp | awk -F'/' '{print NF-1, $0}' | sort -nk1 | cut -d' ' -f2- >> /root/all_disk_map
	cat /root/swap_fstab >> /root/all_disk_map
	rm -f /root/all_disk_map_tmp
#	grep EFI /root/all_disk_map 1>/dev/null && EFI_UUID=$(lsblk -rno name,uuid | grep "^${EFI_DRIVE:-sda1}" | awk {'print $2'})
	[[ -z "$EFI_DRIVE" ]] && { ERR "BOOT" "Var EFI_DRIVE is not set"; exit 1; }
	grep EFI /root/all_disk_map 1>/dev/null && EFI_UUID=$(ls -l /dev/disk/by-uuid/ | grep "${EFI_DRIVE:-sda1}$" | awk {'print $9'})
	LOG "EFI UUID: $EFI_UUID"
	while read -r LLABEL; do
		LOG "Adding $LLABEL into fstab"
		case "$LLABEL" in
		SWAP*)
			echo "LABEL=$LLABEL	none	swap	sw	0	0" >> /root/new_fstab
			;;
		"EFI")
			[[ -z "$EFI_UUID" ]] && { ERR "BOOT" "Var EFI_UUID is not set"; exit 1; }
			echo "UUID=$EFI_UUID	/boot/efi	vfat	umask=0077,shortname=winnt	0	2" >> /root/new_fstab
			;;
		"/")
			echo "LABEL=$LLABEL	$LLABEL	ext4	defaults	1	1" >> /root/new_fstab
			;;
		*)
			echo "LABEL=$LLABEL	$LLABEL	ext4	defaults	1	2" >> /root/new_fstab
			;;
		esac
	done < /root/all_disk_map
	cat /root/new_fstab > /root/new_fstab_mnt
	sed -i 's|\(\s\)/|\1/mnt/|' /root/new_fstab_mnt
	LOG "fstab file:" && cat /root/new_fstab
}
function mount_fstab {
	if [[ "$1" == "umount" ]]; then
		LOG "Unmounting all /mnt/*"
		while [[ "$(mount | grep '/mnt')" ]]; do
			umount -f /mnt/*
			umount -f /mnt
			umount -f dev
	                sleep 2
	        done
	else
		mv /etc/fstab /etc/fstab_orig
		cp /root/new_fstab_mnt /etc/fstab
		echo "Mounting new fstab:"
		cat /etc/fstab
		LOG "Daemon-reload"
		systemctl daemon-reload
		LOG "EXE: mount -m -a"
		mount -m -a
		cat /etc/fstab_orig > /etc/fstab
		systemctl daemon-reload
	fi
}


function get_templates {
LOG "Downloading template list"
cat << EOF > /root/templates
$(wget -q -O - $WPASS http://1.1.1.1/setup/list.txt)
EOF
}
function print_templates {
	echo -e "${BLUE}=====================================${NORM}"
	while IFS=: read -r PrID PrNAME PrDESC; do
		echo -e "${GREEN}=====================================${NORM}"
		echo "	[ID=$PrID] $PrNAME"
		echo "	$PrDESC"
		echo -e "${GREEN}=====================================${NORM}"
	done < /root/templates
	echo -e "${BLUE}=====================================${NORM}"
}

function select_template { #temp_id
	print_templates
	echo "Enter template ID to select it."
	IN SID
	local LINE=$(grep "^$SID:" /root/templates)
	NAME=$(echo $LINE | cut -d':' -f2)
	NETTYPE=$(echo $LINE | cut -d':' -f3)
	DESC=$(echo $LINE | cut -d':' -f4)
	LOG "Selected template: [$SID] $NAME $DESC"
}
function copy_root {
	LOG "Downloading and unpacking template [$SID] $NAME..."
	wget -q -O - $WPASS http://1.1.1.1/setup/id${SID}.tar.gz | pv -s $(wget --spider $WPASS http://1.1.1.1/setup/id${SID}.tar.gz |& grep Length | cut -d' ' -f2) | tar -xz -C /mnt/ 
	LOG "Copying fstab into /mnt/etc/fstab"
	cat /root/new_fstab > /mnt/etc/fstab
}
function print_drive_info {
PARTED_LIST=$(parted -l 2>/dev/null)
for drive in $DRIVE_LIST; do
	echo -e "${GREEN}______[$drive]______${NORM}"
	echo "$PARTED_LIST" | grep -A3 -B1 "/dev/${drive}:"
	echo -e "${GREEN}‾‾‾‾‾‾[$drive]‾‾‾‾‾‾${NORM}"
done
}
PASSB() { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 4; }
PASS="$(PASSB)-$(PASSB)-$(PASSB)-$(PASSB)"


function make_chroot {
cat << EOF > /mnt/root/vars.sh
BOOT_MODE="$BOOT_MODE"
VERBOSE="$VERBOSE"
EFI_DRIVE=$EFI_DRIVE
EFI_GUID="$EFI_GUID"
PASS="$PASS"
NEWHOSTNAME="$NEWHOSTNAME"
NEW_IP="$NEW_IP"
NEW_IFACE="$NEW_IFACE"
EOF
echo $PASS > /mnt/root/.password
mount --bind /sys /mnt/sys
mount --bind /dev /mnt/dev
mount --bind /run /mnt/run
mount --bind /proc /mnt/proc


test -f /mnt/etc/rc.local && RCLOCAL=/etc/rc.local
test -f /mnt/etc/rc.d/rc.local && RCLOCAL=/etc/rc.d/rc.local
local RCLOCAL=${RCLOCAL:-/etc/rc.local}

{ ls /lib/systemd/system/*rc*local* || ls /mnt/etc/systemd/system/*rc*local*; }  || {
LOG "Adding rc-local systemd"
cat << EOF > /etc/systemd/system/rc-local.service
[Unit]
 Description=/etc/rc.local Compatibility
 ConditionPathExists=/etc/rc.local

[Service]
 Type=forking
 ExecStart=/etc/rc.local start
 TimeoutSec=0
 StandardOutput=tty
 RemainAfterExit=yes
 SysVStartPriority=99

[Install]
 WantedBy=multi-user.target
EOF
ls -l /etc/rc.local > /dev/null 2>&1 || cat << EOF > /etc/rc.local
#!/bin/sh -e
exit 0
EOF
}

LOG "rc.local file path: $RCLOCAL"
mv /mnt$RCLOCAL /mnt$RCLOCAL.old
echo '#!/bin/bash' > /mnt$RCLOCAL
grep -v '^#' /mnt$RCLOCAL.old >> /mnt$RCLOCAL
touch /root/rc.local.sh
LOG "rc.local file content: $(cat /root/rc.local.sh)"
cat /root/rc.local.sh >> /mnt$RCLOCAL
echo "cat ${RCLOCAL}.old > $RCLOCAL" >> /mnt$RCLOCAL
echo "chmod -x $RCLOCAL" >> /mnt$RCLOCAL
chmod +x /mnt$RCLOCAL


cat << UYYU > /mnt/root/chroot.sh
$(wget -q -O - $PASS http://1.1.1.1/scripts/chroot.sh)
UYYU
LOG "Making chroot and doing GRUB setup"
arch-chroot /mnt /bin/bash -c "/bin/bash /root/chroot.sh"
}


function print_iface_info {
local MACS=$(ip link show | grep ether | awk {'print $2'})
for mac in $MACS; do
        local LMAC=$mac
        local LINAME=$(ip link show | grep -B1 $LMAC | head -n1 | awk {'print $2'} | cut -d':' -f1)
	local LSTATE=$(ip link show | grep $LINAME | grep -oP 'state \S+' | awk {'print $2'})
	local LIPS=$(ip -4 addr show | grep $LINAME | grep inet | awk {'print $2'})
	[[ "$LSTATE" == "UP" ]] && local LCOLOR=GREEN || local LCOLOR=RED
	echo -ne "Interface: ${GREEN}${LINAME}${NORM}	MAC: ${GREEN}${LMAC}${NORM}	STATE: ${!LCOLOR}${LSTATE}${NORM}"
	[[ -n $LIPS ]] && echo "	IP:	$LIPS"
	echo
	done
}
function set_password {
	echo -e "${BLUE}Enter new root password.$NORM"
	echo -e "${BLUE}Type 0 to generate random password.$NORM"
	IN PASSINPUT
	[[ "$PASSINPUT" == "0" ]] && return 0 || PASS="$PASSINPUT"
}
function set_hostname {
        echo -e "${BLUE}Enter new hostname.$NORM"
        IN NEWHOSTNAME
}
function set_ip {
	echo "Press RETURN to set [autodetected] value"
	NEW_IP=$(curl -sk http://ifconfig.co/)
	echo -e "${BLUE}Enter new IPv4 address [$NEW_IP]: $NORM"
	IN NEW_IP_INPUT
	[[ -n $NEW_IP_INPUT ]] && NEW_IP="$NEW_IP_INPUT"
	print_iface_info
	NEW_IFACE=$(ip -4 addr | grep "$NEW_IP" | awk {'print $NF'})
	echo -e "${BLUE}Enter network interface name [$NEW_IFACE]: $NORM"
	IN NEW_IFACE_INPUT
	[[ -n $NEW_IFACE_INPUT ]] && NEW_IFACE="$NEW_IFACE_INPUT"
	LOG "IP: [$NEW_IP] IFace: [$NEW_IFACE]"
}

function drive_mapper {
local DLOOP=1
while [[ "$DLOOP" == "1" ]]; do
echo -e "${GREEN} Avalible mapping methods: $GREEN
	1) Disk Partition
	2) EXT4
	3) RAID
	4) LVM
	5) Use premade template
	0) Complete mapping$NORM"
echo -e "Please enter a number: $NORM"
IN1 MAP_TYPE
case "$MAP_TYPE" in
	1)
		disk_part
		;;
	2)
		ext4
		;;
	3)
		make_raid
		;;
	4)
		echo lvm
		;;
	5)
		make_default
		;;
	0)
		DLOOP=0
		break
		;;
	*)
		echo -n "[$MAP_TYPE] is not correct. Try again: "
		;;

esac
done
}
VERBOSE=0
while [[ $# -gt 0 ]]; do
        case "$1" in
                --show-templates)
			get_templates
			print_templates
			exit 0
                        ;;
                --show-drives)
			print_drive_info
                        exit 0
			;;
		--show-ifaces)
			print_iface_info
			exit 0
			;;
		-S|--show-all)
			get_templates
			print_templates
			print_drive_info
			print_iface_info
			exit 0
			;;
		-h|--help)
			echo "$USAGE"
			exit 0
			;;
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		-Z|--wipe)
			wipe_disk $2
			exit 0;
			;;
		-p|--panel)
cat << EOF >> /root/rc.local.sh
sed -i '$d' /root/install_${2}.sh
curl -k http://194.28.86.221/sh/install_${2}.sh -o /root/install_${2}.sh || wget --no-check-certificate http://194.28.86.221/sh/install_${2}.sh -O /root/install_${2}.sh
( /bin/bash /root/install_${2}.sh >> /root/${2}_install 2>&1 ) &
EOF
			shift
			shift
			;;
		-u | --update)
cat << EOF >> /root/rc.local.sh
apt-get update || apt update
( DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -u -o Dpkg::Options::="--force-confdef" --allow-downgrades --allow-remove-essential --allow-change-held-packages --allow-change-held-packages --allow-unauthenticated || DEBIAN_FRONTEND=noninteractive apt upgrade -y -u -o Dpkg::Options::="--force-confdef" --allow-downgrades --allow-remove-essential --allow-change-held-packages --allow-change-held-packages --allow-unauthenticated ) &
yum check-update || dnf check-update
( yum update -y || dnf update -y ) &
EOF
			shift
			;;
		--custom)
			cat $2 >> /root/rc.local.sh
			shift
			shift
			;;
                *)
                        ERR "GENERAL" "Unknown option: $1"
                        exit 1
                        ;;
        esac
done



###START INTERACTIVE
get_templates
set_boot_mode
drive_mapper
select_template
make_swap
make_fstab
#echo exit && exit 1
mount_fstab
copy_root
set_password
set_hostname
set_ip
echo "Press any key to run chroot script"
read -n1
echo "Starting in 5 sec..."
sleep 5
make_chroot

###END INTERACTIVE





