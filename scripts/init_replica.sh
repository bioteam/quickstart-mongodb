#!/bin/bash

#################################################################
# Update the OS, install packages, initialize environment vars,
# and get the instance tags
#################################################################
yum -y update
yum install -y jq
yum install -y xfsprogs

source ./orchestrator.sh -i
source ./config.sh

tags=`aws ec2 describe-tags --filters "Name=resource-id,Values=${AWS_INSTANCEID}"`

#################################################################
#  gatValue() - Read a value from the instance tags
#################################################################
getValue() {
    index=`echo $tags | jq '.[]' | jq '.[] | .Key == "'$1'"' | grep -n true | sed s/:.*//g | tr -d '\n'`
    (( index-- ))
    filter=".[$index]"
    result=`echo $tags | jq '.[]' | jq $filter.Value | sed s/\"//g | sed s/Primary.*/Primary/g | tr -d '\n'`
    echo $result
}

##version=`getValue MongoDBVersion`

# MongoDBVersion set inside config.sh
version=${MongoDBVersion}

if [ -z "$version" ] ; then
  version="5.0"
fi

if [ "$version" == "4.0" ] || [ "$version" == "4.2" ] || [ "$version" == "5.0" ];
then
echo "[mongodb-org-${version}]
name=MongoDB Repository
baseurl=http://repo.mongodb.org/yum/amazon/2/mongodb-org/${version}/x86_64/
gpgcheck=0
enabled=1" > /etc/yum.repos.d/mongodb-org-${version}.repo
else
echo "[mongodb-org-${version}]
name=MongoDB Repository
baseurl=http://repo.mongodb.org/yum/amazon/2013.03/mongodb-org/${version}/x86_64/
gpgcheck=0
enabled=1" > /etc/yum.repos.d/mongodb-org-${version}.repo
fi

# To be safe, wait a bit for flush
sleep 5

amazon-linux-extras install epel

yum --enablerepo=epel install node npm -y

yum install -y libcgroup libcgroup-tools sysstat munin-node

#################################################################
#  Figure out what kind of node we are and set some values
#################################################################
NODE_TYPE=`getValue Name`
IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
IS_CONFIG_NODE=`getValue IsConfigNode`
IS_SHARD_NODE=`getValue IsShardNode`
IS_MONGOS_NODE=`getValue IsMongosNode`
CONFIG_NODES=`getValue ClusterConfigReplicaSetCount`
SHARD_NODES=`getValue ClusterShardReplicaSetCount`
MONGO_NODES=`getValue ClusterMongosReplicaSetCount`
SHARD=`getValue ReplicaShardIndex`

if [ "${IS_MONGOS_NODE}" == "false" ]; then
    yum install -y mongodb-org mongodb-org-server mongodb-org-tools
    yum install -y mongo-10gen-server
else
    yum install -y mongodb-org-mongos mongodb-org-tools mongodb-mongosh
fi

if [ "${IS_SHARD_NODE}" == "true" ]; then
    SHARD=s${SHARD}
fi

if [ "$IS_CONFIG_NODE" == "true" ]; then
    port=27019
    NODES=${CONFIG_NODES}
elif [ "$IS_SHARD_NODE" == "true" ]; then
    port=27018
    NODES=${SHARD_NODES}
elif [ "$IS_MONGOS_NODE" == "true" ]; then
    port=27017
    NODES=${MONGO_NODES}
fi

#  Do NOT use timestamps here!!
# This has to be unique across multiple runs!
UNIQUE_NAME=MONGODB_${TABLE_NAMETAG}_${VPC}

#################################################################
#  Wait for all the nodes to synchronize so we have all IP addrs
#################################################################
if [ "${IS_MONGOS_NODE}" == "false" ]; then
    if [[ "${NODE_TYPE}" == *Primary ]]; then
        ./orchestrator.sh -c -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -s "WORKING" -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -w "WORKING=${NODES}" -n "${SHARD}_${UNIQUE_NAME}"
        IPADDRS=$(./orchestrator.sh -g -n "${SHARD}_${UNIQUE_NAME}")
        read -a IPADDRS <<< $IPADDRS
    else
        ./orchestrator.sh -b -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -w "WORKING=1" -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -s "WORKING" -n "${SHARD}_${UNIQUE_NAME}"
        NODE_TYPE="Secondary"
        ./orchestrator.sh -w "WORKING=${NODES}" -n "${SHARD}_${UNIQUE_NAME}"
    fi
