#!/usr/bin/env bash
#
# Remove an AltKeeper Docker install created by install.sh, on a host or inside an LXC.
#
#   curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/uninstall.sh | sudo bash
#
# By default the container, image, generated compose file, PIN and source checkout are removed;
# pairing, account and backups under /opt/altkeeper/data are kept. Options:
#   --dir PATH   install directory (default: /opt/altkeeper)
#   --purge      also delete the data directory (pairing, account, backups)
#   --docker     also uninstall Docker, but only if install.sh installed it
#   --yes        do not ask for confirmation
#   --dry-run    print the commands without running them
#   -h, --help
#
set -Eeuo pipefail

DIR="${ALTKEEPER_DIR:-/opt/altkeeper}"
PURGE=0
DOCKER=0
YES=0
DRY=0

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Remove an AltKeeper Docker install (host or LXC)

  curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/uninstall.sh | sudo bash

Options (when piping, put them after `-s --`):
  --dir PATH   install directory (default: /opt/altkeeper)
  --purge      also delete data (pairing, account, backups)
  --docker     also uninstall Docker, only if install.sh installed it
  --yes        do not ask for confirmation
  --dry-run    print the commands without running them
  -h, --help   show this help
USAGE
}

run() {
  if [ "$DRY" -eq 1 ]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

confirm() {
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || die "$1 Pass --yes to run non-interactively."
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)      [ $# -ge 2 ] || die "--dir needs a path"; DIR="$2"; shift 2 ;;
    --purge)    PURGE=1; shift ;;
    --docker)   DOCKER=1; shift ;;
    --yes|-y)   YES=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Unknown option: $1 (try --help)" ;;
  esac
done

[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "Run as root: curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/uninstall.sh | sudo bash"
DIR="${DIR%/}"
case "$DIR" in
  /*) ;;
  *) die "--dir must be an absolute path." ;;
esac

DOCKER_INSTALLED=0
[ -f "$DIR/.docker-installed" ] && DOCKER_INSTALLED=1

if command -v docker >/dev/null 2>&1; then
  if [ -f "$DIR/docker-compose.yml" ]; then
    info "Stopping the AltKeeper stack..."
    ( cd "$DIR" && run docker compose down --remove-orphans ) || warn "docker compose down failed; continuing."
  fi
  info "Removing the container and image..."
  run docker rm -f altkeeper || true
  run docker rmi altkeeper:latest || true
else
  warn "Docker is not installed here; no container to remove."
fi

info "Removing generated configuration and source..."
run rm -f "$DIR/docker-compose.yml" "$DIR/.env" "$DIR/.docker-installed"
run rm -rf "$DIR/src"

if [ "$PURGE" -eq 1 ]; then
  if confirm "Delete $DIR including pairing, account, backups and logs?"; then
    run rm -rf "$DIR"
    ok "Removed $DIR."
  else
    warn "Data kept in $DIR."
  fi
elif [ -d "$DIR/data" ] || [ "$DRY" -eq 1 ]; then
  ok "Data kept in $DIR/data (pairing, account, backups). Use --purge to delete it."
fi

if [ "$DOCKER" -eq 1 ]; then
  if [ "$DOCKER_INSTALLED" -ne 1 ]; then
    warn "install.sh did not install Docker here, so Docker was left untouched."
  elif confirm "Uninstall Docker from this system? Other containers will stop working."; then
    packages=()
    for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose; do
      if dpkg -s "$package" >/dev/null 2>&1; then
        packages+=("$package")
      fi
    done
    if [ "${#packages[@]}" -gt 0 ]; then
      run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}"
      run apt-get autoremove -y
      ok "Docker packages removed."
    else
      warn "No Docker packages found."
    fi
  else
    warn "Docker left installed."
  fi
fi

if [ "$DRY" -eq 1 ]; then
  echo
  echo "Dry run: nothing was changed."
elif [ "$DOCKER" -ne 1 ] && [ "$DOCKER_INSTALLED" -eq 1 ]; then
  echo
  echo "Docker was installed by install.sh. To remove it as well, re-run with --docker."
fi
