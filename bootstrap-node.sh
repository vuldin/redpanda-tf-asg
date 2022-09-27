#!/bin/bash

set -ex

INTERNAL_IP=`wget -q -O - http://169.254.169.254/latest/meta-data/local-ipv4`
REGION=$(curl http://169.254.169.254/latest/meta-data/placement/region)

yum update -y
curl https://get.volta.sh | bash
/.volta/bin/volta install node@${NODEJS_VERSION}
mkdir bootstrap-node && cd bootstrap-node
/root/.volta/bin/npm init -y
/root/.volta/bin/npm i @aws-sdk/client-s3 @aws-sdk/lib-storage fastify node-fetch

cat <<EOF > index.js
const { GetObjectCommand, S3Client } = require('@aws-sdk/client-s3')
const { Upload } = require('@aws-sdk/lib-storage')
const fastify = require('fastify')({ logger: true })
const fetch = (...args) => import('node-fetch').then(({ default: fetch }) => fetch(...args))

const region = '$REGION'
// TODO this variable will not be set if bootstrap instance is replaced
const Bucket = '${BUCKET}'

const client = new S3Client({ region })

fastify.get('/ebs-volume-id', async (request, reply) => {
  /*
   * redpanda instances call this endpoint early in their user_data script
   * after system updates, redpanda install, prior to redpanda start
   */
  var result = null
  // get instance id from request
  const instanceId = request.query.instance_id
  // get hostnames
  const hostnamesStr = await getState('hostnames')
  if(typeof hostnamesStr === 'object') {
    reply.code(500)
    return hostnamesStr
  }
  const hostnames = hostnamesStr.split(' ')
  const hostnameVolumeIdMap = new Map()
  for(var i = 0; i < hostnames.length; i++) {
    const hostname = hostnames[i]
    // with hostnames, get volume ids
    const volumeId = await getState(hostname + '_to_volume_id')
    if(typeof volumeId === 'object') {
      reply.code(500)
      return volumeId
    }
    // with hostnames, get instance ids
    const matchedInstanceId = await getState(hostname + '_to_instance_id')
    if(typeof matchedInstanceId === 'object') {
      reply.code(500)
      return matchedInstanceId
    }
    // compare instanceId to matchedInstanceId
    if(instanceId === matchedInstanceId) {
      reply.code(400)
      return new Error('Instance ID ' + instanceId + ' already matches volume ID ' + volumeId)
    }
    if(matchedInstanceId.length === 0) {
      hostnameVolumeIdMap.set(hostname, volumeId)
    }
  }
  if(hostnameVolumeIdMap.size === 0) {
    reply.code(400)
    return new Error('All EBS volumes are assigned to hosts')
  }
  // find first hostname without instance id
  const [hostname, volumeId] = Array.from(hostnameVolumeIdMap.entries())[0]
  //set value to instance id from request
  const s3Result = await setState(hostname + '_to_instance_id', instanceId)
  if(typeof s3Result === 'object') {
    reply.code(500)
    return s3Result
  }
  result = volumeId
  reply
    .code(200)
    .header('Content-Type', 'application/text; charset=utf-8')
    .send(result)
})

/*
* health check calls this for an instance that fails health check
*/
fastify.delete('/instance-id', async (request, reply) => {
  var result = null
  // get instance id from request
  const instanceId = request.query.instance_id
  // get hostnames
  const hostnamesStr = await getState('hostnames')
  if(typeof hostnamesStr === 'object') {
    reply.code(500)
    return hostnamesStr
  }
  const hostnames = hostnamesStr.split(' ')
  const hostnameVolumeIdMap = new Map()
  for(var i = 0; i < hostnames.length; i++) {
    const hostname = hostnames[i]
    // with hostnames, get volume ids
    const volumeId = await getState(hostname + '_to_volume_id')
    if(typeof volumeId === 'object') {
      reply.code(500)
      return volumeId
    }
    // with hostnames, get instance ids
    const matchedInstanceId = await getState(hostname + '_to_instance_id')
    if(typeof matchedInstanceId === 'object') {
      reply.code(500)
      return matchedInstanceId
    }
    // compare instanceId to matchedInstanceId
    if(instanceId === matchedInstanceId) {
      const unsetResult = await setState(hostname + '_to_instance_id', '')
      if(typeof unsetResult === 'object') {
        reply.code(500)
        return unsetResult
      }
      result = 'Successfully freed volume ID ' + volumeId
    }
  }
  if(!result) {
    reply.code(500)
    return 'Instance ID ' + instanceId + ' not associated with any volume'
  }
  reply
    .code(200)
    .header('Content-Type', 'application/text; charset=utf-8')
    .send(result)
})

fastify.get('/is-leader', async (request, reply) => {
  /*
   * redpanda instances will look for redpanda.yaml in EBS volume to determine node_id
   * if redpanda.yaml exists, then node_id will be pulled and re-used
   * if there is no redpanda.yaml, then node_id will be set to ami launch index
   * instance will call this endpoint passing node_id and is_reusing_node_id query params
   */
  var result = null
  const thisNodeId = Number(request.query.node_id)
  const doesClusterExist = Number(request.query.is_reusing_node_id)
  if(doesClusterExist === 0) {
    // terraform start, empty EBS volume, leader is determined by index
    result = thisNodeId === 0 ? '1' : '0'
  } else {
    // subsequent start, leader is determined by health_overview call to other nodes
    // TODO each instance could read seed_servers to get hostnames to avoid calling this endpoint
    const hostnamesStr = await getState('hostnames')
    if(typeof hostnamesStr === 'object') {
      reply.code(500)
      return hostnamesStr
    }
    const hostnames = hostnamesStr.split(' ')
    const hostname = hostnames.filter((_, index) => index !== thisNodeId)[0]
    const domain = await getState('domain')
    const healthOverviewUrl = 'http://internal.' + hostname + '.' + domain + ':9644/v1/cluster/health_overview'
    const response = await fetch(healthOverviewUrl)

    const data = await response.json()
    const leaderNodeId = data.controller_id
    result = thisNodeId === leaderNodeId ? '1' : '0'
  }
  reply
    .code(200)
    .header('Content-Type', 'application/text; charset=utf-8')
    .send(result)
})

async function getState(Key) {
  const streamToString = (stream) =>
    new Promise((resolve, reject) => {
      const chunks = []
      stream.on('data', (chunk) => chunks.push(chunk))
      stream.on('error', reject)
      stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    })

  var result = null

  const bucketParams = { Bucket, Key }
  try {
    const data = await client.send(new GetObjectCommand(bucketParams))
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
    const upload = new Upload({ client, params })
    await upload.done()
  } catch (err) {
    console.error('Error', err)
    result = err
  }
  return 'success'
}

const startServer = async () => {
  try {
    await fastify.listen({ host: '0.0.0.0', port: 3000 })
  } catch (err) {
    fastify.log.error(err)
    process.exit(1)
  }
}

startServer()

EOF

/root/.volta/bin/node index.js