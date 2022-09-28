# redpanda-tf-bash-deployment

This project provides a Terraform script to deploy Redpanda in AWS.

## Requirements

Terraform and an AWS account is required.

Details on installing Terraform can be found [here](https://www.terraform.io/downloads.html).

## Variables

Copy the variable sample file:

```bash
cp terraform.tfvars.sample terraform.tfvars
```

Make changes to the newly-created file based on your environment. Here are some notes on each variable:

`hostnames         = ["rp0", "rp1", "rp2"]`
Determines how many redpanda nodes are deployed and each node's hostname.

`subdomain         = "jlp"`
This is the subdomain, which will be dedicated to this deployment's resources (bootstrap service, health check service, Redpanda nodes).

`domain            = "dev.vectorized.cloud"`
This domain must already exist, and be the same domain connected to `domain_zone_id` below. Each Redpanda node will have a resolvable name based on <hostname>.<subdomain>.<domain>.

`domain_zone_id    = "Z03100913AM3M9FSF30OG"`
Open AWS Console in your browser, then go to Route53 > Hosted zones. Select the domain you want to create a subdomain on (the same domain used in the `domain` variable above), then expand `Hosted zone details` to find the zone ID used here.

`key_name          = "jlp"`
This key name points to the existing key in AWS that is used for providing SSH access to each instance.

`nodejs_version    = "16.17.0"`
Nodejs is used in the bootstrap service to create the REST API used by Redpanda instances to determine which EBS volume they connect to, which node is leader, etc.

`bucket_name       = "jlp-rp-bucket"`
This S3 bucket is used to store various state used by the bootstrap service.

`region            = "us-east-2"`
`availability_zone = "us-east-2a"`
`cluster_id        = "jlp-cluster"`

## Steps

Run the following command to initialize the Terraform modules, backend, and provider plugins.

```bash
terraform init
```

Optionally, you can show the required changes based on your current configuration:

```bash
terraform plan
```

Once you are ready, run the following command to create/update the infrastructure, deploy Redpanda, and configure the nodes:

```bash
terraform apply
```

## Clean up

```bash
terraform destroy
```