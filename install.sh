#!/usr/bin/env bash
#
# AltKeeper installer (community-scripts style): one command on a Debian/Ubuntu host or a
# Proxmox LXC, with Docker installed automatically when missing.
#
#   curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh | sudo bash
#
# Re-run the same command to update. When piping, pass options after `-s --`.
#
set -Eeuo pipefail

REPO_URL="${ALTKEEPER_REPO:-https://github.com/ethanbanker/altkeeper.git}"
BRANCH="${ALTKEEPER_BRANCH:-main}"
INSTALL_DIR="${ALTKEEPER_DIR:-/opt/altkeeper}"
IMAGE="${ALTKEEPER_IMAGE:-altkeeper:latest}"
PIN=""
PAIRING=""
NO_BUILD=0

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
AltKeeper installer (Docker on Debian/Ubuntu or a Proxmox LXC)

  curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh | sudo bash

Re-run the same command to update AltKeeper.

Options (when piping, put them after `-s --`):
  --dir PATH       install directory (default: /opt/altkeeper)
  --pin PIN        dashboard PIN (default: generated once, then kept)
  --pairing FILE   copy an rp-pairing.plist into the data volume
  --branch NAME    git branch to build (default: main)
  --image NAME     use an existing image; do not clone or build
  --no-build       reuse the image already built on this machine
  -h, --help       show this help
USAGE
}

