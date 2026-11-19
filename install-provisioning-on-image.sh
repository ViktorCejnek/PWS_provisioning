#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONING_SH="$SCRIPT_DIR/provisioning.sh"
FIRSTLOGIN_FILE="$SCRIPT_DIR/.not_logged_in_yet"

read -r -e -p "Path to Armbian .img file: " IMAGE_PATH
[[ -n "${IMAGE_PATH//[[:space:]]/}" ]] || { echo "ERROR: No image path provided." >&2; exit 1; }
IMAGE_PATH="$(realpath -e -- "$IMAGE_PATH")"

for file in "$PROVISIONING_SH" "$FIRSTLOGIN_FILE"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: Required file is missing: $file" >&2
    exit 1
  fi
done

for command in lsblk losetup realpath mount umount sync install stat sed grep; do
  command -v "$command" >/dev/null || {
    echo "ERROR: Required command '$command' is missing." >&2
    exit 1
  }
done

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "ERROR: Image file not found: $IMAGE_PATH" >&2
  exit 1
fi

printf 'Normalizing line endings to LF...\n'
for file in "$FIRSTLOGIN_FILE" "$PROVISIONING_SH"; do
  if grep -q $'\r' "$file"; then
    sed -i 's/\r$//' "$file"
    printf '  Converted CRLF to LF: %s\n' "$file"
  else
    printf '  LF line endings confirmed: %s\n' "$file"
  fi

  if grep -q $'\r' "$file"; then
    echo "ERROR: CR characters remain in $file." >&2
    exit 1
  fi
done

if [[ $(id -u) -ne 0 ]]; then
  command -v sudo >/dev/null || {
    echo "ERROR: This script requires root privileges; 'sudo' is not installed." >&2
    exit 1
  }
  sudo -v
  SUDO="sudo"
else
  SUDO=""
fi

MOUNT_POINT="$(mktemp -d /tmp/pws-armbian-image.XXXXXX)"
LOOP_DEVICE=""
MOUNTED=0

cleanup() {
  local status=$?
  set +e
  if [[ "$MOUNTED" -eq 1 ]]; then
    sync
    $SUDO umount "$MOUNT_POINT" >/dev/null 2>&1
  fi
  if [[ -n "$LOOP_DEVICE" ]]; then
    $SUDO losetup -d "$LOOP_DEVICE" >/dev/null 2>&1
  fi
  rmdir "$MOUNT_POINT" >/dev/null 2>&1
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

printf 'Image: %s\n' "$IMAGE_PATH"
printf 'Using loop device; requesting partition privileges...\n'
LOOP_DEVICE="$($SUDO losetup --find --show --partscan -- "$IMAGE_PATH")"

udevadm settle 2>/dev/null || true

mapfile -t EXT4_PARTITIONS < <(
  lsblk -lnpo NAME,FSTYPE "$LOOP_DEVICE" |
    awk '$2 == "ext4" { print $1 }'
)

if [[ ${#EXT4_PARTITIONS[@]} -eq 0 ]]; then
  echo "ERROR: No ext4 partition found in $IMAGE_PATH." >&2
  exit 1
fi

ROOT_PARTITION=""
for partition in "${EXT4_PARTITIONS[@]}"; do
  if $SUDO mount -t ext4 -o rw "$partition" "$MOUNT_POINT" 2>/dev/null; then
    MOUNTED=1
    if [[ -d "$MOUNT_POINT/root" && -d "$MOUNT_POINT/etc" ]]; then
      ROOT_PARTITION="$partition"
      break
    fi
    $SUDO umount "$MOUNT_POINT" >/dev/null 2>&1
    MOUNTED=0
  fi
done

if [[ -z "$ROOT_PARTITION" ]]; then
  echo "ERROR: Could not identify the Armbian root partition." >&2
  exit 1
fi

printf 'Root partition: %s\n' "$ROOT_PARTITION"

$SUDO install -d -o root -g root -m 0755 "$MOUNT_POINT/root"
$SUDO install -o root -g root -m 0600 "$FIRSTLOGIN_FILE" "$MOUNT_POINT/root/.not_logged_in_yet"
$SUDO install -o root -g root -m 0755 "$PROVISIONING_SH" "$MOUNT_POINT/root/provisioning.sh"

FIRSTLOGIN_DEST="$MOUNT_POINT/root/.not_logged_in_yet"
PROVISIONING_DEST="$MOUNT_POINT/root/provisioning.sh"

verify_installed_file() {
  local file=$1
  local expected_mode=$2
  local actual

  actual="$($SUDO stat -c '%u:%g:%a' "$file")"
  if [[ "$actual" != "0:0:$expected_mode" ]]; then
    echo "ERROR: $file has owner/mode $actual; expected 0:0:$expected_mode." >&2
    exit 1
  fi

  if grep -q $'\r' "$file"; then
    echo "ERROR: $file still contains CR characters." >&2
    exit 1
  fi

  printf '  Verified root:root %s: %s\n' "$expected_mode" "$file"
}

sync
printf 'Verifying installed files...\n'
verify_installed_file "$FIRSTLOGIN_DEST" 600
verify_installed_file "$PROVISIONING_DEST" 755

printf 'Copied:\n'
printf '  %s -> %s/root/.not_logged_in_yet (root:root, 0600, LF)\n' "$FIRSTLOGIN_FILE" "$MOUNT_POINT"
printf '  %s -> %s/root/provisioning.sh (root:root, 0755, LF)\n' "$PROVISIONING_SH" "$MOUNT_POINT"

$SUDO umount "$MOUNT_POINT"
MOUNTED=0
sync

$SUDO losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=""
rmdir "$MOUNT_POINT"
trap - EXIT HUP INT TERM

printf '\nDone. The image has been synced and safely unmounted.\n'
printf 'It is now safe to remove the SD card or write the image to it.\n'
