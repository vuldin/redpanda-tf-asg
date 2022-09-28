#!/bin/bash

set -ex

# tasks:
# - call bootstrap service to find node and EBS volume for this instance, and determine if node is new or old
#   - new: node has never been attached to an instance, and EBS volume is blank
#   - old: node was attached a destroyed instance, and EBS volume has data
# - attach to this node's EBS volume
# - update this node's route53 DNS record

# questions:
# - if ASG handles re-attaching EBS volume to instances, then this instance will always have an attached EBS volume
# - could I read a file in the filesystem to determine my node_id?
# - if so, then I could use that node_id to lookup my node from the bootstrap service
#
# ebs volume
# - load balancer health checks will monitor asg instances
# - a new instance is started when a instance fails health check
# - the instance will be attached to the existing EBS volume from the previous instance
#   - how does the instance get associated with the proper EBS volume when terraform isn't involved?

CLUSTER_ID="test-cluster-1"
ORGANIZATION="Redpanda"
INTERNAL_HOSTS=(jlp-internal-0.ddns.net jlp-internal-1.ddns.net jlp-internal-2.ddns.net) # internal DNS names for each broker
EXTERNAL_HOSTS=(jlp-external-0.ddns.net jlp-external-1.ddns.net jlp-external-2.ddns.net) # external DNS names for each broker

# The broker ID and the array index in each HOSTS array
# If replacing a node, you will want to hard-code this value to the same node_id as the broker being replaced.
# TODO standardize on curl rather than wget
INDEX=`wget -q -O - http://169.254.169.254/latest/meta-data/ami-launch-index`

# sleep later instances in a launch to help ensure bootstrap state updates are isolated
sleep $((4*$INDEX))

INTERNAL_IP=`wget -q -O - http://169.254.169.254/latest/meta-data/local-ipv4`
#EXTERNAL_IP=`wget -q -O - http://169.254.169.254/latest/meta-data/public-ipv4`

# TODO verify this works or leave it out
# set name tag for this instance according to its id
# https://underthehood.meltwater.com/blog/2020/02/07/dynamic-route53-records-for-aws-auto-scaling-groups-with-terraform/
export AVAILABILITY_ZONE=$(curl -sLf http://169.254.169.254/latest/meta-data/placement/availability-zone)
export INSTANCE_ID=$(curl -sLf http://169.254.169.254/latest/meta-data/instance-id)
#export NEW_HOSTNAME="${hostname_prefix}-$INSTANCE_ID"
#hostname $NEW_HOSTNAME
export NEW_HOSTNAME="`hostname`-$INSTANCE_ID"
hostname $NEW_HOSTNAME

# TODO attach EBS volume
# how do I get volume id?
#aws ec2 attach-volume --volume-id vol-1234567890abcdef0 --instance-id i-01474ef662b89480 --device /dev/sdf

# first attempt fails due to using aws cli
#INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
#CURRENT_TAG=$(aws ec2 --region eu-west-1 describe-tags | grep Value | awk {'print $2'})
#aws ec2 create-tags --resources ${INSTANCE_ID} --tags Key=Name,Value=${CURRENT_TAG}_${INSTANCE_ID}
#REGION=$(curl http://169.254.169.254/latest/meta-data/placement/region)
#aws configure set region $REGION
# TODO access_key and secret_key needs to be set
#aws ec2 create-tags --resources ${INSTANCE_ID} --tags Key=Name,Value=${CLUSTER_ID}-${INSTANCE_ID}

yum update -y

# Create a string of other broker names for seed_servers
OTHER_BROKERS=("${INTERNAL_HOSTS[@]}")
unset 'OTHER_BROKERS[$INDEX]'
printf -v OTHER_BROKERS_JOINED '%s,' "${OTHER_BROKERS[@]}"

# Install and configure Redpanda
curl -1sLf https://packages.vectorized.io/sMIXnoa7DK12JW4A/redpanda/cfg/setup/bash.rpm.sh | sudo -E bash
yum install -y redpanda
# TODO issue with rpk redpanda config bootstrap
# Error: accepts 0 arg(s), received 1
if [ $INDEX -eq 0 ]; then
  sudo -u redpanda rpk redpanda config bootstrap --id $INDEX --self $INTERNAL_IP
else
  sudo -u redpanda rpk redpanda config bootstrap --id $INDEX --self $INTERNAL_IP --ips ${OTHER_BROKERS_JOINED%,}
fi
sudo -u redpanda rpk redpanda config set cluster_id $CLUSTER_ID
sudo -u redpanda rpk redpanda config set organization $ORGANIZATION
sudo -u redpanda rpk redpanda config set redpanda.advertised_kafka_api "[{address: ${EXTERNAL_HOSTS[$INDEX]},port: 9092}]"
sudo -u redpanda rpk redpanda config set redpanda.advertised_rpc_api "{address: ${INTERNAL_HOSTS[$INDEX]},port: 33145}"

# Start Redpanda
systemctl restart redpanda

# Set seed_servers for the root node
if [ $INDEX -eq 0 ]; then
  sudo -u redpanda rpk redpanda config bootstrap --id $INDEX --self $INTERNAL_IP --ips ${OTHER_BROKERS_JOINED%,}
fi
