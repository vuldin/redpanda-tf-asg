#!/bin/bash

set -ex

yum update -y
yum install -y jq

BOOTSTRAP_URL=${BOOTSTRAP_URL}

INSTANCE_ID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/region`

GENERAL_INFO=`curl -s $BOOTSTRAP_URL/general-info`
while [ `echo $GENERAL_INFO | jq -r '.statusCode'` = 404 ]; do
  sleep 10
  GENERAL_INFO=`curl -s $BOOTSTRAP_URL/general-info`
done
CLUSTER_ID=`echo $GENERAL_INFO | jq -r '.clusterId'`
DOMAIN=`echo $GENERAL_INFO | jq -r '.domain'`
HOSTNAMES=(`echo $GENERAL_INFO | jq -r '.hostnames'`)
ORGANIZATION=`echo $GENERAL_INFO | jq -r '.organization'`
MOUNT_DIR=`echo $GENERAL_INFO | jq -r '.mountDir'`

INSTANCE_INFO=`curl -s "$BOOTSTRAP_URL/node-info?instance_id=$INSTANCE_ID"`
while [ `echo $INSTANCE_INFO | jq -r '.statusCode'` = 404 ]; do
  sleep 10
  INSTANCE_INFO=`curl -s "$BOOTSTRAP_URL/node-info?instance_id=$INSTANCE_ID"`
done
VOLUME_ID=`echo $INSTANCE_INFO | jq -r '.volumeId'`
HOSTNAME=`echo $INSTANCE_INFO | jq -r '.hostname'`
EIP=`echo $INSTANCE_INFO | jq -r '.eip'`

sudo -u ec2-user aws configure set region $REGION

# update DNS
sudo -u ec2-user aws ec2 associate-address --instance-id "$INSTANCE_ID" --public-ip $EIP

# set instance name
CURRENT_TAG=`sudo -u ec2-user aws ec2 --region $REGION describe-tags | jq '.Tags[]' | jq 'select(.ResourceId == "i-0e1271fbbebe2220c" and .Key == "Name")' | jq -r '.Value'`
sudo -u ec2-user aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=Name,Value=$CURRENT_TAG-$HOSTNAME"

# TODO register with load balancer
# this may be done automatically due to elastic IP and/or route53

# TODO replace broker list with load balancer URL
#unset BROKERS
#for HOST in $HOSTNAMES; do
#  BROKERS="$BROKERS $HOST.$DOMAIN"
#done
#BROKERS=`echo $BROKERS | xargs`

# attach EBS volume
sudo -u ec2-user aws ec2 attach-volume --volume-id $VOLUME_ID --instance-id $INSTANCE_ID --device /dev/xvdb

# TODO mount volume
mkdir -p /local/apps/redpanda

# TODO read files to determine if new or replacing previous instance
#IS_NEW_VOLUME=0
#if [ `sudo file -s /dev/xvdf` = "/dev/xvdf: data" ]; then
#  IS_NEW_VOLUME=1
#fi

# TODO determine leadership
# The broker ID and the array index in each HOSTS array
# If replacing a node, you will want to hard-code this value to the same node_id as the broker being replaced.
#INDEX=`curl -s http://169.254.169.254/latest/meta-data/ami-launch-index`

# install redpanda
#curl -1sLf https://packages.vectorized.io/sMIXnoa7DK12JW4A/redpanda/cfg/setup/bash.rpm.sh | sudo -E bash
#yum install -y redpanda

# TODO update DNS
#INTERNAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
#EXTERNAL_IP=`wget -q -O - http://169.254.169.254/latest/meta-data/public-ipv4`

# TODO configure redpanda
# if [ $INDEX -eq 0 ]; then
  # sudo -u redpanda rpk redpanda config bootstrap --id $INDEX --self $INTERNAL_IP
# else
  # sudo -u redpanda rpk redpanda config bootstrap --id $INDEX --self $INTERNAL_IP --ips $OTHER_BROKERS_JOINED%,
# fi
# sudo -u redpanda rpk redpanda config set cluster_id $CLUSTER_ID
# sudo -u redpanda rpk redpanda config set organization $ORGANIZATION
# sudo -u redpanda rpk redpanda config set redpanda.advertised_kafka_api "[{address: $EXTERNAL_HOSTS[$INDEX],port: 9092}]"
# sudo -u redpanda rpk redpanda config set redpanda.advertised_rpc_api "{address: $INTERNAL_HOSTS[$INDEX],port: 33145}"

# restart redpanda
#systemctl restart redpanda

# TODO if leader, set seed_servers
# if [ $INDEX -eq 0 ]; then
  # sudo -u redpanda rpk redpanda config bootstrap --id $INDEX --self $INTERNAL_IP --ips $OTHER_BROKERS_JOINED%,
# fi



# sleep later instances in a launch to help ensure bootstrap state updates are isolated
#sleep $((4*$INDEX))
