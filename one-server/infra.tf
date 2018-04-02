#Providers
provider "aws" {
  access_key = ""
  secret_key = ""
  region     = "eu-west-1"
}

#VPC
module "vpc" {
  source = "github.com/terraform-community-modules/tf_aws_vpc"
  name = "virtual-subnet"
  cidr = "10.0.0.0/16"
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  enable_dns_hostnames = "true"
  enable_dns_support = "true"
  azs = ["eu-west-1a","eu-west-1b","eu-west-1c"]
}

#Security Group
resource "aws_security_group" "nodes-sg" {
  name        = "nodes-sg"
  description = "Auto Scaling Nodes Security Group"
  vpc_id      = "${module.vpc.vpc_id}"

  tags {
    Name         = "nodes-sg"
    }
}

#Rules Out
resource "aws_security_group_rule" "nodes-sg-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.nodes-sg.id}"
}

#Rule IN
resource "aws_security_group_rule" "nodes-sg-allow-ssh"{
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.nodes-sg.id}"
}

#Rule IN
resource "aws_security_group_rule" "nodes-sg-allow-http"{
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.nodes-sg.id}"
}

#Create Machine
resource "aws_instance" "asg-node" {
  ami                         = "ami-f90a4880"
  instance_type               = "t2.micro"
  key_name                    = "redhat"
  vpc_security_group_ids      = ["${aws_security_group.nodes-sg.id}"]
  associate_public_ip_address = true
  user_data                   = "${file("wp-install.sh")}"
  availability_zone           = "eu-west-1a"
  subnet_id                   = "${element(module.vpc.public_subnets,0)}"

  tags {
    Name         = "asg-node"
   }

  root_block_device {
    volume_type = "gp2"
    volume_size = "10"
  }
}
