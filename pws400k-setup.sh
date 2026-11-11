#!/usr/bin/env bash
# ==============================================================================
#  pws400k-setup.sh
#  Automated Headless Provisioning for PrintWithSmile PWS400K on OrangePi 3 LTS
#
#  Installs and configures:
#    - System dependencies & UART / GPIO pins (UART3 for MCU)
#    - Klipper (firmware host communicating via /dev/ttyS3 @ 250000 baud)
#    - Moonraker (REST/WebSocket API with GPIO power control)
#    - Mainsail (web frontend on port 80 via Nginx)
#    - Crowsnest (webcam streamer on port 8080)
#    - Klipper_IP (network status plugin showing IP on LCD display)
#    - PWS 400K printer configurations (EN or CZ)
#    - Optional: Spectoda Bridge (disabled by default)
#
#  Usage:
#    ./pws400k-setup.sh [--lang en|cz] [--serial AA12345] [--enable-spectoda]
#
#  Remote one-liner:
#    curl -fsSL https://raw.githubusercontent.com/<YOUR_FORK>/provision/pws400k-setup.sh | bash -s -- --lang en
# ==============================================================================
set -euo pipefail

# ── Configurable defaults ─────────────────────────────────────────────────────
LANG_VARIANT="${LANG_VARIANT:-en}"          # 'en' or 'cz'
PRINTER_SERIAL="${PRINTER_SERIAL:-}"        # e.g. AA23000 (optional serial number)
ENABLE_SPECTODA="${ENABLE_SPECTODA:-0}"      # Default 0 (disabled / skipped)
HOME_DIR="${HOME:-/home/pi}"
KLIPPER_USER="${KLIPPER_USER:-pi}"
PWS_DIR="${HOME_DIR}/PWS"
PRINTER_DATA="${HOME_DIR}/printer_data"
KLIPPER_DIR="${HOME_DIR}/klipper"
MOONRAKER_DIR="${HOME_DIR}/moonraker"
MAINSAIL_DIR="${HOME_DIR}/mainsail"
CROWSNEST_DIR="${HOME_DIR}/crowsnest"
SPECTODA_BRIDGE_DIR="${HOME_DIR}/spectoda-bridge-pws400k"
SPECTODA_PKG_DIR="${HOME_DIR}/spectoda-pws400k"
KLIPPER_IP_DIR="${HOME_DIR}/Klipper_IP"
MOONRAKER_SPECTODA_DIR="${HOME_DIR}/moonraker-spectoda-connector"

# Public GitHub Repositories (PrintWithSmile)
REPO_BASE="https://github.com/PrintWithSmile"
CONFIG_EN_REPO="${REPO_BASE}/PWS_400K_EN.git"
CONFIG_CZ_REPO="${REPO_BASE}/PWS_400K_CZ.git"
KLIPPER_IP_REPO="${REPO_BASE}/Klipper_IP.git"
SPECTODA_BRIDGE_REPO="${REPO_BASE}/spectoda-bridge-pws400k.git"
SPECTODA_PKG_REPO="${REPO_BASE}/spectoda-pws400k.git"
PWS_INSTALL_REPO="${REPO_BASE}/PWS_install.git"
MOONRAKER_SPECTODA_REPO="https://github.com/fragaria/moonraker-spectoda-connector.git"

LOG_FILE="/tmp/pws400k-setup.log"

# ── Output styling ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC}   $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" | tee -a "$LOG_FILE"; exit 1; }

# ── Parse CLI arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)            LANG_VARIANT="$2"; shift 2 ;;
    --serial)          PRINTER_SERIAL="$2"; shift 2 ;;
    --enable-spectoda) ENABLE_SPECTODA=1; shift ;;
    --skip-spectoda)   ENABLE_SPECTODA=0; shift ;;
    *)                 warn "Unknown parameter: $1"; shift ;;
  esac
done

[[ "$LANG_VARIANT" =~ ^(en|cz)$ ]] || error "Invalid --lang '$LANG_VARIANT'. Choose 'en' or 'cz'."

# ── Safety check ──────────────────────────────────────────────────────────────
if [[ "$EUID" -eq 0 ]]; then
  error "This script should be run as the user 'pi' (with sudo rights), not directly as root."
fi

step() { echo -e "\n${YELLOW}════ $* ════${NC}" | tee -a "$LOG_FILE"; }

