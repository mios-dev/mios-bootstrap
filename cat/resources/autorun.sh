#!/bin/bash
# SystemRescue Autorun Script to Wipe All System Disks (Except USB Boot Media)

# Redirect all output to console and a temp log file
exec > >(tee -i /tmp/autorun.log /dev/console) 2>&1

echo "==============================================="
echo "   MiOS SYSTEM WIPE AUTORUN RESCUE SCRIPT      "
echo "==============================================="
echo "Started at: $(date)"

# 1. Identify the USB boot disk
usb_partition=$(readlink -f /dev/disk/by-label/Medicat)
if [ -z "$usb_partition" ] || [ ! -b "$usb_partition" ]; then
    echo "ERROR: Could not find USB partition labeled 'Medicat'!"
    # Fallback: scan mountpoints or sysfs
    usb_partition=$(mount | grep -E '/run/archiso/img_dev|/run/archiso/bootmnt' | awk '{print $1}' | head -n 1)
fi

if [ -b "$usb_partition" ]; then
    usb_disk=$(lsblk -no PKNAME "$usb_partition" 2>/dev/null)
    if [ -z "$usb_disk" ]; then
        usb_disk=$(echo "$usb_partition" | sed 's/[0-9]*$//')
    fi
    # Format to absolute dev path if needed
    if [[ ! "$usb_disk" =~ ^/dev/ ]]; then
        usb_disk="/dev/$usb_disk"
    fi
    echo "Identified USB boot partition: $usb_partition"
    echo "Identified USB boot disk: $usb_disk"
else
    echo "WARNING: USB partition not found. Extreme caution: will skip dev/loop only."
    usb_disk=""
fi

# 2. Iterate and wipe all other disks
echo "Scanning for local disks..."
for disk in $(lsblk -dno NAME,TYPE | grep disk | awk '{print "/dev/"$1}'); do
    [ -b "$disk" ] || continue
    
    # Exclude the USB boot disk
    if [ -n "$usb_disk" ] && [ "$disk" = "$usb_disk" ]; then
        echo "Skipping USB boot media disk: $disk"
        continue
    fi
    
    # Skip virtual loop devices
    if [[ "$disk" =~ loop ]]; then
        continue
    fi

    echo "Wiping disk: $disk ..."
    
    # Unmount any active mounts on this disk
    for part in $(lsblk -rno NAME "$disk" | tail -n +2); do
        dev_part="/dev/$part"
        if mountpoint -q "/mnt/$part" 2>/dev/null || grep -q "$dev_part" /proc/mounts; then
            echo "  Unmounting partition $dev_part"
            umount -f "$dev_part" 2>/dev/null || true
        fi
    done

    # Overwrite partition tables and headers (first 100MB)
    echo "  Zeroing out partition headers (100MB)..."
    dd if=/dev/zero of="$disk" bs=1M count=100 conv=fdatasync 2>/dev/null || true
    
    # Zap GPT data structures
    if command -v sgdisk >/dev/null 2>&1; then
        echo "  Zapping GPT metadata..."
        sgdisk --zap-all "$disk" 2>/dev/null || true
    fi
    
    # Inform kernel of partition changes
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$disk" 2>/dev/null || true
    fi
    
    echo "  [+] Disk $disk successfully wiped."
done

echo "Syncing changes..."
sync

# 3. Write log file back to USB partition
echo "Writing execution log back to USB partition..."
mkdir -p /mnt/usb_log
if mount -o remount,rw "$usb_partition" /mnt/usb_log 2>/dev/null || mount -o rw "$usb_partition" /mnt/usb_log 2>/dev/null; then
    cp /tmp/autorun.log /mnt/usb_log/autorun.log
    echo "Log successfully copied to USB partition."
    sync
    umount /mnt/usb_log 2>/dev/null || true
else
    # Try mounting any other writable partition on the USB disk to save log
    for part in $(lsblk -rno NAME,TYPE "$usb_disk" | grep part | awk '{print "/dev/"$1}'); do
        if mount -o rw "$part" /mnt/usb_log 2>/dev/null; then
            cp /tmp/autorun.log /mnt/usb_log/autorun.log
            sync
            umount /mnt/usb_log 2>/dev/null || true
            break
        fi
    done
fi

echo "==============================================="
echo "            SYSTEM WIPE COMPLETE               "
echo "        System will shut down in 10s           "
echo "==============================================="
sleep 10

poweroff
