
provider "aws" {
  region  = var.aws_region
}

resource "aws_ecs_cluster" "test" {
  name = "ECS-Fargate-Demo"
}

resource "aws_ecs_task_definition" "service" {
  family = "fisrt-ecs_task_definition-by-terrafom"

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024 //256 
  memory                   = 2048 //512
  execution_role_arn = "arn:aws:iam::Account-ID:role/ecsTaskExecutionRole"
  task_role_arn      = "arn:aws:iam::Account-ID:role/ecsTaskRole"

  volume {
    name = "EFS-storage-demo"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.efs.id
      root_directory          = "/opt/data"
      transit_encryption      = "ENABLED"
      transit_encryption_port = 2999
      authorization_config {
        access_point_id = aws_efs_access_point.test.id
        iam             = "ENABLED"  
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name1
      image     = var.image2
      cpu       = 256
      memory    = 512
      essential = true

      mountPoints = [
        {
          containerPath =  "/efs-share"
          sourceVolume  = "EFS-storage-demo"
        }
      ] 

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
        }
      ] 
      
    } /* , 
     {
      name      = var.container_name2
      image     = var.image2
      cpu       = 256
      memory    = 512
      essential = true
      
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
        }
      ] 
      
    }, */

  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

}

resource "aws_ecs_cluster_capacity_providers" "example" {
  cluster_name = aws_ecs_cluster.test.name

  capacity_providers = ["FARGATE","FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 0
    weight            = 1
    capacity_provider = "FARGATE"
  }
  default_capacity_provider_strategy {
    base              = 0
    weight            = 1
    capacity_provider = "FARGATE_SPOT"
  }
}


resource "aws_ecs_service" "fargate_service" {
  name            = "ecs_service_from_terraform"
  cluster         = aws_ecs_cluster.test.id
  task_definition = aws_ecs_task_definition.service.arn
  desired_count   = 1
  force_new_deployment = true
  //launch_type = "FARGATE"

  network_configuration {
    subnets = ["${module.vpc.private_subnets[0]}"]
    security_groups = ["${module.ecs-security_group.security_group_id}"]
    assign_public_ip = false 
  }

 load_balancer {
    target_group_arn = aws_lb_target_group.ip-example.arn
    container_name   = var.container_name2
    container_port   = 8000
  } 

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base = 1
    weight = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base = 0
    weight = 2
  }

}

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 2
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.test.name}/${aws_ecs_service.fargate_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}


resource "aws_appautoscaling_policy" "ecs_policy_target_cpu" {
  name               = "scale-up"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
  }

    target_value       = 20
    scale_in_cooldown  = 60
    scale_out_cooldown = 500
  }
}


resource "aws_lb" "test" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${module.alb_security_group.security_group_id}"]
  subnets            = ["${module.vpc.public_subnets[0]}","${module.vpc.public_subnets[1]}"]

  enable_deletion_protection = false

  tags = {
    Name        = "Application-load_balancer"
    Environment = "production"
  }
}


resource "aws_lb_target_group" "ip-example" {
  name        = "tf-demo-alb-target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${module.vpc.vpc_id}"
}


resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.test.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ip-example.arn
  }
}


resource "aws_lb_listener_rule" "static" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ip-example.arn
  }

  condition {
    path_pattern {
      values = ["/fargate/*"]
    }
  }

}

resource "aws_ecr_repository" "app_image" {
  name                 = "ecr-x"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
    
  }
}

resource "aws_codecommit_repository" "docker_repo" {
  repository_name = "MyDockerRepo"
}

# Create a json file for CodeBuild's policy
data "aws_iam_policy_document" "CodeBuild_AssumeRole_policy" {
  statement {
        effect  = "Allow"
        actions = ["sts:AssumeRole"]

        principals {
            type = "Service"
            identifiers = ["codebuild.amazonaws.com"]
        }
    }
  
}

