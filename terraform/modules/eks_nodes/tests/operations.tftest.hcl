mock_provider "aws" {
  mock_data "aws_default_tags" {
    defaults = { tags = { Project = "jangin", Environment = "staging", ManagedBy = "Terraform" } }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"}}]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/review-node" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
}

variables {
  project                     = "jangin"
  env                         = "staging"
  cluster_name                = "review-cluster"
  cluster_version             = "1.35"
  subnet_ids                  = ["subnet-0123456789abcdef0"]
  node_role_extra_policy_arns = []
  ssh_key_name                = null

  cluster_security_group_id = "sg-0000000000cluster"

  # 각 run 이 labels 를 db 또는 gpu 로만 쓰지만,
  # 네 계층 전부 넣어두면 나중에 run 을 추가할 때 손댈 일이 없습니다.
  security_groups_by_workload_type = {
    system = ["sg-0000000000node"]
    app    = ["sg-0000000000node"]
    db     = ["sg-0000000000db"]
    gpu    = ["sg-0000000000gpu"]
  }
}
run "db_running_and_instance_volume_tags" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 3
        min_size      = 3
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }

  assert {
    condition = alltrue([
      for kind in ["instance", "volume"] :
      { for spec in aws_launch_template.node["test"].tag_specifications : spec.resource_type => spec.tags }[kind]["NodePool"] == "db"
      && { for spec in aws_launch_template.node["test"].tag_specifications : spec.resource_type => spec.tags }[kind]["Project"] == "jangin"
      && { for spec in aws_launch_template.node["test"].tag_specifications : spec.resource_type => spec.tags }[kind]["Environment"] == "staging"
    ])
    error_message = "Instance and EBS tags must include NodePool and provider default tags."
  }
  assert {
    condition     = one(aws_launch_template.node["test"].block_device_mappings).ebs[0].volume_size == 30 && one(aws_launch_template.node["test"].block_device_mappings).ebs[0].encrypted
    error_message = "Root disk size must be preserved and encrypted."
  }
}
run "db_full_shutdown_allowed" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 0
        min_size      = 0
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }


}
run "db_one_node_rejected" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 1
        min_size      = 1
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }
  expect_failures = [aws_eks_node_group.this]

}
run "db_two_nodes_rejected" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 2
        min_size      = 2
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }
  expect_failures = [aws_eks_node_group.this]

}
run "db_running_with_zero_min_rejected" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 3
        min_size      = 0
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }
  expect_failures = [aws_eks_node_group.this]

}
run "db_spot_rejected" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 3
        min_size      = 3
        max_size      = 3
        capacity_type = "SPOT"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }
  expect_failures = [aws_eks_node_group.this]

}
run "invalid_scaling_rejected" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 4
        min_size      = 3
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }
  expect_failures = [aws_eks_node_group.this]

}
run "gpu_cost_tags" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 0
        min_size      = 0
        max_size      = 1
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "gpu" }
        taints        = []
      }
    }
  }

  assert {
    condition     = alltrue([for spec in aws_launch_template.node["test"].tag_specifications : spec.tags["NodePool"] == "ai"])
    error_message = "GPU cost tags must use the ai pool."
  }
}

run "cluster_sg_and_tier_sg_attached" {
  command = plan
  variables {
    node_groups = {
      test = {
        enabled       = true
        instance_type = "t3.small"
        ami_type      = "AL2023_x86_64_STANDARD"
        desired_size  = 3
        min_size      = 3
        max_size      = 3
        capacity_type = "ON_DEMAND"
        disk_size     = 30
        labels        = { "workload-type" = "db" }
        taints        = []
      }
    }
  }

  # 🔴 클러스터 SG 가 빠지면 노드가 조인하지 못한다.
  #    LT 에 SG 를 지정하면 EKS 가 이 SG 를 자동으로 붙여주지 않기 때문.
  assert {
    condition = contains(
      aws_launch_template.node["test"].vpc_security_group_ids,
      var.cluster_security_group_id,
    )
    error_message = "Cluster SG must always be attached or nodes fail to join."
  }

  # 계층 SG 가 실제로 붙는지 — 이게 빠지면 ALB → Pod 경로가 막힌다.
  assert {
    condition = contains(
      aws_launch_template.node["test"].vpc_security_group_ids,
      "sg-0000000000db",
    )
    error_message = "Tier SG from security_groups_by_workload_type must be attached."
  }

  assert {
    condition     = aws_launch_template.node["test"].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced on custom launch templates."
  }
}
