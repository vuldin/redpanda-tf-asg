resource "local_file" "bucket_name" {
  content  = local.bucket_name
  filename = "${path.module}/s3-artifacts/bucket_name"
}

resource "aws_s3_object" "s3_bucket_name" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "bucket_name"
  source     = "${path.module}/s3-artifacts/bucket_name"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.bucket_name
  ]
}

resource "local_file" "cluster_id" {
  content  = local.cluster_id
  filename = "${path.module}/s3-artifacts/cluster_id"
}

resource "aws_s3_object" "s3_cluster_id" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "cluster_id"
  source     = "${path.module}/s3-artifacts/cluster_id"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.cluster_id
  ]
}

resource "local_file" "domain" {
  content  = "${local.subdomain}.${local.domain}"
  filename = "${path.module}/s3-artifacts/domain"
}

resource "aws_s3_object" "s3_domain" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "domain"
  source     = "${path.module}/s3-artifacts/domain"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.domain
  ]
}

resource "local_file" "hostnames" {
  content  = local.hostnames_string
  filename = "${path.module}/s3-artifacts/hostnames"
}

resource "aws_s3_object" "s3_hostnames" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "hostnames"
  source     = "${path.module}/s3-artifacts/hostnames"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.hostnames
  ]
}

resource "local_file" "mount_dir" {
  content  = local.mount_dir
  filename = "${path.module}/s3-artifacts/mount_dir"
}

resource "aws_s3_object" "s3_mount_dir" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "mount_dir"
  source     = "${path.module}/s3-artifacts/mount_dir"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.bucket_name
  ]
}

resource "local_file" "organization" {
  content  = local.organization
  filename = "${path.module}/s3-artifacts/organization"
}

resource "aws_s3_object" "s3_organization" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "organization"
  source     = "${path.module}/s3-artifacts/organization"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.bucket_name
  ]
}

resource "local_file" "region" {
  content  = local.region
  filename = "${path.module}/s3-artifacts/region"
}

resource "aws_s3_object" "s3_region" {
  bucket     = aws_s3_bucket.bootstrap.id
  key        = "region"
  source     = "${path.module}/s3-artifacts/region"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.region
  ]
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

resource "local_file" "hostname_to_instance_ids" {
  for_each = toset(local.hostnames)
  content  = ""
  filename = "${path.module}/s3-artifacts/${each.value}_to_instance_id"
}

resource "aws_s3_object" "s3_hostname_to_instance_ids" {
  bucket     = aws_s3_bucket.bootstrap.id

  for_each   = toset(local.hostnames)
  key        = "${each.value}_to_instance_id"
  source     = "${path.module}/s3-artifacts/${each.value}_to_instance_id"

  depends_on = [
    aws_s3_bucket.bootstrap,
    local_file.hostname_to_instance_ids
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_acl" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  #acl    = "private"
  acl    = "public-read"
}

resource "aws_s3_bucket_versioning" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  versioning_configuration {
    status = "Disabled"
  }
}

