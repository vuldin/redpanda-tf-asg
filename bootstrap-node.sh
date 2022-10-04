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
import Fastify from 'fastify'
import fetch from 'node-fetch'
import {
  DescribeAddressesCommand,
  DescribeInstanceStatusCommand,
  DescribeVolumesCommand,
  EC2Client,
  TerminateInstancesCommand,
} from '@aws-sdk/client-ec2'
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3'
import { Upload } from '@aws-sdk/lib-storage'

const sleep = (ms) => {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

const HEALTH_CHECK_FREQUENCY_MS = 10 * 1000
const HEALTH_CHECK_FAILURE_LIMIT = 3
const REQUEST_TIMEOUT_MS = 2 * 1000

const region = '$REGION'
const Bucket = '${BUCKET}'

const fastify = Fastify({ logger: true })
const s3Client = new S3Client({ region })
const ec2Client = new EC2Client({ region })
const signal = AbortSignal.timeout(REQUEST_TIMEOUT_MS)

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
async function getNodeDetails() {
  const map = new Map()
  for (let i = 0; i < hostnames.length; i++) {
    const hostname = hostnames[i]
    let hostnameInfo = null
    try {
      hostnameInfo = await getState(hostname + '_info')
    } catch (err) {
      console.error(err)
    }
    const { volume_id: volumeId, eip } = JSON.parse(hostnameInfo)
    map.set(hostname, {
      nodeId: i,
      hostname,
      volumeId,
      eip,
      adminUrl: 'http://' + hostname + '.' + domain + ':9644',
      instanceId: '',
      failCount: 0,
      isPrimary: false,
      isVolumeReady: false,
      hasCompletedStartup: false,
      brokers: [],
    })
  }
  return map
}
const nodeDetails = await getNodeDetails()

//set instanceID based off elastic IP association
async function linkInstances() {
  console.log('linking instances based off elastic IP association')
  let PublicIps = []
  for (let i = 0; i < hostnames.length; i++) {
    const details = nodeDetails.get(hostnames[i])
    PublicIps.push(details.eip)
  }
  const params = { PublicIps }
  let result = null
  try {
    result = await ec2Client.send(new DescribeAddressesCommand(params))
  } catch (err) {
    console.error('linkInstances error', err)
  }
  result.Addresses.forEach((addressObj) => {
    const { InstanceId, PublicIp } = addressObj
    if(!InstanceId) return
    // set nodeDetails.instanceId
    for (let i = 0; i < hostnames.length; i++) {
      const details = nodeDetails.get(hostnames[i])
      if (details.eip === PublicIp) {
        nodeDetails.set(hostnames[i], {
          ...details,
          ...{ instanceId: InstanceId },
        })
      }
    }
  })
}
await linkInstances()

// determine primary node
async function determinePrimaryNode() {
  let primaryNodeId = null
  for (let i = 0; i < hostnames.length && !primaryNodeId; i++) {
    const url = nodeDetails.get(hostnames[i]).adminUrl + '/v1/cluster/health_overview'
    try {
      const result = await fetch(url, { signal })
      primaryNodeId = result.controller_id
    } catch (err) {
    }
  }
  if (!primaryNodeId) {
    primaryNodeId = nodeDetails.get(hostnames[0]).nodeId
  }
  let primaryNodeChanged = false
  for (let i = 0; i < hostnames.length; i++) {
    let details = nodeDetails.get(hostnames[i])
    if (details.nodeId === primaryNodeId && !details.isPrimary) {
      nodeDetails.set(hostnames[i], {
        ...details,
        ...{ isPrimary: true },
      })
      primaryNodeChanged = true
    }
    if (details.nodeId !== primaryNodeId && details.isPrimary) {
      nodeDetails.set(hostnames[i], {
        ...details,
        ...{ isPrimary: false },
      })
      primaryNodeChanged = true
    }
  }
  if(primaryNodeChanged) {
    console.log('primary node updated')
  }
}
await determinePrimaryNode()

function getSeedServers() {
  let result = []
  nodeDetails.forEach((details, hostname) => {
    const { failCount, hasCompletedStartup } = details
    if(failCount === 0 && hasCompletedStartup) result.push(hostname + '.' + domain)
  })
  console.log('seed servers', result.toString())
  return result
}

//assign instance to node, return node details
async function registerInstance(instanceId) {
  let result = null
  let seedServers = getSeedServers()

  let notMatched = true
  nodeDetails.forEach((details, key) => {
    const otherBrokers = seedServers
      .filter(seedServer => seedServer.split('.')[0] !== key)
    console.log(key, otherBrokers)
    if(otherBrokers.length === 0 && !details.isPrimary) {
      // no seed servers available after removing self
      // if not primary node, make node wait
      return result
    }
    if(details.instanceId.length === 0 && notMatched) {
      const newDetails = {
        ...details,
        ...{
          instanceId,
          brokers: brokers.toString(),
        },
      }
      nodeDetails.set(details.hostname, newDetails)
      result = newDetails
      notMatched = false
    }
  })
  return result
}

let handlingRegistration = ''

fastify.get('/register', async (request, reply) => {
  const instanceId = request.query.instance_id
  if(handlingRegistration.length === 0) {
    handlingRegistration = instanceId
    if(handlingRegistration !== instanceId) {
      reply.code(503).header('Content-Type', 'application/text; charset=utf-8')
      return 'already handling registration'
    }
    // get instance id from request
    const result = await registerInstance(instanceId)
    if(!result) {
      reply.code(503).header('Content-Type', 'application/text; charset=utf-8')
      return 'no seed servers available'
    }
    handlingRegistration = ''
    reply.code(200).header('Content-Type', 'application/json; charset=utf-8')
    return result
  }
  reply.code(503).header('Content-Type', 'application/text; charset=utf-8')
  return 'already handling registration'
})

fastify.get('/general-info', async (_, reply) => {
  reply.code(200).header('Content-Type', 'application/json; charset=utf-8')
  return generalInfo
})

// nodes call after volume is ready and are waiting to start
fastify.get('/can-start', async (request, reply) => {
  let result = 0
  const instanceId = request.query.instance_id
  let primaryNotFound = true
  let primaryDetails = null

  nodeDetails.forEach((details, key) => {
    if(details.isPrimary) primaryDetails = details
    if(instanceId === details.instanceId && !details.isVolumeReady) {
      const newDetails = {
        ...details,
        ...{ isVolumeReady: true },
      }
      nodeDetails.set(key, newDetails)
    }
  })
  if(instanceId === primaryDetails.instanceId || primaryDetails.hasCompletedStartup) {
    result = 1
  }
  return result
})

fastify.get('/completed-startup', async (request, reply) => {
  const instanceId = request.query.instance_id
  for (let i = 0; i < hostnames.length; i++) {
    const details = nodeDetails.get(hostnames[i])
    const { instanceId: linkedInstance } = details
    if (linkedInstance === instanceId) {
      nodeDetails.set(hostnames[i], {
        ...details,
        ...{ hasCompletedStartup: true },
      })
    }
  }
  reply.code(200).header('Content-Type', 'application/json; charset=utf-8')
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

// start server
try {
  await fastify.listen({ host: '0.0.0.0', port: 3000 })
} catch (err) {
  fastify.log.error(err)
  process.exit(1)
}

/*
 * available:
 * - /public_metrics
 * - TODO kafka API
 */
async function isNodeAvailable(nodeDetails) {
  const { adminUrl, hostname } = nodeDetails
  try {
    const response = await fetch(adminUrl + '/public_metrics', { signal })
    return true
  } catch (err) {
    //console.error(hostname + ' ' + err.name)
    return false
  }
}

/*
 * return true if node is healthy, false otherwise
 * healthy means the node can become available
 * healthy:
 * - EBS volume status
 * - attached to EBS volume
 * - network
 * - instance
 * when is a node unhealthy?
 * - instance is unavailable and not starting or started recently
 * - instance is started but not attached to volume
 */
async function isNodeHealthy(nodeDetails) {
  const {
    nodeId,
    hostname,
    volumeId,
    eip,
    adminUrl,
    instanceId,
    failCount,
    isPrimary,
    isVolumeReady,
    hasCompletedStartup,
  } = nodeDetails

  if (instanceId.length === 0) {
    return true
  }

  // get instance status
  const instanceStatusParams = { InstanceIds: [instanceId] }
  // can be: impaired, initializing, insufficient_data, not_applicable, ok
  let instanceStatus = null
  try {
    const instanceStatusResult = await ec2Client.send(
      new DescribeInstanceStatusCommand(instanceStatusParams)
    )
    instanceStatus = instanceStatusResult.InstanceStatuses[0]?.InstanceStatus?.Status
    if (!instanceStatus) {
      console.log(instanceId + ' in unknown state')
      return true
    }
  } catch (err) {
    if (err.Code === 'InvalidInstanceID.NotFound') {
      console.log(instanceId + ' not found')
      return false
    }
  }

  // instance is unavailable and either 1) not starting or 2) started recently
  if (instanceStatus === 'initializing' || instanceStatus === 'ok') return true

  // get volume status
  let volumeStatus = null
  try {
    const volumeStatusResult = await ec2Client.send(
      new DescribeVolumesCommand({ VolumeIds: [volumeId] })
    )
    // can be: available, creating, deleted, deleting, error, in_use
    volumeStatus = volumeStatusResult.Volumes[0]?.State
  } catch (err) {
    console.error('volume ' + volumeId + ' error', err)
    return true
  }
  if (volumeStatus === 'available') {
    console.log('instance ' + instanceId + ' and volume ' + volumeId + ' are not yet attached')
    return false
  }
  if (volumeStatus === 'creating') {
    console.log('volume ' + volumeId + ' is still creating')
    return true
  }
  if (!volumeStatus.includes('-')) {
    console.log('volume ' + volumeId + ' ' + volumeStatus)
    return true
  }
}

async function unlinkAndTerminateInstance(instanceId) {
  // terminate
  const terminateParams = { InstanceIds: [instanceId] }
  try {
    await ec2Client.send(new TerminateInstancesCommand(terminateParams))
    console.log('requested termination of instance ' + instanceId)
  } catch (err) {
    console.error(err)
  }
  // unlink
  for (let i = 0; i < hostnames.length; i++) {
    const details = nodeDetails.get(hostnames[i])
    const { hostname, eip, instanceId: linkedInstance } = detail
    if (linkedInstance === instanceId) {
      nodeDetails.set(hostnames[i], {
        ...details,
        ...{
          instanceId: '',
          failCount: 0,
          isPrimary: false,
          hasCompletedStartup: false,
        },
      })
    }
  }
}

/*
 * loop continuously checking node availability and then health
 * availability: whether node responds to admin API requests
 * healthy: status of volume, instance, network
 * if node is available then health check is skipped
 * multiple failed health checks in a row result in instance being terminated
 * causing the ASG to start another instance
 * when to unlink and terminate an instance?
 * - when failure count limit is exceeded
 * what increases failure count?
 * - instance is unavailable and not starting or started recently
 * - instance is started but not attached to volume
 */
while (true) {
  for (let i = 0; i < hostnames.length; i++) {
    const details = nodeDetails.get(hostnames[i])
    const { failCount, hostname, instanceId, adminUrl } = details
    const isAvailable = await isNodeAvailable(hostname, adminUrl)
    if (isAvailable) {
      console.log(hostname + ' is available')
      continue
    }
    const isHealthy = await isNodeHealthy(details)
    if (isHealthy) {
      console.log(hostname + ' is not available but is healthy')
      continue
    }
    if (failCount > HEALTH_CHECK_FAILURE_LIMIT) {
      console.log(
        hostname +
          ':' +
          instanceId +
          ' failed too many application health checks, delinking and terminating instance'
      )
      unlinkAndTerminateInstance(instanceId)
    } else {
      console.log(
        hostname + ':' + instanceId + ' failed application health check, increasing fail count'
      )
      const newDetails = {
        ...details,
        ...{ failCount: failCount + 1 },
      }
      console.log(newDetails)
      nodeDetails.set(hostname[i], newDetails)
    }
  }
  getSeedServers()
  await determinePrimaryNode()
  await sleep(HEALTH_CHECK_FREQUENCY_MS)
  console.log('---')
}

EOF

/home/ec2-user/.volta/bin/node index.js
exit 1
