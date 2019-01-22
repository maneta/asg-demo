#Providers
provider "aws" {
  access_key = "YOUR_ACCESS_ID_KEY_HERE"
  secret_key = "YOUR_SECRET_KEY_HERE"
  region     = "eu-west-1"
}

#VPC
module "vpc" {
  source = "github.com/terraform-aws-modules/terraform-aws-vpc"
  name = "virtual-subnet"
  cidr = "10.0.0.0/16"
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  enable_dns_hostnames = "true"
  enable_dns_support = "true"
  azs = ["eu-west-1a","eu-west-1b","eu-west-1c"]
}
#Security Group RDS Nodes
resource "aws_security_group" "rds-sg" {
  name        = "rds-sg"
  description = "RDS Security Group"
  vpc_id      = "${module.vpc.vpc_id}"

  tags {
    Name = "rds-sg"
  }
}

#Rules Out RDS
resource "aws_security_group_rule" "rds-sg-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.rds-sg.id}"
}

#Rule IN RDS
resource "aws_security_group_rule" "rds-nodes-allow" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.nodes-sg.id}"
  security_group_id        = "${aws_security_group.rds-sg.id}"
}

#Create RDS Instance
resource "aws_db_instance" "rds-wordpress" {
  depends_on             = ["aws_security_group.rds-sg"]
  identifier             = "wordpress"
  allocated_storage      = 10
  storage_type           = "gp2"
  engine                 = "mysql"
  engine_version         = "5.7"
  instance_class         = "db.t2.micro"
  name                   = "wordpress"
  username               = "wordpress"
  password               = "wordpress"
  skip_final_snapshot    = true
  vpc_security_group_ids = ["${aws_security_group.rds-sg.id}"]
  db_subnet_group_name   = "${aws_db_subnet_group.vpc.id}"
}

resource "aws_db_subnet_group" "vpc" {
  name        = "main_subnet_group"
  description = "Our main group of subnets"
  subnet_ids  = ["${element(module.vpc.private_subnets,0)}", "${element(module.vpc.private_subnets,1)}", "${element(module.vpc.private_subnets,2)}"]
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
  ami                         = "AMI-ID"
  instance_type               = "t2.micro"
  key_name                    = "YOUR-KEY-NAME"
  vpc_security_group_ids      = ["${aws_security_group.nodes-sg.id}"]
  associate_public_ip_address = true
  availability_zone           = "eu-west-1a"
  subnet_id                   = "${element(module.vpc.public_subnets,0)}"
  user_data = <<EOF
#!/bin/bash -v

# Variables
WP_DOMAIN=`curl http://169.254.169.254/latest/meta-data/public-hostname`
WP_ADMIN_USERNAME="admin"
WP_ADMIN_PASSWORD="admin"
WP_ADMIN_EMAIL="no@spam.org"
WP_DB_NAME="wordpress"
WP_DB_USERNAME="wordpress"
WP_DB_PASSWORD="wordpress"
WP_DB_HOST="${aws_db_instance.rds-wordpress.address}"
WP_PATH="/var/www/wordpress"

# Install software
apt-get update
apt install -y nginx php php-mysql php-curl php-gd

# Configure web server
mkdir -p $WP_PATH/public $WP_PATH/logs
tee /etc/nginx/sites-available/$WP_DOMAIN <<END_OF_FILE
server {
  listen 80;
  server_name _;

  root $WP_PATH/public;
  index index.php;

  access_log $WP_PATH/logs/access.log;
  error_log $WP_PATH/logs/error.log;

  location / {
    try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php7.0-fpm.sock;
  }
}
END_OF_FILE

sed -i -e '/server_names_hash_bucket_size/s/# server_names_hash_bucket_size 64/server_names_hash_bucket_size 128/' /etc/nginx/nginx.conf
ln -s /etc/nginx/sites-available/$WP_DOMAIN /etc/nginx/sites-enabled/$WP_DOMAIN
unlink /etc/nginx/sites-enabled/default
systemctl restart nginx

# Install WordPress
rm -rf $WP_PATH/public/
mkdir -p $WP_PATH/public/
cd $WP_PATH/public/

wget https://wordpress.org/latest.tar.gz
tar xf latest.tar.gz --strip-components=1
rm latest.tar.gz

mv wp-config-sample.php wp-config.php
sed -i s/database_name_here/$WP_DB_NAME/ wp-config.php
sed -i s/username_here/$WP_DB_USERNAME/ wp-config.php
sed -i s/password_here/$WP_DB_PASSWORD/ wp-config.php
sed -i s/localhost/$WP_DB_HOST/ wp-config.php
echo "define('FS_METHOD', 'direct');" >> wp-config.php

chown -R www-data:www-data $WP_PATH/public/

# Configure WordPress admin
curl "http://$WP_DOMAIN/wp-admin/install.php?step=2" \
--data-urlencode "weblog_title=$WP_DOMAIN" \
--data-urlencode "user_name=$WP_ADMIN_USERNAME" \
--data-urlencode "admin_email=$WP_ADMIN_EMAIL" \
--data-urlencode "admin_password=$WP_ADMIN_PASSWORD" \
--data-urlencode "admin_password2=$WP_ADMIN_PASSWORD" \
--data-urlencode "pw_weak=1"

EOF

  tags {
    Name         = "asg-node"
   }

  root_block_device {
    volume_type = "gp2"
    volume_size = "10"
  }
}
