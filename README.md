pgpool-online-recovery
======================

This simple project aims to automate and make easy the online recovery process of a failed pgpool's backend node in master/slave mode.

Requirements
============

There are two requirements to these scripts to work.

*The first one is [pgpool2](http://www.pgpool.net) (v3.1.3) available in [Debian Wheezy](http://packages.debian.org/stable/database/pgpool2). We assume that pgpool2 is installed and set up in master/slave mode.
*The second one is obviously Postgres server (v9.1) also available in Wheezy packages repository.

There are several tutorials about setting up pgpool2 and postgres servers with [Streaming Replication](http://wiki.postgresql.org/wiki/Streaming_Replication) and this readme is far to be a howto for configuring both of them. You can check out [this tutorial](https://aricgardner.com/databases/postgresql/pgpool-ii-3-0-5-with-streaming-replication/) which describes really all the steps needed.

Installation and configuration
==============================



Tests
=====