data "aws_iam_policy_document" "CodeBuild_policy" {
    statement {
        sid     = "CodeCommitPolicy"
        effect  = "Allow"
        actions = [
            "codecommit:GitPull"
            ]
            
        resources = ["*"]
    }
    statement {
        sid     = "CloudWatchLogsPolicy"
        effect  = "Allow"
        actions = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
            ]
            
        resources = ["*"]
    }
    statement {
        sid     = "ECRAuthPolicy"
        effect  = "Allow"
        actions = [
            "ecr:GetAuthorizationToken"
            ]
            
        resources = ["*"]
    }
    statement {
        sid     = "ECRPullPolicy"
        effect  = "Allow"
        actions = [
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage"
            ]
            
        resources = ["*"]
    }
    statement {
        sid     = "S3BucketIdentity"
        effect  = "Allow"
        actions = [
            "s3:GetBucketAcl",
            "s3:GetBucketLocation"
            ]
            
        resources = ["*"]
    }
    statement {
        sid     = "S3PutObjectPolicy"
        effect  = "Allow"
        actions = [
            "s3:PutObject"
            ]
            
        resources = ["*"]
    }
    statement {
        sid     = "S3GetObjectPolicy"
        effect  = "Allow"
        actions = [
            "s3:GetObject",
            "s3:GetObjectVersion"
            ]
            
        resources = ["*"]
    }
}

# Create CodeBuild policy
resource "aws_iam_role_policy" "attach_Codebuild_policy" {
    name = "CodeBuildServiceRolePolicy"
    role = aws_iam_role.role.name

    policy = data.aws_iam_policy_document.CodeBuild_policy.json

}

resource "aws_iam_role" "role" {
  name = "CodeBuildServiceRole"
  assume_role_policy = data.aws_iam_policy_document.CodeBuild_AssumeRole_policy.json
}

data "aws_iam_policy" "example" {
  arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "test-attach" {
  role       = aws_iam_role.role.name
  policy_arn = "${data.aws_iam_policy.example.arn}"
}


# Create CodeBuild project
resource "aws_codebuild_project" "build_project" {
    name          = "ecs_fargate"
    description   = "CodeBuild project for ECS Fargate"
    service_role  = aws_iam_role.role.arn
    build_timeout = "300"

    artifacts {
        type = "S3"
        location = module.s3_bucket.s3_bucket_id
    }

    environment {
        compute_type = "BUILD_GENERAL1_SMALL"
        image = "aws/codebuild/standard:5.0"
        type = "LINUX_CONTAINER"
        image_pull_credentials_type = "CODEBUILD"
        privileged_mode = true
    }

    source {
        type       = "CODECOMMIT"
        location   = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/xxxxxxx"
    }

    source_version = "refs/heads/master"
    
    
    tags = {
        ManagedBy = "Terraform"
  }
}


module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = var.bucket_name // S3 Bucket (Artifact Storage)
  acl    = "private"

  # S3 bucket-level Public Access Block configuration
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  force_destroy           = true

  versioning = {
    enabled = true
  }

 // attach_policy = true    
 // policy    = data.aws_iam_policy_document.bucket_policy.json

  tags = {
    ManagedBy = "Terraform"
  }

}

module "s3_bucket_2" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = var.bucket_name2 // s3 bucket for ecs cluster
  acl    = "public-read-write"

  # S3 bucket-level Public Access Block configuration
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false

  force_destroy           = true

  versioning = {
    enabled = true
  }

 // attach_policy = true    
 // policy    = data.aws_iam_policy_document.bucket_policy.json

  tags = {
    ManagedBy = "Terraform"
  }

}

/*
data "aws_iam_policy_document" "bucket_policy" {

 policy_id = "Access-to-bucket-using-specific-endpoint"

 statement {
  
    sid       = "Access-to-specific-VPCE-only"
    effect    = "Allow"
    actions   = [
          "s3:*"
    ]
    resources = [
      "${module.s3_bucket_2.s3_bucket_arn}",
      "${module.s3_bucket_2.s3_bucket_arn}/*"
      ]

    principals {
      type = "AWS"
      identifiers = ["*"]
    }

   condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpce"
      values   = [
        "${aws_vpc_endpoint.s3.id}",
        "vpce-021ae36332cf55766",
        "vpce-0f778b40fa9677678"
        ]
      
    } 

  //}

  */

/*  statement {
  
    sid       = "Access-to-specific-VPCE-only-2"
    effect    = "Allow"
    actions   = [
          "s3:GetObject",
          "s3:PutObject"
    ]
    resources = [
      "${module.s3_bucket_2.s3_bucket_arn}",
      "${module.s3_bucket_2.s3_bucket_arn}/*"
      ]

    principals {
      type = "Service"
      identifiers = ["*"]
    }
  } 


}

*/

# Create a json file for CodePipeline's policy
data "aws_iam_policy_document" "codepipeline_assume_policy" {
    statement {
        effect = "Allow"
        actions = ["sts:AssumeRole"]

        principals {
            type = "Service"
            identifiers = ["codepipeline.amazonaws.com"]
        }
    }
}

