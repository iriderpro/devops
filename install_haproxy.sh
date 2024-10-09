#!/bin/bash
function rollback {
	systemctl stop haproxy
	systemctl disable haproxy
	if [ -f /etc/haproxy/haproxy.cfg_orig ]
	then
		echo "Restoring old Haproxy config"
		sudo rm /etc/haproxy/haproxy.cfg
		mv /etc/haproxy/haproxy.cfg_orig /etc/haproxy/haproxy.cfg
	fi
}
echo "=============================="
echo "====INSTALL HAPROXY SCRIPT===="
echo "=============================="
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
if [ -n "$1" ] ||[ -n "$2" ]
then
	serversList=$1
	serversArray=(${serversList//,/ })
	echo "Server configuring enabled"
	echo "[Configuring HOSTS file]"
	echo "Deleting old data from hosts"
	for i in ${!serversArray[@]}; do
	  serversListData=(${serversArray[$i]//:/ })
	  sed -i '/'${serversListData[0]}'/d' /etc/hosts >> /dev/null
	  echo -e ${serversListData[0]}'	'${serversListData[1]} >> /etc/hosts
	done
	configureEnable="true"
else
	configureEnable="false"
	setupEnable="false"
	configureRollback="false"
fi
if [ -n "$2" ]
then
	case $2 in
	
		"configonly")
			if [ $configureEnable == "true" ]
			then
				echo "Start with configure only"
				setupEnable="false"
				configureEnable="true"
			fi
		;;

		"installonly")
			echo "Start with install only"
			setupEnable="true"
			configureEnable="false"
		;;

		"rollback")
			echo "Start rollback only"
			setupEnable="false"
			configureEnable="false"
			configureRollback="true"
			rollback
		;;

		*)
			echo "No additional parameters"
		;;
	esac
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
	dnf install -y wget
	dnf install -y epel-release
	dnf install -y yum-utils
	dnf install -y haproxy
	echo "============================="
	echo "===FINISH:INSTALL PACKAGES==="
	echo "============================="
fi
if [ $configureEnable == "true" ]
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
	echo -e '	bind *:5000' >> /etc/haproxy/haproxy.cfg
	echo -e '	option httpchk OPTIONS /master' >> /etc/haproxy/haproxy.cfg
	echo -e '	http-check expect status 200' >> /etc/haproxy/haproxy.cfg
	echo -e '	default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions' >> /etc/haproxy/haproxy.cfg
	for i in ${!serversArray[@]}; do
	  serversListData=(${serversArray[$i]//:/ })
	  echo -e '	server '${serversListData[1]}' '${serversListData[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
	done
	echo -e 'listen standby' >> /etc/haproxy/haproxy.cfg
	echo -e '	bind *:5001' >> /etc/haproxy/haproxy.cfg
	echo -e '	option httpchk OPTIONS /replica' >> /etc/haproxy/haproxy.cfg
	echo -e '	http-check expect status 200' >> /etc/haproxy/haproxy.cfg
	echo -e '	default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions' >> /etc/haproxy/haproxy.cfg
	for i in ${!serversArray[@]}; do
	  serversListData=(${serversArray[$i]//:/ })
	  echo -e '	server '${serversListData[1]}' '${serversListData[0]}':6432 maxconn 100 check port 8008' >> /etc/haproxy/haproxy.cfg
	done
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
	echo "============================="
	echo "==FINISH:CONFIGURE PACKAGES=="
	echo "============================="
fi