################################################################################
# STEP 0 – Stopping all services just in case
################################################################################
step "0/11  Updating system and installing base packages"
info "Ensuring services are stopped before provisioning..."
sudo systemctl stop klipper moonraker nginx crowsnest spectoda-bridge-pws400k moonraker-spectoda-connector 2>/dev/null || true

################################################################################
# STEP 1 – Update OS & Install Core Dependencies
################################################################################
step "1/11  Updating system and installing base packages"

sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# Install libgpiod (libgpiod3 on Debian 12 / Bookworm, fallback to libgpiod2 on older)
GPIOD_PKG="libgpiod3"
if ! apt-cache show libgpiod3 &>/dev/null; then
  GPIOD_PKG="libgpiod2"
fi

sudo apt-get install -y --no-install-recommends \
  git curl wget python3 python3-pip python3-venv python3-dev \
  libffi-dev libssl-dev liblzma-dev build-essential \
  libncurses-dev libusb-1.0-0-dev pkg-config \
  nginx libnginx-mod-stream \
  iproute2 net-tools wireless-tools rfkill \
  gpiod "$GPIOD_PKG" \
  avrdude stm32flash openocd \
  jq unzip zip ca-certificates

# Install bluetooth packages only if spectoda is enabled
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  sudo apt-get install -y --no-install-recommends bluetooth bluez bluez-tools || true
fi

success "Base packages installed ($GPIOD_PKG)"

################################################################################
# STEP 2 – Hardware: Configure UART3, UART0 & GPIO Pins
################################################################################
step "2/11  Configuring UART3 and GPIO permissions"

ARMBIAN_ENV="/boot/armbianEnv.txt"

# 1. UART3 overlay for MCU communication (/dev/ttyS3)
UART3_OVERLAY="uart3"
if ls /boot/dtb/allwinner/overlay/sun50i-h6-uart3* &>/dev/null 2>&1; then
  UART3_OVERLAY="sun50i-h6-uart3"
fi

if [[ -f "$ARMBIAN_ENV" ]]; then
  if ! grep -qE "(^|\s)${UART3_OVERLAY}(\s|$)" "$ARMBIAN_ENV"; then
    if grep -q "^overlays=" "$ARMBIAN_ENV"; then
      sudo sed -i "s/^overlays=\(.*\)/overlays=\1 ${UART3_OVERLAY}/" "$ARMBIAN_ENV"
    else
      echo "overlays=${UART3_OVERLAY}" | sudo tee -a "$ARMBIAN_ENV"
    fi
    info "Added '${UART3_OVERLAY}' overlay to $ARMBIAN_ENV"
  else
    info "UART3 overlay already present in $ARMBIAN_ENV"
  fi
fi

sudo systemctl stop bluetooth.service hciuart.service 2>/dev/null
sudo systemctl disable bluetooth.service hciuart.service 2>/dev/null
sudo systemctl mask bluetooth.service hciuart.service

# 2. Release ttyS0 only if it is active
if systemctl is-active --quiet serial-getty@ttyS0.service 2>/dev/null; then
  info "Disabling serial-getty on ttyS0 to free port for Spectoda Controller..."
  sudo systemctl stop serial-getty@ttyS0.service 2>/dev/null || true
  sudo systemctl disable serial-getty@ttyS0.service 2>/dev/null || true
  sudo systemctl mask serial-getty@ttyS0.service 2>/dev/null || true
fi

# 3. Add pi user to dialout, gpio, and tty groups
sudo usermod -aG dialout,tty "$KLIPPER_USER"
sudo usermod -aG gpio "$KLIPPER_USER" 2>/dev/null || true
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  sudo usermod -aG bluetooth "$KLIPPER_USER" 2>/dev/null || true
fi

# 4. Udev rules for non-root hardware access (UART & GPIO chips)
UDEV_RULE="/etc/udev/rules.d/99-pws400k-hardware.rules"
sudo tee "$UDEV_RULE" > /dev/null <<'EOF'
# Klipper MCU UART
KERNEL=="ttyS3", GROUP="dialout", MODE="0660"
# GPIO chip access for Moonraker power control (gpiochip1/gpio117)
KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
EOF
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  echo 'KERNEL=="ttyS0", GROUP="dialout", MODE="0660"' | sudo tee -a "$UDEV_RULE" > /dev/null
fi
sudo udevadm control --reload-rules || true
sudo udevadm trigger || true

