#!/bin/bash
function rollback {
	sed -i '/net.ipv4.ip_nonlocal_bind=1/d' /etc/sysctl.conf >> /dev/null
	sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf >> /dev/null
	systemctl stop patroni
	systemctl stop etcd
	systemctl stop haproxy
	systemctl disable haproxy
	systemctl disable patroni
	systemctl disable etcd
	if grep -Fxq 'export PGDATA="/var/lib/pgsql/15/data"' /root/.bash_profile
	then
		echo "Deleting old data from .bash_profile"
		sed -i '/PGDATA/d' /root/.bash_profile >> /dev/null
		sed -i '/ETCD/d' /root/.bash_profile >> /dev/null
		sed -i '/PATRONI/d' /root/.bash_profile >> /dev/null
		sed -i '/ENDPOINTS/d' /root/.bash_profile >> /dev/null
	fi
	rm -r /var/lib/etcd/$currentServerName
	rm -r /var/lib/pgsql/15/data
	rm -r /var/lib/pgsql/15/data.fail
	if [ -f /etc/etcd/etcd.conf_orig ]
	then
		echo "Restore old ETCD config"
		mv /etc/etcd/etcd.conf_orig /etc/etcd/etcd.conf
	fi
	if [ -f /etc/patroni/patroni.yml_orig ]
	then
		echo "Restore old patroni config file"
		mv /etc/patroni/patroni.yml_orig /etc/patroni/patroni.yml
	fi
	if [ -f /etc/haproxy/haproxy.cfg_orig ]
	then
		echo "Restore old haproxy config file"
		mv /etc/haproxy/haproxy.cfg_orig /etc/haproxy/haproxy.cfg
	fi
}
echo "============================="
echo "===INSTALL PATRONI CLUSTER==="
echo "============================="
if [ -f /etc/os-release ]
then
	. /etc/os-release
	OS=$ID
	VER=$VERSION_ID
fi
if [ $OS == "centos" ]
then
	SystemInstaller=dnf
else
	SystemInstaller=apt
fi
echo 'Current OS: '$OS
# COMPONENTS ENABLER
enableHaproxy="false"
enableKeepAlived="false"
# END COMPONENTS ENABLER
setupEnable="true"
configureEnable="false"
configureRollback="false"
currentServerIp=""
currentServerName=""
clusterSharedIp=""
pgbouncerPass=""
waitingTryMax=10
waitingTryCount=0
if [[ "$(whoami)" != root ]]; then
	echo "Only user root can run this script."
	exit 1
