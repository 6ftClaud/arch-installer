#!/bin/bash
# Warning: the script wipes the entire disk


# Logging
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# Ensuring time is correct
timedatectl set-ntp true

# Installing dependencies
pacman -Sy --noconfirm dialog reflector

# Setting variables
swapsize=$(($(cat /proc/meminfo | grep MemTotal | awk '{ print $2 }')/2000))"M"
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
username=$(dialog --stdout --inputbox "Enter username" 0 0) || exit 1
password=$(dialog --stdout --inputbox "Enter password" 0 0) || exit 1
password2=$(dialog --stdout --inputbox "Enter password again" 0 0) || exit 1
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )
DE=$(dialog --stdout --menu "Select which Desktop Environment to install" 0 60 0 'KDE' '' 'Gnome' '' 'LXDE' '' 'Xfce' '' 'none' '') || exit 1
GPU=$(dialog --stdout --menu "Select which GPU drivers to install" 0 60 0 'radeon' '' 'nvidia' '' 'intel integrated' '' 'none' '') || exit 1
dialog --title "Use EFI mode?" --yesno "" 0 60;EFI=$?
clear

# Partitioning disk
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1

wipefs -a ${device}
if [ $EFI == 0 ]; then
	# EFI
	parted ${device} mklabel gpt
	sgdisk ${device} -n=1:0:+1024M -t=1:ef00
	sgdisk ${device} -n=2:0:+${swapsize} -t=2:8200
	sgdisk ${device} -n=3:0:0
else
	# BIOS
	parted ${device} mklabel gpt
	sgdisk ${device} -n=1:0:+32M -t=1:ef02
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

# Install base packages
pacstrap /mnt base base-devel linux linux-headers linux-firmware
# Install wifi packages if wifi is available
[[ $(ip link) == *"wlan"* ]] && pacstrap /mnt iw iwd wpa_supplicant netctl dialog networkmanager \
&& arch-chroot /mnt systemctl enable NetworkManager
# Install appropriate bootloader
if [ $EFI == 0 ]; then
	pacstrap /mnt refind
else
	pacstrap /mnt grub grub-customizer
fi

# Edit pacman.conf to enable multilib
echo "[multilib]" >> /mnt/etc/pacman.conf
echo "Include = /etc/pacman.d/mirrorlist" >> /mnt/etc/pacman.conf
arch-chroot /mnt pacman -Syyu --noconfirm nano dhcpcd dhcp discord git mpv nomacs cronie code firefox

# Install GPU drivers
if [ $GPU == "radeon" ]; then
	arch-chroot /mnt pacman -S --noconfirm lib32-mesa mesa vulkan-radeon xf86-video-amdgpu
elif [ $GPU == "nvidia" ]; then
	arch-chroot /mnt pacman -S --noconfirm nvidia lib32-nvidia-utils
	arch-chroot /mnt nvidia-xconfig
elif [ $GPU == "intel integrated" ]; then
	arch-chroot /mnt pacman -S --noconfirm mesa lib32-mesa vulkan-intel
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
echo $hostname > /mnt/etc/hostname

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
# Add user to sudoers
echo "${username} ALL=(ALL) ALL" >> /mnt/etc/sudoers

# Install desktop environment
echo "Installing desktop environment"
if [ $DE == "KDE" ]; then
	arch-chroot /mnt pacman -S --noconfirm plasma konsole ark dolphin
else if [ $DE == "Gnome"]; then
	arch-chroot /mnt pacman -S --noconfirm gnome
else if [ $DE == "LXDE"]; then
	arch-chroot /mnt pacman -S --noconfirm lxde-gtk3
else if [ $DE == "Xfce"]; then
	arch-chroot /mnt pacman -S --noconfirm xfce4
fi

echo "Installing login manager"
arch-chroot /mnt pacman -S --noconfirm sddm
arch-chroot /mnt systemctl enable sddm

# Install bootloader
if [ $EFI == 0 ]; then
	arch-chroot /mnt refind-install
	UUID=$(arch-chroot /mnt findmnt -no UUID /)
	> /mnt/boot/refind_linux.conf
	echo "\"Boot with standard options\"  \"root=UUID=$UUID rw quiet loglevel=3\"" >> /mnt/boot/refind_linux.conf
	echo "\"Boot to single-user mode\"    \"root=UUID=$UUID rw quiet loglevel=3 single\"" >> /mnt/boot/refind_linux.conf
	echo "\"Boot with minimal options\"   \"ro root=$part_root\"" >> /mnt/boot/refind_linux.conf
else
	arch-chroot /mnt grub-install --target=i386-pc ${device}
	arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

# End install
cp stderr.log /mnt/home/${username}/Install_Errors.log
cp stdout.log /mnt/home/${username}/Install_Log.log

echo -e "\nLogs are located at /home/${username}/\nScript's work here is done.\n"
[ -s stderr.log ] && echo "Something went wrong during install, check stderr.log" \
|| echo -e "Installed successfully."
