#!/bin/bash

# Credit goes to https://gist.githubusercontent.com/krzys-h/226a16eb56c82df0dc3a9d35fad989c8/raw/e794ea7863705aef7740b3a73685556a32c4e757/encrypt.sh
# Safe LUKS2 in-place encryption of ext4 partition
set -euo pipefail

DISK="$1"
HEADER_RESERVE="32M"

if [ -z "$DISK" ]; then
    echo "Usage: $0 /dev/sdXY"
    exit 1
fi

# Sanity checks
if mountpoint=$(lsblk -no MOUNTPOINT "$DISK") && [ -n "$mountpoint" ]; then
    echo "Error: $DISK is mounted at $mountpoint — unmount first."
    exit 1
fi

fstype=$(blkid -o value -s TYPE "$DISK")
if [ "$fstype" != "ext4" ]; then
    echo "Error: Only ext4 supported (found $fstype)"
    exit 1
fi

echo "Running fsck..."
e2fsck -f "$DISK"

# Make the filesystem slightly smaller to make space for the LUKS header
BLOCK_SIZE=`dumpe2fs -h $DISK | grep "Block size" | cut -d ':' -f 2 | tr -d ' '`
BLOCK_COUNT=`dumpe2fs -h $DISK | grep "Block count" | cut -d ':' -f 2 | tr -d ' '`
SPACE_TO_FREE=$((1024 * 1024 * 32)) # 16MB should be enough, but add a safety margin
NEW_BLOCK_COUNT=$(($BLOCK_COUNT - $SPACE_TO_FREE / $BLOCK_SIZE))
resize2fs -p "$DISK" "$NEW_BLOCK_COUNT"

echo "Encrypting partition in place with LUKS2..."
cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size "$HEADER_RESERVE" "$DISK"

echo "Opening encrypted device..."
cryptsetup open "$DISK" recrypt

echo "Expanding filesystem to fill encrypted volume..."
resize2fs /dev/mapper/recrypt
e2fsck -f /dev/mapper/recrypt

cryptsetup close recrypt

# Don't forget to update /etc/crypttab and /etc/fstab if required!
#
# For example:
# /etc/crypttab
# crypt_root    UUID=xxx    none    luks,keyscript=decrypt_keyctl
# crypt_home    UUID=xxx    none    luks,keyscript=decrypt_keyctl
# /etc/fstab
# /dev/mapper/crypt_root    /        ext4    errors=remount-ro    0    1
# /dev/mapper/crypt_home    /home    ext4    defaults             0    2
#
# The decrypt_keyctl makes it possible to unlock both partitions with the same password,
# and unlock gnome-keyring-daemon if you enable autologin and it's encrypted with the same password
# Note: if you are doing a clean install, using LVM is probably a better idea
#
# and remember to run "update-initramfs -u -k all" after updating the rootfs crypttab