fi
if [ -n "$1" ] ||[ -n "$2" ] || [ -n "$3" ] || [ -n "$4" ]|| [ -n "$5" ]
then
	currentServer=$1
	clusterSharedIp=$2
	server1=$3
	server2=$4
	server3=$5
	serverArray1=(${server1//:/ })
	serverArray2=(${server2//:/ })
	serverArray3=(${server3//:/ })
	case $1 in

		"1")
		currentServerIp=${serverArray1[0]}
		currentServerName=${serverArray1[1]}
		;;

		"2")
		currentServerIp=${serverArray2[0]}
		currentServerName=${serverArray2[1]}
		;;

		"3")
		currentServerIp=${serverArray3[0]}
		currentServerName=${serverArray3[1]}
		;;

		*)
		echo "Parameter CurrentServer incorrect. Configuring disabled."
		configureEnable="false"
		;;
	esac
	serverIpArray=(${currentServerIp//./ })
	serverSubnet=${serverIpArray[0]}'.'${serverIpArray[1]}'.'${serverIpArray[2]}'.1/24'
	echo "Current server IP:" $currentServerIp
	echo "Current server name:" $currentServerName
	echo "Current server Subnet:" $serverSubnet
	echo "Server configuring enabled"
	echo "[Configuring HOSTS file]"
	echo "Deleting old data from hosts"
	sed -i '/'${serverArray1[0]}'/d' /etc/hosts >> /dev/null
	sed -i '/'${serverArray2[0]}'/d' /etc/hosts >> /dev/null
	sed -i '/'${serverArray3[0]}'/d' /etc/hosts >> /dev/null
	echo -e ${serverArray1[0]}'	'${serverArray1[1]} >> /etc/hosts
	echo -e ${serverArray2[0]}'	'${serverArray2[1]} >> /etc/hosts
	echo -e ${serverArray3[0]}'	'${serverArray3[1]} >> /etc/hosts
	configureEnable="true"
else
	configureEnable="false"
	setupEnable="false"
	configureRollback="false"
fi
if [ -n "$6" ] && [ $6 == "configonly" ] && [ $configureEnable == "true" ]
then
	echo "Start with configure only"
	setupEnable="false"
	configureEnable="true"
fi
if [ -n "$6" ] && [ $6 == "installonly" ]
then
	echo "Start with install only"
	setupEnable="true"
	configureEnable="false"
fi
if [ -n "$6" ] && [ $6 == "rollback" ]
then
	echo "Start rollback only"
	setupEnable="false"
	configureEnable="false"
	configureRollback="true"
	rollback
fi
if [ $configureEnable == "false" ] && [ $setupEnable == "false" ] && [ $configureRollback == "false" ] 
then
	echo "Parameters error. Script interrupted."
	exit 1
fi
if [ $setupEnable == "true" ]
then
	echo "============================="
	echo "===START: INSTALL PACKAGES==="
	echo "============================="
	echo "[Disabling SELINUX]"
	sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' >> /etc/selinux/config
	setenforce 0
	echo "[Disabling Firewall]"
	systemctl stop firewalld
	systemctl disable firewalld
	echo "[Preparing packages]"
	sudo sed -i '/^failovermethod=/d' >> /etc/yum.repos.d/*.repo
	dnf install -y epel-release
	dnf install -y yum-utils
	echo "[Installing PostgreSQL]"
	dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
	dnf config-manager --enable pgdg15
	dnf module disable -y postgresql
	dnf -y install postgresql15-server postgresql15 postgresql15-devel --nobest
	ln -s /usr/pgsql-15/bin/* /usr/sbin/
	echo "[Adding ETCD repo]"
	touch /etc/yum.repos.d/etcd.repo
	echo -e "[etcd] " >> /etc/yum.repos.d/etcd.repo
	echo -e "name=PostgreSQL common RPMs for RHEL / oracle \$releasever - \$basearch " >> /etc/yum.repos.d/etcd.repo
	echo -e "baseurl=http://ftp.postgresql.org/pub/repos/yum/common/pgdg-rhel8-extras/redhat/rhel-\$releasever-\$basearch " >> /etc/yum.repos.d/etcd.repo
	echo -e "enabled=1 " >> /etc/yum.repos.d/etcd.repo
	echo -e "gpgcheck=1 " >> /etc/yum.repos.d/etcd.repo
	echo -e "gpgkey=file:///etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL " >> /etc/yum.repos.d/etcd.repo
	echo -e "repo_gpgcheck = 1 " >> /etc/yum.repos.d/etcd.repo
	dnf -y makecache
	echo "[Install ETCD]"
	dnf install -y etcd
	echo "[Install Python, patroni, watchdog]"
	dnf -y install python3 python3-devel python3-pip gcc libpq-devel --nobest
	pip3 install --upgrade testresources --upgrade setuptools psycopg2 python-etcd
	dnf -y install patroni patroni-etcd watchdog --nobest
	echo "[Install PgBouncer]"
	dnf install -y pgbouncer
	if [ $enableHaproxy == "true" ]
	then
		echo "[Install HaProxy]"
		dnf install -y haproxy
	fi
	if [ $enableHKeepAlived == "true" ]
	then
		echo "[Install KeepAlived]"
		dnf install -y keepalived	
	fi
	echo "============================="
	echo "===FINISH:INSTALL PACKAGES==="
	echo "============================="
fi
if [ $configureEnable == "true" ]
then
	echo "============================="
	echo "==START: CONFIGURE PACKAGES=="
	echo "============================="
	echo "[Configuring ETCD]"
	if [ -f /etc/etcd/etcd.conf ]
	then
		echo "Backup old ETCD config"
		mv /etc/etcd/etcd.conf /etc/etcd/etcd.conf_orig
	fi
	touch /etc/etcd/etcd.conf
	echo -e 'ETCD_NAME= '$currentServerName >> /etc/etcd/etcd.conf
	echo -e 'ETCD_DATA_DIR="/var/lib/etcd/'$currentServerName'"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_LISTEN_PEER_URLS="http://'$currentServerIp':2380"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_LISTEN_CLIENT_URLS="http://'$currentServerIp':2379"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_INITIAL_ADVERTISE_PEER_URLS="http://'$currentServerIp':2380"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_INITIAL_CLUSTER="'${serverArray1[1]}'=http://'${serverArray1[0]}':2380,'${serverArray2[1]}'=http://'${serverArray2[0]}':2380,'${serverArray3[1]}'=http://'${serverArray3[0]}':2380"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_INITIAL_CLUSTER_STATE="new"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_ADVERTISE_CLIENT_URLS="http://'$currentServerIp':2379"' >> /etc/etcd/etcd.conf
	echo -e 'ETCD_ENABLE_V2="true"' >> /etc/etcd/etcd.conf
	echo "[Configuring ETCD]"
	if [ ! -f /root/.bash_profile ]
	then
		echo "Create file .bash_profile"
		touch /root/.bash_profile
	fi
	if grep -Fxq 'export PGDATA="/var/lib/pgsql/15/data"' /root/.bash_profile
	then
		echo "Deleting old data from .bash_profile"
		sed -i '/PGDATA/d' /root/.bash_profile >> /dev/null
		sed -i '/ETCD/d' /root/.bash_profile >> /dev/null
		sed -i '/PATRONI/d' /root/.bash_profile >> /dev/null
		sed -i '/ENDPOINTS/d' /root/.bash_profile >> /dev/null
	fi
	echo -e 'export PGDATA="/var/lib/pgsql/15/data"' >> /root/.bash_profile
	echo -e 'export ETCD_API="3"' >> /root/.bash_profile
	echo -e 'export PATRONI_ETCD_URL="http://127.0.0.1:2379"' >> /root/.bash_profile
	echo -e 'export PATRONI_SCOPE="pg_cluster"' >> /root/.bash_profile
	echo -e 'ENDPOINTS='${serverArray1[0]}':2379,'${serverArray2[0]}':2379,'${serverArray3[0]}':2379' >> /root/.bash_profile
	echo "[Starting ETCD]"
	systemctl enable etcd
	systemctl start etcd
	while [ "$(systemctl is-active etcd)" == "inactive" ]
		do
			if [ "$waitingTryCount" -ge "$waitingTryMax"]
			then
				echo "Service etcd not started started. Rolling back changes and stop script"
				rollback
				exit 1
			fi
			echo "Waiting 5s for etcd started"
			waitingTryCount=$((waitingTryCount+1))
		sleep 5
	done
	waitingTryCount=0
	echo "[Configure WatchDog]"
	if grep -Fxq '#watchdog-device' /etc/watchdog.conf
	then
		echo "Uncomment #watchdog-device"
		sed -i 's/#watchdog-device/watchdog-device/g' >> /etc/watchdog.conf
	fi
	echo "Create /dev/watchdog"
	mknod /dev/watchdog c 10 30
	modprobe softdog
	chown postgres /dev/watchdog
	echo "[Configure Patroni]"
	if [ ! -f /etc/patroni/patroni.yml ]
	then
		echo "Create new patroni config file"
		touch /etc/patroni/patroni.yml
	else
		echo "Backuping old patroni config file"
		mv /etc/patroni/patroni.yml /etc/patroni/patroni.yml_orig
		touch /etc/patroni/patroni.yml
	fi
	echo -e 'scope: pg_cluster' >> /etc/patroni/patroni.yml
	echo -e 'name: '$currentServerName >> /etc/patroni/patroni.yml
	echo -e 'restapi:' >> /etc/patroni/patroni.yml
	echo -e '  listen: 0.0.0.0:8008' >> /etc/patroni/patroni.yml
	echo -e '  connect_address: '$currentServerName':8008' >> /etc/patroni/patroni.yml
	echo -e 'etcd:' >> /etc/patroni/patroni.yml
	echo -e '  host: '$currentServerName':2379' >> /etc/patroni/patroni.yml
	echo -e 'bootstrap:' >> /etc/patroni/patroni.yml
	echo -e '  dcs:' >> /etc/patroni/patroni.yml
	echo -e '    ttl: 30' >> /etc/patroni/patroni.yml
	echo -e '    loop_wait: 10' >> /etc/patroni/patroni.yml
	echo -e '    retry_timeout: 10' >> /etc/patroni/patroni.yml
	echo -e '    maximum_lag_on_failover: 1048576' >> /etc/patroni/patroni.yml
	echo -e '    postgresql:' >> /etc/patroni/patroni.yml
	echo -e '      use_pg_rewind: true' >> /etc/patroni/patroni.yml
	echo -e '      use_slots: true' >> /etc/patroni/patroni.yml
	echo -e '      parameters:' >> /etc/patroni/patroni.yml
	echo -e '        wal_level: replica' >> /etc/patroni/patroni.yml
	echo -e '        hot_snatdby: "on"' >> /etc/patroni/patroni.yml
	echo -e '        logging_collector: "on"' >> /etc/patroni/patroni.yml
	echo -e '        max_wal_senders: 5' >> /etc/patroni/patroni.yml
	echo -e '        max_replication_slots: 5' >> /etc/patroni/patroni.yml
	echo -e '        wal_log_hints: "on"' >> /etc/patroni/patroni.yml
	echo -e '    users:' >> /etc/patroni/patroni.yml
	echo -e '      admin:' >> /etc/patroni/patroni.yml
	echo -e '        password: admin' >> /etc/patroni/patroni.yml
	echo -e '        options:' >> /etc/patroni/patroni.yml
	echo -e '         - createrole' >> /etc/patroni/patroni.yml
	echo -e '         - createdb' >> /etc/patroni/patroni.yml
	echo -e 'initdb:' >> /etc/patroni/patroni.yml
	echo -e '      - encoding: UTF8' >> /etc/patroni/patroni.yml
	echo -e '      - data-checksums' >> /etc/patroni/patroni.yml
	echo -e 'pg_hba:' >> /etc/patroni/patroni.yml
	echo -e '  - host replication replicator '$serverSubnet' md5' >> /etc/patroni/patroni.yml
	echo -e '  - host replication replicator 127.0.0.1/32 trust' >> /etc/patroni/patroni.yml
	echo -e '  - host all all '$serverSubnet' md5' >> /etc/patroni/patroni.yml
	echo -e '  - host all all 0.0.0.0/0 md5' >> /etc/patroni/patroni.yml
	echo -e '  - local all postgres   trust' >> /etc/patroni/patroni.yml
	echo -e 'postgresql:' >> /etc/patroni/patroni.yml
	echo -e '  listen: 0.0.0.0:5432' >> /etc/patroni/patroni.yml
	echo -e '  connect_address: '$currentServerName':5432' >> /etc/patroni/patroni.yml
	echo -e '  data_dir: /var/lib/pgsql/15/data' >> /etc/patroni/patroni.yml
	echo -e '  bin_dir: /usr/pgsql-15/bin' >> /etc/patroni/patroni.yml
	echo -e '  pgpass: /tmp/pgpass0' >> /etc/patroni/patroni.yml
	echo -e '  authentication:' >> /etc/patroni/patroni.yml
	echo -e '    replication:' >> /etc/patroni/patroni.yml
	echo -e '      username: replicator' >> /etc/patroni/patroni.yml
	echo -e '      password: replicator' >> /etc/patroni/patroni.yml
	echo -e '    superuser:' >> /etc/patroni/patroni.yml
	echo -e '      username: postgres' >> /etc/patroni/patroni.yml
	echo -e '      password: postgres' >> /etc/patroni/patroni.yml
	echo -e '  parameters:' >> /etc/patroni/patroni.yml
	echo -e '    unix_socket_directories: "/var/run/postgresql"' >> /etc/patroni/patroni.yml
	echo -e '  pg_hba:' >> /etc/patroni/patroni.yml
	echo -e '    - host replication replicator '$serverSubnet' md5' >> /etc/patroni/patroni.yml
	echo -e '    - host replication replicator 127.0.0.1/32 trust' >> /etc/patroni/patroni.yml
	echo -e '    - host all all '$serverSubnet' md5' >> /etc/patroni/patroni.yml
	echo -e '    - host all all 0.0.0.0/0 md5' >> /etc/patroni/patroni.yml
	echo -e '    - local all postgres   md5' >> /etc/patroni/patroni.yml
	echo -e 'watchdog:' >> /etc/patroni/patroni.yml
	echo -e '  mode: off' >> /etc/patroni/patroni.yml
	echo -e '  device: /dev/watchdog' >> /etc/patroni/patroni.yml
	echo -e '  safety_margin: 5' >> /etc/patroni/patroni.yml
	echo -e 'tags:' >> /etc/patroni/patroni.yml
	echo -e '  nofailover: false' >> /etc/patroni/patroni.yml
	echo -e '  noloadbalance: false' >> /etc/patroni/patroni.yml
	echo -e '  clonefrom: false' >> /etc/patroni/patroni.yml
	echo -e '  nosync: false' >> /etc/patroni/patroni.yml
	systemctl enable patroni
	systemctl start patroni
	while [ "$(systemctl is-active patroni)" == "inactive" ]
		do
			if [ "$waitingTryCount" -ge "$waitingTryMax"]
			then
				echo "Service patroni not started started. Rolling back changes and stop script"
				rollback
				exit 1
			fi
			echo "Waiting 5s for patroni started"
			waitingTryCount=$((waitingTryCount+1))
		sleep 5
	done
	waitingTryCount=0
	echo "Waiting 15s for patroni started"
	sleep 15
	clusterLeaderData='>>>'$(patronictl -c /etc/patroni/patroni.yml list | awk ' /Leader/{print $2}')
	clusterLeaderArray=(${clusterLeaderData//>>>/ })
	clusterLeader=${clusterLeaderArray[0]}
	echo 'Current cluster leader is '$clusterLeader
	if [ $clusterLeader == $currentServerName ]
	then
		echo "[Configure DataBase for SENAT]"
		echo "I am LEADER of cluster"
		psql postgresql://postgres:postgres@localhost:5432 --no-align --quiet --tuples-only -c 'CREATE DATABASE senat;'
		psql postgresql://postgres:postgres@localhost:5432 --no-align --quiet --tuples-only -c "CREATE USER senat WITH PASSWORD 'senat';"
		psql postgresql://postgres:postgres@localhost:5432/senat --no-align --quiet --tuples-only -c 'GRANT ALL PRIVILEGES ON DATABASE senat TO senat;'
		psql postgresql://postgres:postgres@localhost:5432/senat --no-align --quiet --tuples-only -c 'CREATE SCHEMA reports;'
		psql postgresql://postgres:postgres@localhost:5432/senat --no-align --quiet --tuples-only -c 'ALTER DATABASE senat OWNER TO senat;'
		echo "[Configure DataBase for PGBOUNCER]"
		psql postgresql://postgres:postgres@localhost:5432/senat --no-align --quiet --tuples-only -c "CREATE ROLE pgbouncer WITH LOGIN ENCRYPTED PASSWORD 'senat';"
		psql postgresql://postgres:postgres@localhost:5432/senat --no-align --quiet --tuples-only -c "CREATE FUNCTION public.lookup (INOUT p_user name, OUT p_password text) RETURNS record LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS \$\$SELECT usename, passwd FROM pg_shadow WHERE usename = p_user \$\$;"
		pgbouncerPass=$(psql postgresql://postgres:postgres@localhost:5432 --no-align --quiet --tuples-only -c "SELECT passwd FROM pg_shadow WHERE usename='pgbouncer';")
		echo "Founded PgBouncer password hash "$pgbouncerPass	
	else
		echo "I am REPLICA of cluster. Waiting for replication"
		while [ "$pgbouncerPass" == "" ]
		do
			pgbouncerPass=$(psql postgresql://postgres:postgres@localhost:5432 --no-align --quiet --tuples-only -c "SELECT passwd FROM pg_shadow WHERE usename='pgbouncer';")
			echo "Replica not ready. Waiting 5s"
		sleep 5
		done
		echo "Founded PgBouncer password hash "$pgbouncerPass
	fi
	echo "[Configuring PGBOUNCER]"
	if [ ! -f /etc/pgbouncer/userlist.txt ]
	then
		echo "Create new pgbouncer userlist"
		touch /etc/pgbouncer/userlist.txt
	else
		echo "Backuping old pgbouncer userlist"
		mv /etc/pgbouncer/userlist.txt /etc/pgbouncer/userlist.txt_orig
		touch /etc/pgbouncer/userlist.txt
	fi
	echo -e '"PGBOUNCER" "'$pgbouncerPass'"' >> /etc/pgbouncer/userlist.txt
	if [ ! -f /etc/pgbouncer/pgbouncer.ini ]
	then
		echo "Create new pgbouncer.ini"
		touch /etc/pgbouncer/pgbouncer.ini
	else
		echo "Backuping old pgbouncer.ini"
		mv /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini_orig
		touch /etc/pgbouncer/pgbouncer.ini
	fi
	echo -e '[databases]' >> /etc/pgbouncer/pgbouncer.ini
	echo -e '* = host='$currentServerIp' port=5432 dbname=postgres' >> /etc/pgbouncer/pgbouncer.ini
	echo -e '[users]' >> /etc/pgbouncer/pgbouncer.ini
	echo -e '' >> /etc/pgbouncer/pgbouncer.ini
	echo -e '[pgbouncer]' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'logfile = /var/log/pgbouncer/pgbouncer.log' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'pidfile = /var/run/pgbouncer/pgbouncer.pid' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'listen_addr = *' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'listen_port = 6432' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'auth_type = md5' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'auth_file = /etc/pgbouncer/userlist.txt' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'auth_user = pgbouncer' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'auth_query = SELECT p_user, p_password FROM public.lookup(\$1)' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'admin_users = postgres' >> /etc/pgbouncer/pgbouncer.ini
	echo -e 'stats_users = stats, postgres' >> /etc/pgbouncer/pgbouncer.ini
	systemctl enable pgbouncer
	systemctl start pgbouncer
	while [ "$(systemctl is-active pgbouncer)" == "inactive" ]
		do
			if [ "$waitingTryCount" -ge "$waitingTryMax"]
			then
				echo "Service pgbouncer not started started. Stop script"
				exit 1
			fi
			echo "Waiting 5s for pgbouncer started"
			waitingTryCount=$((waitingTryCount+1))
		sleep 5
	done
	waitingTryCount=0
	if [ $enableHaproxy == "true" ]
	then
		echo "[Configuring HaProxy]"
		if [ ! -f /etc/haproxy/haproxy.cfg ]
		then
			echo "Create new haproxy config"
			touch /etc/haproxy/haproxy.cfg
		else
			echo "Backuping old haproxy config"
			mv /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg_orig
			touch /etc/haproxy/haproxy.cfg
		fi
		echo -e 'global' >> /etc/haproxy/haproxy.cfg
		echo -e '	log		127.0.0.1 local2' >> /etc/haproxy/haproxy.cfg
		echo -e '	chroot	/var/lib/haproxy' >> /etc/haproxy/haproxy.cfg
		echo -e '	pidfile	/var/run/haproxy.pid' >> /etc/haproxy/haproxy.cfg
		echo -e '	maxconn	10000' >> /etc/haproxy/haproxy.cfg
		echo -e '	user	haproxy' >> /etc/haproxy/haproxy.cfg
		echo -e '	group	haproxy' >> /etc/haproxy/haproxy.cfg
		echo -e '	daemon' >> /etc/haproxy/haproxy.cfg
		echo -e '	stats socket /var/lib/haproxy/stats' >> /etc/haproxy/haproxy.cfg	
		echo -e 'defaults' >> /etc/haproxy/haproxy.cfg
		echo -e '	mode			tcp' >> /etc/haproxy/haproxy.cfg
		echo -e '	log				global' >> /etc/haproxy/haproxy.cfg
		echo -e '	option			tcplog' >> /etc/haproxy/haproxy.cfg
		echo -e '	retries			3' >> /etc/haproxy/haproxy.cfg
		echo -e '	timeout queue	1m' >> /etc/haproxy/haproxy.cfg
		echo -e '	timeout connect	10s' >> /etc/haproxy/haproxy.cfg
		echo -e '	timeout client	1m' >> /etc/haproxy/haproxy.cfg
		echo -e '	timeout server	1m' >> /etc/haproxy/haproxy.cfg
		echo -e '	timeout check	10s' >> /etc/haproxy/haproxy.cfg
		echo -e '	maxconn			900' >> /etc/haproxy/haproxy.cfg	
		echo -e 'listen stats' >> /etc/haproxy/haproxy.cfg
		echo -e '	mode http' >> /etc/haproxy/haproxy.cfg
		echo -e '	bind *:7000' >> /etc/haproxy/haproxy.cfg
		echo -e '	stats enable' >> /etc/haproxy/haproxy.cfg
		echo -e '	stats uri /' >> /etc/haproxy/haproxy.cfg
		echo -e 'listen primary' >> /etc/haproxy/haproxy.cfg
		echo -e '	bind '$clusterSharedIp':5000' >> /etc/haproxy/haproxy.cfg
		echo -e '	option httpchk OPTIONS /master' >> /etc/haproxy/haproxy.cfg
		echo -e '	http-check expect status 200' >> /etc/haproxy/haproxy.cfg
		echo -e '	default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions' >> /etc/haproxy/haproxy.cfg
		echo -e '	server '${serverArray1[1]}' '${serverArray1[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
		echo -e '	server '${serverArray2[1]}' '${serverArray2[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
		echo -e '	server '${serverArray3[1]}' '${serverArray3[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg	
		echo -e 'listen standby' >> /etc/haproxy/haproxy.cfg
		echo -e '	bind '$clusterSharedIp':5001' >> /etc/haproxy/haproxy.cfg
		echo -e '	option httpchk OPTIONS /replica' >> /etc/haproxy/haproxy.cfg
		echo -e '	http-check expect status 200' >> /etc/haproxy/haproxy.cfg
		echo -e '	default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions' >> /etc/haproxy/haproxy.cfg
		echo -e '	server '${serverArray1[1]}' '${serverArray1[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
		echo -e '	server '${serverArray2[1]}' '${serverArray2[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
		echo -e '	server '${serverArray3[1]}' '${serverArray3[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
		systemctl enable haproxy
		systemctl start haproxy
		while [ "$(systemctl is-active haproxy)" == "inactive" ]
		do
			if [ "$waitingTryCount" -ge "$waitingTryMax"]
			then
				echo "Service haproxy not started started.Rollback changes and stop script"
				rollback
				exit 1
			fi
			echo "Waiting 5s for haproxy started"
			waitingTryCount=$((waitingTryCount+1))
		sleep 5
		done
		waitingTryCount=0
	fi
	echo "[Configuring sysctl.conf]"
	sed -i '/net.ipv4.ip_nonlocal_bind=1/d' /etc/sysctl.conf >> /dev/null
	sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf >> /dev/null
	echo -e 'net.ipv4.ip_nonlocal_bind=1' >> /etc/sysctl.conf
	echo -e 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
	sudo sysctl -p
fi