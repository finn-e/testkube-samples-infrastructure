resource "kind_cluster" "default" {
  name           = var.cluster_name
  node_image     = "kindest/node:v1.31.0"
  wait_for_ready = true

  kubeconfig_path = pathexpand(var.kubeconfig_path)

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      
      kubeadm_config_patches = [
        <<-EOF
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOF
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }
      
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.0"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = false

  values = [
    <<-EOF
    controller:
      hostPort:
        enabled: true
      nodeSelector:
        ingress-ready: "true"
      tolerations:
        - key: "node-role.kubernetes.io/control-plane"
          operator: "Equal"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/master"
          operator: "Equal"
          effect: "NoSchedule"
      publishService:
        enabled: false
      extraArgs:
        publish-status-address: "localhost"
    EOF
  ]

  depends_on = [kind_cluster.default]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.3.11"
  namespace        = "argocd"
  create_namespace = true
  wait             = false

  values = [
    <<-EOF
    configs:
      params:
        server.insecure: "true"
    server:
      extraArgs:
        - --insecure
    EOF
  ]

  depends_on = [kind_cluster.default]
}



