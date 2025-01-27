#!/bin/bash

# REGEX
REGEX_QUIT="[Qq]"
REGEX_YES="[Yy]"
REGEX_NO="[Nn]"
REGEX_SEARCH="[Ss]"

# variables
USERID=$(id -u)
EFIVARS_DIR="/sys/firmware/efi/efivars/"
DRIVES=''
ENCRYPTED_NAME=''
IS_NVME=''
EFI_PARTRITION=''
EFI_UUID=''
ROOT_PARTRITION=''
ROOT_UUID=''
LUKS_PARTRITION=''
LUKS_UUID=''
BTRFS_OPT=''
ARCH=''
REPO=''
HOST_NAME=''
LOCALES_FILE="/etc/default/libc-locales"
LOCALE=''
LINE_NUMBER=''
ADJUSTED_LINE_NUMBER=''
LANGUAGE=''
MEMORY=''
RESUME_OFFSET=''

# colors
NORMAL='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'

# check if root user
check_if_root() {
    if [[ ${USERID} != 0 ]]; then
        printf "${RED}%s${NORMAL}\n" "Please run this script as superuser!"
        sleep 1
        clear
        exit 0
    fi
}

# check if the system is uefi and mount the efivarfs if so
check_if_efi() {
    if [[ -d ${EFIVARS_DIR} ]]; then
        mount -t efivarfs efivarfs ${EFIVARS_DIR} >/dev/null
    else
        printf "${RED}%s${NORMAL}\n" "Please run this script only on efi systems!"
        sleep 1
        clear
        exit 0
    fi
}

# Select Drive:
select_drive() {
    mapfile -t DRIVES < <(lsblk -d --noheading -o NAME)
    PS3='Select the Disk you want to install Void Linux on: '
    lsblk -d -o NAME,SIZE,TYPE | grep -E "disk"
    select OPT in "${DRIVES[@]}" "Quit"; do
        if [[ -z "${OPT}" ]]; then
            printf "${RED}%s${NORMAL}\n" "Invalid Selection."
        elif [[ "${OPT}" =~ ${REGEX_QUIT} ]]; then
            printf "${RED}%s${NORMAL}\n" "Exiting script ..."
            sleep 1
            clear
            exit 0
        else
            DRIVE="/dev/${OPT}"
            if [[ "${OPT}" == nvme* ]]; then
                IS_NVME=true
            else
                IS_NVME=false
            fi
            break
        fi
    done
    PS3=''
    clear
}

# Partrition Drive

partrition_drive() {
    printf "${GREEN}%s${NORMAL}" "This script will create a 1G EFI partrition and a ROOT partrition taking up the rest of your Drive. Are you okay with that? "
    read -rep '[Y/y,N/n]:\n » ' yn
    case ${yn} in
    ${REGEX_YES}*)
        printf "${GREEN}%s${NORMAL}\n" "Creating Partritions ..."
        # printf "g\nn\n\n\n+1G\nt\n1\nn\n\n\n\nt\n2\n20\nw\n" | fdisk "${DRIVE}"
        printf "${GREEN}%s${NORMAL}\n" "DONE"
        if [[ "${IS_NVME}" == true ]]; then
            EFI_PARTRITION="${DRIVE}p1"
            ROOT_PARTRITION="${DRIVE}p2"
        else
            EFI_PARTRITION="${DRIVE}1"
            ROOT_PARTRITION="${DRIVE}2"
        fi
        lsblk | grep "${DRIVE}"
        sleep 1
        clear
        return 0
        ;;
    ${REGEX_NO}*)
        printf "${RED}%s${NORMAL}\n" "Exiting script ..."
        sleep 1
        clear
        exit 0
        ;;
    *)
        printf "${RED}%s${NORMAL}\n" "Invalid selection. Please try again."
        sleep 0.5
        clear
        partrition_drive
        ;;
    esac
}

# Encrypt main Partrition using LUKS1
encrypt_root() {
    cryptsetup luksFormat --type1 "${ROOT_PARTRITION}"
    sleep 0.5
    printf "${GREEN}%s${NORMAL}\n" "Please enter a name for the encrypted partrition"
    read -rep '' ENCRYPTED_NAME
    cryptsetup luksOpen "${ROOT_PARTRITION}" "${ENCRYPTED_NAME}"
    LUKS_PARTRITION="/dev/mapper/${ENCRYPTED_NAME}"
    printf "${GREEN}%s${NORMAL}\n" "ROOT partrition encrypted."
    sleep 1
    clear
}

# TODO: (optional) create LVM

# format partritions
create_filesystem() {
    mkfs.vfat -n EFI -F 32 "${EFI_PARTRITION}"
    mkfs.btrfs -L ROOT "${LUKS_PARTRITION}"
}

