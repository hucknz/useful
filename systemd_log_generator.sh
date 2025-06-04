#!/bin/bash

echo 'logs:'
for i in $(journalctl --output=json | jq -r 'select(._SYSTEMD_UNIT | type == "string" and endswith(".service")) | ._SYSTEMD_UNIT' | cut -d '.' -f1 | sort -u); do
    echo "  - name: systemd-$i"
    echo "    systemd: $i"
done
