#!/usr/bin/env bash

# Hardcoded execution variables
IMAGE_NAME="golden_image_bookworm.img"
BOOT_SOURCE="/tftpboot"
ROOT_SOURCE="/nfs/raspi1"

# 1. Allocate a sparse 5GB empty container file
echo "Allocating empty raw file system payload image container..."
dd if=/dev/zero of="${IMAGE_NAME}" bs=1M count=5120

# 2. Partition layout setup (Sector 8192 align, +256MB FAT32 boot, remainder ext4 root)
echo "Writing MBR partition tables..."
sudo parted --script "${IMAGE_NAME}" \
    mklabel msdos \
    mkpart primary fat32 8192s 532479s \
    mkpart primary ext4 532480s 100%

# 3. Associate with kernel loop subsystem device channels
echo "Binding loop devices..."
LOOP_DEV=$(sudo losetup --show -fP "${IMAGE_NAME}")
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# 4. Synthesize file systems on virtual sectors
echo "Formating partitions (FAT32 and Ext4)..."
sudo mkfs.vfat -F 32 -n "boot" "${BOOT_PART}"
sudo mkfs.ext4 -F -L "rootfs" "${ROOT_PART}"

# 5. Establish staging mount boundaries
echo "Mounting image spaces..."
mkdir -p ./mnt_boot ./mnt_root
sudo mount "${BOOT_PART}" ./mnt_boot
sudo mount "${ROOT_PART}" ./mnt_root

# 6. Synchronize loose active filesystem trees into image sectors
echo "Copying active boot code binaries..."
sudo cp -a "${BOOT_SOURCE}"/. ./mnt_boot/

echo "Synchronizing root tree paths (preserving extended attributes/ACLs)..."
sudo rsync -aHAXxv "${ROOT_SOURCE}"/ ./mnt_root/

# Force storage layer buffers to commit blocks to image
sync

# 7. Safe Teardown
echo "Unmounting local file trees..."
sudo umount ./mnt_boot
sudo umount ./mnt_root
sudo losetup -d "${LOOP_DEV}"
rmdir ./mnt_boot ./mnt_root

echo "Base processing complete. Raw file output built: ${IMAGE_NAME}"