# Create a role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
    name = "ecs-codepipeline-role"
    assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_policy.json
}


# Create a json file for CodePipeline's policy needed to use GitHub and CodeBuild
data "aws_iam_policy_document" "codepipeline_policy" {

  statement {

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject"
    ]

    resources = ["${module.s3_bucket.s3_bucket_arn}",
                 "${module.s3_bucket.s3_bucket_arn}/*"]
  }

  statement{
    
    effect = "Allow"
    
    actions  = [  
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:UploadArchive",
      "codecommit:GetUploadArchiveStatus",      
      "codecommit:CancelUploadArchive"
            ]

    resources = ["*"]
  }

  statement {

    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild"
    ]

    resources = ["*"]
      
    }

    statement {

    effect = "Allow"

    actions = [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:*"
    ]

    resources = ["*"]
      
    }
    
    statement {

    effect = "Allow"

    actions = [
        "iam:PassRole"
    ]

    resources = [
      "arn:aws:iam::Account-ID:role/ecsTaskExecutionRole",
      "arn:aws:iam::Account-ID:role/ecsTaskRole"
      ]
      
    }
  
}


# CodePipeline policy needed to use GitHub and CodeBuild
resource "aws_iam_role_policy" "attach_codepipeline_policy" {

    name = "ecs-codepipeline-policy"
    role = "${aws_iam_role.codepipeline_role.id}"

    policy = data.aws_iam_policy_document.codepipeline_policy.json

}

# Create CodePipeline
resource "aws_codepipeline" "codepipeline" {
 
    name     = "ecs-codepipeline"
    role_arn = aws_iam_role.codepipeline_role.arn

    artifact_store {

        location = module.s3_bucket.s3_bucket_id
        type     = "S3"
    }

    stage {

        name = "Source"

        action {
            name     = "Source"
            category = "Source"
            owner    = "AWS"
            provider = "CodeCommit"
            version  = "1"
            output_artifacts = ["SourceArtifact"]

            configuration = {            
                RepositoryName = "RepositoryName"
                BranchName       = "master"
                PollForSourceChanges = true 
            }
        }
    }

    stage {
        name = "Build"

        action {
            name     = "Build"
            category = "Build"
            owner    = "AWS"
            provider = "CodeBuild"
            input_artifacts  = ["SourceArtifact"]
            output_artifacts = ["OutputArtifact"]
            version = "1"

            configuration = {
                ProjectName = aws_codebuild_project.build_project.name
            }
        }
    }

    stage {
        name = "Deploy"

        action {
            name     = "Deploy"
            category = "Deploy"
            owner    = "AWS"
            provider = "ECS"
            input_artifacts = ["OutputArtifact"]
            version = "1"
            
            configuration = {
                ClusterName = "ECS-Fargate-Demo"
                ServiceName = "ecs_service_from_terraform"
                FileName    = "imagedefinitions.json"
            }
        }
    }

  tags = {
    ManagedBy = "Terraform"
  }

}

module "endpoints" {
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = ["${module.interface_endpoints_security_group.security_group_id}"]

  endpoints = {
    s3 = {
      # gateway endpoint
      service             = "s3"
      service_type    = "Gateway"
      route_table_ids = "${module.vpc.private_route_table_ids}"
      policy          = data.aws_iam_policy_document.s3_endpoint_policy.json
      tags                = { Name = "s3-vpc-endpoint", ManagedBy = "Terraform" }
    },
    dynamodb = {
      # gateway endpoint
      service         = "dynamodb"
      service_type    = "Gateway"
      route_table_ids = "${module.vpc.private_route_table_ids}"
      policy          = data.aws_iam_policy_document.dynamodb_endpoint_policy.json
      tags            = { Name = "dynamodb-vpc-endpoint", ManagedBy = "Terraform" }
    },
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
     // policy              = data.aws_iam_policy_document.interface_endpoint_policy.json
    },
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
     // policy              = data.aws_iam_policy_document.interface_endpoint_policy.json
    }
  }
}


