#!/bin/bash

set -ex
yum update -y

# run the rest of this script as ec2-user
tail -n +$[LINENO+2] $0 | exec sudo -u ec2-user bash
exit $?
set -ex
INSTANCE_ID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/region`

cd $HOME
curl https://get.volta.sh | sudo -u ec2-user bash
/home/ec2-user/.volta/bin/volta install node@${NODEJS_VERSION}
mkdir bootstrap-node && cd bootstrap-node
/home/ec2-user/.volta/bin/npm init -y es6
/home/ec2-user/.volta/bin/npm i @aws-sdk/client-ec2 @aws-sdk/client-s3 @aws-sdk/lib-storage fastify node-fetch

# update DNS
aws configure set region $REGION
aws ec2 associate-address --instance-id "$INSTANCE_ID" --public-ip ${EIP}

cat <<EOF > index.js
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3'
import {
  DescribeInstanceStatusCommand,
  EC2Client,
  TerminateInstancesCommand,
} from '@aws-sdk/client-ec2'
import { Upload } from '@aws-sdk/lib-storage'
import Fastify from 'fastify'
import fetch from 'node-fetch'

const HEALTH_CHECK_FREQUENCY_MS = 10 * 1000
const HEALTH_CHECK_FAILURE_LIMIT = 3

const region = '$REGION'
const Bucket = '${BUCKET}'

const fastify = Fastify({ logger: true })
const s3Client = new S3Client({ region })
const ec2Client = new EC2Client({ region })

// get general cluster info
const clusterId = await getState('cluster_id')
const domain = await getState('domain')
const hostnamesStr = await getState('hostnames')
const mountDir = await getState('mount_dir')
const organization = await getState('organization')
const generalInfo = {
  clusterId,
  domain,
  hostnames: hostnamesStr,
  mountDir,
  organization,
}

// get hostname info
const hostnames = hostnamesStr.split(' ')
const nodeDetails = new Map()
for(let i = 0; i < hostnames.length; i++) {
  const hostname = hostnames[i]
  let hostnameInfo = await getState(hostname + '_info')
  const { volume_id: volumeId, eip } = JSON.parse(hostnameInfo)
  nodeDetails.set(hostname, {
    hostname,
    volumeId,
    eip,
    url: 'http://' + hostname + '.' + domain + ':9644/public_metrics',
  })
}

const didInstanceAlreadyFail = new Map()
nodeDetails.forEach(({ hostname }) => didInstanceAlreadyFail.set(hostname, 0))

/*
 * redpanda instances call this endpoint early in their user_data script
 * after system updates
 * before DNS update, volume mount, redpanda install/start
 * in: instanceId, out: { hostname, volumeId, eip }
 */
fastify.get('/node-info', async (request, reply) => {
  // get instance id from request
  const instanceId = request.query.instance_id
  const unmatchedHostnames = []
  for(let i = 0; i < hostnames.length; i++) {
    const hostname = hostnames[i]
    // get matching instance ids
    const matchedInstanceId = await getState(hostname + '_to_instance_id')
    if(typeof matchedInstanceId === 'object') {
      reply.code(500)
      return matchedInstanceId
    }
    // compare instanceId to matchedInstanceId
    if(instanceId === matchedInstanceId) {
      //reply.code(400)
      //return new Error('Instance ID ' + instanceId + ' already matches hostname ' + hostname)
      reply
        .code(200)
        .header('Content-Type', 'application/json; charset=utf-8')
      return nodeDetails.get(hostname)
    }
    if(matchedInstanceId.length === 0) {
      unmatchedHostnames.push(hostname)
    }
  }
  if(unmatchedHostnames.length === 0) {
    reply.code(400)
    return new Error('All EBS volumes are assigned to hosts')
  }
  // find first hostname without instance id
  const hostname = unmatchedHostnames[0]
  //set value to instance id from request
  const instanceIdResult = await setState(hostname + '_to_instance_id', instanceId)
  if(typeof instanceIdResult === 'object') {
    reply.code(500)
    return instanceIdResult
  }
  reply
    .code(200)
    .header('Content-Type', 'application/json; charset=utf-8')
  return nodeDetails.get(hostname)
})

/*
 * health check calls this for an instance that fails health check
 */
async function deleteInstanceLink(instanceId) {
  let unsetHostname = null
  // get hostnames
  const hostnamesStr = await getState('hostnames')
  if(typeof hostnamesStr === 'object') {
    return {
      code: 500,
      response: hostnamesStr,
    }
  }
  const hostnames = hostnamesStr.split(' ')
  for(let i = 0; i < hostnames.length; i++) {
    const hostname = hostnames[i]
    // get matched instance ids
    const matchedInstanceId = await getState(hostname + '_to_instance_id')
    if(typeof matchedInstanceId === 'object') {
      return {
        code: 500,
        response: matchedInstanceId,
      }
    }
    if(instanceId === matchedInstanceId) {
      const unsetResult = await setState(hostname + '_to_instance_id', '')
      if(typeof unsetResult === 'object') {
        return {
          code: 500,
          response: unsetResult,
        }
      }
      unsetHostname = hostname
    }
  }
  if(!unsetHostname) {
    return {
      code: 500,
      response: 'Instance ID ' + instanceId + ' not associated with any hostname',
    }
  }
  return {
    code: 200,
    response: 'Disconnected instance ID ' + instanceId + ' from hostname ' + unsetHostname,
  }
}

fastify.delete('/instance-id', async (request, reply) => {
  // get instance id from request
  const instanceId = request.query.instance_id
  const result = await deleteInstanceLink(instanceId)
  reply.code(result.code)
  if(result.code === 200) {
    reply.header('Content-Type', 'application/text; charset=utf-8')
  }
  return result.response
})

fastify.get('/general-info', async (_, reply) => {
  reply
    .code(200)
    .header('Content-Type', 'application/json; charset=utf-8')
  return generalInfo
})

async function getState(Key) {
  const streamToString = (stream) =>
    new Promise((resolve, reject) => {
      const chunks = []
      stream.on('data', (chunk) => chunks.push(chunk))
      stream.on('error', reject)
      stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    })

  let result = null

  const bucketParams = { Bucket, Key }
  try {
    const data = await s3Client.send(new GetObjectCommand(bucketParams))
    const remoteState = await streamToString(data.Body)
    result = remoteState
  } catch (err) {
    console.error('Error', err)
    result = err
  }
  return result
}

async function setState(Key, Body) {
  if (typeof Key !== 'string' && Key.length > 0) return 'key must be valid string'
  if (typeof Body !== 'string' && Body.length > 0) return 'body must be valid string'
  const params = { Bucket, Key, Body }
  try {
    const upload = new Upload({ client: s3Client, params })
    await upload.done()
  } catch (err) {
    console.error('Error', err)
    result = err
  }
  return 'success'
}

async function handleStatus(hostname, endpoint) {
  const instanceId = await getState(hostname + '_to_instance_id')
  if(typeof instanceId === 'object') {
    console.error(instanceId)
    return
  }
  if(instanceId.length === 0) {
    console.log(hostname + ' is not connected to an instance')
    return
  }

  // get system status
  const params = { InstanceIds: [instanceId] }
  try {
    const instanceStatusResult = await ec2Client.send(new DescribeInstanceStatusCommand(params))
    const instanceStatus = instanceStatusResult.InstanceStatuses[0]?.InstanceStatus?.Status
    // don't delete instance if initializing
    if (instanceStatus === 'initializing') return
    if (instanceStatus !== 'ok') {
      console.log(hostname + ':' + instanceId + ' failed system health check, delinking')
      deleteInstanceLink(instanceId)
      return
    }
  } catch (err) {
    if(err.Code === 'InvalidInstanceID.NotFound') {
      console.log(hostname + ':' + instanceId + ' doesn\'t exist, delinking')
      deleteInstanceLink(instanceId)
      return
    }
    console.error(err)
    process.exit(1)
  }

  // get app status
  try {
  const { status } = await fetch(endpoint)
  } catch(err) {
    //console.error(hostname + ' ' + err.name)
    const failCount = didInstanceAlreadyFail.get(hostname)
    if (failCount > HEALTH_CHECK_FAILURE_LIMIT) {
      console.log(hostname + ':' + instanceId + ' failed too many application health checks, delinking and terminating instance')
      //await ec2Client.send(new TerminateInstancesCommand(params))
      //deleteInstanceLink(instanceId)
      //didInstanceAlreadyFail.set(hostname, 0)
      return
    } else {
      console.log(hostname + ':' + instanceId + ' failed application health check, increasing fail count')
      //didInstanceAlreadyFail.set(hostname, failCount + 1)
      return
    }
  }
  console.log(hostname + ':' + instanceId + ' passed health check')
}

const sleep = (ms) => {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

try {
  await fastify.listen({ host: '0.0.0.0', port: 3000 })
} catch (err) {
  fastify.log.error(err)
  process.exit(1)
}

while (true) {
  nodeDetails.forEach(({ hostname, url }) => handleStatus(hostname, url))
  await sleep(HEALTH_CHECK_FREQUENCY_MS)
  console.log('---')
}

EOF

/home/ec2-user/.volta/bin/node index.js
exit 1