success "UART3 & GPIO rules configured"

################################################################################
# STEP 3 – Setup Directory Structure
################################################################################
step "3/11  Setting up directories"

mkdir -p "${PWS_DIR}"
mkdir -p "${PRINTER_DATA}/config/PWS_config"
mkdir -p "${PRINTER_DATA}/config/Archive"
mkdir -p "${PRINTER_DATA}/gcodes"
mkdir -p "${PRINTER_DATA}/logs"
mkdir -p "${PRINTER_DATA}/comms"
mkdir -p "${PRINTER_DATA}/systemd"

# Moonraker allowed services file
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  cat > "${PRINTER_DATA}/moonraker.asvc" <<EOF
klipper
crowsnest
spectoda-bridge-pws400k
moonraker-spectoda-connector
EOF
else
  cat > "${PRINTER_DATA}/moonraker.asvc" <<EOF
klipper
crowsnest
EOF
fi

success "Directories & moonraker.asvc created"

################################################################################
# STEP 4 – Clone Public PrintWithSmile Repositories
################################################################################
step "4/11  Cloning PrintWithSmile public repositories"

clone_or_update() {
  local repo="$1" dest="$2" branch="${3:-}"
  if [[ -d "${dest}/.git" ]]; then
    info "Updating repository: $(basename "$dest")"
    git -C "$dest" pull --ff-only || true
  else
    info "Cloning repository: $repo → $dest"
    if [[ -n "$branch" ]]; then
      git clone --branch "$branch" "$repo" "$dest"
    else
      git clone "$repo" "$dest"
    fi
  fi
}

# 1. Printer configuration (EN or CZ)
if [[ "$LANG_VARIANT" == "en" ]]; then
  CONFIG_REPO="$CONFIG_EN_REPO"
  CONFIG_DIR="${PWS_DIR}/PWS_400K_EN"
  CONFIG_SUBDIR="Configurations"
else
  CONFIG_REPO="$CONFIG_CZ_REPO"
  CONFIG_DIR="${PWS_DIR}/PWS_400K_CZ"
  CONFIG_SUBDIR="Konfigurace"
fi

clone_or_update "$CONFIG_REPO"            "$CONFIG_DIR"
clone_or_update "$KLIPPER_IP_REPO"        "$KLIPPER_IP_DIR"
clone_or_update "$PWS_INSTALL_REPO"       "${PWS_DIR}/PWS_install"

if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  clone_or_update "$SPECTODA_BRIDGE_REPO"   "$SPECTODA_BRIDGE_DIR" "release"
  clone_or_update "$SPECTODA_PKG_REPO"      "$SPECTODA_PKG_DIR"
  clone_or_update "$MOONRAKER_SPECTODA_REPO" "$MOONRAKER_SPECTODA_DIR"
fi

# Setup automatic post-merge hook so 'git pull' hot-deploys updated configs
HOOK_FILE="${CONFIG_DIR}/.git/hooks/post-merge"
cat > "$HOOK_FILE" <<HOOK
#!/bin/sh
echo "[PWS] Syncing updated configurations to printer_data..."
cp -f "${CONFIG_DIR}/printer.cfg"     "${PRINTER_DATA}/config/"
cp -f "${CONFIG_DIR}/moonraker.conf"  "${PRINTER_DATA}/config/"
cp -f "${CONFIG_DIR}/crowsnest.conf"  "${PRINTER_DATA}/config/"
cp -rf "${CONFIG_DIR}/${CONFIG_SUBDIR}/." "${PRINTER_DATA}/config/PWS_config/"
chown -R ${KLIPPER_USER}:${KLIPPER_USER} "${PRINTER_DATA}/config"
echo "[PWS] Configuration sync complete."
HOOK
chmod +x "$HOOK_FILE"

success "Repositories cloned and post-merge hook configured"

################################################################################
# STEP 5 – Install Klipper
################################################################################
step "5/11  Installing Klipper"

if [[ ! -d "${KLIPPER_DIR}/.git" ]]; then
  git clone https://github.com/Klipper3d/klipper.git "$KLIPPER_DIR"
fi

