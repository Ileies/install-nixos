#!/usr/bin/env bash
set -euo pipefail

# --- helpers ---------------------------------------------------------------

msg() { printf "\n\033[1m%s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m%s\033[0m\n" "$*" >&2; }

confirm() {
  local prompt=${1:-"Proceed?"}
  read -r -p "$prompt [y/N] " ans || true
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  fi
}

init_logging() {
  # Try /var/log first; fall back to /tmp if not writable
  local default="/var/log/nixos-installer.log"
  if touch "$default" >/dev/null 2>&1; then
    LOG="$default"
  else
    LOG="/tmp/nixos-installer.log"
    touch "$LOG"
  fi
  # Start logging all stdout/stderr
  exec > >(tee -a "$LOG") 2>&1
  msg "Logging to $LOG"
}

cleanup() {
  set +e
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
}
# On error or Ctrl-C, explain and clean up mounts
trap 'err "Aborted due to an error or interrupt."; cleanup' ERR INT

is_mnt_clean() {
  # nothing mounted on /mnt?
  if findmnt -R -n /mnt >/dev/null 2>&1; then
    return 1
  fi
  # nothing inside /mnt ?
  if [ -d /mnt ] && [ -n "$(ls -A /mnt 2>/dev/null || true)" ]; then
    return 1
  fi
  return 0
}

part_suffix_for() {
  # nvme/mmcblk style need an extra 'p' before the partition number
  local d="$1"
  if [[ "$d" =~ (nvme|mmcblk) ]]; then
    echo "p"
  else
    echo ""
  fi
}

bytes_to_gb() {
  # decimal GB
  awk -v b="$1" 'BEGIN { printf "%.1f", b/1e9 }'
}

