#!/bin/bash
failed_node=$1
new_master=$2
trigger_file=$4
old_primary=$3
# if standby goes down.
if [ $failed_node != $old_primary ]; then
    echo "[INFO] Slave node is down. Failover not triggred !";
    exit 0;
fi
# Create the trigger file if primary node goes down.
echo "[INFO] Master node is down. Performing failover..."
ssh -i /var/lib/postgresql/.ssh/id_rsa postgres@$new_master "touch $trigger_file"

exit 0;
