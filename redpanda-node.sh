#!/bin/bash

set -ex

yum update -y
yum install -y jq
wget -qO /bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
chmod +x /bin/yq

BOOTSTRAP_URL=${BOOTSTRAP_URL}

INSTANCE_ID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/region`

GENERAL_INFO='{"statusCode":404}'
while [ `echo $GENERAL_INFO | jq -r '.statusCode'` = 404 ]; do
  sleep 10
  GENERAL_INFO=`curl -s $BOOTSTRAP_URL/general-info`
done
CLUSTER_ID=`echo $GENERAL_INFO | jq -r '.clusterId'`
DOMAIN=`echo $GENERAL_INFO | jq -r '.domain'`
HOSTNAMES=`echo $GENERAL_INFO | jq -r '.hostnames'`
ORGANIZATION=`echo $GENERAL_INFO | jq -r '.organization'`
MOUNT_DIR=`echo $GENERAL_INFO | jq -r '.mountDir'`

# TODO this loop could be improved to not always sleep the initial run
INSTANCE_INFO='{"statusCode":404}'
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
until [ "`dig +short $HOSTNAME.$DOMAIN`" = "$EIP" ]; do
  sleep 10
done
# TODO update internal DNS entry?

# set instance name
sudo -u ec2-user aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=Name,Value=$CLUSTER_ID-$HOSTNAME"

# TODO register with load balancer
# this may be done automatically due to elastic IP and/or route53

# TODO replace broker list with load balancer URL
for HOST in $HOSTNAMES; do
  BROKERS="$BROKERS$HOST.$DOMAIN,"
done
BROKERS=`echo $${BROKERS::-1}`

# attach EBS volume
sudo -u ec2-user aws ec2 attach-volume --volume-id $VOLUME_ID --instance-id $INSTANCE_ID --device /dev/xvdb
# wait until volume status is ok
until [ `sudo -u ec2-user aws ec2 describe-volume-status --volume-ids $VOLUME_ID | jq -r '.VolumeStatuses[].VolumeStatus.Status'` = ok ]; do
  sleep 10
done
sleep 5 # TODO volume still not mountable immediately after ok status
# create mount directory
mkdir -p $MOUNT_DIR

# determine if volume contents is empty or populated
if [ "`file -s /dev/xvdb`" = "/dev/xvdb: data" ]; then
  # empty
  mkfs.xfs /dev/xvdb
  mount /dev/xvdb $MOUNT_DIR
  mkdir $MOUNT_DIR/{config,data}
  NODE_ID=`curl -s http://169.254.169.254/latest/meta-data/ami-launch-index`
  NEW=1
else
  # populated
  mount /dev/xvdb $MOUNT_DIR
  NODE_ID=`cat $MOUNT_DIR/config/redpanda.yaml | yq '.redpanda.node_id'`
  NEW=0
fi

# link redpanda data and config directories to volume
ln -s $MOUNT_DIR/config /etc/redpanda
ln -s $MOUNT_DIR/data /var/lib/redpanda

# install redpanda
curl -1sLf https://packages.vectorized.io/sMIXnoa7DK12JW4A/redpanda/cfg/setup/bash.rpm.sh | sudo -E bash
yum install -y redpanda

# ensure redpanda user is owner of all related files/directories
find /etc/redpanda/ /var/lib/redpanda/ $MOUNT_DIR/ -name '*' | xargs -d '\n' chown redpanda:redpanda

# configure redpanda
INTERNAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
if [ $NODE_ID -eq 0 ] && [ $NEW -eq 1 ]; then
  sudo -u redpanda rpk redpanda config bootstrap --id $NODE_ID --self $INTERNAL_IP
else
  # TODO use load balancer IP for ips flag
  sudo -u redpanda rpk redpanda config bootstrap --id $NODE_ID --self $INTERNAL_IP --ips $BROKERS
fi
sudo -u redpanda rpk redpanda config set cluster_id $CLUSTER_ID
sudo -u redpanda rpk redpanda config set organization $ORGANIZATION
sudo -u redpanda rpk redpanda config set redpanda.advertised_kafka_api "[{address: $HOSTNAME.$DOMAIN, port: 9092}]"
sudo -u redpanda rpk redpanda config set redpanda.advertised_rpc_api "{address: $HOSTNAME.$DOMAIN, port: 33145}"

# restart redpanda
systemctl restart redpanda

# if leader, set seed_servers
if [ $NODE_ID -eq 0 ]; then
  # TODO use load balancer IP for ips flag
  sudo -u redpanda rpk redpanda config bootstrap --id $NODE_ID --self $INTERNAL_IP --ips $BROKERS
fi
