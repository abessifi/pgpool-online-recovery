#!/bin/bash

#Postgres data directory
postgres_datadir='/var/lib/postgresql/9.1/main'
#Postgres configuration directory
postgres_configdir='/etc/postgresql/9.1/main'
#Postgres user ssh key
postgres_user_key='/var/lib/postgresql/.ssh/id_rsa'
#Pgpool configuration directory
pgpool_configdir='/etc/pgpool2'

if [ -f '/tmp/postgres_master' ]
then
    #Get current postgres master id 
    current_master_id=$(cat /tmp/postgres_master);
else
    echo "[ERROR] /tmp/postgres_master not found !";
    exit 0;
fi

#Get postgres master name
current_master_name=$(pcp_node_info 10 localhost 9898 postgres postgres $current_master_id | cut -d' ' -f1)
#Get postgres slave id
[ $current_master_id == 0 ] && current_slave_id=1 || current_slave_id=0
#Get postgres slave name
current_slave_name=$(pcp_node_info 10 localhost 9898 postgres postgres $current_slave_id | cut -d' ' -f1)

#Test if pgpool is running
CheckIfPgpoolIsRunning () {
    #Send signal 0 to pgpool to check if it's running
    if ! killall -0 pgpool; then echo "[ERROR] Pgpool is not running !"; exit 1; fi;
}

AttachNodeToPgpool () {
   #pcp_attach_node is a command that permit to attach a specific postgres server (identified by 6th parameter) to pgpool.
   #pcp_attach_node dont return a good error code when it fails so here if I catch "BackendError" message in stderr I presume
   #that attachment failed.
   #TODO:find a condition to break the folowing loop if attachment fails.
   while [ "`pcp_attach_node 10 localhost 9898 postgres postgres  $1`" == "BackendError" ]
    do
        pcp_attach_node 10 localhost 9898 postgres postgres  $1;
        #This sleep is recommanded to avoid stressing pgpool in this infinite loop.
        sleep 5;
    done
}

#Whether the slave node is down, start it and attach it to pgpool's backend pool.
ReattachDegeneratedSlave () {
    #Reboot slave node
    echo "[INFO] Slave node '$current_slave_name' is down. Performing postgres server reboot..."
    #Remote postgres reboot via ssh
    ssh -i $postgres_user_key postgres@$current_slave_name "/etc/init.d/postgresql restart"
    #Test if postgres is running
    status=$(ssh -i $postgres_user_key postgres@$current_slave_name "if ! killall -0 postgres; then echo 'error'; else echo 'running'; fi;")
    if [ $status == "error" ]
    then
        echo "[ERROR] Postgres slave still down !";
        exit 0;
    else
        echo "[OK] Slave node successfully started.";
    fi

    #Do 'slave online recovery' to force slave sync if it has incoherent data relatevely to master.
    #echo "[INFO] Starting online recovery for slave '$current_slave_name' ..."
    #ssh -i /var/lib/postgresql/.ssh/id_rsa postgres@$current_slave_name "bash /var/lib/postgresql/streaming-replication.sh $current_master_name"
    #Atttach slave (even master) to pgpool's backends pool
    #Reattach the master node if you have performed an online recovery for slave node and not juste a simple reboot. 
    #Attempting to reatach master to pgpool's backend pool
    #echo "[INFO] Attaching master node '$current_master_name' ..."
    #AttachNodeToPgpool "$current_master_id"
    #echo "[OK] Master node '$current_master_name' has been successfully reattached to pgpool."
    #Attempting to reattach slave to pgpool's backend pool
    echo "[INFO] Attaching slave node '$current_slave_name'..."
    AttachNodeToPgpool "$current_slave_id"
    echo "[OK] Slave node '$current_slave_name' has been successfully reattached to pgpool."
}


#Whether the master is down do the folowing operations :
SwitchOldMasterToSlave () {

    new_master_name=$current_slave_name
    new_master_id=$current_slave_id
    new_slave_name=$current_master_name
    new_slave_id=$current_master_id
    #Setup old master config to slave mode
    echo "[INFO] Setting up configuration for the new slave node '$new_slave_name'..."
    ssh -i $postgres_user_key postgres@$new_slave_name "/etc/init.d/postgresql stop"
    ssh -i $postgres_user_key postgres@$new_slave_name "cp -p $postgres_configdir/postgresql.conf.slave $postgres_configdir/postgresql.conf"
    ssh -i $postgres_user_key postgres@$new_slave_name  "[ -f $postgres_datadir/recovery.done ] && mv $postgres_datadir/recovery.done $postgres_datadir/recovery.conf"
    # Switch slave to new master
    echo "[INFO] Setting up configuration for the new master '$new_master_name'..."
    ssh -i $postgres_user_key postgres@$new_master_name "[ -f /tmp/trigger_file ] && rm /tmp/trigger_file"
    ssh -i $postgres_user_key postgres@$new_master_name "[ -f $postgres_datadir/recovery.conf ] && mv $postgres_datadir/recovery.conf $postgres_datadir/recovery.done"
    ssh -i $postgres_user_key postgres@$new_master_name "cp -p $postgres_configdir/postgresql.conf.master $postgres_configdir/postgresql.conf"
    echo "[INFO] Restarting new master..."
    ssh -i $postgres_user_key postgres@$new_master_name "/etc/init.d/postgresql restart"
    status=$(ssh -i $postgres_user_key postgres@$new_master_name "if ! killall -0 postgres; then echo 'error'; else echo 'running'; fi;")
    if [ $status == "error" ]
    then
    	echo "[ERROR] New postgres master not running !";
	exit 0;
    else
        echo "[OK] New master started.";
    fi
    # Start new slave/master with online recovery
    echo "[INFO] Performing online slave recovery..."
    ssh -i $postgres_user_key postgres@$new_slave_name "bash /var/lib/postgresql/streaming-replication.sh $new_master_name"
    echo "[OK] Online recovery completed."

    #Write changes to pgpool.conf file to keep the same current master and slave nodes even after pgpool reboot.
    sed -i "s/^backend_hostname0.*/backend_hostname0='$new_master_name'/" $pgpool_configdir/pgpool.conf
    sed -i "s/^backend_hostname1.*/backend_hostname1='$new_slave_name'/" $pgpool_configdir/pgpool.conf
    echo "[OK] Pgpool configuration file updated."

    #Attach new master to pgpool
    echo "[INFO] Attaching new master node '$new_master_name'..."
    AttachNodeToPgpool "$new_master_id"
    echo "[OK] New master node '$new_master_name' has been successfully reattached to pgpool."

    #Attach new slave to pgpool
    echo "[INFO] Attaching new slave node '$new_slave_name'..."
    AttachNodeToPgpool "$new_slave_id"
    echo "[OK] New slave node '$new_slave_name' has been successfully reattached to pgpool."
    
}

CheckIfPgpoolIsRunning

#Get master/slave state
current_master_state=$(pcp_node_info 10 localhost 9898 postgres postgres $current_master_id | cut -d' ' -f3)
current_slave_state=$(pcp_node_info 10 localhost 9898 postgres postgres $current_slave_id | cut -d' ' -f3)

# state 1 => postgres server is attached but still not receiving connections
# state 2 => postgres server is attached and managing clients connections
# state 3 => postgres server is detached and probably is down.

#If slave is down and master is up then perform an online slave backup.
[ $current_slave_state == 3 ] && ([ $current_master_state == 1 ] || [ $current_master_state == 2 ]) && ReattachDegeneratedSlave
#If master is down then switch roles between failed master(new server) and the slave(new master).
[ $current_master_state == 3 ] && SwitchOldMasterToSlave
