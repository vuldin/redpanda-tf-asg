#!/bin/bash

set -ex
#apt update && apt upgrade -y

# install redpanda
curl -1sLf https://packages.vectorized.io/sMIXnoa7DK12JW4A/redpanda/cfg/setup/bash.deb.sh | sudo -E bash
apt install -y redpanda

# ensure redpanda user is owner of all related files/directories
find /etc/redpanda/ /var/lib/redpanda/ -name '*' | xargs -d '\n' chown redpanda:redpanda

# configure redpanda
INTERNAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`

sudo -u redpanda rpk redpanda config bootstrap --id 0 --self $INTERNAL_IP

sudo -u redpanda rpk redpanda config set cluster_id 'test-cluster'
sudo -u redpanda rpk redpanda config set organization 'test-org'
sudo -u redpanda rpk redpanda config set redpanda.advertised_kafka_api "[{address: $INTERNAL_IP, port: 9092}]"
sudo -u redpanda rpk redpanda config set redpanda.advertised_rpc_api "{address: $INTERNAL_IP, port: 33145}"

sudo -u redpanda rpk cluster config set cloud_storage_bucket prefix-redpanda-si-bucket --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_region us-west2 --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_access_key ABCDEFGHIJKLMNOP --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_secret_key 1234567890abcdefghijklmnop --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_enable_remote_read true --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_enable_remote_write true --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_segment_max_upload_interval_sec 30 --api-urls 34.220.95.159:9644
sudo -u redpanda rpk cluster config set cloud_storage_enabled true --api-urls 34.220.95.159:9644

# start redpanda
systemctl start redpanda