# Note: Klipper's legacy install-debian.sh script attempts to install deprecated
# 'python-dev' (Python 2), which fails on Debian 12 / Bookworm.
# We create the Python 3 virtual environment directly using python3-venv.
info "Creating Klipper Python 3 virtual environment..."
if [[ ! -d "${KLIPPER_DIR}/klippy-env" ]]; then
  python3 -m venv "${KLIPPER_DIR}/klippy-env"
fi
"${KLIPPER_DIR}/klippy-env/bin/pip" install --upgrade pip
"${KLIPPER_DIR}/klippy-env/bin/pip" install --quiet -r "${KLIPPER_DIR}/scripts/klippy-requirements.txt"

# Service definition for Klipper
sudo tee /etc/systemd/system/klipper.service > /dev/null <<EOF
[Unit]
Description=Klipper 3D Printer Firmware
Documentation=https://www.klipper3d.org/
After=network.target
Before=moonraker.service

[Service]
Type=simple
User=${KLIPPER_USER}
RemainAfterExit=yes
WorkingDirectory=${KLIPPER_DIR}
EnvironmentFile=/etc/default/klipper
ExecStart=${KLIPPER_DIR}/klippy-env/bin/python ${KLIPPER_DIR}/klippy/klippy.py \${KLIPPER_ARGS}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/default/klipper > /dev/null <<EOF
KLIPPER_ARGS="${PRINTER_DATA}/config/printer.cfg -l ${PRINTER_DATA}/logs/klippy.log -a ${PRINTER_DATA}/comms/klippy.sock"
EOF

success "Klipper installed & enabled"

################################################################################
# STEP 6 – Install Moonraker
################################################################################
step "6/11  Installing Moonraker"

if [[ ! -d "${MOONRAKER_DIR}/.git" ]]; then
  git clone https://github.com/Arksine/moonraker.git "$MOONRAKER_DIR"
fi

if [[ -f "${MOONRAKER_DIR}/scripts/install-moonraker.sh" ]]; then
  info "Running Moonraker official install-moonraker.sh..."
  
  # -f : Force overwrite of systemd/polkit rules
  # -s : Install C-extension speedups 
  # -z : Disable systemctl commands (avoids starting Moonraker early)
  # -d : Set custom data path
  bash "${MOONRAKER_DIR}/scripts/install-moonraker.sh" -f -s -z -d "${PRINTER_DATA}"
else
  error "Moonraker repository is corrupted or install script is missing!"
fi

success "Moonraker installed (service enable deferred to Step 12)"

################################################################################
# STEP 7 – Install Mainsail (Web Frontend via Nginx)
################################################################################
step "7/11  Installing Mainsail web interface"

mkdir -p "$MAINSAIL_DIR"
MAINSAIL_RELEASE_URL=$(curl -fsSL "https://api.github.com/repos/mainsail-crew/mainsail/releases/latest" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['assets'][0]['browser_download_url'])" 2>/dev/null || \
  echo "https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip")

curl -fsSL "$MAINSAIL_RELEASE_URL" -o /tmp/mainsail.zip
unzip -qo /tmp/mainsail.zip -d "$MAINSAIL_DIR"
rm -f /tmp/mainsail.zip

