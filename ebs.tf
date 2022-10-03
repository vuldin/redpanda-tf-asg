resource "aws_ebs_volume" "redpanda_volumes" {
  for_each          = toset(local.hostnames)
  availability_zone = local.availability_zone
  iops              = 3000
  size              = 40
  type              = "gp3"
  throughput        = 125

  tags = {
    Name = "${local.cluster_id}-${each.value}"
  }
}

resource "local_file" "hostnames_info" {
  for_each = toset(local.hostnames)
  content = jsonencode({
    volume_id = aws_ebs_volume.redpanda_volumes["${each.value}"].id
    eip = aws_eip.redpanda_nodes["${each.value}"].public_ip
  })
  filename = "${path.module}/s3-artifacts/${each.value}_info"
}

resource "aws_s3_object" "s3_hostnames_info" {
  bucket     = aws_s3_bucket.bootstrap.id

  for_each   = toset(local.hostnames)
  key        = "${each.value}_info"
  source     = "${path.module}/s3-artifacts/${each.value}_info"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.hostnames_info
  ]
}
