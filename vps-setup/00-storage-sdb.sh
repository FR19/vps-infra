#!/bin/bash
set -euo pipefail

# Storage setup for a fresh VPS with two disks:
# - /dev/sda: OS disk (already in use)
# - /dev/sdb: data disk (unused) -> format + mount to /srv
#
# This script will ERASE /dev/sdb by default. To proceed, set:
#   CONFIRM_ERASE_SDB=yes
#
# After running:
# - /srv will be backed by /dev/sdb1 (ext4)
# - directories for k3s data + PVs + backups will be created under /srv

DATA_DISK="${DATA_DISK:-/dev/sdb}"
PARTITION="${PARTITION:-/dev/sdb1}"
MOUNTPOINT="${MOUNTPOINT:-/srv}"
FS_LABEL="${FS_LABEL:-vps-data}"

K3S_DATA_DIR="${K3S_DATA_DIR:-/srv/k3s}"
K3S_STORAGE_DIR="${K3S_STORAGE_DIR:-/srv/k3s/storage}"
BACKUP_DIR="${BACKUP_DIR:-/srv/backups}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Please run as root (sudo)."
  exit 1
fi

if [[ "${CONFIRM_ERASE_SDB:-no}" != "yes" ]]; then
  echo "ERROR: Refusing to run without confirmation."
  echo "This will ERASE ${DATA_DISK}. If you're sure, run:"
  echo "  sudo CONFIRM_ERASE_SDB=yes bash 00-storage-sdb.sh"
  exit 1
fi

if [[ ! -b "${DATA_DISK}" ]]; then
  echo "ERROR: ${DATA_DISK} not found (block device missing)."
  exit 1
fi

echo "=== Storage Setup (${DATA_DISK} -> ${MOUNTPOINT}) ==="

echo "Installing required packages (parted, util-linux)..."
apt-get update -y
apt-get install -y parted util-linux e2fsprogs

# Safety checks: refuse if disk is mounted or has a filesystem (fresh VPS expected)
if lsblk -no MOUNTPOINT "${DATA_DISK}" | awk 'NF{exit 0} END{exit 1}'; then
  echo "ERROR: ${DATA_DISK} appears to be mounted. Aborting."
  lsblk "${DATA_DISK}"
  exit 1
fi

if blkid "${DATA_DISK}" >/dev/null 2>&1; then
  echo "ERROR: ${DATA_DISK} already has a filesystem signature. Aborting to avoid data loss."
  blkid "${DATA_DISK}" || true
  exit 1
fi

if [[ -b "${PARTITION}" ]]; then
  echo "ERROR: ${PARTITION} already exists. Aborting to avoid overwriting an existing partition table."
  lsblk "${DATA_DISK}"
  exit 1
fi

echo "Creating GPT partition table and a single partition on ${DATA_DISK}..."
parted -s "${DATA_DISK}" mklabel gpt
parted -s -a optimal "${DATA_DISK}" mkpart primary ext4 0% 100%

echo "Waiting for kernel to recognize the new partition..."
partprobe "${DATA_DISK}" || true
udevadm settle || true

if [[ ! -b "${PARTITION}" ]]; then
  echo "ERROR: Expected partition ${PARTITION} not found after partitioning."
  lsblk "${DATA_DISK}"
  exit 1
fi

echo "Formatting ${PARTITION} as ext4 (label: ${FS_LABEL})..."
mkfs.ext4 -F -L "${FS_LABEL}" "${PARTITION}"

echo "Creating mountpoint ${MOUNTPOINT}..."
mkdir -p "${MOUNTPOINT}"

UUID="$(blkid -s UUID -o value "${PARTITION}")"
if [[ -z "${UUID}" ]]; then
  echo "ERROR: Failed to read UUID from ${PARTITION}."
  exit 1
fi

FSTAB_LINE="UUID=${UUID} ${MOUNTPOINT} ext4 defaults,noatime 0 2"

echo "Persisting mount in /etc/fstab..."
if grep -q "${UUID}" /etc/fstab; then
  echo "fstab entry already exists for UUID=${UUID}."
else
  echo "${FSTAB_LINE}" >> /etc/fstab
fi

echo "Mounting ${MOUNTPOINT}..."
mount "${MOUNTPOINT}"

echo "Creating directories for k3s data, PV storage, and backups..."
mkdir -p "${K3S_DATA_DIR}" "${K3S_STORAGE_DIR}" "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

echo "Storage setup complete."
echo
echo "Mounted:"
df -h "${MOUNTPOINT}"
echo
echo "Next:"
echo "  - Run k3s install script (06-k3s-install.sh)."
echo "  - Then run local-path storage move script (07-k3s-local-path-to-srv.sh)."
