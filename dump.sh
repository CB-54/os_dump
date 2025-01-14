#!/bin/bash
WPASS="--user=setup --password='http_auth_pass'"
ls ./include.sh &>/dev/null || { echo "include.sh not found"; exit 1; }
PWD_DIR="$(dirname $(realpath $0))"
. $PWD_DIR/include.sh
USAGE=$(cat << EOF

Usage:
   $0 [options]

   Utility for dumping OS templates to template server.

   Options:
	General:
	-h|-H|--help	Print this text and exit
	-s|--show	Show templates on template server and exit
	-n|--net	Print network information and exit
	-v|-V		Set verbose mode

	SSH:
	-k|--init-ssh	Run ssh-agent and add ssh key to template server
	-K|--del-ssh	Delete SSH key on template server and exit

	Main:
	-D|-d|--dump	Make server dump to template server
EOF
)

DRIVE_LIST=$(lsblk -o NAME,TYPE -d -n | grep disk | awk {'print $1'})
LOG "Drive list: [${DRIVE_LIST//$'\n'/ }]"
LOG "Checking wget and rsync"
which wget > /dev/null 2>&1 || { apt install -y wget; yum install -y wget; }
which rsync > /dev/null 2>&1 || { apt install -y rsync; yum install -y rsync; }
function mount_drives {
	for drive in $DRIVE_LIST; do
	for part in $(lsblk -o NAME,TYPE -n | grep -E "md|part|lvm" | grep ${drive}. | awk {'print $1'}); do
		part=$(echo $part | grep -o \[a-zA-Z0-9\] | tr -d '\n');
		if [[ "$1" == "umount" ]]; then
			LOG "Unmounting /dev/$part from /mnt2/$part" 
			umount -f /mnt2/$part
		else
			LOG "Mounting /dev/$part to /mnt2/$part"
			mkdir -p /mnt2/$part
			mount /dev/$part /mnt2/$part
		fi

	done
done
}
function apply_fstab {
	FSTAB_FILE=$(ls -1 /mnt2/*/etc/fstab)
	[[ -z "$FSTAB_FILE" ]] && { echo "Cannot locate fstab file. Exiting..."; exit 1; }
	if [[ "$(echo $FSTAB_FILE | tr ' ' '\n' | wc -l)" != "1" ]]; then
		echo -e "${RED}Detected multiple fstab files. You need manually choose fstab file:"
		echo -e "$GREEN$FSTAB_FILE$NORM"
		echo -e "${BLUE}Type prefered fstab file (full path): "
		LOOP=1
                while [[ "$LOOP" == "1" ]]; do
	                IN FSTAB_FILE
			[[ ! -f "$FSTAB_FILE" ]] && echo "File $FSTAB_FILE doesnt exist. Please try again: " || LOOP=0
                done
	fi
	LOG "fstab file set as: $FSTAB_FILE"
	cp -a /etc/fstab /etc/fstab_orig
	cat $FSTAB_FILE > /root/.fstab.tmp
	cat /root/.fstab.tmp > /etc/fstab
	rm -f /root/.fstab.tmp
	sed -i 's|\(\s\)/|\1/mnt/|' /etc/fstab
	LOG "EXE: systemctl daemon-reload"
	systemctl daemon-reload
	while IFS='\n' read -r line; do
	        [[ $line =~ ^#.*$ || -z $line ]] && continue || line=$(echo $line | awk {'print $2'})
		LOG "Creating dir $line"
		mkdir -p $line
	done < /etc/fstab
	LOG "EXE: mount -a"
	mount -a
	mv /etc/fstab /etc/fstab_mnt
	mv /etc/fstab_orig /etc/fstab
	LOG "EXE: systemctl daemon-reload"
	systemctl daemon-reload
}
function halt_fstab {
	while IFS='\n' read -r line; do
	        [[ $line =~ ^#.*$ || -z $line ]] && continue || line=$(echo $line | awk {'print $2'})
		LOG "Unmounting $line"
	        umount -f $line
	done < /etc/fstab_mnt
}
function init_ssh_key {
	. /root/.ssh_agent
	if [[ "$1" == "delete" ]]; then
		LOG "Deleting SSH key"
		ssh-add -d /root/.id_copy
		kill -9 $SSH_AGENT_PID
		rm -f /root/.id_copy /root/.ssh_agent
		unset SSH_AGENT_PID 
		unset SSH_AUTH_SOCK
        else
		ssh-add -l | grep 'IDbh3JzmiZ1btv7uN34ipCrAKkKtgNhoKsO0Er52hR4' > /dev/null 2>&1 || {  # Open (public) SSH key
cat << EOF > /root/.id_copy
-----BEGIN OPENSSH PRIVATE KEY-----
Here's your private SSH KEY
-----END OPENSSH PRIVATE KEY-----
EOF
	chmod 600 /root/.id_copy
	ssh-agent -s > /root/.ssh_agent
	eval $(cat /root/.ssh_agent)
	ssh-add /root/.id_copy
	LOG "SSH key added"
	return 0
	}
	LOG "SSH key already added"
	fi
}

function copy_root {
	SID=$(($(wget $WPASS http://1.1.1.1/setup/list.txt -qO - | tail -n1 | cut -d':' -f1) +1))
	RSYNC_PATH=/home/templates/id$SID
	LOG "Copying /mnt via rsync to template server in $RSYNC_PATH"
	rsync -a --info=progress2 /mnt/ root@1.1.1.1:$RSYNC_PATH/ -e "ssh -i /root/.id_copy -o PasswordAuthentication=no -o StrictHostKeyChecking=no"
}

# Replace /root and user root to another if needed
# http://example.ua/setup = /home/templates

function print_templates {
LOG "Downloading template list"
cat << EOF > /root/templates
$(wget -q -O - $WPASS http://1.1.1.1/setup/list.txt)
EOF
        echo -e "${BLUE}=====================================${NORM}"
        while IFS=: read -r PrID PrNAME PrDESC; do
                echo -e "${GREEN}=====================================${NORM}"
                echo "  [ID=$PrID] $PrNAME"
                echo "  $PrDESC"
                echo -e "${GREEN}=====================================${NORM}"
        done < /root/templates
        echo -e "${BLUE}=====================================${NORM}"
}

function append_template_info { #	NAME	DESC
	echo -e "${BLUE}Enter template name: "
	IN NAME
	echo -e "${BLUE}Enter template description: "
	IN DESC
	ssh -i /root/.id_copy -o PasswordAuthentication=no -o StrictHostKeyChecking=no root@1.1.1.1 "echo '$SID:$NAME:$DESC' >> /home/templates/list.txt"
	LOG "Added: ID: $SID Name: $NAME Description: $DESC"
}
function set_replace { #        FROM    TO      WHERE
unset REPLACE_ARG 
if [[ "$#" == "0" ]];then
        echo -e "${BLUE}Type DONE when inputing word you want to replace to complete replace."
        echo -e "${RED}[!!!] Do not use next symbols in FROM and TO variables: : + (colon and plus)"
        while [[ "$LOOP" == "1" ]]; do
                echo -e "${BLUE}Specify the word you want to replace: " 
                IN WFROM
                echo -e "${BLUE}Specify a word to replace it with:  "
                IN WTO
                echo -e "${BLUE}Specify abs path where to replace (/ or /home etc): "
                IN WPATH
                REPLACE_ARG+="$WFROM:$WTO:$WPATH+"
        done
else
        while [[ $# -gt 0 ]]; do
                REPLACE_ARG+="$1:$2:$3+"
                shift
                shift
                shift
        done
fi
LOG "Replace set as: [FROM:TO:WHERE+]: [$REPLACE_ARG]"
}

function make_replace { #	ServerID
[[ -z "$REPLACE_ARG" ]] && { echo "Replace arg not set."; return 1; }
local REPLACE_ID=$1
[[ -z "$REPLACE_ID" ]] && local REPLACE_ID=$SID
for arg in $(echo $REPLACE_ARG | tr '+' '\n');do
	local RFROM=$(echo $arg | cut -d':' -f1)
	local RTO=$(echo $arg | cut -d':' -f2)
	local RWHERE=$(echo $arg | cut -d':' -f3)
	LOG "Replacing from [$RFROM] to [$RTO] in [$RWHERE] on template ID [$REPLACE_ID]"
	ssh -i /root/.id_copy -o PasswordAuthentication=no -o StrictHostKeyChecking=no root@1.1.1.1 "grep -lRs \"$RFROM\" /home/templates/id${REPLACE_ID}$RWHERE | xargs sed -i 's!'\"$RFROM\"'!'\"$RTO\"'!g'"
done
unset REPLACE_ARG
}
function get_network_info {
	PUBLIC_IP=$(curl -sk http://ifconfig.co/)
	PUBLIC_INTERFACE=$(ip -o -4 addr show | grep $PUBLIC_IP | awk {'print $2'})
	PUBLIC_MAC=$(ip link show $PUBLIC_INTERFACE | grep ether | awk {'print $2'})
	GATEWAY=$(echo $PUBLIC_IP | rev | cut -d'.' -f2- | rev).1
	LOG "Public IP: $PUBLIC_IP GW: $GATEWAY Public network interface: $PUBLIC_INTERFACE [$PUBLIC_MAC]"
}
function default_replace { #	ServerID
	local ID=$1
	[[ -z "$1" ]] && local ID=$SID
	IPUnder=$(echo $PUBLIC_IP | sed 's!\.!_!g')
	IPMinus=$(echo $PUBLIC_IP | sed 's!\.!-!g')
	set_replace $PUBLIC_IP DefaultIPReplaceDots /etc $IPUnder DefaultIPReplaceUnder /etc $IPMinus DefaultIPReplaceMinus /etc $PUBLIC_INTERFACE DefaultIFACE /etc $GATEWAY DefaultReplaceGateway /etc
	LOG "Making default replace on template ID $ID"
	make_replace $ID
}
function archive_template {
	local ID=$1
	[[ -z "$1" ]] && local ID=$SID
	LOG "Archiving template on storage server..."
	ssh -i /root/.id_copy -o PasswordAuthentication=no -o StrictHostKeyChecking=no root@1.1.1.1 "cd /home/templates/id${ID}; tar -czf /home/templates/id${ID}.tar.gz ./"
	#; cd; rm -rf /home/templates/id${ID}"
	LOG "...complete."
}

[[ $# == "0" ]] && set -- "-h"
while [[ $# -gt 0 ]]; do
        case "$1" in
                -H|-h|--help)
                        echo "$USAGE"
                        exit 0
                        ;;
                -s|--show)
                        print_templates
                        exit 0
                        ;;
		-n|--net)
			get_network_info
			exit 0
			;;
		-v|-V)
			VERBOSE=1
			shift
			;;
		-k|--init-ssh)
			init_ssh_key
			shift
			;;
		-K|--del-ssh)
			init_ssh_key delete
			shift
			;;
		-D|-d|--dump)
			init_ssh_key
			get_network_info
			mount_drives
			apply_fstab
			mount_drives umount
			copy_root
			halt_fstab
			append_template_info
			default_replace
			archive_template
			shift
			;;
		*)
			ERR "INPUT" "Unknow var: $1"
			exit 1
			;;
			
	esac
done




