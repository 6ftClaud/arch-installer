#!/bin/bash

# Logging
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
exec 2> >(tee "stderr.log")

# Ensuring time is correct
timedatectl set-ntp true

# Installing dependencies
pacman -Syyu dialog reflector --noconfirm

# Setting variables
echo -e "--- Setting variables ---\n"
efi_size=513
swap_size=$(($(free --mebi | awk '/Mem:/ {print $2}')/2))
swap_end=$(( $swap_size + ${efi_size} + 1 ))MiB
echo "Enter hostname:";read hostname
echo "Enter username:";read username
echo "Enter password:";read password
echo "Enter password again:";read password2
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )


# Partitioning disk
echo -e "--- Disk partitioning ---\n"
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
partitionlist=$(lsblk -plnx size -o name,size | grep ${device} | tac)


# Partition disk
echo "Partitioning disk"
parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib ${efi_size}MiB \
  set 1 boot on \
  mkpart primary linux-swap ${efi_size}MiB ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

part_boot=$(dialog --stdout --menu "Select boot partition" 0 0 0 ${partitionlist}) || exit 1
part_swap=$(dialog --stdout --menu "Select swap partition" 0 0 0 ${partitionlist}) || exit 1
part_root=$(dialog --stdout --menu "Select root partition" 0 0 0 ${partitionlist}) || exit 1

# Make and mount partitions
echo "Making and mounting partitions"
mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.ext4 "${part_root}"

swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

# Updating mirrorlist
mkdir /mnt/etc;mkdir /mnt/etc/pacman.d
reflector -c "LT" -f 12 -l 10 -n 12 --save /mnt/etc/pacman.d/mirrorlist

# Install packages
echo "Installing packages"
pacstrap /mnt base base-devel linux-zen linux-zen-headers nano dhcpcd dhcp refind

# Generate fstab
echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Set up clock
echo "Setting up clock"
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Vilnius /etc/localtime
arch-chroot /mnt hwclock --systohc

# Set up locale
echo "Setting up locale"
arch-chroot /mnt echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
arch-chroot /mnt echo "en_US ISO-8859-1" >> /etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo "Setting hostname"
arch-chroot /mnt echo $(hostname) > /etc/hostname

# Network configuration
echo "Configuring network"
arch-chroot /mnt cat <<EOF > /etc/hosts
127.0.0.1	localhost
::1	localhost
127.0.1.1	${hostname}.localdomain	${hostname}
EOF
arch-chroot /mnt systemctl enable dhcpcd

# Add user
echo "Adding user"
arch-chroot /mnt useradd -mU -G wheel "$username"
echo "$username:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

# Install bootloader
echo "Installing bootloader"
arch-chroot /mnt refind-install --usedefault ${part_boot}

# Install desktop environment
echo "Installing desktop environment and display manager"
arch-chroot /mnt pacman -Syu plasma sddm --noconfirm
arch-chroot /mnt systemctl enable sddm

# Unmount partitions
umount $part_boot
umount $part_root
swapoff $part_swap

# End install
[ -s stderr.log ] && echo "Something went wrong during install, check stderr.log" || \
read -p -e "Installed successfully.\nPress enter to reboot." && reboot