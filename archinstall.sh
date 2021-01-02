#!/bin/bash


clear
echo -e "--- Setting variables ---\n"

efi_size=512
# swap size = memory / 2
swap_size=$(($(free --mebi | awk '/Mem:/ {print $2}')/2))
swap_end=$(( $swap_size + ${efi_size} + 1 ))MiB

echo "Enter hostname:";read hostname
echo "Enter username:";read username
echo "Enter password:";read password
echo "Enter password again:";read password2
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )


clear
echo -e "--- Disk partitioning ---\n"
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
echo -e "List of disks available to partition:\n$devicelist\n"
echo "Enter name of device to partition:";read device


clear
timedatectl set-ntp true

# Partition disk
parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib ${efi_size}MiB \
  set 1 boot on \
  mkpart primary linux-swap ${efi_size} ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

part_boot="$(ls ${device}* | grep -E "^${device}1")"
part_swap="$(ls ${device}* | grep -E "^${device}2")"
part_root="$(ls ${device}* | grep -E "^${device}3")"

# Wipe partitions
wipefs "${part_boot}"
wipefs "${part_swap}"
wipefs "${part_root}"

# Make and mount partitions
mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.ext4 "${part_root}"

swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

# Install packages
pacstrap /mnt base base-devel linux-zen linux-zen-headers nano dhcpcd dhcp

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Set up clock
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Vilnius /etc/localtime
arch-chroot /mnt hwclock --systohc

# Set up locale
arch-chroot /mnt nano /etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt echo "LANG=en_US.UTF-8" >> /etc/locale.conf

# Set hostname
arch-chroot /mnt echo $(hostname) > /etc/hostname

# Network configuration
arch-chroot /mnt cat <<EOF > /etc/hosts
127.0.0.1	localhost
::1	localhost
127.0.1.1	${hostname}.localdomain	${hostname}
EOF

# Add user
arch-chroot /mnt useradd -mU -G wheel "$username"
echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

# Install desktop environment
arch-chroot /mnt pacman -Syu kde-plasma sddm --noconfirm

# Enable things
arch-chroot /mnt systemctl enable sddm
arch-chroot /mnt systemctl enable dhcpcd

