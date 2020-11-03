terraform {
  required_version = "> 0.13.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.0.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

provider "random" {}

## We generate a random s3-bucket suffix, this is to avoid collisions since AWS 
## s3 buckets are "global" to AWS, you can also use your own bucket name and
## remove this randomness alltogether
resource "random_pet" "bucket_suffix" {}

## AWS S3 Bucket
## Elastic beanstalk requires a S3 Bucket to host configuration files
resource "aws_s3_bucket" "beanstalk_scim" {
  bucket = "1password-scim-${random_pet.bucket_suffix.id}"
  acl    = "private"
}

resource "aws_s3_bucket_object" "docker_compose" {
  bucket = aws_s3_bucket.beanstalk_scim.bucket
  key    = "scim-1.6/docker-compose.yml"
  source = "docker-compose.yml"
  etag   = filemd5("docker-compose.yml")
}

resource "aws_elastic_beanstalk_application" "onepassword_scimbridge" {
  name        = "1password-scimbridge"
  description = "1Password SCIM bridge"
}

resource "aws_elastic_beanstalk_application_version" "scim_latest" {
  name        = "latest"
  application = aws_elastic_beanstalk_application.onepassword_scimbridge.name
  description = "Version latest of app ${aws_elastic_beanstalk_application.onepassword_scimbridge.name}"
  bucket      = aws_s3_bucket.beanstalk_scim.bucket
  key         = aws_s3_bucket_object.docker_compose.key
}

# Beanstalk instance profile
data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = ""
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "in_beanstalk_ec2" {
  name               = "1p-scimbridge-beanstalk-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_instance_profile" "in_beanstalk_ec2" {
  name = "1p-scimbridge-beanstalk-ec2-user"
  role = aws_iam_role.in_beanstalk_ec2.name
}

resource "aws_elastic_beanstalk_environment" "onepassword_scimbridge" {
  name         = "1password-scimbridge-test"
  application  = aws_elastic_beanstalk_application.onepassword_scimbridge.name
  cname_prefix = "1password-scimbridge"

  # To get the list of available solutions stack, aws-cli
  # aws elasticbeanstalk list-available-solution-stacks
  solution_stack_name = "64bit Amazon Linux 2 v3.2.0 running Docker"
  # solution_stack_name = "64bit Amazon Linux 2018.03 v2.22.1 running Multi-container Docker 19.03.6-ce (Generic)"
  version_label = aws_elastic_beanstalk_application_version.scim_latest.name

  # There are a LOT of settings, see here for the basic list:
  # https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/command-options-general.html

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.in_beanstalk_ec2.name
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = "t2.micro"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "LoadBalancerType"
    value     = "network"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment:process:HTTPS"
    name      = "Port"
    value     = "443"
  }

  setting {
    namespace = "aws:elbv2:listener:443"
    name      = "Protocol"
    value     = "TCP"
  }

  setting {
    namespace = "aws:elbv2:listener:443"
    name      = "DefaultProcess"
    value     = "HTTPS"
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "OP_LETSENCRYPT_DOMAIN"
    value     = "1password-scimbridge.us-east-1.elasticbeanstalk.com"
    // Self referencial failure
    //    value = aws_elastic_beanstalk_environment.onepassword_scimbridge.cname
  }
  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "EC2KeyName"
    value     = "p-a"
  }
}
