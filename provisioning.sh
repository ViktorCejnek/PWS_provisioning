#!/usr/bin/env bash
# ==============================================================================
#  /root/provisioning.sh
#  Armbian First-Boot Autonomous Provisioning Hook for PWS400K on OrangePi 3 LTS
#
#  Armbian's 'armbian-firstlogin' (https://docs.armbian.com/user-guide/autoconfig/)
#  automatically executes this script ONCE as root immediately after creating
#  the user account and network configured in /root/.not_logged_in_yet.
#
#  HOW TO DEPLOY ON SD CARD:
#    1. Mount the ext4 root partition on Linux / WSL2:
#         sudo mount /dev/sdX2 /mnt
#    2. Copy .not_logged_in_yet to /mnt/root/.not_logged_in_yet
#    3. Copy this file to /mnt/root/provisioning.sh
#    4. Optionally copy pws400k-setup.sh to /mnt/root/pws400k-setup.sh.
#       If absent, provisioning.sh downloads it from this repository.
#    5. (Optional) chmod +x /mnt/root/provisioning.sh
#       Note: Even without chmod +x, Armbian sources it via: . /root/provisioning.sh
#             and provisioning.sh automatically chmods pws400k-setup.sh!
#    6. Unmount: sudo umount /mnt
#    7. Insert into OrangePi 3 LTS and boot up. Complete setup is autonomous!
# ==============================================================================

# ── User Configuration ────────────────────────────────────────────────────────
LANG_VARIANT="en"                   # 'en' for PWS_400K_EN or 'cz' for PWS_400K_CZ
PRINTER_HOSTNAME="pws"              # mDNS hostname -> http://pws.local
PRINTER_SERIAL=""                   # Optional: e.g. "AA23000" (first line in moonraker.conf)
ENABLE_SPECTODA=0                   # 0 to skip spectoda completely (default), 1 to enable
TIMEZONE="Europe/Prague"

# Download the current setup script when it is not pre-staged in /root.
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/ViktorCejnek/PWS_provisioning/main/pws400k-setup.sh"
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail
LOG="/var/log/pws400k-provisioning.log"
exec > >(tee -a "$LOG") 2>&1

echo "========================================================"
echo " Starting PWS 400K Autonomous Provisioning — $(date)"
echo "========================================================"

LOCK="/root/.provisioning_done"
if [[ -f "$LOCK" ]]; then
  echo "Provisioning already completed previously. Exiting."
  exit 0
fi

# 1. System Hostname & Timezone
echo "[1/4] Setting hostname: $PRINTER_HOSTNAME"
hostnamectl set-hostname "$PRINTER_HOSTNAME"
echo "$PRINTER_HOSTNAME" > /etc/hostname
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${PRINTER_HOSTNAME}/" /etc/hosts || \
  echo "127.0.1.1 ${PRINTER_HOSTNAME}" >> /etc/hosts

# echo "[1/5] Setting timezone: $TIMEZONE"
# timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

# 2. Base packages for downloading and running
echo "[2/4] Updating apt package lists..."
apt-get update -qq
apt-get install -y --no-install-recommends git curl wget

# 3. Fetch pws400k-setup.sh
echo "[3/4] Preparing pws400k-setup.sh..."
TARGET_SH="/home/pi/pws400k-setup.sh"

if [[ -f "/root/pws400k-setup.sh" ]]; then
  echo "Using pre-staged setup script from /root/pws400k-setup.sh"
  chmod +x /root/pws400k-setup.sh
  cp /root/pws400k-setup.sh "$TARGET_SH"
else
  echo "Downloading setup script from: $SETUP_SCRIPT_URL"
  if ! curl -fsSL "$SETUP_SCRIPT_URL" -o "${TARGET_SH}.tmp"; then
    rm -f "${TARGET_SH}.tmp"
    echo "ERROR: Could not download pws400k-setup.sh from $SETUP_SCRIPT_URL"
    exit 1
  fi
  mv "${TARGET_SH}.tmp" "$TARGET_SH"
fi

if [[ ! -f "$TARGET_SH" ]]; then
  echo "ERROR: Could not locate pws400k-setup.sh! Provisioning aborted."
  exit 1
fi

chown pi:pi "$TARGET_SH"
chmod +x "$TARGET_SH"

# 4. Execute setup script as user 'pi'
echo "[4/4] Launching pws400k-setup.sh as user 'pi'..."
SETUP_ARGS=("--lang" "$LANG_VARIANT")
if [[ -n "$PRINTER_SERIAL" ]]; then
  SETUP_ARGS+=("--serial" "$PRINTER_SERIAL")
fi
if [[ "$ENABLE_SPECTODA" -eq 1 ]]; then
  SETUP_ARGS+=("--enable-spectoda")
else
  SETUP_ARGS+=("--skip-spectoda")
fi

echo "Granting pi user passwordless sudo for headless installation..."
echo "pi ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010_pi-nopasswd
chmod 0440 /etc/sudoers.d/010_pi-nopasswd

sudo -u pi -H bash "$TARGET_SH" "${SETUP_ARGS[@]}"

# Mark complete
touch "$LOCK"

echo "========================================================"
echo " Provisioning successfully finished! Rebooting in 10s..."
echo "========================================================"
sleep 5
echo "Removing pi user passwordless sudo after headless installation..."
rm -f /etc/sudoers.d/010_pi-nopasswd
sleep 5
reboot
