data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}
provider "aws" {
  region = "us-east-1"
  alias  = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}