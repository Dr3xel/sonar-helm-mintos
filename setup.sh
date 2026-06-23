#!/usr/bin/env bash

set -Eeuo pipefail

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-sonarqube}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-4096}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
NAMESPACE="${NAMESPACE:-sonarqube}"
SONARQUBE_HOST="${SONARQUBE_HOST:-sonarqube.local}"
TERRAFORM_DIR="${TERRAFORM_DIR:-terraform}"
RESET_CLUSTER="${RESET_CLUSTER:-false}"
STOP_DOCKER_DESKTOP="${STOP_DOCKER_DESKTOP:-true}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USE_SG_DOCKER="false"

log() {
  echo
  echo "==> $1"
}

fail() {
  echo
  echo "ERROR: $1" >&2
  exit 1
}

run_docker_group() {
  if [[ "$USE_SG_DOCKER" == "true" ]]; then
    sg docker -c "$(printf '%q ' "$@")"
  else
    "$@"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      echo "amd64"
      ;;
    aarch64 | arm64)
      echo "arm64"
      ;;
    *)
      fail "Unsupported architecture: $(uname -m)"
      ;;
  esac
}

validate_repo_structure() {
  log "Validating repository structure"

  [[ -d "$REPO_ROOT/helm/postgresql" ]] || fail "Missing helm/postgresql chart"
  [[ -d "$REPO_ROOT/helm/sonarqube" ]] || fail "Missing helm/sonarqube chart"
  [[ -d "$REPO_ROOT/$TERRAFORM_DIR" ]] || fail "Missing terraform directory"

  [[ -f "$REPO_ROOT/$TERRAFORM_DIR/providers.tf" ]] || fail "Missing terraform/providers.tf"
  [[ -f "$REPO_ROOT/$TERRAFORM_DIR/helm.tf" ]] || fail "Missing terraform/helm.tf"
}

install_base_packages() {
  log "Installing base packages"

  sudo apt-get update -y
  sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common
}

install_docker_engine() {
  log "Installing Docker Engine"

  if ! dpkg -s docker-ce >/dev/null 2>&1; then
    sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker || true

    sudo install -m 0755 -d /etc/apt/keyrings

    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc

    sudo chmod a+r /etc/apt/keyrings/docker.asc

    local ubuntu_codename
    ubuntu_codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${ubuntu_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update -y
    sudo apt-get install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
  fi

  sudo systemctl enable --now docker

  if [[ "$STOP_DOCKER_DESKTOP" == "true" ]] && systemctl --user is-active --quiet docker-desktop 2>/dev/null; then
    log "Stopping Docker Desktop to free RAM; native Docker Engine will be used"
    systemctl --user stop docker-desktop || true
  fi

  docker context use default >/dev/null 2>&1 || true

  if docker info >/dev/null 2>&1; then
    return
  fi

  if sudo docker info >/dev/null 2>&1; then
    log "Adding current user to docker group"

    sudo usermod -aG docker "$USER"

    if sg docker -c "docker info >/dev/null 2>&1"; then
      USE_SG_DOCKER="true"
      return
    fi
  fi

  fail "Docker is installed, but current user cannot access Docker. Log out/in or run: newgrp docker"
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl already installed: $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 || true)"
    return
  fi

  log "Installing kubectl"

  local arch
  arch="$(detect_arch)"

  curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl"

  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    log "Helm already installed: $(helm version --short)"
    return
  fi

  log "Installing Helm 3"

  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
  rm -f /tmp/get_helm.sh
}

install_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    log "Terraform already installed: $(terraform version | head -1)"
    return
  fi

  log "Installing Terraform"

  local ubuntu_codename
  ubuntu_codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

  curl -fsSL https://apt.releases.hashicorp.com/gpg -o /tmp/hashicorp.gpg

  sudo rm -f /usr/share/keyrings/hashicorp-archive-keyring.gpg
  gpg --dearmor < /tmp/hashicorp.gpg | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
  rm -f /tmp/hashicorp.gpg

  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${ubuntu_codename} main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y terraform
}

