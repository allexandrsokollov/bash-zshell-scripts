#!/bin/zsh
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

usage() {
  cat <<'EOF'
Usage:
  ./run-n-vms.zsh -n COUNT [options] -k /path/to/key1.pub [-k /path/to/key2.pub ...]

Required:
  -n COUNT              Number of VMs to create
  -k FILE.pub           Public key file to install into every VM
                        You can pass -k multiple times

Options:
  -p PREFIX             VM name prefix (default: vm)
  -c CPUS               CPUs per VM (default: 1)
  -m MEMORY             Memory per VM (default: 1G)
  -d DISK               Disk per VM (default: 10G)
  -i IMAGE              Ubuntu image/version for Multipass (default: 24.04)
  -b BASE_PORT          Base host port (default: 2220)
                        VM1 => BASE_PORT+1, VM2 => BASE_PORT+2, ...
  -a ANCHOR_NAME        PF anchor name (default: multipass-vms)
  -h, --help            Show this help

Examples:
  ./run-n-vms.zsh -n 3 -k ~/.ssh/id_ed25519.pub

  ./run-n-vms.zsh -n 5 -p node -c 2 -m 2G -d 20G -b 3000 \
    -k ~/.ssh/laptop.pub \
    -k ~/.ssh/workstation.pub

Result:
  If your Mac IP is 192.168.1.50 and BASE_PORT=3000:
    node1 => ssh ubuntu@192.168.1.50 -p 3001
    node2 => ssh ubuntu@192.168.1.50 -p 3002
    ...
EOF
}

vm_name() {
  local i="$1"
  echo "${VM_PREFIX}${i}"
}

host_port() {
  local i="$1"
  echo $((BASE_PORT + i))
}

append_unique_line() {
  local target_file="$1"
  local line="$2"
  grep -qxF "$line" "$target_file" 2>/dev/null || echo "$line" >> "$target_file"
}

