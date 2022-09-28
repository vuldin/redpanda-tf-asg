#!/bin/bash

set -ex

CLUSTER_ID="test-cluster-1"
ORGANIZATION="Redpanda"
INTERNAL_HOSTS=(jlp-internal-0.ddns.net jlp-internal-1.ddns.net jlp-internal-2.ddns.net) # internal DNS names for each broker
EXTERNAL_HOSTS=(jlp-external-0.ddns.net jlp-external-1.ddns.net jlp-external-2.ddns.net) # external DNS names for each broker

# The broker ID and the array index in each HOSTS array
# If replacing a node, you will want to hard-code this value to the same node_id as the broker being replaced.
INDEX=`curl -sLf http://169.254.169.254/latest/meta-data/ami-launch-index`

# sleep later instances in a launch to help ensure bootstrap state updates are isolated
sleep $((4*$INDEX))

INTERNAL_IP=`curl -sLf http://169.254.169.254/latest/meta-data/local-ipv4`
#EXTERNAL_IP=`wget -q -O - http://169.254.169.254/latest/meta-data/public-ipv4`

export AVAILABILITY_ZONE=$(curl -sLf http://169.254.169.254/latest/meta-data/placement/availability-zone)
export INSTANCE_ID=$(curl -sLf http://169.254.169.254/latest/meta-data/instance-id)

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