trap 'printf "\n%s[FAIL]%s Installation aborted (line %s).\n" "$C_RED" "$C_RESET" "$LINENO" >&2' ERR

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)      [ $# -ge 2 ] || die "--dir needs a path";   INSTALL_DIR="$2"; shift 2 ;;
    --pin)      [ $# -ge 2 ] || die "--pin needs a value";  PIN="$2"; shift 2 ;;
    --pairing)  [ $# -ge 2 ] || die "--pairing needs a file"; PAIRING="$2"; shift 2 ;;
    --branch)   [ $# -ge 2 ] || die "--branch needs a name"; BRANCH="$2"; shift 2 ;;
    --image)    [ $# -ge 2 ] || die "--image needs a name"; IMAGE="$2"; NO_BUILD=1; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root: curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh | sudo bash"

INSTALL_DIR="${INSTALL_DIR%/}"
case "$INSTALL_DIR" in
  /*) ;;
  *) die "--dir must be an absolute path." ;;
esac
if [ -n "$PIN" ] && [ "${#PIN}" -lt 4 ]; then
  die "The PIN must be at least 4 characters."
fi

DATA_DIR="$INSTALL_DIR/data"
SRC_DIR="$INSTALL_DIR/src"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

gen_pin() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    od -An -tx1 -N8 /dev/urandom | tr -d ' \n'
  fi
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 || die "This is not a Debian/Ubuntu system; install $* manually."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

if ! command -v docker >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 \
    || die "Docker is not installed and this is not Debian/Ubuntu. Install Docker Engine and Compose v2, then re-run."
  info "Docker not found; installing Docker Engine..."
  apt_install ca-certificates curl git
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
fi

command -v curl >/dev/null 2>&1 || apt_install curl
if [ "$NO_BUILD" -eq 0 ] && ! command -v git >/dev/null 2>&1; then
  apt_install ca-certificates git
fi

if ! docker compose version >/dev/null 2>&1; then
  info "Installing the Docker Compose plugin..."
  if command -v apt-get >/dev/null 2>&1; then
    apt_install docker-compose-plugin || die "Install the Docker Compose v2 plugin (docker-compose-plugin) and re-run."
  else
    die "Docker Compose v2 is required: install the docker-compose-plugin package."
  fi
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (the 'docker compose' command)."

info "Using $INSTALL_DIR for configuration and data."
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [ "$NO_BUILD" -eq 0 ]; then
  if [ -d "$SRC_DIR/.git" ]; then
    info "Updating the source in $SRC_DIR..."
    git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$SRC_DIR" reset --hard FETCH_HEAD >/dev/null
  else
    info "Cloning $REPO_URL ($BRANCH)..."
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
  fi
  info "Building the image. A Rust release build takes 10-20 minutes on a small LXC."
  docker build --tag "$IMAGE" "$SRC_DIR"
  ok "Built $IMAGE."
fi

if [ -n "$PIN" ]; then
  printf 'ALTKEEPER_WEB_PIN=%s\n' "$PIN" > "$ENV_FILE"
  info "Saved the dashboard PIN."
elif [ ! -s "$ENV_FILE" ]; then
  PIN="$(gen_pin)"
  printf 'ALTKEEPER_WEB_PIN=%s\n' "$PIN" > "$ENV_FILE"
  info "Generated a dashboard PIN."
else
  PIN="$(sed -n 's/^ALTKEEPER_WEB_PIN=//p' "$ENV_FILE" | head -n 1)"
fi
chmod 600 "$ENV_FILE"
[ -n "$PIN" ] || die "$ENV_FILE exists but has no ALTKEEPER_WEB_PIN line."

if [ -n "$PAIRING" ]; then
  [ -f "$PAIRING" ] || die "Pairing file not found: $PAIRING"
  install -m 600 "$PAIRING" "$DATA_DIR/rp-pairing.plist"
  ok "Pairing file copied to $DATA_DIR/rp-pairing.plist."
elif [ -f "$INSTALL_DIR/rp-pairing.plist" ]; then
  install -m 600 "$INSTALL_DIR/rp-pairing.plist" "$DATA_DIR/rp-pairing.plist"
  ok "Pairing file copied from $INSTALL_DIR/rp-pairing.plist."
fi

cat > "$COMPOSE_FILE" <<EOF
# Generated by AltKeeper install.sh; re-running the installer regenerates it.
services:
  altkeeper:
    image: $IMAGE
    container_name: altkeeper
    restart: unless-stopped
    # PID 1 reaping and clean SIGTERM forwarding to \`altkeeper serve\`.
    init: true
    # Bonjour is multicast and AltStore must reach AltServer on 49500 directly.
    network_mode: host
    working_dir: /data
    volumes:
      - "$DATA_DIR:/data"
    environment:
      - TZ=\${TZ:-UTC}
      - ALTKEEPER_LANG=en
      - ALTKEEPER_WEB_PIN=\${ALTKEEPER_WEB_PIN:?set ALTKEEPER_WEB_PIN in .env}
      # No USB inside an unprivileged LXC: the pairing file is copied in instead.
      - ALTKEEPER_NO_AUTO_PAIR=1
    command: ["serve", "--bind", "0.0.0.0:8787", "--altserver"]
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8787/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
chmod 600 "$COMPOSE_FILE"

info "Starting AltKeeper..."
cd "$INSTALL_DIR"
docker compose up -d --remove-orphans

info "Waiting for the dashboard..."
HEALTHY=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:8787/healthz >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 2
done
if [ "$HEALTHY" -eq 1 ]; then
  ok "Dashboard is healthy."
else
  warn "The dashboard did not answer yet. Check: docker logs altkeeper"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${IP:-}" ] || IP="<this-machine-ip>"

cat <<EOF

${C_BOLD}AltKeeper is installed.${C_RESET}

  Dashboard:  http://$IP:8787
  PIN:        $PIN
  Data:       $DATA_DIR
  Compose:    $COMPOSE_FILE

Next steps:
  1. Open the dashboard and sign in with your Apple ID.
  2. Without USB in the container, pair once on a machine that sees the iPhone:
       altkeeper pair-usb
     then copy rp-pairing.plist into $INSTALL_DIR and re-run this script,
     or pass it on the first run:  ... | sudo bash -s -- --pairing /root/rp-pairing.plist
  3. Save the iPhone address under Settings -> iPhone addresses
     (give the iPhone a DHCP reservation so the address does not change).
  4. Point AltStore Classic at this server (port 49500), or use DNS-SD for remote access.

Update later by re-running the same command. Logs: docker logs -f altkeeper
EOF
