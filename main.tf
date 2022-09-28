# variables
locals {
  hostnames         = ["rp0", "rp1", "rp2"]
  hostnames_string  = join(" ", local.hostnames)
  hostname_content  = ""
  domain            = "dev.vectorized.cloud"
  domain_zone_id    = "Z03100913AM3M9FSF30OG"
  subdomain         = "jlp"
  region            = "us-east-2"
  availability_zone = "us-east-2a"
  bucket_name       = "jlp-rp-bucket"
  cluster_id        = "jlp-cluster"
  nodejs_version    = "16.17.0"
  key_name          = "jlp"
}

# resource "aws_security_group" "redpanda_security_group" {
#   name        = "redpanda_security_group"
#   description = "allow ssh and redpanda external access"

#   ingress {
#      from_port   = 22
#      to_port     = 22
#      protocol    = "tcp"
#      cidr_blocks = ["0.0.0.0/0"]
#   }

#   ingress {
#      from_port   = 8081
#      to_port     = 8081
#      protocol    = "tcp"
#      cidr_blocks = ["0.0.0.0/0"]
#    }

#   ingress {
#      from_port   = 8082
#      to_port     = 8082
#      protocol    = "tcp"
#      cidr_blocks = ["0.0.0.0/0"]
#    }

#   ingress {
#      from_port   = 9092
#      to_port     = 9092
#      protocol    = "tcp"
#      cidr_blocks = ["0.0.0.0/0"]
#    }

#   ingress {
#      from_port   = 9644
#      to_port     = 9644
#      protocol    = "tcp"
#      cidr_blocks = ["0.0.0.0/0"]
#    }

#   egress {
#      from_port   = 0
#      to_port     = 0
#      protocol    = "-1"
#      cidr_blocks = ["0.0.0.0/0"]
#     }
# }

# resource "aws_launch_configuration" "aws_autoscale_conf" {
#   name            = "jlp-asg-config"
#   image_id        = "ami-0568773882d492fc8"
#   instance_type   = "i3.large"
#   key_name        = "jlp"
#   security_groups = [aws_security_group.redpanda_security_group.name]
#   user_data       = file("${path.module}/redpanda-node.sh")
# }

# resource "aws_autoscaling_group" "mygroup" {
#   availability_zones        = ["${local.availability_zone}"]
#   name                      = "jlp-asg"
#   max_size                  = 3
#   min_size                  = 3
#   desired_capacity          = 3
#   health_check_grace_period = 30
#   health_check_type         = "EC2"
#   force_delete              = true
#   termination_policies      = ["OldestInstance"]
#   launch_configuration      = aws_launch_configuration.aws_autoscale_conf.id

#   depends_on = [
#     aws_autoscaling_group.bootstrap_asg
#   ]

#   tag {
#     key                 = "Name"
#     value               = "jlp-redpanda"
#     propagate_at_launch = true
#   }
# }