# Nginx site configuration
sudo tee /etc/nginx/sites-available/mainsail > /dev/null <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream moonraker {
    server 127.0.0.1:7125;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;
    root ${MAINSAIL_DIR};
    index index.html;

    client_max_body_size 1G;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /websocket {
        proxy_pass http://moonraker/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }

    location ~ ^/(printer|api|access|machine|server)/ {
        proxy_pass http://moonraker\$request_uri;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300;
    }

    location /webcam/ {
        proxy_pass http://127.0.0.1:8080/;
    }
}
EOF

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
sudo nginx -t

success "Mainsail installed on port 80"

################################################################################
# STEP 8 – Install Crowsnest (Webcam Streamer)
################################################################################
step "8/11  Installing Crowsnest"

# Follow official Mainsail instructions: https://docs.mainsail.xyz/crowsnest/setup/installation/
# cd ~ && git clone https://github.com/mainsail-crew/crowsnest.git
# cd ~/crowsnest && sudo make install
if [[ ! -d "${CROWSNEST_DIR}/.git" ]]; then
  git clone https://github.com/mainsail-crew/crowsnest.git "$CROWSNEST_DIR"
fi

cd "$CROWSNEST_DIR"
# CROWSNEST_UNATTENDED=1 allows sudo make install to run headlessly without interactive prompts
sudo CROWSNEST_UNATTENDED=1 CROWSNEST_ADD_CROWSNEST_MOONRAKER=1 make install || warn "Crowsnest installer finished with warnings"
cd "$HOME_DIR"

success "Crowsnest installed"

################################################################################
# STEP 9 – Spectoda Bridge (Optional / Skipped by default)
################################################################################
step "9/11  Nope"

################################################################################
# STEP 10 – Install Klipper_IP (Network Status Plugin)
################################################################################
step "10/11  Installing Klipper_IP plugin"

if [[ -f "${KLIPPER_IP_DIR}/install.sh" ]]; then
  bash "${KLIPPER_IP_DIR}/install.sh"
else
  ln -sf "${KLIPPER_IP_DIR}/network_status.py" "${KLIPPER_DIR}/klippy/extras/network_status.py"
fi

success "Klipper_IP plugin installed"

################################################################################
# STEP 11 – Deploy Printer Configurations
################################################################################
step "11/11  Deploying PWS 400K configurations"

# Backup existing configs if found
if [[ -f "${PRINTER_DATA}/config/printer.cfg" ]]; then
  BACKUP_FILE="${PRINTER_DATA}/config/Archive/printer.cfg.$(date +%Y%m%d_%H%M%S).bak"
  cp "${PRINTER_DATA}/config/printer.cfg" "$BACKUP_FILE"
  info "Existing printer.cfg backed up to $(basename "$BACKUP_FILE")"
fi

# Deploy primary configuration files
cp -f "${CONFIG_DIR}/printer.cfg"     "${PRINTER_DATA}/config/"
# cp -f "${CONFIG_DIR}/moonraker.conf"  "${PRINTER_DATA}/config/"
cp -f "${CONFIG_DIR}/crowsnest.conf"  "${PRINTER_DATA}/config/"
cp -rf "${CONFIG_DIR}/${CONFIG_SUBDIR}/." "${PRINTER_DATA}/config/PWS_config/"

# Ensure static IP CGNAT subnet (100.64.0.0/10) is in trusted_clients
if ! grep -q "100.64.0.0/10" "${PRINTER_DATA}/config/moonraker.conf"; then
  sed -i '/trusted_clients:/a \    100.64.0.0/10' "${PRINTER_DATA}/config/moonraker.conf"
fi


# Inject printer serial number if provided (used by Spectoda bridge / identification)
if [[ -n "$PRINTER_SERIAL" ]]; then
  info "Setting printer serial number: #$PRINTER_SERIAL"
  sed -i "1s/^/#${PRINTER_SERIAL}\n/" "${PRINTER_DATA}/config/moonraker.conf"
fi

chown -R "${KLIPPER_USER}:${KLIPPER_USER}" "${PRINTER_DATA}"
chown -R "${KLIPPER_USER}:${KLIPPER_USER}" "${PWS_DIR}"
chown -R "${KLIPPER_USER}:${KLIPPER_USER}" "${KLIPPER_IP_DIR}"

success "Printer configs deployed"

################################################################################
# STEP 12 – Enable & Start Services
################################################################################
sudo systemctl daemon-reload

SERVICES=(klipper moonraker nginx crowsnest)
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  SERVICES+=(bluetooth spectoda-bridge-pws400k)
fi

for svc in "${SERVICES[@]}"; do
  sudo systemctl enable "$svc" 2>/dev/null || true
  sudo systemctl restart "$svc" 2>/dev/null || warn "Could not start $svc yet"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    success "$svc is active"
  else
    warn "$svc is not active yet (will start after reboot)"
  fi
done

IP_ADDR=$(hostname -I | awk '{print $1}' || echo "100.65.3.145")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           PWS 400K Headless Installation Complete!           ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Mainsail Web Interface : http://${IP_ADDR}                     ║${NC}"
echo -e "${GREEN}║  Moonraker API          : http://${IP_ADDR}:7125                ║${NC}"
echo -e "${GREEN}║  Webcam Stream          : http://${IP_ADDR}:8080                ║${NC}"
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
echo -e "${GREEN}║  Spectoda REST Bridge   : http://${IP_ADDR}:8888                ║${NC}"
fi
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║  ⚠ PLEASE REBOOT THE BOARD to load UART3 device tree overlay:║${NC}"
echo -e "${GREEN}║     sudo reboot                                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
