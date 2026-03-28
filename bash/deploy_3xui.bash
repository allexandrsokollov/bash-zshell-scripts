#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------
# Config
# -----------------------------
CONTAINER_NAME="x-ui"
IMAGE="ghcr.io/mhsanaei/3x-ui:v2.8.11"
BASE_DIR="/opt/3x-ui"
DATA_DIR="${BASE_DIR}/data"
CERT_DIR="${BASE_DIR}/cert"
PANEL_PORT="2053"

# Common network ports used by 3x-ui/Xray setups.
# Adjust if you know exactly which ones you need.
PORTS=(
  "2053:2053"   # panel
  "80:80"       # HTTP / ACME
  "443:443"     # HTTPS / TLS / reality / proxy traffic
)

# Optional: set timezone for the container
TZ_VALUE="UTC"

# -----------------------------
# Helpers
# -----------------------------
log() {
  echo "[+] $*"
}

warn() {
  echo "[!] $*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root: sudo bash $0"
    exit 1
  fi
}

open_firewall_if_present() {
  if command -v ufw >/dev/null 2>&1; then
    log "Detected UFW. Opening required ports..."
    ufw allow 2053/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed."
    return
  fi

  log "Installing Docker..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

deploy_container() {
  mkdir -p "${DATA_DIR}" "${CERT_DIR}"

  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    log "Removing existing container ${CONTAINER_NAME}..."
    docker rm -f "${CONTAINER_NAME}"
  fi

  log "Pulling image ${IMAGE}..."
  docker pull "${IMAGE}"

  local docker_args=()
  for mapping in "${PORTS[@]}"; do
    docker_args+=(-p "${mapping}")
  done

  log "Starting ${CONTAINER_NAME}..."
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    "${docker_args[@]}" \
    -e TZ="${TZ_VALUE}" \
    -e XRAY_VMESS_AEAD_FORCED=false \
    -v "${DATA_DIR}:/etc/x-ui/" \
    -v "${CERT_DIR}:/root/cert/" \
    "${IMAGE}"
}

print_result() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo
  echo "3x-ui is deployed."
  echo "Container: ${CONTAINER_NAME}"
  echo "Image:     ${IMAGE}"
  echo "Data dir:  ${DATA_DIR}"
  echo "Cert dir:  ${CERT_DIR}"
  echo
  echo "Panel URL:"
  if [[ -n "${ip}" ]]; then
    echo "  http://${ip}:${PANEL_PORT}"
    echo "  https://${ip}:${PANEL_PORT}   (if you later enable SSL)"
  else
    echo "  http://<server-ip>:${PANEL_PORT}"
  fi
  echo
  echo "Useful commands:"
  echo "  docker logs -f ${CONTAINER_NAME}"
  echo "  docker exec -it ${CONTAINER_NAME} sh"
  echo "  docker restart ${CONTAINER_NAME}"
  echo "  docker stop ${CONTAINER_NAME}"
  echo
  warn "If the panel does not open, check cloud firewall rules and Ubuntu UFW rules."
}

main() {
  require_root
  install_docker_if_needed
  open_firewall_if_present
  deploy_container
  print_result
}

main "$@"