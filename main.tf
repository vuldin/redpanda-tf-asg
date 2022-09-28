# variables
locals {
  hostnames         = ["apple", "bacon", "carrot"]
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

# TODO
# resource "aws_security_group" "redpanda_nodeport_access" {
#   count       = var.enable_external_connectivity ? 1 : 0
#   name_prefix = "rp_node_access"
#   vpc_id      = module.vpc.vpc_id
#   description = "Allows access to the redpanda nodeport services"

#   ingress {
#     from_port = 30000
#     to_port   = 32767
#     protocol  = "tcp"

#     cidr_blocks = ["0.0.0.0/0"]
#   }
# }

# resource "aws_security_group" "redpanda_security_group" {
#   # TODO implement enable_external_connectivity variable
#   #count       = var.enable_external_connectivity ? 1 : 0
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

# DNS via Route 53
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record
# data "aws_route53_zone" "selected" {
#   name         = "test.com."
#   private_zone = true
# }

# resource "aws_route53_record" "www" {
#   zone_id = aws_route53_zone.primary.zone_id
#   name    = "www.example.com"
#   type    = "A"
#   ttl     = 300
#   records = [aws_eip.lb.public_ip]
# }

# Creating the autoscaling launch configuration that contains AWS EC2 instance details
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_configuration
# resource "aws_launch_configuration" "aws_autoscale_conf" {
#   name            = "jlp-asg-config"
#   image_id        = "ami-0568773882d492fc8"
#   instance_type   = "i3.large"
#   #key_name        = "jlp"
#   security_groups = [aws_security_group.redpanda_security_group.name]
#   user_data       = file("${path.module}/redpanda-node.sh")

#   lifecycle {
#     create_before_destroy = true
#   }
# }

# # Creating the autoscaling group within us-east-1a availability zone
# # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group
# resource "aws_autoscaling_group" "mygroup" {
#   availability_zones        = ["${local.availability_zone}"]
#   name                      = "jlp-asg"
#   max_size                  = 4
#   min_size                  = 3
#   desired_capacity          = 3
#   #health_check_grace_period = 300
#   health_check_type         = "EC2"
#   force_delete              = true
#   termination_policies      = ["OldestInstance"]
#   launch_configuration      = aws_launch_configuration.aws_autoscale_conf.id
#
#   # TODO make asg depend on bootstrap instance
#   #depends_on = [
#   #  ec2_instance.?
#   #]
#
#   tag {
#         key = "Name"
#         value = "jlp-redpanda"
#         propagate_at_launch = true
#     }
# }

# # Creating the autoscaling schedule of the autoscaling group
# resource "aws_autoscaling_schedule" "mygroup_schedule" {
#   scheduled_action_name  = "autoscalegroup_action"
#   # The minimum size for the Auto Scaling group
#   min_size               = 1
#   # The maxmimum size for the Auto Scaling group
#   max_size               = 2
#   # Desired_capacity is the number of running EC2 instances in the Autoscaling group
#   desired_capacity       = 1
#   # defining the start_time of autoscaling if you think traffic can peak at this time.
#   start_time             = "2022-09-23T08:18:32Z"
#   autoscaling_group_name = aws_autoscaling_group.mygroup.name
# }

# # Creating the autoscaling policy of the autoscaling group
# resource "aws_autoscaling_policy" "mygroup_policy" {
#   name                   = "autoscalegroup_policy"
#   # The number of instances by which to scale.
#   scaling_adjustment     = 2
#   adjustment_type        = "ChangeInCapacity"
#   # The amount of time (seconds) after a scaling completes and the next scaling starts.
#   cooldown               = 300
#   autoscaling_group_name = aws_autoscaling_group.mygroup.name
# }

# # Creating the AWS CLoudwatch Alarm that will autoscale the AWS EC2 instance based on CPU utilization.
# resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_up" {
#   # defining the name of AWS cloudwatch alarm
#   alarm_name          = "web_cpu_alarm_up"
#   comparison_operator = "GreaterThanOrEqualToThreshold"
#   evaluation_periods  = "2"
#   # Defining the metric_name according to which scaling will happen (based on CPU) 
#   metric_name         = "CPUUtilization"
#   # The namespace for the alarm's associated metric
#   namespace           = "AWS/EC2"
#   # After AWS Cloudwatch Alarm is triggered, it will wait for 60 seconds and then autoscales
#   period              = "60"
#   statistic           = "Average"
#   # CPU Utilization threshold is set to 10 percent
#   threshold           = "10"
#   alarm_actions       = ["${aws_autoscaling_policy.mygroup_policy.arn}"]
#   dimensions          = {
#     AutoScalingGroupName = "${aws_autoscaling_group.mygroup.name}"
#   }
# }
