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
/home/ec2-user/.volta/bin/npm i @aws-sdk/client-ec2 @aws-sdk/client-s3 @aws-sdk/lib-storage fastify node-libcurl

# update DNS
aws configure set region $REGION
aws ec2 associate-address --instance-id "$INSTANCE_ID" --public-ip ${EIP}

cat <<EOF > index.js
import Fastify from 'fastify'
import { curly } from 'node-libcurl'
import {
  DescribeAddressesCommand,
  DescribeInstanceStatusCommand,
  EC2Client,
  TerminateInstancesCommand,
} from '@aws-sdk/client-ec2'
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3'

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
      //isVolumeReady: false,
      hasCompletedStartup: false,
      seedServers: [],
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
      const { data } = await curly.get(url, {
        TIMEOUT_MS: REQUEST_TIMEOUT_MS,
      })
      primaryNodeId = data.controller_id
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

async function updateSeedServers() {

  const allSeedServers = []
  // get all node DNS names
  //nodeDetails.forEach((details, hostname) => {
    //const { hasCompletedStartup } = details
    // TODO setting seed servers based on hasCompletedStartup
    // only works if bootstrap service is running before all nodes
    //if(hasCompletedStartup) allSeedServers.push(hostname + '.' + domain)
    //allSeedServers.push(hostname + '.' + domain)
  //})

  // verify seed servers
  const values = [...nodeDetails.values()]
  for(let i = 0; i < values.length; i++) {
    const result = await isNodeAvailable(values[i])
    if(result) allSeedServers.push(values[i].hostname + '.' + domain)
  }

  // update seed servers for all nodes
  nodeDetails.forEach((details, hostname) => {
    const otherSeedServers = allSeedServers
      .filter(seedServer => seedServer.split('.')[0] !== hostname)
    const newDetails = {
      ...details,
      ...{ seedServers: otherSeedServers.toString() },
    }
    nodeDetails.set(hostname, newDetails)
    console.log(hostname, 'seed servers', otherSeedServers.toString())
  })
}

//assign instance to node, return node details
function registerInstance(instanceId) {
  const availableNodes = new Map()
  let result = null
  // find available nodes
  nodeDetails.forEach((details, hostname) => {
    // TODO
    //console.log(JSON.stringify(details, null, 2))
    const { instanceId: linkedInstanceId, isPrimary, seedServers } = details
    //console.log(linkedInstanceId, seedServers?.toString(), isPrimary)
    if(
      linkedInstanceId.length === 0 &&
      ((seedServers.length === 0 && isPrimary) || (seedServers.length > 0 && !isPrimary))
    ) {
      availableNodes.set(hostname, details)
    }
  })
  if(availableNodes.size === 0) return result
  const firstNodeDetails = [...availableNodes.values()][0]
  const newDetails = {
    ...firstNodeDetails,
    ...{ instanceId },
  }
  nodeDetails.set(newDetails.hostname, newDetails)
  return newDetails
}

let handlingRegistration = false
fastify.get('/register', (request, reply) => {
  if(handlingRegistration) {
    console.log('already handling registration')
    reply.code(503).header('Content-Type', 'application/text; charset=utf-8')
    return 'already handling registration'
  }
  handlingRegistration = true
  const instanceId = request.query.instance_id
  const result = registerInstance(instanceId)
  if(!result) {
    console.log('no nodes available')
    handlingRegistration = false
    reply.code(503).header('Content-Type', 'application/text; charset=utf-8')
    return 'no nodes available'
  }
  handlingRegistration = false
  reply.code(200).header('Content-Type', 'application/json; charset=utf-8')
  return result
})

fastify.get('/general-info', async (_, reply) => {
  reply.code(200).header('Content-Type', 'application/json; charset=utf-8')
  return generalInfo
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

// start server
try {
  await fastify.listen({ host: '0.0.0.0', port: 3000 })
} catch (err) {
  fastify.log.error(err)
  process.exit(1)
}

async function isNodeAvailable(nodeDetails) {
  const { adminUrl } = nodeDetails
  const url = adminUrl + '/public_metrics'
  try {
    const { statusCode } = await curly.get(url, {
      TIMEOUT_MS: REQUEST_TIMEOUT_MS,
    })
    return true
  } catch (err) {
    //console.error(hostname + ' ' + err.name)
    return false
  }
}

async function isNodeHealthy(nodeDetails) {
  const { instanceId } = nodeDetails
  if (instanceId.length === 0) return true

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
      console.log(instanceId + ' doesn\'t exist')
      return false
    }
  } catch (err) {
    if (err.Code === 'InvalidInstanceID.NotFound') {
      console.log(instanceId + ' not found')
      return false
    }
  }

  // instance is unavailable and either 1) not starting or 2) started recently
  //if (instanceStatus === 'initializing' || instanceStatus === 'ok') return true

  return true
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
    const { hostname, instanceId: linkedInstance } = detail
    if (linkedInstance === instanceId) {
      nodeDetails.set(hostname, {
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

while (true) {
  await updateSeedServers()
  await determinePrimaryNode()
  for (let i = 0; i < hostnames.length; i++) {
    const details = nodeDetails.get(hostnames[i])
    const { failCount, hostname, instanceId, adminUrl } = details
    const isAvailable = await isNodeAvailable(details)
    if (isAvailable) {
      console.log(hostname + ' is available')
      continue
    }
    const isHealthy = await isNodeHealthy(details)
    if (isHealthy) {
      console.log(hostname + ' is not available but is healthy')
      continue
    }

    console.log(
      hostname + ':' + instanceId + ' failed application health check, increasing fail count'
    )
    failCount += 1
    if (failCount > HEALTH_CHECK_FAILURE_LIMIT) {
      console.log(
        hostname +
          ':' +
          instanceId +
          ' failed too many application health checks, delinking and terminating instance'
      )
      unlinkAndTerminateInstance(instanceId)
    }
  }
  await sleep(HEALTH_CHECK_FREQUENCY_MS)
  console.log('---')
}

EOF

/home/ec2-user/.volta/bin/node index.js
exit 1
