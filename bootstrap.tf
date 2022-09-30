resource "aws_security_group" "bootstrap" {
  name = "${local.subdomain}-bootstrap"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
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

resource "aws_iam_policy" "bootstrap" {
  name        = "${local.subdomain}-bootstrap"
  path        = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:PutObject",
        ],
        "Resource": [
          "arn:aws:s3:::${local.bucket_name}/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:AssociateAddress",
        ],
        "Resource": [
          "*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "bootstrap" {
  name = "${local.subdomain}-bootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy_attachment" "bootstrap" {
  name       = "${local.subdomain}-bootstrap"
  roles      = [aws_iam_role.bootstrap.name]
  policy_arn = aws_iam_policy.bootstrap.arn
}

resource "aws_iam_instance_profile" "bootstrap" {
  name = "${local.subdomain}-bootstrap"
  role = aws_iam_role.bootstrap.name
}

resource "aws_launch_configuration" "bootstrap" {
  name_prefix                 = "${local.subdomain}-bootstrap"
  image_id                    = "ami-0f924dc71d44d23e2"
  instance_type               = "t2.micro"
  key_name                    = local.key_name
  iam_instance_profile        = aws_iam_instance_profile.bootstrap.name
  security_groups             = [aws_security_group.bootstrap.id]
  associate_public_ip_address = true
  user_data                   = templatefile("${path.module}/bootstrap-node.sh", {
    NODEJS_VERSION = local.nodejs_version
    BUCKET         = local.bucket_name
    ROLE           = aws_iam_role.bootstrap.name
    EIP            = aws_eip.bootstrap.public_ip
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bootstrap" {
  availability_zones        = ["${local.availability_zone}"]
  name                      = "${local.subdomain}-bootstrap"
  desired_capacity          = 1
  min_size                  = 1
  max_size                  = 1
  health_check_grace_period = 30
  health_check_type         = "EC2"
  force_delete              = true
  termination_policies      = ["OldestInstance"]
  launch_configuration      = aws_launch_configuration.bootstrap.id

  depends_on = [
    aws_s3_bucket.bootstrap
  ]

  tag {
        key = "Name"
        value = "${local.subdomain}-bootstrap"
        propagate_at_launch = true
    }
}
