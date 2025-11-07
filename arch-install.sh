## Written by: Lucas M Rodrigues 07/11/2025
## Arch installation for personal Machine

#!/usr/bin/env bash
set -euo pipefail
cleanup() { umount -R /mnt 2>/dev/null || true; swapoff -a 2>/dev/null || true; }
trap cleanup EXIT

## ========= SET VALUES
DISK="/dev/nvme0n1"
EFI_SIZE_MIB=512
SWAP_SIZE_MIB=4096
ROOT_FS="ext4"     # atualmente fixo em ext4

## ========= PARTITIONS ALIAS
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"

## ========= PARTITIONING/FORMATTING/MOUNTING
partition_format_mount() {
  echo "[*] Cleaning old mounts (if they exist)..."
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true

  echo "[*] Wiping and recreating GPT on $DISK..."
  parted -s "$DISK" mklabel gpt

  ## CALCULATE LIMITS IN MiB
  ESP_START_MIB=1
  ESP_END_MIB=$((ESP_START_MIB + EFI_SIZE_MIB))
  SWAP_START_MIB=$ESP_END_MIB
  SWAP_END_MIB=$((SWAP_START_MIB + SWAP_SIZE_MIB))
  ROOT_START_MIB=$SWAP_END_MIB

  echo "[*] Creating partitions (EFI=${EFI_SIZE_MIB}MiB, SWAP=${SWAP_SIZE_MIB}MiB, ROOT=rest)..."
  parted -s "$DISK" mkpart ESP fat32 "${ESP_START_MIB}MiB" "${ESP_END_MIB}MiB"
  parted -s "$DISK" set 1 esp on
  parted -s "$DISK" mkpart swap linux-swap "${SWAP_START_MIB}MiB" "${SWAP_END_MIB}MiB"
  parted -s "$DISK" mkpart root ext4 "${ROOT_START_MIB}MiB" 100%

  # make the kernel re-read the new partition table
  partprobe "$DISK" || true
  udevadm settle || true
  sleep 1

  echo "[*] Formatting partitions..."
  mkfs.fat -F32 "${EFI_PART}"
  mkswap "${SWAP_PART}"
  mkfs.ext4 -F "${ROOT_PART}"

  echo "[*] Mounting..."
  swapon "${SWAP_PART}"
  mount "${ROOT_PART}" /mnt
  mkdir -p /mnt/boot/efi
  mount "${EFI_PART}" /mnt/boot/efi

  echo "[*] Done: $EFI_PART (EFI), $SWAP_PART (swap), $ROOT_PART (/) mounted."
}

## ======= PRE-CHECKS (ROOT, DISK, NET, UEFI/BIOS, DEPS)
pre_checks() {
  echo "[*] Running pre-checks..."

  # root?
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[!] Run this script as root."
    exit 1
  fi

  # existing disk?
  if [[ ! -b "$DISK" ]]; then
    echo "[!] Disk not found: $DISK"
    lsblk
    exit 1
  fi

  # minimum deps
  for cmd in parted partprobe udevadm mkfs.fat mkfs.ext4 mkswap mount swapon lsblk blkid timedatectl ping; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[!] Missing command: $cmd"; exit 1; }
  done

  # boot mode
  if [[ -d /sys/firmware/efi/efivars ]]; then
    BOOTMODE="UEFI"
  else
    BOOTMODE="BIOS"
  fi
  echo "    Boot mode: $BOOTMODE"

  # net
  if ! ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
    echo "[!] No internet connectivity. Connect before proceeding."
    exit 1
  fi

  # NTP
  timedatectl set-ntp true || true
}

## ========= BASE INSTALL (vars)
HOSTNAME="ArchRice"
USERNAME="Archnight"
PASSWORD="12345abcde"
PKGS="base linux linux-firmware git nano networkmanager intel-ucode sudo"

## ========= BASE INSTALL (pacstrap) + FSTAB
install_base_and_fstab() {
  echo "[*] Running pacstrap..."
  pacstrap -K /mnt $PKGS grub efibootmgr mtools dosfstools

  echo "[*] Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab
  echo "[V] Pacstrap done and fstab generated."
}

## ========= INITIAL SYSTEM CONFIG (chroot)
configure_system_in_chroot() {
  echo "[*] Entering chroot to configure timezone/locale/user/hostname and GRUB..."

  arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

TIMEZONE="America/Fortaleza"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
BOOTMODE="$BOOTMODE"

echo "[*] Timezone & clock..."
ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime
hwclock --systohc

echo "[*] Locale & keymap..."
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/#pt_BR.UTF-8/pt_BR.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=pt_BR.UTF-8' > /etc/locale.conf
echo 'KEYMAP=br-abnt2' > /etc/vconsole.conf

echo "[*] Hostname & hosts..."
echo "\$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   \$HOSTNAME.localdomain \$HOSTNAME
EOF

echo "[*] Users & sudo..."
echo "root:\$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash "\$USERNAME"
echo "\$USERNAME:\$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "[*] Services..."
systemctl enable NetworkManager

echo "[*] GRUB install..."
if [[ "\$BOOTMODE" == "UEFI" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  echo "[!] BIOS mode detected. GRUB MBR will be installed from host after chroot."
fi

grub-mkconfig -o /boot/grub/grub.cfg

# quality of life
pacman --noconfirm -S bash-completion reflector >/dev/null || true
systemctl enable reflector.timer || true

echo "[✓] chroot config done."
CHROOT

  # Em BIOS/Legacy, precisamos gravar no MBR do DISCO, fora do chroot:
  if [[ "$BOOTMODE" == "BIOS" ]]; then
    echo "[*] Installing GRUB to MBR on $DISK (BIOS mode)..."
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
}

## ======== MAIN FLOW 
main() {
  pre_checks
  partition_format_mount
  install_base_and_fstab
  configure_system_in_chroot

  echo
  echo "[✓] Installation finished."
  echo "    To reboot:"
  echo "    umount -R /mnt && swapoff -a || true && reboot"
}

main "$@"
