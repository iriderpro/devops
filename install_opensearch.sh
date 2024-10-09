#!/bin/bash
function rollback {
	systemctl stop opensearch
	systemctl disable opensearch
	systemctl stop opensearch-dashboards
	systemctl disable opensearch-dashboards
	if [ -f /etc/opensearch/opensearch.yml_orig ]
	then
		echo "Restoring old OpenSearch config"
		sudo rm /etc/opensearch/opensearch.yml
		mv /etc/opensearch/opensearch.yml_orig /etc/opensearch/opensearch.yml
	fi
}
echo "=============================="
echo "==INSTALL OPENSEARCH CLUSTER=="
echo "=============================="
if [ -f /etc/os-release ]
then
	. /etc/os-release
	OS=$ID
	VER=$VERSION_ID
fi
SystemInstaller=yum
echo 'Current OS: '$OS
setupEnable="true"
configureEnable="false"
configureRollback="false"
currentServerIp=""
currentServerName=""
clusterSharedIp=""
pgbouncerPass=""
waitingTryMax=10
waitingTryCount=0

if [ -n "$1" ] ||[ -n "$2" ] || [ -n "$3" ]
then
	currentServerNumber=$1
	serversList=$2
	serversArray=(${serversList//,/ })
	if [ ${#serversArray[@]} == "1" ]
	then
		serverData=(${serversList//:/ })
	else
		serverData=(${serversArray[$1]//:/ })
	fi
	currentServerIp=${serverData[0]}
	currentServerName=${serverData[1]}
	serverIpArray=(${currentServerIp//./ })
	serverSubnet=${serverIpArray[0]}'.'${serverIpArray[1]}'.'${serverIpArray[2]}'.1/24'
	serverIpArray=(${currentServerIp//./ })
	serverSubnet=${serverIpArray[0]}'.'${serverIpArray[1]}'.'${serverIpArray[2]}'.1/24'
	echo "Current server IP:" $currentServerIp
	echo "Current server name:" $currentServerName
	echo "Current server Subnet:" $serverSubnet
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
if [ -n "$3" ]
then
	case $3 in
	
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
	$SystemInstaller install -y wget
	$SystemInstaller install -y epel-release
	$SystemInstaller install -y yum-utils
	$SystemInstaller dnf -y install java-17-openjdk

fi
if [ $configureEnable == "true" ]
then
	echo "============================="
	echo "==START: CONFIGURE PACKAGES=="
	echo "============================="
	if [ -f /etc/opensearch/opensearch.yml ]
	then
		echo "Backup old OpenSearch config"
		cp /etc/opensearch/opensearch.yml /etc/opensearch/opensearch.yml_orig
	fi
	echo "Starting OpenSearch"
	systemctl start opensearch
	while [ "$(systemctl is-active opensearch)" == "inactive" ]
		do
			if [ "$waitingTryCount" -ge "$waitingTryMax"]
			then
				echo "Service opensearch not started started. Rollback changes and stop script"
				rollback
				exit 1
			fi
			echo "Waiting 5s for opensearch started"
			waitingTryCount=$((waitingTryCount+1))
		sleep 5
	done
	waitingTryCount=0
	echo "OpenSearch Init Security Config"
	/usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh -cd /etc/opensearch/opensearch-security -icl -nhnv -cacert /etc/opensearch/root-ca.pem -cert /etc/opensearch/kirk.pem -key /etc/opensearch/kirk-key.pem
	systemctl stop opensearch
	echo "[Configuring OpenSearch]"
	sed -i 's/#network.host: 192.168.0.1/network.host: 0.0.0.0/g' /etc/opensearch/opensearch.yml
	sed -i 's/#http.port: 9200/http.port: 9200/g' /etc/opensearch/opensearch.yml
	for i in ${!serversArray[@]}; do
	  serversListData=(${serversArray[$i]//:/ })
	  serversListArray=$serversListArray'"'${serversListData[1]}'",'
	done
	serversListArray=$(echo $serversListArray|sed 's/,\([^,]*\)$/ \1/')
	mainServerData=(${serversArray[0]//:/ })
	sed -i '/network.bind_host:/d' /etc/opensearch/opensearch.yml >> /dev/null
	sed -i '/network.host/i network.bind_host: '$currentServerIp /etc/opensearch/opensearch.yml
	serversCount=${#serversArray[@]}
	if [ $serversCount == "1" ]
	then
		echo "Configuring SingleNode Mode"
		sed -i '/discovery.type: single-node/d' /etc/opensearch/opensearch.yml >> /dev/null
		sed -i '/network.host/i discovery.type: single-node' /etc/opensearch/opensearch.yml
	else
		echo "Configuring MultiNode Mode"
		sed -i 's/#cluster.name: my-application/cluster.name: senat/g' /etc/opensearch/opensearch.yml
		sed -i 's/#node.name: node-1/node.name: '$currentServerName'/g' /etc/opensearch/opensearch.yml
		sed -i 's/#discovery.seed_hosts: \["host1", "host2"\]/discovery.seed_hosts: \['$serversListArray'\]/g' /etc/opensearch/opensearch.yml
		if [ $currentServerNumber == "1" ]
		then
			sed -i '/node.roles:/d' /etc/opensearch/opensearch.yml >> /dev/null
			sed -i '/node.name/i node.roles: \[ cluster_namager \]' /etc/opensearch/opensearch.yml
			sed -i 's/#cluster.initial_cluster_manager_nodes: \["node-1", "node-2"\]/cluster.initial_cluster_manager_nodes: \["'$currentServerName'"\]/g' /etc/opensearch/opensearch.yml
			
		else
			sed -i '/node.name/i node.roles: \[ data , ingest \]' /etc/opensearch/opensearch.yml
			sed -i 's/#cluster.initial_cluster_manager_nodes: \["node-1", "node-2"\]/cluster.initial_cluster_manager_nodes: \["'${mainServerData[1]}'"\]/g' /etc/opensearch/opensearch.yml
		fi
	fi
	echo "Starting OpenSearch"
	systemctl start opensearch
	while [ "$(systemctl is-active opensearch)" == "inactive" ]
		do
			if [ "$waitingTryCount" -ge "$waitingTryMax"]
			then
				echo "Service opensearch not started started. Rollback changes and stop script"
				rollback
				exit 1
			fi
			echo "Waiting 5s for opensearch started"
			waitingTryCount=$((waitingTryCount+1))
		sleep 5
	done
	waitingTryCount=0
	echo "Enabling autostart for OpenSearch"
	systemctl enable opensearch
	echo "Tuning OpenSearch"
	curl -X PUT https://$currentServerIp:9200/_cluster/settings -H "Content-Type: application/json" -d '{ "persistent": { "cluster.max_shards_per_node": "50000" } }' -u 'admin:admin' --insecure
	curl -X PUT https://$currentServerIp:9200/_cluster/settings -H "Content-Type: application/json" -d '{ "persistent": { "compatibility": {"override_main_response_version": true } } }' -u 'admin:admin' --insecure
	curl -X PUT https://snt-log.msk.novatek.int:9200/_ingest/pipeline/attachment -H "Content-Type: application/json" -d '{ "description": "Extract attachment information", "processors": [{"attachment":{"field":"data","target_field":"attachment","indexed_chars": -1},"remove":{"field":"data"}}]}' -u 'admin:admin' --insecure
	if [ $currentServerNumber == "1" ]
	then
		echo "Configuring Opensearch Dashboards"
		if [ -f /etc/opensearch-dashboards/opensearch_dashboards.yml ]
		then
			echo "Backup old OpenSearch config"
			mv /etc/opensearch-dashboards/opensearch_dashboards.yml /etc/opensearch-dashboards/opensearch_dashboards.yml_orig
		fi
		touch /etc/opensearch-dashboards/opensearch_dashboards.yml
		
		echo -e 'server.host: '$currentServerIp >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'server.ssl.enabled: false' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		#echo -e 'server.ssl.certificate: /etc/opensearch-dashboards/esnode.pem' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		#echo -e 'server.ssl.key: /etc/opensearch-dashboards/esnode-key.pem' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		#echo -e 'opensearch.ssl.certificateAuthorities: [ "/etc/opensearch-dashboards/root-ca.pem" ]' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch.hosts: [https://'$currentServerIp':9200]' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch.ssl.verificationMode: none' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch.username: admin' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch.password: admin' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch.requestHeadersWhitelist: [authorization, securitytenant]' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch_security.multitenancy.enabled: true' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch_security.multitenancy.tenants.preferred: [Private, Global]' >> /etc/opensearch-dashboards/opensearch_dashboards.yml
		echo -e 'opensearch_security.readonly_mode.roles: [kibana_read_only]' >> /etc/opensearch-dashboards/opensearch_dashboards.yml

		echo "Starting OpenSearch Dashboards"
		systemctl start opensearch-dashboards
		while [ "$(systemctl is-active opensearch-dashboards)" == "inactive" ]
			do
				if [ "$waitingTryCount" -ge "$waitingTryMax" ]
				then
					echo "Service opensearch-dashboards not started started. Rollback changes and stop script"
					rollback
					exit 1
				fi
				echo "Waiting 5s for opensearch-dashboards started"
				waitingTryCount=$((waitingTryCount+1))
			sleep 5
		done
		waitingTryCount=0
		echo "Enabling autostart for opensearch-dashboards"
		systemctl enable opensearch-dashboards
	fi
	echo "============================="
	echo "==FINISH:CONFIGURE PACKAGES=="
	echo "============================="
fi