else
    if [[ "${NODE_TYPE}" == *Primary ]]; then
        ./orchestrator.sh -c -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -s "WORKING" -n "${SHARD}_${UNIQUE_NAME}"
    else
        ./orchestrator.sh -b -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -w "WORKING=1" -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -s "WORKING" -n "${SHARD}_${UNIQUE_NAME}"
        NODE_TYPE="Secondary"
    fi
    #################################################################
    # Mongos Type servers need to wait for the config servers to be secured
    #################################################################
    ./orchestrator.sh -w "SECURED=${CONFIG_NODES}" -n "config_${UNIQUE_NAME}"
    CONFIG_IPADDRS=$(./orchestrator.sh -g -n "config_${UNIQUE_NAME}")
    read -a CONFIG_IPADDRS <<< $CONFIG_IPADDRS
fi

#################################################################
# Make filesystems, set ulimits and block read ahead on ALL nodes
#################################################################
# TODO: This is probably not needed for mongos type nodes
mkfs.xfs -f /dev/xvdf
echo "/dev/xvdf /data xfs defaults,auto,noatime,noexec 0 0" | tee -a /etc/fstab
mkdir -p /data
mount /data
chown -R mongod:mongod /data
blockdev --setra 32 /dev/xvdf
rm -rf /etc/udev/rules.d/85-ebs.rules
touch /etc/udev/rules.d/85-ebs.rules
echo 'ACTION=="add", KERNEL=="'$1'", ATTR{bdi/read_ahead_kb}="16"' | tee -a /etc/udev/rules.d/85-ebs.rules
echo "* soft nofile 64000
* hard nofile 64000
* soft nproc 32000
* hard nproc 32000" > /etc/limits.conf
#################################################################
# End All Nodes
#################################################################

#################################################################
# Listen to all interfaces, not just local
#################################################################

enable_all_listen() {
  for f in /etc/mongo*.conf
  do
    sed -e '/bindIp/s/^/#/g' -i ${f}
    sed -e '/bind_ip/s/^/#/g' -i ${f}
    echo " Set listen to all interfaces : ${f}"
  done
}

check_primary() {
    expected_state=$1
    master_substr=ismaster:\ ${expected_state}
    while true; do
      check_master=$( mongosh --port ${port} --eval "printjson(db.isMaster())" )
      log "${check_master}..."
      if [[ $check_master == *"$master_substr"* ]]; then
        log "Node is in desired state, proceed with security setup"
        break
      else
        log "Wait for node to become primary"
        sleep 10
      fi
    done
}

setup_security_common() {
    DDB_TABLE=$1
    auth_key=$(./orchestrator.sh -f -n $DDB_TABLE)
    echo $auth_key > /mongo_auth/mongodb.key
    chmod 400 /mongo_auth/mongodb.key
    chown -R mongod:mongod /mongo_auth
    if [ "${IS_MONGOS_NODE}" == "false" ]; then
        sed $'s/processManagement:/security: \\\n  authorization: enabled \\\n  keyFile: \/mongo_auth\/mongodb.key \\\n\\\n&/g' /etc/mongod.conf >> /tmp/mongod_sec.txt
        mv /tmp/mongod_sec.txt /etc/mongod.conf
    else
        sed $'s/processManagement:/security: \\\n  keyFile: \/mongo_auth\/mongodb.key \\\n\\\n&/g' /etc/mongos.conf >> /tmp/mongos_sec.txt
        mv /tmp/mongos_sec.txt /etc/mongos.conf
    fi
}

# Only called by the primary replica of the Config replica set
setup_security_config_primary() {
    DDB_TABLE=$1
    MONGO_PASSWORD=$( cat /tmp/mongo_pass.txt )

    mongosh --port ${port} << EOF
use admin;
db.createUser(
  {
    user: "${MONGODB_ADMIN_USER}",
    pwd: "${MONGO_PASSWORD}",
    roles: [ { role: "root", db: "admin" } ]
  }
);
EOF
    systemctl stop mongod
    ./orchestrator.sh -k -n $DDB_TABLE
}

setup_security_primary() {
    CONFIG_DDB_TABLE=$1
    REPL_SET_DDB_TABLE=$2
    systemctl stop mongod
    setup_security_common ${CONFIG_DDB_TABLE}
    sleep 5
    systemctl start mongod
    sleep 10
    ./orchestrator.sh -s "SECURED" -n ${REPL_SET_DDB_TABLE}
}

