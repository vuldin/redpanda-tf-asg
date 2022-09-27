# redpanda-tf-bash-deployment

This project provides a Terraform script to deploy Redpanda in AWS.

## Requirements

Terraform and an AWS account is required.

Details on installing Terraform can be found [here](https://www.terraform.io/downloads.html).

## Steps

Run the following command to initialize the Terraform modules, backend, and provider plugins.

```bash
terraform init
```

Copy the variable sample file:

```bash
cp terraform.tfvars.sample terraform.tfvars
```

Make changes to the newly-created file based on your environment.


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