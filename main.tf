locals {
  hostnames         = ["rp0", "rp1", "rp2"]
  hostnames_string  = join(" ", local.hostnames)
  #hostname_content  = ""
  domain            = "dev.vectorized.cloud"
  domain_zone_id    = "Z03100913AM3M9FSF30OG"
  subdomain         = "jlp"
  region            = "us-east-2"
  availability_zone = "us-east-2a"
  bucket_name       = "jlp-rp-bucket"
  cluster_id        = "jlp-cluster"
  organization      = "jlp-org"
  mount_dir         = "/local/apps/redpanda"
  nodejs_version    = "16.17.0"
  key_name          = "jlp"
}