#################################################################
# Setup MongoDB servers and config nodes
#################################################################
#mkdir /var/run/mongod
#chown mongod:mongod /var/run/mongod
if [ "${IS_MONGOS_NODE}" == "false" ]; then
    echo "sharding:" > mongod.conf
    if [ "$IS_CONFIG_NODE" == "true" ]; then
        echo "  clusterRole: configsvr" >> mongod.conf
    elif [ "$IS_SHARD_NODE" == "true" ]; then
        echo "  clusterRole: shardsvr" >> mongod.conf
    fi

    echo "net:" >> mongod.conf
    echo "  port:" >> mongod.conf
    if [ "$version" == "3.6" ] || [ "$version" == "4.0" ] || [ "$version" == "4.2" ] || [ "$version" == "5.0" ]; then
        echo "  bindIpAll: true" >> mongod.conf
    fi
    echo "" >> mongod.conf
    echo "systemLog:" >> mongod.conf
    echo "  destination: file" >> mongod.conf
    echo "  logAppend: true" >> mongod.conf
    echo "  path: /log/mongod.log" >> mongod.conf
    echo "" >> mongod.conf
    echo "storage:" >> mongod.conf
    echo "  dbPath: /data" >> mongod.conf
    echo "  journal:" >> mongod.conf
    echo "    enabled: true" >> mongod.conf
    echo "" >> mongod.conf
    echo "processManagement:" >> mongod.conf
    echo "  fork: true" >> mongod.conf
    echo "  pidFilePath: /var/run/mongodb/mongod.pid" >> mongod.conf
else
    echo "sharding:" > mongos.conf
    conf="configDB: config/"
    for addr in "${CONFIG_IPADDRS[@]}"
    do
        conf="${conf}${addr}:27019,"
    done
    conf=${conf::-1}
    echo "Configuring mongos with: ${conf}"
    echo "  ${conf}" >> mongos.conf
    echo "net:" >> mongos.conf
    echo "  port:" >> mongos.conf
    if [ "$version" == "3.6" ] || [ "$version" == "4.0" ] || [ "$version" == "4.2" ] || [ "$version" == "5.0" ]; then
        echo "  bindIpAll: true" >> mongos.conf
    fi
    echo "" >> mongos.conf
    echo "systemLog:" >> mongos.conf
    echo "  destination: file" >> mongos.conf
    echo "  logAppend: true" >> mongos.conf
    echo "  path: /log/mongos.log" >> mongos.conf
    echo "processManagement:" >> mongos.conf
    echo "  fork: true" >> mongos.conf
    echo "  pidFilePath: /var/run/mongodb/mongos.pid" >> mongos.conf
fi

#################################################################
#  Enable munin plugins for iostat and iostat_ios
#################################################################
ln -s /usr/share/munin/plugins/iostat /etc/munin/plugins/iostat
ln -s /usr/share/munin/plugins/iostat_ios /etc/munin/plugins/iostat_ios
touch /var/lib/munin/plugin-state/iostat-ios.state
chown munin:munin /var/lib/munin/plugin-state/iostat-ios.state

#################################################################
# Make the filesystems, add persistent mounts
#################################################################
mkfs.xfs -f /dev/xvdg
mkfs.xfs -f /dev/xvdh

echo "/dev/xvdg /journal xfs defaults,auto,noatime,noexec 0 0" | tee -a /etc/fstab
echo "/dev/xvdh /log xfs defaults,auto,noatime,noexec 0 0" | tee -a /etc/fstab

#################################################################
# Make directories for data, journal, and logs
#################################################################
mkdir -p /journal
mount /journal

#################################################################
#  Figure out how much RAM we have and how to slice it up
#################################################################
memory=$(vmstat -s | grep "total memory" | sed -e 's/ total.*//g' | sed -e 's/[ ]//g' | tr -d '\n')
memory=$(printf %.0f $(echo "${memory} / 1024 / 1 * .9 / 1024" | bc))

if [ ${memory} -lt 1 ]; then
    memory=1
fi

#################################################################
#  Make data directories and add symbolic links for journal files
#################################################################

mkdir -p /data/
mkdir -p /journal/

  # Add links for journal to data directory
ln -s /journal/ /data/journal

mkdir -p /log
mount /log

#################################################################
# Change permissions to the directories
#################################################################
chown -R mongod:mongod /journal
chown -R mongod:mongod /log
chown -R mongod:mongod /data

#################################################################
# Clone the mongod config file and create cgroups for mongod
#################################################################
c=0
if [ ${IS_MONGOS_NODE} == "false" ]; then
    cp mongod.conf /etc/mongod.conf
    sed -i "s/.*port:.*/  port: ${port}/g" /etc/mongod.conf
    echo "replication:" >> /etc/mongod.conf
    echo "  replSetName: ${SHARD}" >> /etc/mongod.conf
else
    cp mongos.conf /etc/mongos.conf
    sed -i "s/.*port:.*/  port: ${port}/g" /etc/mongos.conf
fi

echo CGROUP_DAEMON="memory:mongod" > /etc/sysconfig/mongod

echo "group mongod {
    perm {
      admin {
        uid = mongod;
        gid = mongod;
      }
      task {
        uid = mongod;
        gid = mongod;
      }
    }
    memory {
      memory.limit_in_bytes = ${memory}G;
      }
  }" > /etc/cgconfig.conf


#################################################################
#  Start cgconfig, munin-node, and all mongod processes
#################################################################
systemctl enable cgconfig
systemctl start cgconfig

