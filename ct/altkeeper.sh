#!/usr/bin/env bash
#
# Create an unprivileged Debian 12 LXC on Proxmox VE and install AltKeeper inside it.
# Run this ON THE PROXMOX HOST, not inside a container.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/ct/altkeeper.sh)"
#
# Options:
#   --vmid N        container ID (default: next free)
#   --hostname NAME default: altkeeper
#   --cores N       default: 2
#   --ram MB        default: 4096 (a Rust release build needs headroom)
#   --disk GB       default: 8
#   --storage NAME  rootfs storage (default: local-lvm when present, else local)
#   --bridge NAME   default: vmbr0
#   --password PW   root password inside the container (default: generated)
#   --destroy VMID  stop and destroy an AltKeeper container
#   -h, --help
#
set -Eeuo pipefail

INSTALL_URL="https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh"
VMID=""
HOSTNAME="altkeeper"
CORES=2
RAM=4096
DISK=8
STORAGE=""
BRIDGE="vmbr0"
PASSWORD=""
DESTROY=""

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
AltKeeper LXC creator (run on the Proxmox VE host)

  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/ct/altkeeper.sh)"

Options:
  --vmid N        container ID (default: next free)
  --hostname NAME default: altkeeper
  --cores N       default: 2
  --ram MB        default: 4096
  --disk GB       default: 8
  --storage NAME  rootfs storage (default: local-lvm when present, else local)
  --bridge NAME   default: vmbr0
  --password PW   root password inside the container (default: generated)
  --destroy VMID  stop and destroy an AltKeeper container
  -h, --help      show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid)     [ $# -ge 2 ] || die "--vmid needs a number"; VMID="$2"; shift 2 ;;
    --hostname) [ $# -ge 2 ] || die "--hostname needs a name"; HOSTNAME="$2"; shift 2 ;;
    --cores)    [ $# -ge 2 ] || die "--cores needs a number"; CORES="$2"; shift 2 ;;
    --ram)      [ $# -ge 2 ] || die "--ram needs megabytes"; RAM="$2"; shift 2 ;;
    --disk)     [ $# -ge 2 ] || die "--disk needs gigabytes"; DISK="$2"; shift 2 ;;
    --storage)  [ $# -ge 2 ] || die "--storage needs a name"; STORAGE="$2"; shift 2 ;;
    --bridge)   [ $# -ge 2 ] || die "--bridge needs a name"; BRIDGE="$2"; shift 2 ;;
    --password) [ $# -ge 2 ] || die "--password needs a value"; PASSWORD="$2"; shift 2 ;;
    --destroy)  [ $# -ge 2 ] || die "--destroy needs a VMID"; DESTROY="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox VE host."
[ -d /etc/pve ] || die "This is not a Proxmox VE host. Inside a container, run the installer instead: curl -fsSL $INSTALL_URL | sudo bash"
command -v pct >/dev/null 2>&1 || die "pct not found; run this on the Proxmox VE host."

if [ -n "$DESTROY" ]; then
  pct status "$DESTROY" >/dev/null 2>&1 || die "Container $DESTROY does not exist."
  info "Stopping and destroying container $DESTROY..."
  pct stop "$DESTROY" >/dev/null 2>&1 || true
  pct destroy "$DESTROY" --purge 1
  ok "Container $DESTROY destroyed."
  exit 0
fi

trap 'printf "\n%s[FAIL]%s Creation aborted. Inspect with: pct status %s / pct enter %s\n" "$C_RED" "$C_RESET" "${VMID:-?}" "${VMID:-?}" >&2' ERR

if [ -z "$VMID" ]; then
  VMID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  [ -n "$VMID" ] || die "Cannot determine the next free VMID; pass --vmid."
fi
case "$VMID" in
  ''|*[!0-9]*) die "--vmid must be numeric." ;;
esac
if pct status "$VMID" >/dev/null 2>&1; then
  die "Container $VMID already exists. Choose another --vmid."
fi

if [ -z "$STORAGE" ]; then
  if pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1}' | grep -qx local-lvm; then
    STORAGE="local-lvm"
  else
    STORAGE="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1; exit}')"
  fi
fi
[ -n "$STORAGE" ] || die "No storage supports containers; pass --storage."

info "Looking for a Debian 12 template..."
TEMPLATE="$(pveam list local 2>/dev/null | awk '/debian-12-standard_/{print $1}' | tail -n 1)"
if [ -z "$TEMPLATE" ]; then
  pveam update >/dev/null
  TEMPLATE_NAME="$(pveam available --section system | awk '/debian-12-standard_/{print $2}' | tail -n 1)"
  [ -n "$TEMPLATE_NAME" ] || die "No Debian 12 template is available for this Proxmox version."
  info "Downloading $TEMPLATE_NAME..."
  pveam download local "$TEMPLATE_NAME"
  TEMPLATE="local:vztmpl/$TEMPLATE_NAME"
fi
ok "Template: $TEMPLATE"

if [ -z "$PASSWORD" ]; then
  PASSWORD="$(openssl rand -base64 12 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-12 || true)"
  [ -n "$PASSWORD" ] || PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
fi

info "Creating container $VMID ($CORES vCPU, ${RAM} MB RAM, ${DISK} GB on $STORAGE)..."
pct create "$VMID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap 512 \
  --rootfs "$STORAGE:$DISK" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
  --unprivileged 1 \
  --features "nesting=1,keyctl=1" \
  --onboot 1 \
  --password "$PASSWORD" \
  --description "AltKeeper: AltServer for iOS 17+; renews sideloaded apps over Wi-Fi" \
  --tags "altkeeper"

info "Starting the container..."
pct start "$VMID"

info "Waiting for networking inside the container..."
READY=0
for _ in $(seq 1 60); do
  if pct exec "$VMID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  warn "The container has no DNS/network yet. Check the bridge and DHCP, then run inside it:"
  warn "  pct enter $VMID"
  warn "  curl -fsSL $INSTALL_URL | bash"
  exit 1
fi
ok "Network is up."

info "Installing AltKeeper inside the container (Docker + Rust build, 10-20 minutes)..."
pct exec "$VMID" -- bash -lc "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git && curl -fsSL $INSTALL_URL | bash"

IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
PIN="$(pct exec "$VMID" -- sh -c "sed -n 's/^ALTKEEPER_WEB_PIN=//p' /opt/altkeeper/.env" 2>/dev/null || true)"
[ -n "${IP:-}" ] || IP="<container-ip>"

cat <<EOF

${C_BOLD}AltKeeper is running in container $VMID.${C_RESET}

  Dashboard:  http://$IP:8787
  PIN:        ${PIN:-see /opt/altkeeper/.env inside the container}

  Root shell: pct enter $VMID       (password: $PASSWORD)
  Logs:       pct exec $VMID -- docker logs -f altkeeper
  Destroy:    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/ct/altkeeper.sh)" -- --destroy $VMID

Next: open the dashboard, sign in with your Apple ID, then upload rp-pairing.plist in the
iPhone card ("No USB? Upload a pairing file") and save the iPhone address in Settings.
EOF