# Defaults
VM_COUNT=""
VM_PREFIX="vm"
VM_CPUS="1"
VM_MEM="1G"
VM_DISK="10G"
UBUNTU_IMAGE="24.04"
BASE_PORT="2220"
PF_ANCHOR_NAME="multipass-vms"
KEY_FILES=()

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      [[ $# -ge 2 ]] || fail "Missing value for -n"
      VM_COUNT="$2"
      shift 2
      ;;
    -p)
      [[ $# -ge 2 ]] || fail "Missing value for -p"
      VM_PREFIX="$2"
      shift 2
      ;;
    -c)
      [[ $# -ge 2 ]] || fail "Missing value for -c"
      VM_CPUS="$2"
      shift 2
      ;;
    -m)
      [[ $# -ge 2 ]] || fail "Missing value for -m"
      VM_MEM="$2"
      shift 2
      ;;
    -d)
      [[ $# -ge 2 ]] || fail "Missing value for -d"
      VM_DISK="$2"
      shift 2
      ;;
    -i)
      [[ $# -ge 2 ]] || fail "Missing value for -i"
      UBUNTU_IMAGE="$2"
      shift 2
      ;;
    -b)
      [[ $# -ge 2 ]] || fail "Missing value for -b"
      BASE_PORT="$2"
      shift 2
      ;;
    -a)
      [[ $# -ge 2 ]] || fail "Missing value for -a"
      PF_ANCHOR_NAME="$2"
      shift 2
      ;;
    -k)
      [[ $# -ge 2 ]] || fail "Missing value for -k"
      KEY_FILES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

# Validation
require_cmd multipass
require_cmd awk
require_cmd route
require_cmd ipconfig
require_cmd sudo
require_cmd mktemp

[[ -n "$VM_COUNT" ]] || fail "You must pass -n COUNT"
[[ "$VM_COUNT" =~ '^[0-9]+$' ]] || fail "VM count must be an integer"
(( VM_COUNT >= 1 )) || fail "VM count must be >= 1"

[[ "$BASE_PORT" =~ '^[0-9]+$' ]] || fail "Base port must be an integer"
(( BASE_PORT >= 1 && BASE_PORT <= 65500 )) || fail "Base port must be between 1 and 65500"

(( ${#KEY_FILES[@]} >= 1 )) || fail "You must pass at least one -k public key file"

for key_file in "${KEY_FILES[@]}"; do
  [[ -f "$key_file" ]] || fail "Public key file not found: $key_file"
  [[ -s "$key_file" ]] || fail "Public key file is empty: $key_file"
done

PF_ANCHOR_FILE="/etc/pf.anchors/${PF_ANCHOR_NAME}"
PF_CONF="/etc/pf.conf"

EXT_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
[[ -n "${EXT_IF:-}" ]] || fail "Could not detect default network interface"

MAC_IP="$(ipconfig getifaddr "$EXT_IF" 2>/dev/null || true)"
[[ -n "${MAC_IP:-}" ]] || fail "Could not detect IP address for interface $EXT_IF"

echo "Interface:        $EXT_IF"
echo "Mac IP:           $MAC_IP"
echo "VM count:         $VM_COUNT"
echo "VM prefix:        $VM_PREFIX"
echo "VM CPUs:          $VM_CPUS"
echo "VM memory:        $VM_MEM"
echo "VM disk:          $VM_DISK"
echo "Ubuntu image:     $UBUNTU_IMAGE"
echo "Base host port:   $BASE_PORT"
echo "PF anchor:        $PF_ANCHOR_NAME"
echo "Public key files:"
for key_file in "${KEY_FILES[@]}"; do
  echo "  - $key_file"
done
echo

# Read and validate key contents
PUBKEYS=()
for key_file in "${KEY_FILES[@]}"; do
  key_content="$(<"$key_file")"
  [[ -n "$key_content" ]] || fail "Public key file is empty: $key_file"
  PUBKEYS+=("$key_content")
done

# Create VMs
for ((i=1; i<=VM_COUNT; i++)); do
  name="$(vm_name "$i")"

  if multipass info "$name" >/dev/null 2>&1; then
    echo "VM $name already exists, skipping creation."
  else
    echo "Creating $name..."
    multipass launch "$UBUNTU_IMAGE" \
      --name "$name" \
      --cpus "$VM_CPUS" \
      --memory "$VM_MEM" \
      --disk "$VM_DISK"
  fi
done

echo
echo "Waiting for instances to settle..."
sleep 10

# Prepare temp file with all authorized keys
TMP_KEYS_FILE="$(mktemp)"
trap 'rm -f "$TMP_KEYS_FILE"' EXIT

: > "$TMP_KEYS_FILE"
for key in "${PUBKEYS[@]}"; do
  append_unique_line "$TMP_KEYS_FILE" "$key"
done

# Configure SSH in guests and install all keys
for ((i=1; i<=VM_COUNT; i++)); do
  name="$(vm_name "$i")"
  echo "Configuring SSH in $name..."

  multipass exec "$name" -- bash -lc '
    set -e
    sudo apt-get update
    sudo apt-get install -y openssh-server
    sudo systemctl enable ssh
    sudo systemctl restart ssh
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
  '

  while IFS= read -r key_line; do
    [[ -n "$key_line" ]] || continue
    multipass exec "$name" -- bash -lc "grep -qxF '$key_line' ~/.ssh/authorized_keys || echo '$key_line' >> ~/.ssh/authorized_keys"
  done < "$TMP_KEYS_FILE"
done

# Collect VM IPs
typeset -A VM_IPS
for ((i=1; i<=VM_COUNT; i++)); do
  name="$(vm_name "$i")"
  ip="$(multipass info "$name" | awk '/IPv4/{print $2; exit}')"
  [[ -n "${ip:-}" ]] || fail "Failed to get IPv4 for $name"
  VM_IPS["$name"]="$ip"
done

echo
echo "VM IPs:"
for ((i=1; i<=VM_COUNT; i++)); do
  name="$(vm_name "$i")"
  echo "  $name -> ${VM_IPS[$name]}"
done

# Build PF rules
TMP_RULES="$(mktemp)"
{
  echo "# Auto-generated by run-n-vms.zsh"
  echo "# Forward incoming TCP ports on Mac -> SSH(22) in each Multipass VM"
  echo

  for ((i=1; i<=VM_COUNT; i++)); do
    name="$(vm_name "$i")"
    ip="${VM_IPS[$name]}"
    port="$(host_port "$i")"
    echo "rdr pass on ${EXT_IF} inet proto tcp from any to ${MAC_IP} port ${port} -> ${ip} port 22"
  done

  echo

  for ((i=1; i<=VM_COUNT; i++)); do
    name="$(vm_name "$i")"
    ip="${VM_IPS[$name]}"
    echo "pass in on ${EXT_IF} inet proto tcp from any to ${ip} port 22"
  done
} > "$TMP_RULES"

echo
echo "Installing PF rules..."
sudo cp "$TMP_RULES" "$PF_ANCHOR_FILE"
rm -f "$TMP_RULES"

if ! grep -q "anchor \"${PF_ANCHOR_NAME}\"" "$PF_CONF"; then
  echo "Adding PF anchor to $PF_CONF"
  {
    echo
    echo "anchor \"${PF_ANCHOR_NAME}\""
    echo "load anchor \"${PF_ANCHOR_NAME}\" from \"${PF_ANCHOR_FILE}\""
  } | sudo tee -a "$PF_CONF" >/dev/null
fi

echo "Enabling IP forwarding..."
sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null

echo "Reloading PF..."
sudo pfctl -f "$PF_CONF"
sudo pfctl -e 2>/dev/null || true

echo
echo "Done."
echo
echo "Connect from another machine using:"
for ((i=1; i<=VM_COUNT; i++)); do
  name="$(vm_name "$i")"
  port="$(host_port "$i")"
  ip="${VM_IPS[$name]}"
  echo "  ssh ubuntu@${MAC_IP} -p ${port}   # ${name} (${ip})"
done

echo
echo "Mapping summary:"
for ((i=1; i<=VM_COUNT; i++)); do
  name="$(vm_name "$i")"
  port="$(host_port "$i")"
  ip="${VM_IPS[$name]}"
  echo "  ${MAC_IP}:${port} -> ${name}:${ip}:22"
done