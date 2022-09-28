resource "aws_route53_zone" "subdomain" {
  name         = "${local.subdomain}.${local.domain}"
  #private_zone = true
}

resource "aws_route53_record" "subdomain_ns" {
  zone_id = local.domain_zone_id
  name    = "${local.subdomain}.${local.domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.subdomain.name_servers
}

resource "aws_eip" "bootstrap" {
  tags = {
    Name = "${local.cluster_id}-bootstrap"
  }
}

resource "aws_route53_record" "bootstrap" {
  allow_overwrite = true
  name    = "bootstrap.${aws_route53_zone.subdomain.name}"
  zone_id = aws_route53_zone.subdomain.zone_id

  type    = "A"
  ttl     = 300
  records = ["${aws_eip.bootstrap.public_ip}"]
}