systemctl enable munin-node
systemctl start munin-node

if [ "${IS_MONGOS_NODE}" == "false" ]; then
    systemctl enable mongod
    if [ "$version" == "3.2" ] || [ "$version" == "3.4" ]; then
        enable_all_listen
    fi
    systemctl start mongod
fi

#################################################################
#  Primaries initiate replica sets
#################################################################
if [[ "$IS_MONGOS_NODE" == "false" ]]; then
    if [[ "$NODE_TYPE" == *Primary ]]; then

        #################################################################
        # Wait unitil all the hosts for the replica set are responding
        #################################################################
        for addr in "${IPADDRS[@]}"
        do
            addr="${addr%\"}"
            addr="${addr#\"}"

            echo ${addr}:${port}
            while [ true ]; do

                echo "mongosh --host ${addr} --port ${port}"

    mongosh --host ${addr} --port ${port} << EOF
use admin
EOF

                if [ $? -eq 0 ]; then
                    break
                fi
                sleep 5
            done
        done

        #################################################################
        # Configure the replica sets, set this host as Primary with
        # highest priority
        #################################################################
        if [ "${NODES}" == "3" ]; then
            conf="{\"_id\" : \"${SHARD}\", \"version\" : 1, \"members\" : ["
            node=1
            for addr in "${IPADDRS[@]}"
            do
                addr="${addr%\"}"
                addr="${addr#\"}"

                priority=5
                if [ "${addr}" == "${IP}" ]; then
                    priority=10
                fi
                conf="${conf}{\"_id\" : ${node}, \"host\" :\"${addr}:${port}\", \"priority\":${priority}}"

                if [ $node -lt ${NODES} ]; then
                    conf=${conf}","
                fi

                (( node++ ))
            done

            conf=${conf}"]}"
            echo "Initiliazing MongoDb with conf: ${conf}"

    mongosh --port ${port} << EOF
rs.initiate(${conf})
EOF

            if [ $? -ne 0 ]; then
                # Houston, we've had a problem here...
                ./signalFinalStatus.sh 1
            fi
        else

            priority=10
            conf="{\"_id\" : \"${SHARD}\", \"version\" : 1, \"members\" : ["
            conf="${conf}{\"_id\" : 1, \"host\" :\"${IP}:${port}\", \"priority\":${priority}}"
            conf=${conf}"]}"
            echo "Initiliazing MongoDb with conf: ${conf}"

    mongosh --port ${port} << EOF
rs.initiate(${conf})
EOF

        fi

        #################################################################
        #  Update status to FINISHED, if this is s0 then wait on the rest
        #  of the nodes to finish and remove orchestration tables
        #################################################################
        ./orchestrator.sh -s "FINISHED" -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -w "FINISHED=${NODES}" -n "${SHARD}_${UNIQUE_NAME}"

        echo "Setting up security, bootstrap table: " "${SHARD}_${UNIQUE_NAME}"
        # wait for mongo to become primary
        sleep 10
        check_primary true

        if [ ${IS_CONFIG_NODE} == "true" ]; then # The auth_key is only created by the Primary Config Node
            setup_security_config_primary "config_${UNIQUE_NAME}"
        fi
        setup_security_primary "config_${UNIQUE_NAME}" "${SHARD}_${UNIQUE_NAME}"

        ./orchestrator.sh -w "SECURED=${NODES}" -n "${SHARD}_${UNIQUE_NAME}"
        # Mongo servers need this table to know the IPs of the Config Servers
        #./orchestrator.sh -d -n "${SHARD}_${UNIQUE_NAME}"
        rm /tmp/mongo_pass.txt
    else
        #################################################################
        #  Update status of Secondary to FINISHED
        #################################################################
        ./orchestrator.sh -s "FINISHED" -n "${SHARD}_${UNIQUE_NAME}"
        ./orchestrator.sh -w "FINISHED=${NODES}" -n "${SHARD}_${UNIQUE_NAME}"

        ./orchestrator.sh -w "SECURED=1" -n "${SHARD}_${UNIQUE_NAME}"
        systemctl stop mongod
        setup_security_common "config_${UNIQUE_NAME}"
        systemctl start mongod
        ./orchestrator.sh -s "SECURED" -n "${SHARD}_${UNIQUE_NAME}"
        rm /tmp/mongo_pass.txt
    fi
else
    systemctl daemon-reload
    systemctl enable mongos
    setup_security_common "config_${UNIQUE_NAME}"
    systemctl start mongos
    ./orchestrator.sh -s "SECURED" -n "${SHARD}_${UNIQUE_NAME}"
    rm /tmp/mongo_pass.txt
fi
# TBD - Add custom CloudWatch Metrics for MongoDB

# exit with 0 for SUCCESS
exit 0