data "aws_iam_policy_document" "s3_endpoint_policy" {
  statement {
    sid = "AccessToSpecificBucket"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

data "aws_iam_policy_document" "dynamodb_endpoint_policy" {
  statement {
    sid       = "AccessToSpecificTable"
    effect    = "Allow"
    actions   = [
          "dynamodb:Batch*",
          "dynamodb:Delete*",
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Update*",
          "dynamodb:ListTables"
    ]
    resources = [
          "arn:aws:dynamodb:us-east-1:Account-ID:table/the_last_dinner",
          "arn:aws:dynamodb:us-east-1:Account-ID:table/the_last_dinner/*"
        ] 

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}


resource "aws_dynamodb_table" "basic-dynamodb-table" {
  name           = "the_last_dinner"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "UserId"

  attribute {
    name = "UserId"
    type = "S"
  }

  tags = {
    ManagedBy = "Terraform"
  }
}


data "aws_iam_policy_document" "dynamodb_assume_policy" {
    statement {
        effect = "Allow"
        actions = ["sts:AssumeRole"]

        principals {
            type = "Service"
            identifiers = ["dynamodb.amazonaws.com"]
        }
    }
}


resource "aws_iam_role" "dynamodb_role" {
    name = "dynamodb-role"
    assume_role_policy = data.aws_iam_policy_document.dynamodb_assume_policy.json
}


resource "aws_efs_file_system" "efs" {
  creation_token = "efs"

  tags = {
     Name      = "EFS-production"
     ManagedBy = "Terraform"
  }
}

resource "aws_efs_mount_target" "mount_target_az1" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = "${module.vpc.private_subnets[0]}"
  security_groups = ["${module.efs-security_group.security_group_id}"]
}

resource "aws_efs_mount_target" "mount_target_az2" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = "${module.vpc.private_subnets[1]}"
  security_groups = ["${module.efs-security_group.security_group_id}"]
}

resource "aws_efs_access_point" "test" {
  file_system_id = aws_efs_file_system.efs.id

  posix_user {
    uid = "1000"
    gid = "1000"
  }
  root_directory {
    path          = "/ecs-demo-path"
    creation_info {
      owner_uid   = "1000"
      owner_gid   = "1000"
      permissions = "755"
    }
  }
}


module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "ecs-cluster-vpc"
  cidr = "20.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["20.0.5.0/24", "20.0.6.0/24"]
  public_subnets  = ["20.0.7.0/24", "20.0.8.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  //enable_nat_gateway     = true
  //one_nat_gateway_per_az = true

  tags = {
    ManagedBy = "Terraform"
  }

}

/*
resource "aws_eip" "nat" {
  count = 2
  vpc = true
}
*/

module "ecs-security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "test - ECS my-cluster - ECS SecurityGroup"
  description = "be creative :)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${module.vpc.vpc_cidr_block}"]

  ingress_with_source_security_group_id = [ {
      from_port   = "8000"
      to_port     = "8000"
      protocol    = "tcp"
      source_security_group_id = "${module.alb_security_group.security_group_id}"
  } ]

  egress_with_cidr_blocks = [
    {
      from_port   = -1
      to_port     = -1
      protocol    = "all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  tags = {
    ManagedBy = "Terraform"
  }
}

module "alb_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "test - alb-sg" 
  description = "be creative :)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${module.vpc.vpc_cidr_block}"]
  ingress_with_cidr_blocks = [
    {
      from_port   = "80"
      to_port     = "80"
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = -1
      to_port     = -1
      protocol    = "all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  tags = {
    ManagedBy = "Terraform"
  }
}



module "efs-security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "test - efs-sec-group"
  description = "be creative :)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${module.vpc.vpc_cidr_block}"]

  ingress_with_source_security_group_id = [ {
      from_port   = "2049"
      to_port     = "2049"
      protocol    = "tcp"
      source_security_group_id = "${module.ecs-security_group.security_group_id}"
  } ]

  egress_with_cidr_blocks = [
    {
      from_port   = -1
      to_port     = -1
      protocol    = "all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  tags = {
    ManagedBy = "Terraform"
  }
}


module "interface_endpoints_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "test - Interface VPC Endpoints (AWS PrivateLink) - SG"
  description = "be creative :)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${module.vpc.vpc_cidr_block}"]

  ingress_with_source_security_group_id = [ {
      from_port   = "443"
      to_port     = "443"
      protocol    = "tcp"
      source_security_group_id = "${module.ecs-security_group.security_group_id}"
  } ]

  egress_with_cidr_blocks = [
    {
      from_port   = -1
      to_port     = -1
      protocol    = "all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  tags = {
    ManagedBy = "Terraform"
  }
}


