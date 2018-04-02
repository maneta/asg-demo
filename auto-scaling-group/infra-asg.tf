#Providers
provider "aws" {
  access_key = ""
  secret_key = ""
  region     = "eu-west-1"
}

#VPC
module "vpc" {
  source               = "github.com/terraform-aws-modules/terraform-aws-vpc"
  name                 = "virtual-subnet"
  cidr                 = "10.0.0.0/16"
  private_subnets      = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets       = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  enable_dns_hostnames = "true"
  enable_dns_support   = "true"
  azs                  = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
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
  vpc_security_group_ids = ["${aws_security_group.rds-sg.id}"]
  db_subnet_group_name   = "${aws_db_subnet_group.vpc.id}"
}

resource "aws_db_subnet_group" "vpc" {
  name        = "main_subnet_group"
  description = "Our main group of subnets"
  subnet_ids  = ["${element(module.vpc.private_subnets,0)}", "${element(module.vpc.private_subnets,1)}", "${element(module.vpc.private_subnets,2)}"]
}

#Security Group ASG Nodes
resource "aws_security_group" "nodes-sg" {
  name        = "nodes-sg"
  description = "Auto Scaling Nodes Security Group"
  vpc_id      = "${module.vpc.vpc_id}"

  tags {
    Name = "nodes-sg"
  }
}

#Rules Out Nodes
resource "aws_security_group_rule" "nodes-sg-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.nodes-sg.id}"
}

#Rule IN Nodes
resource "aws_security_group_rule" "nodes-sg-allow-ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.nodes-sg.id}"
}

#Rule IN Nodes
resource "aws_security_group_rule" "nodes-sg-allow-http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.nodes-sg.id}"
}

## Security Group for ELB
resource "aws_security_group" "elb" {
  name   = "wordpress-elb"
  vpc_id = "${module.vpc.vpc_id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elb" "wordpress-elb" {
  name = "wordpress-elb"

  # The same availability zone as our instances
  #availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  security_groups    = ["${aws_security_group.elb.id}"]
  subnets            = ["${element(module.vpc.public_subnets,0)}", "${element(module.vpc.public_subnets,1)}", "${element(module.vpc.public_subnets,2)}"]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }
}

resource "aws_autoscaling_group" "wordpress-asg" {
  availability_zones   = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  name                 = "wordpress-asg"
  max_size             = "5"
  min_size             = "1"
  force_delete         = true
  launch_configuration = "${aws_launch_configuration.wordpress-lc.name}"
  load_balancers       = ["${aws_elb.wordpress-elb.name}"]
  vpc_zone_identifier  = ["${element(module.vpc.public_subnets,0)}", "${element(module.vpc.public_subnets,1)}", "${element(module.vpc.public_subnets,2)}"]
  health_check_type    = "EC2"
  default_cooldown     = 300
  enabled_metrics      = ["GroupMinSize", "GroupMaxSize", "GroupDesiredCapacity", "GroupInServiceInstances", "GroupTotalInstances"]

  tag {
    key                 = "Name"
    value               = "wordpress-asg"
    propagate_at_launch = "true"
  }
}

resource "aws_launch_configuration" "wordpress-lc" {
  name                        = "wordpress-lc"
  image_id                    = "ami-f90a4880"
  instance_type               = "t2.micro"
  key_name                    = "redhat"
  associate_public_ip_address = true
  security_groups             = ["${aws_security_group.nodes-sg.id}"]

  user_data = <<EOF
#!/bin/bash -v

# Variables
WP_DOMAIN="${aws_elb.wordpress-elb.dns_name}"
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
  root_block_device {
    volume_type = "gp2"
    volume_size = "10"
  }

  lifecycle {
    create_before_destroy = true
  }

}

resource "aws_autoscaling_policy" "scale-up-policy" {
  name = "ASG Scale Up Policy"
  scaling_adjustment = 1
  adjustment_type = "ChangeInCapacity"
  cooldown = 120
  autoscaling_group_name = "${aws_autoscaling_group.wordpress-asg.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpu-up-alarm" {
  alarm_name = "cpu-up-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "1"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "60"
  statistic = "Average"
  threshold = "60"

  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.wordpress-asg.name}"
  }

  alarm_description = "This metric monitor EC2 instance cpu utilization"
  alarm_actions = ["${aws_autoscaling_policy.scale-up-policy.arn}"]
}

#
resource "aws_autoscaling_policy" "scale-down-policy" {
  name = "ASG Scale Down Policy"
  scaling_adjustment = -1
  adjustment_type = "ChangeInCapacity"
  cooldown = 300
  autoscaling_group_name = "${aws_autoscaling_group.wordpress-asg.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpu-down-alarm" {
  alarm_name = "cpu-down-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "300"
  statistic = "Average"
  threshold = "20"
  
  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.wordpress-asg.name}"
  }
  
  alarm_description = "This metric monitor EC2 instance cpu utilization"
  alarm_actions = ["${aws_autoscaling_policy.scale-down-policy.arn}"]
}