# mount partrition (and create btrfs subvol)
mount_partritions() {
    export BTRFS_OPT=rw,noatime,discard=async,compress-force=zstd,space_cache=v2,commit=120
    sleep 0.1
    mount -o ${BTRFS_OPT} "${LUKS_PARTRITION}" /mnt
    sleep 0.1
    btrfs subvol create /mnt/@
    btrfs subvol create /mnt/@home
    btrfs subvol create /mnt/@snapshots
    sleep 0.1
    umount /mnt
    sleep 0.1
    mount -o ${BTRFS_OPT},subvol=@ "${LUKS_PARTRITION}" /mnt
    sleep 0.1
    mkdir /mnt/{home,.snapshots}
    mount -o ${BTRFS_OPT},subvol=@home "${LUKS_PARTRITION}" /mnt/home
    sleep 0.1
    mount -o ${BTRFS_OPT},subvol=@snapshots "${LUKS_PARTRITION}" /mnt/.snapshots
    sleep 0.1
    mkdir -p /mnt/boot/efi
    mount -o rw,noatime "${EFI_PARTRITION}" /mnt/boot/efi/
    sleep 0.1
    mkdir -p /mnt/var/cache
    btrfs subvol create /mnt/var/cache/xbps
    btrfs subvol create /mnt/var/tmp
    btrfs subvol create /mnt/var/log
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
}

# TODO: Select mirror and architecture and install the base-system
install_base_system() {
    # change these for your needs depending on where you live and what kind of system you have / want
    export ARCH=x86_64
    export REPO=https://repo-de.voidlinux.org/
    XBPS_ARCH=${ARCH} xbps-install -Sy -r /mnt "${REPO}" base-system btrfs-progs cryptsetup grub-x86_64-efi grub-btrfs grub-btrfs-runit NetworkManager bash-completion neovim vim wget gcc
    sleep 0.1
    # create pseudo file system
    # TODO: maybe split this function in two seperate 1. install 2. chroot
    for DIR in sys dev proc; do
        mount --rbind /${DIR} /mnt/${DIR}
        mount --make-rslave /mnt/${DIR}
    done
    cp -L /etc/resolc.conf /mnt/etc/
    cp -L /etc/wpa_supplicant/wpa_supplicant-"${INTERFACE}".conf /mnt/etc/wpa_supplicant/
    BTRFS_OPT=${BTRFS_OPT} PS1='(chroot) # ' chroot /mnt/ /bin/bash
}

# TODO: again make sure the efivarfs are mounted

# set a new root password and folder permissions
set_folder_permision() {
    printf "${GREEN}%s${NORMAL}\n" "Please enter a new root password."
    passwd root
    sleep 0.2
    chown root:root /
    chmod 755 /
}

# set a hostname
set_hostname() {
    printf "${GREEN}%s${NORMAL} " "Please enter a hostname"
    read -rep ': ' HOSTNAME
    echo "${HOST_NAME}" >/etc/hostname
}

