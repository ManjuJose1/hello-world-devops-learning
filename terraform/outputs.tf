output "cluster_name" { 
  value = module.eks.cluster_name 
}
output "ecr_repository_url" { 
  value = aws_ecr_repository.app_repo.repository_url 
}
