#!/bin/bash
set -o history -o histexpand
NORM='\033[0m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
LOG() {
	        [ "$VERBOSE" == "1" ] && echo -e "$GREEN[$(date +"%Y-%m-%d %H:%M:%S") $$]$NORM $@" || return 1
}
ERR() {
	        echo -e "$RED[ERR:$1]$NORM $2" && return 1
}
WARN()
{
	        echo -e "$YELLOW[WARN:$1]$NORM $2"
}
IN() {
	echo -ne "	${GREEN}>>$NORM "
	read $@
}
IN1() {
	echo -ne "	${GREEN}>>$NORM "
	read -n1 $1 
	echo -e "\n"
}
function DEB {
        local EXE_CMD="$@"
	echo -e "${YELLOW}CATCH: $NORM[$EXE_CMD]"
	eval "$EXE_CMD"
        local LAST="$?:${_}"
        local EXIT="${LAST%%:*}"
        local CMD="${LAST#*:}"
        DEB_CMD+="[$EXIT] $CMD\n"
        (( DEB_SUM+=$EXIT ))
}
function DEBP {
        [[ "$DEB_SUM" != "0" ]] && { ERR "EXIT" "Exit code sum: [$DEB_SUM]. Executed commands with non-zero exit: "; echo -e "$DEB_CMD" | grep -viE "[0]|^[[:space:]]*$"; }
}
