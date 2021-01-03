#!/bin/bash
# Warning: the script wipes the entire disk


# Logging
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# Ensuring time is correct
timedatectl set-ntp true

# Installing dependencies
pacman -Syyu --noconfirm dialog reflector

# Setting variables
swapsize=$(($(cat /proc/meminfo | grep MemTotal | awk '{ print $2 }')/2000))"M"
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
username=$(dialog --stdout --inputbox "Enter username" 0 0) || exit 1
password=$(dialog --stdout --inputbox "Enter password" 0 0) || exit 1
password2=$(dialog --stdout --inputbox "Enter password again" 0 0) || exit 1
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )
GPU=$(dialog --stdout --menu "Select which GPU drivers to install" 0 40 0 'radeon' '' 'nvidia' '' 'intel integrated' '') || exit 1
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

# Install packages
echo "Installing packages"
pacstrap /mnt base base-devel nano dhcpcd dhcp konsole ark dolphin discord git mpv nomacs 
# Install wifi packages if wifi is available
[[ $(ip link) == *"wlan"* ]] && pacstrap /mnt iw iwd wpa_supplicant netctl dialog
# Install appropriate bootloader
if [ $EFI == 0 ]; then
	pacstrap /mnt refind
else
	pacstrap /mnt grub grub-customizer
fi

# Edit pacman.conf to enable multilib
arch-chroot /mnt sed -i '92s/#[multilib]/[multilib]/' /etc/pacman.conf
arch-chroot /mnt sed -i '93s/#Include = \/etc\/pacman.d\/mirrorlist/Include = \/etc\/pacman.d\/mirrorlist/' /etc/pacman.conf
arch-chroot /mnt pacman -Syyu --noconfirm

# Install GPU drivers
if [ $GPU == "radeon" ]; then
	arch-chroot /mnt pacman -S --noconfirm linux-zen linux-zen-headers linux-firmware lib32-mesa mesa vulkan-radeon xf86-video-amdgpu
elif [ $GPU == "nvidia" ]; then
	arch-chroot /mnt pacman -S --noconfirm linux linux-headers linux-firmware nvidia lib32-nvidia-utils
	arch-chroot /mnt nvidia-xconfig
elif [ $GPU == "intel integrated" ]; then
	arch-chroot /mnt pacman -S --noconfirm linux-zen linux-zen-headers linux-firmware mesa lib32-mesa vulkan-intel
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

# Install desktop environment
echo "Installing desktop environment and display manager"
arch-chroot /mnt pacman -S --noconfirm plasma sddm
arch-chroot /mnt systemctl enable sddm

# Install bootloader
if [ $EFI == 0 ]; then
	arch-chroot /mnt refind-install
else
	arch-chroot /mnt grub-install --target=i386-pc ${device}
	arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

# End install
cp stderr.log /mnt/home/${username}/Install_Errors.log
cp stdout.log /mnt/home/${username}/Install_Log.log
echo "Uncomment %wheel ALL=(ALL) ALL to add ${username} to sudoers"
[ -s stderr.log ] && echo "Something went wrong during install, check stderr.log" \
|| echo -e "\nInstalled successfully."