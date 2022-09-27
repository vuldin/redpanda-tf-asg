resource "local_file" "bucket_name" {
  content  = local.bucket_name
  filename = "${path.module}/s3-artifacts/bucket_name"
}

resource "aws_s3_object" "s3_bucket_name" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id
  key        = "bucket_name"
  source     = "${path.module}/s3-artifacts/bucket_name"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.bucket_name
  ]
}

resource "local_file" "cluster_id" {
  content  = local.cluster_id
  filename = "${path.module}/s3-artifacts/cluster_id"
}

resource "aws_s3_object" "s3_cluster_id" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id
  key        = "cluster_id"
  source     = "${path.module}/s3-artifacts/cluster_id"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.cluster_id
  ]
}

resource "local_file" "domain" {
  content  = local.domain
  filename = "${path.module}/s3-artifacts/domain"
}

resource "aws_s3_object" "s3_domain" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id
  key        = "domain"
  source     = "${path.module}/s3-artifacts/domain"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.domain
  ]
}

resource "local_file" "hostnames" {
  content  = local.hostnames_string
  filename = "${path.module}/s3-artifacts/hostnames"
}

resource "aws_s3_object" "s3_hostnames" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id
  key        = "hostnames"
  source     = "${path.module}/s3-artifacts/hostnames"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.hostnames
  ]
}

resource "local_file" "region" {
  content  = local.region
  filename = "${path.module}/s3-artifacts/region"
}

resource "aws_s3_object" "s3_region" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id
  key        = "region"
  source     = "${path.module}/s3-artifacts/region"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.region
  ]
}

resource "local_file" "hostname_objects" {
  content = local.hostname_content

  for_each = toset(local.hostnames)
  filename = "${path.module}/s3-artifacts/${each.value}"
}

resource "aws_s3_object" "s3_hostname_objects" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id

  for_each   = toset(local.hostnames)
  key        = "${each.value}"
  source     = "${path.module}/s3-artifacts/${each.value}"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.hostname_objects
  ]
}

resource "local_file" "hostnames_to_volume_ids" {
  for_each = toset(local.hostnames)
  content = aws_ebs_volume.redpanda_volumes["${each.value}"].id
  filename = "${path.module}/s3-artifacts/${each.value}_to_volume_id"
}

resource "aws_s3_object" "s3_hostname_to_volume_ids" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id

  for_each   = toset(local.hostnames)
  key        = "${each.value}_to_volume_id"
  source     = "${path.module}/s3-artifacts/${each.value}_to_volume_id"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.hostnames_to_volume_ids
  ]
}

resource "local_file" "hostname_to_instance_ids" {
  for_each = toset(local.hostnames)
  content  = ""
  filename = "${path.module}/s3-artifacts/${each.value}_to_instance_id"
}

resource "aws_s3_object" "s3_hostname_to_instance_ids" {
  bucket     = aws_s3_bucket.bootstrap_bucket.id

  for_each   = toset(local.hostnames)
  key        = "${each.value}_to_instance_id"
  source     = "${path.module}/s3-artifacts/${each.value}_to_instance_id"

  depends_on = [
    aws_s3_bucket.bootstrap_bucket,
    local_file.hostname_to_instance_ids
  ]
}

resource "aws_s3_bucket" "bootstrap_bucket" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_acl" "bootstrap_bucket_acl" {
  bucket = aws_s3_bucket.bootstrap_bucket.id
  #acl    = "private"
  acl    = "public-read"
}

resource "aws_s3_bucket_versioning" "bootstrap_bucket_versioning" {
  bucket = aws_s3_bucket.bootstrap_bucket.id
  versioning_configuration {
    status = "Disabled"
  }
}

