terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.66"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-2"
}

#This specifies how to configure each EC2 instance in the AutoScalingGroup
resource "aws_launch_configuration" "example" {
  image_id        = "ami-0fb653ca2d3203ac1"
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instance.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              nohup busybox httpd -f -p ${var.server_port} &
              EOF

  # Required when using a launch configuration with an auto scaling group.
  lifecycle {
    create_before_destroy = true
  }
}


/*
An ASG takes care of a lot of tasks completely automatically,
including launching a cluster of EC2 Instances,
monitoring the health of each Instance, replacing failed Instances,
and adjusting the size of the cluster in response to load.
*/
resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnets.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = 2
  max_size = 10

  tag {
    key                 = "Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }
}

/*
By default, AWS does not allow any incoming or outgoing traffic from an EC2
Instance. To allow the EC2 Instance to receive traffic on port 8080, you
need to create a security group
*/
resource "aws_security_group" "instance" {
  name = var.instance_security_group_name

  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]# is an IP address range that includes all possible IP addresses 
  }
}

#Here, we're querying AWS to look up the data for our Default VPC
data "aws_vpc" "default" {
  default = true
}

/*
AWS load balancers don’t consist of a single server, but of
multiple servers that can run in separate subnets (and, therefore, separate
datacenters).
*/
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "example" {
  name               = var.alb_name

  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids //Will use all the subnets in our Default VPC
  security_groups    = [aws_security_group.alb.id]
}

/*
This listener configures the ALB to listen on the default HTTP port, port
80, use HTTP as the protocol, and send a simple 404 page as the default
response for requests that don’t match any listener rules.
*/
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = 80
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

/*
This target group will health check your Instances by periodically sending
an HTTP request to each Instance and will consider the Instance “healthy”
only if the Instance returns a response that matches the configured
matcher (e.g., you can configure a matcher to look for a 200 OK
response).
*/
resource "aws_lb_target_group" "asg" {

  name = var.alb_name

  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

/*
Takes requests that come into a listener and sends those that match
specific paths (e.g., /foo and /bar) or hostnames (e.g.,
foo.example.com and bar.example.com) to specific target
groups.
*/
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

/*
This security group should allow incoming
requests on port 80 so that you can access the load balancer over HTTP, and
allow outgoing requests on all ports so that the load balancer can perform
health checks
*/
resource "aws_security_group" "alb" {

  name = var.alb_security_group_name

  # Allow inbound HTTP requests
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound requests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}