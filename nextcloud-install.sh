#!/usr/bin/env bash
#
# Nextcloud installer / uninstaller (Docker Compose)
# Detects distro, ensures Docker + Compose, writes a compose stack
# (Nextcloud + MariaDB + Redis), starts it, and prints the URL.
#
# Usage:
#   bash nextcloud-install.sh            # install
#   bash nextcloud-install.sh uninstall  # stop and optionally remove data
#

set -euo pipefail

START_TIME=$(date +%s)
DEFAULT_DIR="/opt/nextcloud"
DEFAULT_PORT=8080
NC_IMAGE="nextcloud:35-apache"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── docker ─────────────────────────────────────────────────────────────────
install_docker() {
  info "Checking Docker..."

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose already available"
  else
    info "Installing Docker..."
    case "$PKG" in
      apt)
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 curl ca-certificates
        ;;
      dnf)
        if ! command -v docker >/dev/null 2>&1; then
          sudo dnf install -y docker docker-compose curl ca-certificates || \
          sudo dnf install -y moby-engine docker-compose curl ca-certificates
        else
          sudo dnf install -y docker-compose curl ca-certificates || true
        fi
        ;;
      pacman)
        sudo pacman -Sy --noconfirm docker docker-compose curl ca-certificates
        ;;
      zypper)
        sudo zypper --non-interactive install docker docker-compose curl ca-certificates
        ;;
      apk)
        sudo apk add --no-cache docker docker-cli-compose curl ca-certificates
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-update add docker default 2>/dev/null || true
    sudo rc-service docker start 2>/dev/null || true
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin not available. Install docker-compose-v2 / docker-compose and re-run."
  fi
  ok "Docker ready."
}

# ── prompts ────────────────────────────────────────────────────────────────
ask_config() {
  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
  prompt PORT "Host port" "$DEFAULT_PORT"
  prompt DATA_DIR "Data directory" "$INSTALL_DIR/data"
  prompt ADMIN_USER "Admin username" "admin"
  prompt ADMIN_PASSWORD "Admin password" "changeme"
  prompt DB_PASSWORD "Database password" "nextcloud"
  prompt NC_IMAGE "Nextcloud image" "$NC_IMAGE"

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

  # Build trusted domains: localhost + detected IPs + user extras
  local detected
  detected=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -5 | tr '\n' ' ')
  info "Detected IPs: ${detected:-none}"
  prompt EXTRA_DOMAINS "Extra trusted domains/IPs (space-separated, e.g. 10.0.0.101 my.domain)" ""

  TRUSTED_DOMAINS="localhost ${detected} ${EXTRA_DOMAINS}"
  # collapse extra spaces
  TRUSTED_DOMAINS=$(echo "$TRUSTED_DOMAINS" | xargs)
  info "Trusted domains will be: $TRUSTED_DOMAINS"
}

# ── files ──────────────────────────────────────────────────────────────────
setup_files() {
  info "Setting up $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null || true

  info "Writing .env..."
  cat > "$INSTALL_DIR/.env" <<ENV
MYSQL_ROOT_PASSWORD=root${DB_PASSWORD}
MYSQL_PASSWORD=${DB_PASSWORD}
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASSWORD}
NEXTCLOUD_TRUSTED_DOMAINS=${TRUSTED_DOMAINS}
ENV

  info "Writing docker-compose.yml..."
  cat > "$INSTALL_DIR/docker-compose.yml" <<YML
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}

  redis:
    image: redis:7-alpine
    restart: unless-stopped

  app:
    image: ${NC_IMAGE}
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    depends_on:
      - db
      - redis
    volumes:
      - nextcloud:/var/www/html
      - ${DATA_DIR}:/var/www/html/data
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - REDIS_HOST=redis
      - NEXTCLOUD_ADMIN_USER=\${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=\${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=\${NEXTCLOUD_TRUSTED_DOMAINS}

  cron:
    image: ${NC_IMAGE}
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on:
      - db
      - redis
    volumes:
      - nextcloud:/var/www/html
      - ${DATA_DIR}:/var/www/html/data

volumes:
  db:
  nextcloud:
YML

  ok "Files ready."
}

# Pull images with retries so registry rate limits (e.g. ghcr.io
# "toomanyrequests") do not abort the install. Runs in the current dir.
pull_with_retry() {
  local -a dc=(docker compose)
  docker info >/dev/null 2>&1 || dc=(sudo docker compose)
  export COMPOSE_PARALLEL_LIMIT=1
  local delays=(10 20 40 60 60) attempt=0
  until "${dc[@]}" pull; do
    if (( attempt >= ${#delays[@]} )); then
      die "docker compose pull failed after $((attempt + 1)) attempts (registry rate limit or network). Wait a few minutes and rerun this script."
    fi
    warn "docker compose pull failed (attempt $((attempt + 1))/$((${#delays[@]} + 1))). Retrying in ${delays[$attempt]}s..."
    sleep "${delays[$attempt]}"
    attempt=$((attempt + 1))
  done
}

start_stack() {
  info "Starting Nextcloud (docker compose up -d)..."
  cd "$INSTALL_DIR"
  pull_with_retry
  if docker info >/dev/null 2>&1; then
    docker compose up -d
  else
    sudo docker compose up -d
  fi
  ok "Containers started."
}

# ── uninstall ──────────────────────────────────────────────────────────────
uninstall() {
  echo "Nextcloud uninstaller"
  echo "====================="
  detect_distro

  echo
  prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"

  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "Stopping containers..."
    cd "$INSTALL_DIR"
    if docker info >/dev/null 2>&1; then
      docker compose down || true
    else
      sudo docker compose down || true
    fi
    ok "Containers stopped."
  else
    warn "No docker-compose.yml found in $INSTALL_DIR"
  fi

  if ask_yn "Remove install directory $INSTALL_DIR (compose file and .env)?"; then
    sudo rm -rf "$INSTALL_DIR"
    ok "Install directory removed."
  fi

  if ask_yn "Also remove Docker volumes (database + Nextcloud files)? This deletes all data."; then
    if docker info >/dev/null 2>&1; then
      docker volume ls -q | grep -E 'nextcloud|db' | xargs -r docker volume rm || true
    else
      sudo docker volume ls -q | grep -E 'nextcloud|db' | xargs -r sudo docker volume rm || true
    fi
    ok "Volumes removed."
  fi

  if ask_yn "Also remove Docker packages? (may affect other containers)"; then
    info "Removing Docker packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y docker.io docker-compose-v2 || true ;;
      dnf)    sudo dnf remove -y docker docker-compose moby-engine || true ;;
      pacman) sudo pacman -Rns --noconfirm docker docker-compose || true ;;
      zypper) sudo zypper --non-interactive remove docker docker-compose || true ;;
      apk)    sudo apk del docker docker-cli-compose || true ;;
    esac
    ok "Package removal finished."
  fi

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Nextcloud installer (Docker Compose)"
      echo "===================================="
      detect_distro
      install_docker
      ask_config
      setup_files
      start_stack

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${PORT}"
      echo "  Dir:   $INSTALL_DIR"
      echo "  Data:  $DATA_DIR"
      echo "  User:  $ADMIN_USER"
      echo "  Trusted: $TRUSTED_DOMAINS"
      echo
      echo "First start can take a minute while Nextcloud initializes."
      echo
      echo "Useful commands (run from $INSTALL_DIR):"
      echo "  docker compose ps"
      echo "  docker compose logs -f app"
      echo "  docker compose down"
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