install_minikube() {
  if command -v minikube >/dev/null 2>&1; then
    log "Minikube already installed: $(minikube version --short)"
    return
  fi

  log "Installing Minikube"

  local arch
  arch="$(detect_arch)"

  curl -fsSL -o /tmp/minikube "https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-${arch}"

  sudo install /tmp/minikube /usr/local/bin/minikube
  rm -f /tmp/minikube
}

start_minikube() {
  log "Starting Minikube profile: ${MINIKUBE_PROFILE}"

  if [[ "$RESET_CLUSTER" == "true" ]]; then
    log "RESET_CLUSTER=true, deleting existing Minikube profile"
    run_docker_group minikube -p "$MINIKUBE_PROFILE" delete || true
  fi

  if ! run_docker_group minikube -p "$MINIKUBE_PROFILE" status >/dev/null 2>&1; then
    run_docker_group minikube -p "$MINIKUBE_PROFILE" start \
      --driver=docker \
      --memory="$MINIKUBE_MEMORY" \
      --cpus="$MINIKUBE_CPUS"
  else
    log "Minikube profile already running"
  fi

  kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null 2>&1 || true

  log "Enabling Nginx ingress addon"
  run_docker_group minikube -p "$MINIKUBE_PROFILE" addons enable ingress

  log "Waiting for ingress controller"
  kubectl wait \
    --namespace ingress-nginx \
    --for=condition=Ready \
    pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=240s

  log "Configuring sysctl values required by SonarQube Elasticsearch"
  run_docker_group minikube -p "$MINIKUBE_PROFILE" ssh "sudo sysctl -w vm.max_map_count=262144"
  run_docker_group minikube -p "$MINIKUBE_PROFILE" ssh "sudo sysctl -w fs.file-max=131072"
}

lint_helm_charts() {
  log "Linting Helm charts"

  helm lint "$REPO_ROOT/helm/postgresql"
  helm lint "$REPO_ROOT/helm/sonarqube"
}

deploy_with_terraform() {
  log "Deploying with Terraform"

  cd "$REPO_ROOT/$TERRAFORM_DIR"

  terraform init -upgrade
  terraform fmt -recursive
  terraform validate
  terraform apply -auto-approve -var="namespace=${NAMESPACE}"
}

wait_for_workloads() {
  log "Waiting for PostgreSQL"

  kubectl rollout status statefulset/postgresql \
    -n "$NAMESPACE" \
    --timeout=300s

  log "Waiting for SonarQube"

  kubectl rollout status statefulset/sonarqube \
    -n "$NAMESPACE" \
    --timeout=900s
}

configure_hosts_file() {
  log "Configuring /etc/hosts"

  local minikube_ip
  minikube_ip="$(run_docker_group minikube -p "$MINIKUBE_PROFILE" ip)"

  if grep -Eq "[[:space:]]${SONARQUBE_HOST}([[:space:]]|$)" /etc/hosts; then
    sudo sed -i.bak -E "s#^.*[[:space:]]${SONARQUBE_HOST}([[:space:]]|$).*#${minikube_ip} ${SONARQUBE_HOST}#" /etc/hosts
  else
    echo "${minikube_ip} ${SONARQUBE_HOST}" | sudo tee -a /etc/hosts >/dev/null
  fi

  echo "Mapped ${SONARQUBE_HOST} to ${minikube_ip}"
}

print_result() {
  log "Deployment complete"

  kubectl get pods,svc,ingress -n "$NAMESPACE"

  echo
  echo "SonarQube URL:"
  echo "  http://${SONARQUBE_HOST}"
  echo
  echo "Default login:"
  echo "  username: admin"
  echo "  password: admin"
  echo
  echo "Useful commands:"
  echo "  kubectl get pods -n ${NAMESPACE}"
  echo "  kubectl logs -n ${NAMESPACE} sonarqube-0 -f"
  echo "  terraform -chdir=${TERRAFORM_DIR} destroy -auto-approve"
}

main() {
  validate_repo_structure
  install_base_packages
  install_docker_engine
  install_kubectl
  install_helm
  install_terraform
  install_minikube
  start_minikube
  lint_helm_charts
  deploy_with_terraform
  wait_for_workloads
  configure_hosts_file
  print_result
}

main "$@"