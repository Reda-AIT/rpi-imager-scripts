#!/usr/bin/env bash

# Exit immediately on unhandled errors, uninitialized variables, or pipe failures
set -euo pipefail
version="1.0.0"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -b, --boot-source DIR  Path to the boot directory (e.g., /tftpboot)
  -r, --root-source DIR  Path to the root NFS directory (e.g., /nfs/raspi1)
  -o, --output IMAGE     Name of the output .img file (default: golden_image.img)
  -v, --version          Display version information
  -h, --help             Display this help message

Example:
  sudo $(basename "$0") -b /tftpboot -r /nfs/raspi1 -o custom_pi.img
EOF
    exit 1
}

# Default variables
IMAGE_NAME="golden_image.img"
BOOT_SOURCE=""
ROOT_SOURCE=""
LOOP_DEV=""

# Parse command-line arguments
while [[ $# -ge 1 ]]; do
    case "$1" in
        -b|--boot-source)
            BOOT_SOURCE="$2"
            shift 2
            ;;
        -r|--root-source)
            ROOT_SOURCE="$2"
            shift 2
            ;;
        -o|--output)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -v|--version)
            echo "Version $version"
            exit 0
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown parameter '$1'" >&2
            usage
            ;;
    esac
done

# Enforce required arguments
if [[ -z "$BOOT_SOURCE" ]] || [[ -z "$ROOT_SOURCE" ]]; then
    echo "Error: Both --boot-source and --root-source are required parameters." >&2
    usage
fi

# Validate source paths exist
if [[ ! -d "$BOOT_SOURCE" ]]; then
    echo "Error: Boot source directory '$BOOT_SOURCE' does not exist." >&2
    exit 1
fi

if [[ ! -d "$ROOT_SOURCE" ]]; then
    echo "Error: Root source directory '$ROOT_SOURCE' does not exist." >&2
    exit 1
fi

# Ensure script is running with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." >&2
   exit 1
fi

# Define local staging paths
MNT_BOOT="./mnt_boot_staging"
MNT_ROOT="./mnt_root_staging"

# Cleanup function executed automatically on script failure or exit
cleanup() {
    echo "Cleaning up staging environment..."
    set +e
    if mountpoint -q "$MNT_BOOT"; then sudo umount "$MNT_BOOT"; fi
    if mountpoint -q "$MNT_ROOT"; then sudo umount "$MNT_ROOT"; fi
    if [[ -n "$LOOP_DEV" ]] && losetup "$LOOP_DEV" &>/dev/null; then sudo losetup -d "$LOOP_DEV"; fi
    if [[ -d "$MNT_BOOT" ]]; then rmdir "$MNT_BOOT"; fi
    if [[ -d "$MNT_ROOT" ]]; then rmdir "$MNT_ROOT"; fi
    set -e
}
trap cleanup EXIT

# 1. Allocate a sparse 5GB empty container file
echo "Allocating 5GB raw file container: ${IMAGE_NAME}..."
dd if=/dev/zero of="${IMAGE_NAME}" bs=1M count=5120

# 2. Partition layout setup (Sector 8192 align, +256MB FAT32 boot, remainder ext4 root)
echo "Writing MBR partition tables..."
parted --script "${IMAGE_NAME}" \
    mklabel msdos \
    mkpart primary fat32 8192s 532479s \
    mkpart primary ext4 532480s 100%

# 3. Associate with kernel loop subsystem device channels
echo "Binding loop devices..."
LOOP_DEV=$(losetup --show -fP "${IMAGE_NAME}")
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# 4. Synthesize file systems on virtual sectors
echo "Formatting partitions (FAT32 and Ext4)..."
mkfs.vfat -F 32 -n "boot" "${BOOT_PART}"
mkfs.ext4 -F -L "rootfs" "${ROOT_PART}"

# 5. Establish staging mount boundaries
echo "Mounting image spaces..."
mkdir -p "$MNT_BOOT" "$MNT_ROOT"
mount "${BOOT_PART}" "$MNT_BOOT"
mount "${ROOT_PART}" "$MNT_ROOT"

# 6. Synchronize loose active filesystem trees into image sectors
echo "Copying active boot code binaries from ${BOOT_SOURCE}..."
cp -a "${BOOT_SOURCE}"/. "$MNT_BOOT"/

echo "Synchronizing root tree paths from ${ROOT_SOURCE}..."
rsync -aHAXx "${ROOT_SOURCE}"/ "$MNT_ROOT"/

# Force storage layer buffers to commit blocks to image
echo "Flushing file buffers to disk..."
sync

echo "Process complete. Raw file output built successfully: ${IMAGE_NAME}"