#!/bin/bash

ARCCONF="/usr/StorMan/arcconf"
CONTROLLER=1

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

THRESHOLD=70

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

LD_INFO=$(sudo $ARCCONF GETCONFIG $CONTROLLER LD)

LD_STATUS=$(echo "$LD_INFO" \
| awk -F: '/Status of Logical Device/ {gsub(/^ +| +$/,"",$2); print $2}' \
| head -n1)

############################################
# Get failed physical disks
############################################

FAILED_DISKS=$(echo "$LD_INFO" | awk '
/Segment/ && /Missing/ {
    match($0, /Device:([0-9]+)/, d)
    if (d[1] != "") {
        print "Disk#" d[1] "(Missing)"
    } else {
        print "MissingDisk"
    }
}
' | paste -sd "," -)

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
# Disk error counters with threshold logic
############################################

check_threshold() {
    local DATA="$1"
    local ALERTS=""

    [ -z "$DATA" ] && { echo ""; return; }

    IFS=',' read -ra ITEMS <<< "$DATA"
    for item in "${ITEMS[@]}"; do
        ERR=${item##*errors=}
        if [ -n "$ERR" ] && [ "$ERR" -gt "$THRESHOLD" ]; then
            ALERTS+="$item,"
        fi
    done

    echo "${ALERTS%,}"
}

PARITY_ALERT=$(check_threshold "$PARITY_DISKS")
HW_ALERT=$(check_threshold "$HW_DISKS")
MEDIUM_ALERT=$(check_threshold "$MEDIUM_DISKS")


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

REBUILD_PCT=$(echo "$LD_INFO" \
    | grep -oE 'Rebuild *: *[0-9]+' \
    | grep -oE '[0-9]+' \
    | head -n1)

case "$LD_STATUS" in
Optimal)
    ;;
*Rebuild*|*Rebuilding*)
    if [ -n "$REBUILD_PCT" ]; then
        echo "WARNING - RAID rebuilding (${REBUILD_PCT}%) - failed_disks=${FAILED_DISKS:-none}"
    else
        echo "WARNING - RAID rebuilding - failed_disks=${FAILED_DISKS:-none}"
    fi
    exit $STATE_WARNING
    ;;
*Degraded*|*Failed*)
    echo "CRITICAL - RAID $LD_STATUS - failed_disks=${FAILED_DISKS:-none}"
    exit $STATE_CRITICAL
    ;;
*)
    echo "CRITICAL - RAID state $LD_STATUS - failed_disks=${FAILED_DISKS:-none}"
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

# If any disk exceeds threshold → WARNING
if [ -n "$PARITY_ALERT" ] || [ -n "$HW_ALERT" ] || [ -n "$MEDIUM_ALERT" ]; then
    echo "WARNING - RAID Optimal but high errors detected - parity: ${PARITY_DISKS:-none} hw: ${HW_DISKS:-none} medium: ${MEDIUM_DISKS:-none}"
    exit $STATE_WARNING
fi

############################################
# All good (but still show existing errors)
############################################

echo "OK - RAID Optimal - parity: ${PARITY_DISKS:-none} hw: ${HW_DISKS:-none} medium: ${MEDIUM_DISKS:-none}"
exit $STATE_OK