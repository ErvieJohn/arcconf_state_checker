#!/bin/bash

ARCCONF="/usr/StorMan/arcconf"
CONTROLLER=1

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Check arcconf binary
if [ ! -x "$ARCCONF" ]; then
    echo "UNKNOWN - arcconf not found"
    exit $STATE_UNKNOWN
fi

# Test arcconf access
if ! sudo $ARCCONF GETCONFIG $CONTROLLER >/dev/null 2>&1; then
    echo "UNKNOWN - cannot execute arcconf"
    exit $STATE_UNKNOWN
fi

############################################
# Get RAID logical device status
############################################

LD_STATUS=$(sudo $ARCCONF GETCONFIG $CONTROLLER LD \
| awk -F: '/Status of Logical Device/ {gsub(/^ +/,"",$2); print $2}' \
| sort -u)

############################################
# Get failed physical disks
############################################

FAILED_DISKS=$(sudo $ARCCONF GETCONFIG $CONTROLLER PD \
| awk '
/Device #/ {dev=$3}
/State/ {
state=$2
if (state!="Online" && state!="Hot" && state!="Ready")
print "Disk#"dev"("state")"
}' | paste -sd "," -)

############################################
# Get disk error logs
############################################

LOGS=$(sudo $ARCCONF GETLOGS $CONTROLLER DEVICE tabular)

if [ -z "$LOGS" ]; then
    echo "UNKNOWN - unable to read controller logs"
    exit $STATE_UNKNOWN
fi

get_disk_errors() {
    local FIELD=$1
    echo "$LOGS" | awk -v field="$FIELD" '
    /deviceID/ {id=$3}
/productID/ {model=$3" "$4}
$1==field && $3>0 {print "Disk#"id" ("model") errors="$3}
' | paste -sd "," -
}

PARITY_DISKS=$(get_disk_errors numParityErrors)
HW_DISKS=$(get_disk_errors hwErrors)
MEDIUM_DISKS=$(get_disk_errors mediumErrors)

############################################
# SMART failure detection
############################################

# SMART_INFO=$(echo "$LOGS" | awk '
# /deviceID/ {id=$3}
# /productID/ {model=$3" "$4}
# /smartError/ && $3=="true" {print "Disk#"id" ("model")"}
# ' | paste -sd "," -)

############################################
# RAID state logic
############################################

case "$LD_STATUS" in
Optimal)
    ;;
Rebuild*|Rebuilding*)
    echo "WARNING - RAID rebuilding | failed_disks=${FAILED_DISKS:-0}"
    exit $STATE_WARNING
    ;;
Degraded*|Failed*)
    echo "CRITICAL - RAID $LD_STATUS | failed_disks=${FAILED_DISKS:-0}"
    exit $STATE_CRITICAL
    ;;
*)
    echo "CRITICAL - RAID state $LD_STATUS | failed_disks=${FAILED_DISKS:-0}"
    exit $STATE_CRITICAL
    ;;
esac

############################################
# SMART failure check
############################################

# if [ -n "$SMART_INFO" ]; then
#     echo "CRITICAL - SMART failure detected: $SMART_INFO"
#     exit $STATE_CRITICAL
# fi

############################################
# Disk error counters
############################################

if [ -n "$PARITY_DISKS" ] || [ -n "$HW_DISKS" ] || [ -n "$MEDIUM_DISKS" ]; then
    echo "WARNING - RAID Optimal but errors detected | parity: ${PARITY_DISKS:-none} hw: ${HW_DISKS:-none} medium: ${MEDIUM_DISKS:-none}"
    exit $STATE_WARNING
fi

############################################
# All good
############################################

echo "OK - RAID Optimal | errors=0"
exit $STATE_OK