# set system defaults
set_system_defaults() {
    printf "${GREEN}%s${NORMAL}\n" "Select the locale to uncomment or confirm: "
    # display all locales in libc-locales
    tail -n +11 "${LOCALES_FILE}" | nl -v 0 | less
    printf "${GREEN}%s${NORMAL} " "Enter the line number of the locale to uncomment or confirm (Enter search to look at the locales again): "
    read -r LINE_NUMBER
    if [[ "${LINE_NUMBER}" =~ ${REGEX_SEARCH} ]]; then
        set_system_defaults
    else
        ADJUSTED_LINE_NUMBER=$((LINE_NUMBER + 11))
    fi
    LOCALE=$(sed -n "${ADJUSTED_LINE_NUMBER}p" "${LOCALES_FILE}")
    if [[ "${LOCALE}" == \#* ]]; then
        sed -i "${ADJUSTED_LINE_NUMBER}s/^#//" "${LOCALES_FILE}"
        printf "${GREEN}%s%s${NORMAL}\n" "Successfully uncommented ${LOCALE}."
    else
        printf "${GREEN}%s%s${NORMAL}\n" "The selected locale is already uncommented ${LOCALE}"
    fi

    # set default language
    LANGUAGE="${LOCALE%%[[:space:]]*}"
    printf "${GREEN}%s${GREEN}" "Setting the language to ${LANGUAGE}"
    echo "LANG=${LANGUAGE}" /etc/locale.conf

    xbps-reconfigure -f glibc-locales
}

# edit the /etc/fstab
edit_fstab() {
    EFI_UUID=$(blkid -s UUID -o value "${EFI_PARTRITION}")
    LUKS_UUID=$(blkid -s UUID -o value "${LUKS_PARTRITION}")
    ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PARTRITION}")
    sed -i '/tmpfs/d' /etc/fstab
    cat <<EOF >>"${HOME}"/fstab
UUID=${ROOT_UUID} / btrfs ${BTRFS_OPT},subvol=@ 0 1
UUID=${ROOT_UUID} /home btrfs ${BTRFS_OPT},subvol=@home 0 2
UUID=${ROOT_UUID} /.snapshots btrfs ${BTRFS_OPT},subvol=@snapshots 0 2
UUID=${EFI_UUID} /boot/efi vfat defaults,noatime 0 2
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
EOF
}

# configure GRUB
configure_grub() {
    cat <<EOF >>/etc/default/grub
GRUB_ENABLE_CRYPTODISK=y
EOF
    sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ rd.auto=1 rd.luks.name=${LUKS_UUID}=${ENCRYPTED_NAME} rd.luks.allow-discards=${LUKS_UUID}&/" /etc/default/grub
}

# setup luksKey to avoid having to enter a password twice on boot
setup_luksKey() {
    dd bs=512 count=4 if=/dev/random of=/boot/volume.key
    cryptsetup luksAddKey "${ROOT_PARTRITION}" /boot/volume.key
    chmod 000 /boot/volume.key
    chmod -R g-rwx,o-rwx /boot
    cat <<EOF >>/etc/crypttab
"${ENCRYPTED_NAME}" UUID="${LUKS_UUID}" /boot/volume.key luks
EOF
}

# setup darcut to hostonly
# TODO: make the lvm module only load if user decided to build the OS with an lvm
configure_dracut() {
    echo -e "hostonly=yes\nhostonly_cmdline=yes" >>/etc/dracut.conf.d/00-hostonly.conf
    echo "install_items+=\" /boot/volume.key /etc/crypttab \"" >>/etc/dracut.conf.d/10-crypt.conf
    echo "add_dracutmodules+=\" crypt btrfs lvm resume \"" >>/etc/dracut.conf.d/20-addmodules.conf
    echo "tmpdir=/tmp" >>/etc/dracut.conf.d/30-tmpfs.conf
    dracut --regenerate-all --force --hostonly
}

# (optional, but recommended on laptops) setup swapfile
create_swapfile() {
    btrfs subvolume create /var/swap
    truncate -s 0 /var/swap/swapfile
    chattr +C /var/swap/swapfile
    chmod 600 /var/swap/swapfile
    MEMORY=$(echo "$(free -g | awk '/^Mem:/{print $2}') * 1.5" | bc)
    dd if=/dev/zero of=/var/swap/swapfile bs=1G count="${MEMORY}" status=progress
    mkswap /var/swap/swapfile
    swapon /var/swap/swapfile
    wget https://raw.githubusercontent.com/osandov/osandov-linux/master/scripts/btrfs_map_physical.c
    gcc -O2 btrfs_map_physical.c -o btrfs_map_physical
    RESUME_OFFSET=$(($(./btrfs_map_physical /var/swap/swapfile | awk -F " " 'FNR == 2 {print $NF}') / $(getconf PAGESIZE)))
    sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET}&/" /etc/default/grub
    cat <<EOF >>/etc/fstab
/var/swap/swapfile none swap defaults 0 0
EOF
}

# enabling zswap, if swapfile was created (optional, gather more info)
enable_zswap() {
    echo "add_drivers+=\" lz4hc lz4hc_compress z3fold \"" >>/etc/dracut.conf.d/40-add_zswap_drivers.conf
    dracut --regenerate-all --force --hostonly
    sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ zswap.enabled=1 zswap.max_pool_percent=25 zswap.compressor=lz4hc zswap.zpool=z3fold&/" /etc/default/grub
    update-grub
}

# finish system installation
finish_install() {
    # install grub
    grub-install --target=x86_64-efi --boot-directory=/boot --efi-directory=/boot/efi --bootloader-id=VoidLinux --recheck
    # enable networking services
    ln -s /etc/sv/dhcpcd /etc/runit/runsvdir/default/
    ln -s /etc/sv/wpa_supplicant/ /etc/runit/runsvdir/default/
    # reconfigure all packages
    xbps-reconfigure -fa
    # leave chroot and unmount partritions
    eval "$(exit)"
    umount -R /mnt/
}

check_if_root
check_if_efi
select_drive
partrition_drive
encrypt_root
create_filesystem
mount_partritions
install_base_system
set_folder_permision
set_hostname
set_system_defaults
edit_fstab
configure_grub
setup_luksKey
configure_dracut
create_swapfile
enable_zswap
finish_install
