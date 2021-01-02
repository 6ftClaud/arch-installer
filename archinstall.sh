#!/bin/bash

# Install script for an EFI system.
# Warning: the script wipes the entire disk


# Logging
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# Ensuring time is correct
timedatectl set-ntp true

# Installing dependencies
pacman -Syyu dialog reflector --noconfirm

# Setting variables
echo -e "--- Setup ---\n"
swap_size=$(($(free --mebi | awk '/Mem:/ {print $2}')/2))
swap_end=$(($swap_size+512))MiB
echo "Enter hostname:";read hostname
echo "Enter username:";read username
echo "Enter password:";read password
echo "Enter password again:";read password2
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )
echo "Use EFI mode? (y, n):";read EFI

# Partitioning disk
echo -e "--- Disk partitioning ---\n"
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1

if [ $EFI == "y" ]; then
	parted --script "${device}" -- mklabel gpt \
	  mkpart "EFI" fat32 1Mib 512MiB \
	  set 1 esp on \
	  mkpart "swap" linux-swap 512MiB ${swap_end} \
	  mkpart "root" ext4 ${swap_end} 100%
else
	sgdisk ${device} -n=1:0:+31M -t=1:ef02
	sgdisk ${device} -n=2:0:+512M
	sgdisk ${device} -n=3:0:+${swapsize} -t=3:8200
	sgdisk ${device} -n=4:0:0
fi

partitionlist=$(lsblk -plnx size -o name,size | grep ${device} | tac)
part_boot=$(dialog --stdout --menu "Select boot partition" 0 0 0 ${partitionlist}) || exit 1
part_swap=$(dialog --stdout --menu "Select swap partition" 0 0 0 ${partitionlist}) || exit 1
part_root=$(dialog --stdout --menu "Select root partition" 0 0 0 ${partitionlist}) || exit 1

# Make and mount partitions
echo "Making and mounting partitions"
mkfs.fat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.ext4 "${part_root}"

swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

# Updating mirrorlist
reflector -c "LT" -f 12 -l 10 -n 12 --save /etc/pacman.d/mirrorlist
mkdir /mnt/etc;mkdir /mnt/etc/pacman.d
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# Install packages
echo "Installing packages"
pacstrap /mnt base base-devel linux-zen linux-zen-headers nano dhcpcd dhcp
# Install wifi packages if wifi is available
[[ $(ip link) == *"wlan"* ]] && pacstrap /mnt iw iwd wpa_supplicant netctl dialog
# Install appropriate bootloader
if [ $EFI == "y"* ]; then
	pacstrap /mnt refind
else
	pacstrap /mnt grub
fi

# Generate fstab
echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Set up clock
echo "Setting up clock"
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Vilnius /etc/localtime
arch-chroot /mnt hwclock --systohc

# Set up locale
echo "Setting up locale"
echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
echo "en_US ISO-8859-1" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

# Set hostname
echo "Setting hostname"
echo $(hostname) > /mnt/etc/hostname

# Network (ethernet) configuration
echo "Configuring network"
cat <<EOF > /mnt/etc/hosts
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
read -n 1 -s -r -p "Uncomment %wheel ALL=(ALL) ALL to add ${username} to sudoers"
arch-chroot /mnt nano /etc/sudoers

# Install desktop environment
echo "Installing desktop environment and display manager"
arch-chroot /mnt pacman -Syu plasma sddm --noconfirm
arch-chroot /mnt systemctl enable sddm

# Install bootloader
if [ $EFI == "y" ]; then
	echo -e "\nInstall rEFInd with refind-install"
	arch-chroot /mnt
else
	echo -e "\nInstall GRUB with grub-install --target=i386-pc ${device}\ngrub-mkconfig -o /boot/grub/grub.cfg"
	arch-chroot /mnt
fi

# End install
cp stderr.log /mnt/home/${username}/Install_Errors.log
cp stdout.log /mnt/home/${username}/Install_Log.log
[ -s stderr.log ] && echo "Something went wrong during install, check stderr.log" \
|| echo -e "\nInstalled successfully."