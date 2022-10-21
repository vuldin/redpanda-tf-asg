#!/bin/bash

set -ex
yum update -y

# run the rest of this script as ubuntu
tail -n +$[LINENO+2] $0 | exec sudo -u ubuntu bash
exit $?
set -ex
INSTANCE_ID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/region`

cd $HOME
curl https://get.volta.sh | sudo -u ubuntu bash
/home/ubuntu/.volta/bin/volta install node@16.18.0
mkdir bootstrap-node && cd bootstrap-node
/home/ubuntu/.volta/bin/npm init -y es6
/home/ubuntu/.volta/bin/npm i @aws-sdk/client-ec2 @aws-sdk/client-s3 @aws-sdk/lib-storage fastify node-libcurl

# update DNS
aws configure set region $REGION

cat <<EOF > index.js
import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3'

const sleep = (ms) => {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

const HEALTH_CHECK_FREQUENCY_MS = 10 * 1000
const HEALTH_CHECK_FAILURE_LIMIT = 3
const REQUEST_TIMEOUT_MS = 2 * 1000

const region = '$REGION'
const Bucket = 'prefix-redpanda-si-bucket'

const s3Client = new S3Client({ region })

async function setState(Key, Body) {
  let result = null
  try {
    const data = await s3Client.send(new PutObjectCommand({ Bucket, Key, Body }))
    result = data
  } catch (err) {
    console.error('Error', err)
    result = err
  }
  return result
}

async function getState(Key) {
  const streamToString = (stream) =>
    new Promise((resolve, reject) => {
      const chunks = []
      stream.on('data', (chunk) => chunks.push(chunk))
      stream.on('error', reject)
      stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    })
  let result = null
  try {
    const data = await s3Client.send(new GetObjectCommand({ Bucket, Key }))
    const remoteState = await streamToString(data.Body)
    result = remoteState
  } catch (err) {
    console.error('Error', err)
    result = err
  }
  return result
}

await setState('test', 'works')
const clusterId = await getState('test')

EOF

/home/ubuntu/.volta/bin/node index.js
exit 1
