resource "aws_security_group" "redpanda" {
  name        = "${local.subdomain}-redpanda"
  description = "allow ssh and redpanda external access"

  ingress {
     from_port   = 22
     to_port     = 22
     protocol    = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
     from_port   = 8081
     to_port     = 8081
     protocol    = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }

  ingress {
     from_port   = 8082
     to_port     = 8082
     protocol    = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }

  ingress {
     from_port   = 9092
     to_port     = 9092
     protocol    = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }

  ingress {
     from_port   = 9644
     to_port     = 9644
     protocol    = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }

  ingress {
     from_port   = 33145
     to_port     = 33145
     protocol    = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }

  egress {
     from_port   = 0
     to_port     = 0
     protocol    = "-1"
     cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_iam_policy" "redpanda" {
  name        = "${local.subdomain}-redpanda"
  path        = "/"
  policy      = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        "Effect": "Allow",
        "Action": [
          "ec2:AssociateAddress",
          "ec2:AttachVolume",
          "ec2:DescribeVolumeStatus",
          "ec2:CreateTags",
        ],
        "Resource": [
          "*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "redpanda" {
  name               = "${local.subdomain}-redpanda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Sid       = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy_attachment" "redpanda" {
  name       = "${local.subdomain}-redpanda"
  roles      = [aws_iam_role.redpanda.name]
  policy_arn = aws_iam_policy.redpanda.arn
}

resource "aws_iam_instance_profile" "redpanda" {
  name = "${local.subdomain}-redpanda"
  role = aws_iam_role.redpanda.name
}

resource "aws_launch_configuration" "redpanda" {
  name_prefix                 = "${local.subdomain}-redpanda"
  image_id                    = "ami-0568773882d492fc8"
  instance_type               = "i3.large"
  key_name                    = local.key_name
  iam_instance_profile        = aws_iam_instance_profile.redpanda.name
  security_groups             = [aws_security_group.redpanda.id]
  associate_public_ip_address = true # TODO is this needed with eip?
  user_data                   = templatefile("${path.module}/redpanda-node.sh", {
    BOOTSTRAP_URL = "http://bootstrap.${local.subdomain}.${local.domain}:3000"
  })
}

resource "aws_autoscaling_group" "redpanda" {
  availability_zones        = ["${local.availability_zone}"]
  name                      = "${local.subdomain}-redpanda"
  desired_capacity          = length(local.hostnames)
  min_size                  = length(local.hostnames)
  max_size                  = length(local.hostnames)
  health_check_grace_period = 30
  health_check_type         = "EC2"
  force_delete              = true
  termination_policies      = ["OldestInstance"]
  launch_configuration      = aws_launch_configuration.redpanda.id

  tag {
    key                 = "Name"
    value               = "${local.subdomain}-redpanda"
    propagate_at_launch = true
  }
}