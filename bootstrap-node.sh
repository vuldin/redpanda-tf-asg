#!/bin/bash

set -ex

INSTANCE_ID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/region`

yum update -y
sudo -u ec2-user curl https://get.volta.sh | sudo -u ec2-user bash
sudo -u ec2-user /home/ec2-user/.volta/bin/volta install node@${NODEJS_VERSION}
cd /home/ec2-user
sudo -u ec2-user mkdir bootstrap-node && cd bootstrap-node
sudo -u ec2-user /home/ec2-user/.volta/bin/npm init -y
sudo -u ec2-user /home/ec2-user/.volta/bin/npm i @aws-sdk/client-s3 @aws-sdk/lib-storage fastify node-fetch

# update DNS
sudo -u ec2-user aws configure set region $REGION
sudo -u ec2-user aws ec2 associate-address --instance-id "$INSTANCE_ID" --public-ip ${EIP}

sudo -u ec2-user cat <<EOF > index.js
const { GetObjectCommand, S3Client } = require('@aws-sdk/client-s3')
const { Upload } = require('@aws-sdk/lib-storage')
const fastify = require('fastify')({ logger: true })
const fetch = (...args) => import('node-fetch').then(({ default: fetch }) => fetch(...args))

const region = '$REGION'
// TODO this variable will not be set if bootstrap instance is replaced
const Bucket = '${BUCKET}'

const client = new S3Client({ region })

/*
 * redpanda instances call this endpoint early in their user_data script
 * after system updates
 * before DNS update, volume mount, redpanda install/start
 * in: instanceId, out: { hostname, volumeId, eip }
 */
fastify.get('/node-info', async (request, reply) => {
  // get instance id from request
  const instanceId = request.query.instance_id
  // get hostnames
  const hostnamesStr = await getState('hostnames')
  if(typeof hostnamesStr === 'object') {
    reply.code(500)
    return hostnamesStr
  }
  const hostnames = hostnamesStr.split(' ')

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
      let hostnameInfo = await getState(hostname + '_info')
      if(typeof hostnameInfo === 'object') {
        reply.code(500)
        return hostnameInfo
      }
      const { volume_id: volumeId, eip } = JSON.parse(hostnameInfo)
      reply
        .code(200)
        .header('Content-Type', 'application/json; charset=utf-8')
      return {
          hostname,
          volumeId,
          eip,
        }
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
  let hostnameInfo = await getState(hostname + '_info')
  if(typeof hostnameInfo === 'object') {
    reply.code(500)
    return hostnameInfo
  }
  const { volume_id: volumeId, eip } = JSON.parse(hostnameInfo)
  reply
    .code(200)
    .header('Content-Type', 'application/json; charset=utf-8')
    .send({
      hostname,
      volumeId,
      eip,
    })
})

/*
 * health check calls this for an instance that fails health check
 */
fastify.delete('/instance-id', async (request, reply) => {
  let result = null
  // get instance id from request
  const instanceId = request.query.instance_id
  // get hostnames
  const hostnamesStr = await getState('hostnames')
  if(typeof hostnamesStr === 'object') {
    reply.code(500)
    return hostnamesStr
  }
  const hostnames = hostnamesStr.split(' ')
  for(let i = 0; i < hostnames.length; i++) {
    const hostname = hostnames[i]
    // get matched instance ids
    const matchedInstanceId = await getState(hostname + '_to_instance_id')
    if(typeof matchedInstanceId === 'object') {
      reply.code(500)
      return matchedInstanceId
    }
    if(instanceId === matchedInstanceId) {
      const unsetResult = await setState(hostname + '_to_instance_id', '')
      if(typeof unsetResult === 'object') {
        reply.code(500)
        return unsetResult
      }
      result = hostname
    }
  }
  if(!result) {
    reply.code(500)
    return 'Instance ID ' + instanceId + ' not associated with any hostname'
  }
  reply
    .code(200)
    .header('Content-Type', 'application/text; charset=utf-8')
    .send('Disconnected instance ID ' + instanceId + ' from hostname ' + result)
})

fastify.get('/general-info', async (_, reply) => {
  const clusterId = await getState('cluster_id')
  if(typeof clusterId === 'object') {
    reply.code(500)
    return clusterId
  }
  const domain = await getState('domain')
  if(typeof domain === 'object') {
    reply.code(500)
    return domain
  }
  const hostnames = await getState('hostnames')
  if(typeof hostnames === 'object') {
    reply.code(500)
    return hostnames
  }
  const mountDir = await getState('mount_dir')
  if(typeof mountDir === 'object') {
    reply.code(500)
    return mountDir
  }
  const organization = await getState('organization')
  if(typeof organization === 'object') {
    reply.code(500)
    return organization
  }
  reply
    .code(200)
    .header('Content-Type', 'application/json; charset=utf-8')
  return {
    clusterId,
    domain,
    hostnames,
    mountDir,
    organization,
  }
})

/*
 * redpanda instances will look for redpanda.yaml in EBS volume to determine node_id
 * if redpanda.yaml exists, then node_id will be pulled and re-used
 * if there is no redpanda.yaml, then node_id will be set to ami launch index
 * instance will call this endpoint passing node_id and is_reusing_node_id query params
 */
fastify.get('/is-leader', async (request, reply) => {
  let result = null
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
    const subdomain = await getState('subdomain')
    const healthOverviewUrl = 'http://internal.' + hostname + '.' + subdomain + domain + ':9644/v1/cluster/health_overview'
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

  let result = null

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

sudo -u ec2-user /home/ec2-user/.volta/bin/node index.js