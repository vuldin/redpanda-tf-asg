resource "aws_security_group" "bootstrap_security_group" {
  name = "${local.subdomain}_bootstrap_security_group"

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

resource "aws_iam_policy" "bootstrap_policy" {
  name        = "${local.subdomain}_bootstrap_policy"
  path        = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      // s3 object access
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
      // associate an elastic IP to this instance
      {
        "Effect": "Allow",
        "Action": [
          "ec2:AssociateAddress",
        ],
        "Resource": [
          "*",
        ]
      },
      /*
      // for assigning instance IP to route53
      {
        "Effect": "Allow",
        "Action": "ec2:DescribeTags",
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": "route53:ChangeResourceRecordSets",
        "Resource": "arn:aws:route53:::hostedzone/${aws_route53_zone.subdomain.id}"
      },
      */
    ]
  })
}

resource "aws_iam_role" "bootstrap_role" {
  name = "${local.subdomain}_bootstrap_role"

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

resource "aws_iam_policy_attachment" "bootstrap_policy_role" {
  name       = "${local.subdomain}_bootstrap_attachment"
  roles      = [aws_iam_role.bootstrap_role.name]
  policy_arn = aws_iam_policy.bootstrap_policy.arn
}

resource "aws_iam_instance_profile" "bootstrap_profile" {
  name = "${local.subdomain}_bootstrap_profile"
  role = aws_iam_role.bootstrap_role.name
}

resource "aws_launch_configuration" "bootstrap_launch_config" {
  name_prefix          = "${local.subdomain}-"
  image_id             = "ami-0f924dc71d44d23e2"
  instance_type        = "t2.micro"
  key_name             = local.key_name
  iam_instance_profile = aws_iam_instance_profile.bootstrap_profile.name
  security_groups      = [aws_security_group.bootstrap_security_group.id]
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/bootstrap-node.sh", {
    NODEJS_VERSION = local.nodejs_version
    BUCKET         = local.bucket_name
    ROLE           = aws_iam_role.bootstrap_role.name
    EIP            = aws_eip.bootstrap.public_ip
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bootstrap_asg" {
  availability_zones        = ["${local.availability_zone}"]
  name                      = "${local.subdomain}_bootstrap_asg"
  desired_capacity          = 1
  min_size                  = 1
  max_size                  = 1
  health_check_grace_period = 30
  health_check_type         = "EC2"
  force_delete              = true
  termination_policies      = ["OldestInstance"]
  launch_configuration      = aws_launch_configuration.bootstrap_launch_config.id

  depends_on = [
    aws_s3_bucket.bootstrap_bucket
  ]

  tag {
        key = "Name"
        value = "${local.subdomain}_bootstrap"
        propagate_at_launch = true
    }
}
