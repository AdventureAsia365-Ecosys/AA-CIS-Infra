aws_region  = "us-west-1"
environment = "dev"
project     = "aa-cis"
account_id  = "867490540162"

vpc_id             = "vpc-0770c0bbc63988b15"
private_subnet_ids = ["subnet-00e159a403aac08cb", "subnet-04052dca9b2293647"]
public_subnet_ids  = ["subnet-0d610f1825a7ac030", "subnet-0f8649d1e637cbd63"]
db_subnet_ids      = ["subnet-06563c47008949330", "subnet-00c2888a7f499aa9d"]
sg_rds_id          = "sg-02927a6ab367a6dad"
sg_app_id          = "sg-09497928fc37a1541"
sg_alb_id          = "sg-006ffc72acbc1986a"

db_name     = "aa_cis_dev"
db_username = "aa_cis_admin"

uploads_bucket = "aa-cis-dev-uploads-867490540162"
outputs_bucket = "aa-cis-dev-outputs-867490540162"

tags = {
  Project     = "aa-cis"
  Environment = "dev"
  ManagedBy   = "terraform"
}

# ALB + ECS Service (added S6)
acm_certificate_arn   = "arn:aws:acm:us-west-1:867490540162:certificate/260ab2f0-06f6-456b-b5d7-a4d0af96d405"
task_cpu              = 512
task_memory           = 1024
service_desired_count = 1
secret_rds_arn        = "arn:aws:secretsmanager:us-west-1:867490540162:secret:aa-cis/dev/rds-9dlb81"
secret_openai_arn     = "arn:aws:secretsmanager:us-west-1:867490540162:secret:aa-cis/dev/openai-nlOYzI"
secret_langfuse_arn   = "arn:aws:secretsmanager:us-west-1:867490540162:secret:aa-cis/dev/langfuse-f2nGMJ"
