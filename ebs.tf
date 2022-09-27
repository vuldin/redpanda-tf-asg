resource "aws_ebs_volume" "redpanda_volumes" {
  for_each          = toset(local.hostnames)
  availability_zone = local.availability_zone
  iops              = 3000
  size              = 40
  type              = "gp3"
  throughput        = 125

  tags = {
    Name = "${each.value}"
  }
}
