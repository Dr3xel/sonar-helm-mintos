#!/usr/bin/env bash

set -Eeuo pipefail

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-sonarqube}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-4096}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
NAMESPACE="${NAMESPACE:-sonarqube}"
TERRAFORM_DIR="${TERRAFORM_DIR:-terraform}"
RESET_CLUSTER="${RESET_CLUSTER:-false}"
STOP_DOCKER_DESKTOP="${STOP_DOCKER_DESKTOP:-true}"
PORT_FORWARD_PORT="${PORT_FORWARD_PORT:-80}"
PORT_FORWARD_LOG="${PORT_FORWARD_LOG:-/tmp/sonarqube-port-forward.log}"
PORT_FORWARD_PID_FILE="${PORT_FORWARD_PID_FILE:-/tmp/sonarqube-port-forward.pid}"

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

get_ec2_public_ip() {
  local token
  local public_ip

  token="$(curl -fsS -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)"

  if [[ -n "$token" ]]; then
    public_ip="$(curl -fsS \
      -H "X-aws-ec2-metadata-token: ${token}" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
  else
    public_ip="$(curl -fsS \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
  fi

  echo "$public_ip"
}

start_port_forward() {
  log "Starting SonarQube port-forward on 0.0.0.0:${PORT_FORWARD_PORT}"

  if [[ -f "$PORT_FORWARD_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$PORT_FORWARD_PID_FILE" || true)"

    if [[ -n "$old_pid" ]] && sudo ps -p "$old_pid" >/dev/null 2>&1; then
      log "Stopping existing port-forward process: ${old_pid}"
      sudo kill "$old_pid" || true
      sleep 2
    fi

    sudo rm -f "$PORT_FORWARD_PID_FILE"
  fi

  sudo pkill -f "kubectl port-forward.*svc/sonarqube.*${PORT_FORWARD_PORT}:9000" || true

  sudo nohup env \
    KUBECONFIG="${HOME}/.kube/config" \
    PATH="${PATH}" \
    kubectl port-forward \
      --address 0.0.0.0 \
      -n "${NAMESPACE}" \
      svc/sonarqube \
      "${PORT_FORWARD_PORT}:9000" \
    > "${PORT_FORWARD_LOG}" 2>&1 &

  local pf_pid=$!
  echo "$pf_pid" | sudo tee "$PORT_FORWARD_PID_FILE" >/dev/null

  sleep 5

  if ! sudo ps -p "$pf_pid" >/dev/null 2>&1; then
    fail "Port-forward failed to start. Check: ${PORT_FORWARD_LOG}"
  fi

  if ! sudo grep -q "Forwarding from 0.0.0.0:${PORT_FORWARD_PORT}" "$PORT_FORWARD_LOG"; then
    echo "Port-forward started, but readiness message not found yet."
    echo "Check logs with:"
    echo "  sudo tail -f ${PORT_FORWARD_LOG}"
  fi
}

print_result() {
  log "Deployment complete"

  kubectl get pods,svc,ingress -n "$NAMESPACE"

  local public_ip
  public_ip="$(get_ec2_public_ip)"

  echo
  echo "SonarQube access:"
  if [[ -n "$public_ip" ]]; then
    echo "  http://${public_ip}"
  else
    echo "  http://<EC2_PUBLIC_IP>"
  fi

  echo
  echo "Default login:"
  echo "  username: admin"
  echo "  password: admin"

  echo
  echo "Port-forward process:"
  echo "  PID file: ${PORT_FORWARD_PID_FILE}"
  echo "  Log file: ${PORT_FORWARD_LOG}"

  echo
  echo "Useful commands:"
  echo "  kubectl get pods -n ${NAMESPACE}"
  echo "  kubectl logs -n ${NAMESPACE} sonarqube-0 -f"
  echo "  tail -f ${PORT_FORWARD_LOG}"
  echo "  kill \$(cat ${PORT_FORWARD_PID_FILE})"
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
  get_ec2_public_ip
  start_port_forward
  print_result
}

main "$@"