pgpool-online-recovery
======================

This simple project aims to automate and make easy the online recovery process of a failed pgpool's backend node in master/slave mode.

Requirements
============

There are two requirements to these scripts to work.

* The first one is [pgpool2](http://www.pgpool.net) (v3.1.3) available in [Debian Wheezy](http://packages.debian.org/stable/database/pgpool2). We assume that pgpool2 is installed, set up in master/slave mode with loadbalacing and manageable via PCP interface.
* The second one is obviously Postgres server (v9.1) also available in Wheezy packages repository.

There are several tutorials about setting up pgpool2 and postgres servers with [Streaming Replication](http://wiki.postgresql.org/wiki/Streaming_Replication) and this readme is far to be a howto for configuring both of them. You can check out [this tutorial](https://aricgardner.com/databases/postgresql/pgpool-ii-3-0-5-with-streaming-replication/) which describes really all the steps needed.

Installation and configuration
==============================
What about the given scripts and config files ?

**pgpool.conf** : This is a sample config file for pgpool that activates master/slave mode, loadbalancing, backends health check, failover, ...

**postgresql.conf.master** : A config file for postgres master node.

**postgresql.conf.slave** : A config file for postgres slave node.

**recovery.conf** : A config file used by postgres slave for streaming replication process.

**failover.sh** : This script will be executed automatically when a pgpool's backend node (postgres node) fails down. It'll switch the standby node (slave) to master (new master).

**online-recovery.sh** : This is the bash script which you'll execute manually in order to :
* Reboot, sync and reattach slave node to pgpool if it fails.
* Setup new master and new slave, sync and reattach them to pgpool if current master fails.
This script will invoque remotely the script streaming-replication.sh (in the new slave node) to start the [online recovery process](http://www.postgresql.org/docs/8.1/static/backup-online.html) within the standby node.
PS : When a node (master or slave) fails, pgpool still running and DBs remain available. Otherwise, pgpool will detach this node for data consistancy reasons.

**streaming-replication.sh** : This script can be executed manually to synchronize a slave node with a given master node (master name/ip must be passed as argument to streaming-replication.sh). Otherwise, this same script is triggred be online-recovery.sh via ssh during failback process.

Installation
------------

The installation steps are simple. You just need to copy provided bash scripts and config files as follow.

**In pgpool node** :
* Copy pgpool.conf to /etc/pgpool2/. This is an optional operation and in this case you have to edit the default pgpool.conf file in order to looks like the config file we provided.
* Copy failover.sh into /usr/local/bin/ and online-recovery.sh to your home or another directory that will be easily accessible.

**In the master and slave postgres nodes** :
* Copy streaming-replication.sh script into /var/lib/postgresql/ (postgres homedir).
* Copy postgresql.conf.master and postgresql.conf.slave files to /etc/postgresql/9.1/main/.
* Finally copy recovery.conf into /var/lib/postgresql/9.1/main/.

PS : All similar old files must be backed up to be able to rollback in case of risk (e.g: cp -p /etc/pgpool2/pgpool.conf /etc/pgpool2/pgpool.conf.backup).
Make sure that :
- All scripts are executable and owned by the proper users. 
- /var/lib/postgresql/9.1/archive directory is created (used to archive WAL files). This folder must be owned by postgres user !
- Do not forge to edit pg_hba.conf in each postgres server to allow access to cluster's nodes.

Not enough ! It remains only the configuration steps and we'll be done :)

Configuration
-------------

To do, just follow these steps :

1- First of all make sure you have created a postgres user in pgpool node with SSH access to all Postgres nodes. All cluster's nodes have to be able to ssh each other. You can put "config" file with "StrictHostKeyChecking=no" option under .ssh/ directory of postgres user. This is a best practice (essencially when automating a bunch of operations) that allows postgres to ssh remote machine for the first time without prompting and validating Yes/No authorization question.

2- In Pgpool node set up pgpool.conf file for instance the parameters :

	# Controls various backend behavior for instance master and slave(s).
	backend_hostname0='master.foo.bar'
	backend_port0 = 5432
	backend_weight0 = 1
	backend_data_directory0 = '/var/lib/postgres/9.1/main/'
	backend_flag0 = 'ALLOW_TO_FAILOVER'
	backend_hostname1='slave.foo.bar'
	backend_port1 = 5432
	backend_weight1 = 1
	backend_data_directory1 = '/var/lib/postgres/9.1/main/'
	backend_flag1 = 'ALLOW_TO_FAILOVER'
	# Pool size
	num_init_children = 32
	max_pool = 4
	# Master/Slave and load balancing (replication mode must be off)
	load_balance_mode = on
	master_slave_mode = on
	master_slave_sub_mode = 'stream'
	#Health check (must be set up to detecte postgres server status up/down)
	health_check_period = 30
	health_check_user = 'postgres'
	health_check_password = 'postgrespass'
	# - Special commands -
        follow_master_command = 'echo %M > /tmp/postgres_master'
	# Failover command
	failover_command = '/path/to/failover.sh %d %H %P /tmp/trigger_file'

3- In failover.sh script, specify the proper ssh private key to postgres user to access new master  node via SSH.

	ssh -i /var/lib/postgresql/.ssh/id_rsa postgres@$new_master "touch $trigger_file"

4- Idem for online-recovery.sh you have juste to change if needed the postgres's private key, the rest of params is set automatically when the script runs. Magic hein ! :)

5- Change the primary_conninfo access parameters (to master) in recovery.conf file in slave side :

	primary_conninfo = 'host=master-or-slave.foo.bar port=5432 user=postgres password=nopass'

6- Rename recovery.conf to recovery.done in master side.

7- Setup postgres master node (after backup of postgresql.conf) :

	cp -p postgresql.conf.master postgresql.conf
	/etc/init.d/postgresql restart

8- Setup postgres slave node (after backup of postgresql.conf) :

	cp -p postgresql.conf.slave postgresql.conf

9- Start first slave synchronisation with master by executing streaming-replication.sh as postgres user :

	su postgres
	cd ~
	./streaming-replication.sh master.foo.bar

10- Restart pgpool :

	/etc/init.d/pgpool2 restart

At his stage slave node is connected to master and both of them are connected to pgpool. If the master fails down, pgpool detach it from the pool and perform failover process (slave become master) automatically.

Tests
=====

Test PCP interface (as root) :

	#retrieves the node information
	pcp_node_info 10 localhost 9898 postgres "postgres-pass" "postgres-id"
	#detaches a node from pgpool
	pcp_detach_node 10 localhost 9898 postgres "postgres-pass" "postgres-id"
	#attaches a node to pgpool
	pcp_attach_node 10 localhost 9898 postgres "postgres-pass" "postgres-id"

After starting pgpool, try to test this two scenarios :

**1. When a slave fails down** :

Open pgpool log file 'tail -f /var/log/pgpool2/pgpool.log'.

Stop slave node '/etc/init.d/postgres stop'.

After exceeding health_check_period, you should see this log message :

	[INFO] Slave node is down. Failover not triggred !

Now, start slave failback process (as root) :

	# ./online-recovery.sh

**2. When a master fails down** :

Idem, open pgpool log file.

Stop master node '/etc/init.d/postgres stop'.

After exceeding health_check_period, you should see this log message :

	[INFO] Master node is down. Performing failover...

Start failback process (as root) to switch master(new slave) and slave(new master) roles :

	# ./online-recovery.sh