root_disk() {
  # Determine the physical disk that backs "/"
  local src; src="$(findmnt -no SOURCE / || true)"
  if [[ "$src" != /dev/* ]]; then
    echo ""; return
  fi
  local name="${src#/dev/}" pk
  # Walk up PKNAME until we reach a disk (PKNAME empty means root of tree)
  while true; do
    pk="$(lsblk -no PKNAME "/dev/$name" 2>/dev/null | head -n1 || true)"
    if [[ -z "$pk" ]]; then
      # 'name' is the top device (disk)
      # ensure it's a disk
      local t; t="$(lsblk -no TYPE "/dev/$name" 2>/dev/null | head -n1 || true)"
      [[ "$t" == "disk" ]] && echo "/dev/$name" || echo ""
      return
    fi
    name="$pk"
  done
}

list_candidate_disks() {
  local exclude="$1"
  # Output: index|/dev/sdX|MODEL|SIZE_GB
  local idx=0
  while IFS= read -r dn; do
    local dev="/dev/$dn"
    [[ -n "$exclude" && "$dev" == "$exclude" ]] && continue
    # Skip loop devices
    local type; type="$(lsblk -dn -o TYPE "$dev")"
    [[ "$type" != "disk" ]] && continue

    # capacity in bytes
    local bytes; bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    local gb; gb="$(bytes_to_gb "$bytes")"
    # model/title
    local model; model="$(lsblk -dn -o MODEL "$dev" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$model" ]] && model="(unknown model)"

    printf "%d|%s|%s|%s\n" "$idx" "$dev" "$model" "$gb"
    idx=$((idx+1))
  done < <(lsblk -dn -o NAME | sort)
}

any_partitions_mounted_on() {
  local disk="$1"
  # any mountpoints sourced from this disk's partitions?
  findmnt -nr -S "^${disk}[0-9p]*" | awk '{print $1" -> "$2}'
}

unmount_partitions_of() {
  local disk="$1"
  # Unmount deepest mountpoints first
  local lines
  lines="$(findmnt -nr -S "^${disk}[0-9p]*" -o TARGET | sort -r || true)"
  if [[ -n "$lines" ]]; then
    echo "$lines" | while IFS= read -r m; do
      umount -R "$m"
    done
  fi
}

require_tooling() {
  local missing=()
  for t in lsblk findmnt parted mkfs.vfat mkfs.ext4 nixos-generate-config nixos-install rsync wipefs; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    err "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

# --- main ------------------------------------------------------------------

need_root
init_logging
require_tooling

# 1) Ensure /mnt is clean & unused
if ! is_mnt_clean; then
  err "Nothing should be mounted or saved in /mnt before running this script. Please unmount and empty /mnt first."
  exit 1
fi

# 2) Ask for system/host name; ensure /etc/nixos/hosts/<name> doesn't already exist
msg "Choose a name for your new system (example: pronix):"
while true; do
  read -r -p "New host name: " NEWNAME
  NEWNAME="${NEWNAME// /-}"
  if [[ -z "${NEWNAME}" ]]; then
    err "Name cannot be empty."
    continue
  fi
  if [[ ! "$NEWNAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Invalid name. Use letters, numbers, dots, underscores, or dashes."
    continue
  fi
  if [[ -e "/etc/nixos/hosts/$NEWNAME" ]]; then
    err "/etc/nixos/hosts/$NEWNAME already exists. Pick another name."
    continue
  fi
  break
done

# 3) List storage devices excluding the disk that currently hosts /
ROOTDISK="$(root_disk || true)"
if [[ -n "$ROOTDISK" ]]; then
  msg "Detected system disk for '/': $ROOTDISK (excluded from selection)"
else
  msg "Could not determine the system disk backing '/'. Listing all disks."
fi

CANDIDATES="$(list_candidate_disks "$ROOTDISK")"
if [[ -z "$CANDIDATES" ]]; then
  err "No candidate disks found."
  exit 1
fi

msg "Available disks:"
printf "  %-4s %-12s %-32s %s\n" "IDX" "DEVICE" "MODEL" "SIZE(GB)"
echo "$CANDIDATES" | while IFS='|' read -r i dev model gb; do
  printf "  %-4s %-12s %-32s %s\n" "[$i]" "$(basename "$dev")" "$model" "$gb"
done

# 4) Ask user to pick by index
read -r -p "Enter the index of the disk to use: " PICK
if ! [[ "$PICK" =~ ^[0-9]+$ ]]; then
  err "Invalid index."
  exit 1
fi
# Resolve selection
LINE="$(echo "$CANDIDATES" | awk -F'|' -v idx="$PICK" '$1==idx {print}')"
if [[ -z "$LINE" ]]; then
  err "Index not in list."
  exit 1
fi
DISK="$(echo "$LINE" | awk -F'|' '{print $2}')"
MODEL="$(echo "$LINE" | awk -F'|' '{print $3}')"
SIZEGB="$(echo "$LINE" | awk -F'|' '{print $4}')"
# Show mounts (first time)
MOUNTED="$(any_partitions_mounted_on "$DISK" || true)"

# 5) FINAL SUMMARY + explicit confirmation
msg "Summary before wiping:"
echo "  Hostname:           $NEWNAME"
echo "  Target disk:        $DISK"
echo "  Model:              $MODEL"
echo "  Capacity (GB):      $SIZEGB"
if [[ -n "$MOUNTED" ]]; then
  echo "  Mounted partitions: "
  echo "$MOUNTED"
else
  echo "  Mounted partitions: none"
fi
if ! confirm "ALL DATA on $DISK WILL BE ERASED. Is this correct?"; then
  err "Aborted."
  exit 1
fi

# 6) Unmount partitions if needed
if [[ -n "$MOUNTED" ]]; then
  msg "Unmounting partitions on $DISK ..."
  unmount_partitions_of "$DISK"
fi

# 7) SAFETY: Clear metadata, partition fresh GPT, create ESP+root
msg "Clearing old metadata on $DISK ..."
wipefs -af "$DISK"
if command -v sgdisk >/dev/null 2>&1; then
  sgdisk --zap-all "$DISK"
fi

msg "Creating new GPT partition table on $DISK ..."
parted -s "$DISK" mklabel gpt

msg "Creating EFI System Partition (500MiB) and root partition (rest) ..."
parted -s "$DISK" mkpart boot fat32 1MiB 501MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" set 1 boot on
parted -s "$DISK" name 1 boot
parted -s "$DISK" mkpart root ext4 501MiB 100%
parted -s "$DISK" name 2 nixos

P="$(part_suffix_for "$(basename "$DISK")")"
BOOT="${DISK}${P}1"
ROOT="${DISK}${P}2"

# 8) Make filesystems
msg "Formatting filesystems ..."
mkfs.vfat -F32 -n boot "$BOOT"
mkfs.ext4 -L nixos -F "$ROOT"

# 9) Mount to /mnt
msg "Mounting target root to /mnt and EFI to /mnt/boot ..."
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# 10) Generate hardware config on target
msg "Generating NixOS hardware configuration ..."
nixos-generate-config --root /mnt

# 11) Copy current flake, restructure host files (flake-first flow)
msg "Copying current flake from /etc/nixos to target /mnt/etc/nixos ..."
rsync -a /etc/nixos/ /mnt/etc/nixos/

msg "Restructuring host files for '$NEWNAME' ..."
mkdir -p "/mnt/etc/nixos/hosts/$NEWNAME"
if [[ -f /mnt/etc/nixos/hardware-configuration.nix ]]; then
  mv /mnt/etc/nixos/hardware-configuration.nix "/mnt/etc/nixos/hosts/$NEWNAME/"
fi
if [[ -f /mnt/etc/nixos/configuration.nix ]]; then
  rm -f /mnt/etc/nixos/configuration.nix
fi
if [[ -d /mnt/etc/nixos/hosts/template ]]; then
  for f in default.nix users.nix; do
    if [[ -f "/mnt/etc/nixos/hosts/template/$f" ]]; then
      cp "/mnt/etc/nixos/hosts/template/$f" "/mnt/etc/nixos/hosts/$NEWNAME/$f"
    fi
  done
fi

# 12) SINGLE-PASS INSTALL via flake (skip double install)
if [[ -f /mnt/etc/nixos/flake.nix ]]; then
  msg "Installing system using flake '#$NEWNAME' ..."
  # Ensure flakes enabled for this session (harmless if already set)
  export NIX_CONFIG="${NIX_CONFIG:-} experimental-features = nix-command flakes"
  nixos-install --root /mnt --no-root-passwd --flake "/mnt/etc/nixos#$NEWNAME"
else
  err "No flake.nix found in /mnt/etc/nixos; falling back to generated configuration."
  nixos-install --root /mnt --no-root-passwd
fi

# Success — disable traps and cleanly finish
trap - ERR INT
msg "All done. The system is installed and configured for host '$NEWNAME'. You can reboot into the new system now."
