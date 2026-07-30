#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/hirogura/selfnote.git"
INSTALL_DIR="${SELFNOTE_DIR:-$HOME/.selfnote}"
DATA_DIR="${SELFNOTE_DATA:-/opt/lxd-data/note}"
PORT="${SELFNOTE_PORT:-3342}"
HOST="${SELFNOTE_HOST:-127.0.0.1}"

print_bold() { printf "\033[1m%s\033[0m\n" "$*"; }
print_ok()   { printf "\033[32m%s\033[0m\n" "  [✔] $*"; }
print_info() { printf "\033[36m%s\033[0m\n" "  [i] $*"; }
print_err() { printf "\033[31m%s\033[0m\n" "  [✘] $*"; }

detect_pkg_manager() {
  if   command -v apt-get &>/dev/null; then echo "apt"
  elif command -v dnf &>/dev/null;    then echo "dnf"
  elif command -v yum &>/dev/null;    then echo "yum"
  elif command -v pacman &>/dev/null; then echo "pacman"
  elif command -v zypper &>/dev/null; then echo "zypper"
  elif command -v apk &>/dev/null;    then echo "apk"
  else echo ""; fi
}

check_node() {
  if ! command -v node &>/dev/null; then
    print_err "Node.js is not installed."
    local pm; pm=$(detect_pkg_manager)
    if [ -n "$pm" ]; then
      echo ""
      print_info "You can install Node.js with:"
      case "$pm" in
        apt)    echo "  sudo apt-get install -y nodejs npm" ;;
        dnf|yum) echo "  sudo $pm install -y nodejs npm" ;;
        pacman) echo "  sudo pacman -S nodejs npm" ;;
        zypper) echo "  sudo zypper install -y nodejs npm" ;;
        apk)    echo "  sudo apk add nodejs npm" ;;
      esac
      echo ""
      read -rp "Install Node.js now? [Y/n] " yn
      if [[ ! "$yn" =~ ^[Nn] ]]; then
        case "$pm" in
          apt)    sudo apt-get install -y nodejs npm ;;
          dnf)    sudo dnf install -y nodejs npm ;;
          yum)    sudo yum install -y nodejs npm ;;
          pacman) sudo pacman -S --noconfirm nodejs npm ;;
          zypper) sudo zypper --non-interactive install -y nodejs npm ;;
          apk)    sudo apk add nodejs npm ;;
        esac
      fi
    fi
    if ! command -v node &>/dev/null; then
      print_err "Node.js is still missing. Install it manually from https://nodejs.org"
      exit 1
    fi
  fi
  print_ok "Node.js $(node -v)"
}

install_selfnote() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    print_info "SelfNote is already installed at $INSTALL_DIR"
    print_info "Pulling latest changes..."
    git -C "$INSTALL_DIR" pull --ff-only
  else
    mkdir -p "$INSTALL_DIR"
    print_info "Cloning $REPO into $INSTALL_DIR ..."
    git clone "$REPO" "$INSTALL_DIR"
  fi
  print_ok "SelfNote installed at $INSTALL_DIR"
}

setup_data_dir() {
  if [ ! -d "$DATA_DIR" ]; then
    print_info "Creating data directory: $DATA_DIR"
    sudo mkdir -p "$DATA_DIR"
  fi
  sudo chown "$(id -u):$(id -g)" "$DATA_DIR"
  print_ok "Data directory ready: $DATA_DIR"
}

setup_systemd_service() {
  if ! command -v systemctl &>/dev/null; then
    print_info "systemd not detected; skipping service setup."
    return
  fi

  local service_name="selfnote"
  local service_file="/etc/systemd/system/${service_name}.service"

  if [ -f "$service_file" ]; then
    print_info "systemd service already exists at $service_file"
    read -rp "Overwrite? [y/N] " yn
    if [[ ! "$yn" =~ ^[Yy] ]]; then
      print_info "Skipping service setup."
      return
    fi
  fi

  cat <<EOF | sudo tee "$service_file" >/dev/null
[Unit]
Description=SelfNote - Self-hosted Markdown Editor
After=network.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$INSTALL_DIR
ExecStart=$(command -v node) $INSTALL_DIR/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=SELFNOTE_PORT=$PORT
Environment=SELFNOTE_HOST=$HOST
Environment=SELFNOTE_DATA=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  print_ok "systemd service created: $service_file"

  read -rp "Enable and start SelfNote now? [Y/n] " yn
  if [[ ! "$yn" =~ ^[Nn] ]]; then
    sudo systemctl enable --now "$service_name"
    print_ok "Service enabled and started."
    print_info "Status: sudo systemctl status $service_name"
    print_info "Logs:   sudo journalctl -u $service_name -f"
  fi
}

show_summary() {
  echo ""
  print_bold "══════════════════════════════════════════"
  print_bold "  SelfNote installation complete!"
  print_bold "══════════════════════════════════════════"
  echo ""
  print_info "Install directory: $INSTALL_DIR"
  print_info "Data directory:    $DATA_DIR"
  print_info ""
  print_info "To start manually:"
  echo "    cd $INSTALL_DIR && node server.js"
  echo ""
  print_info "SelfNote will be available at:"
  echo "    http://$HOST:$PORT"
  echo ""
  print_info "To uninstall:"
  echo "    rm -rf $INSTALL_DIR"
  echo "    sudo rm /etc/systemd/system/selfnote.service (if created)"
  echo ""
}

main() {
  echo ""
  print_bold "  SelfNote Installer"
  print_bold "  ─────────────────"
  echo ""

  check_node
  install_selfnote

  if [ "$DATA_DIR" = "/opt/lxd-data/note" ]; then
    setup_data_dir
  else
    mkdir -p "$DATA_DIR"
    print_ok "Data directory created: $DATA_DIR"
  fi

  echo ""
  if read -rp "Set up systemd service for auto-start? [Y/n] " yn; then
    if [[ ! "$yn" =~ ^[Nn] ]]; then
      setup_systemd_service
    fi
  fi

  show_summary
}

main "$@"
