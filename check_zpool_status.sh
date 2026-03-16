#!/bin/bash

POOL="zpool"

STATUS=$(zpool status $POOL | awk '/state:/ {print $2}')

FAULT=$(zpool status $POOL | awk '/FAULTED|OFFLINE|UNAVAIL|REMOVED/ {print $1}' | paste -sd "," -)

if [ "$STATUS" = "ONLINE" ]; then
    echo "OK - ZFS pool $POOL healthy (ONLINE)"
    exit 0
else
    if [ -z "$FAULT" ]; then
        echo "CRITICAL - ZFS pool $POOL $STATUS"
    else
        echo "CRITICAL - ZFS pool $POOL $STATUS | Faulty disk(s): $FAULT"
    fi
    exit 2
fi

