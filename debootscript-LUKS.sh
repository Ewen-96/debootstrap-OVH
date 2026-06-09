#!/bin/bash

set -e

# Definitions des variables
TARGET_HOSTNAME="test-OVH"
ROOT_PASSWORD="openfire"
LUKS_PASSWORD="OpenFire"

TARGET_DISK="/dev/nvme0n1"
PART_EFI="${TARGET_DISK}p1"
PART_LVM="${TARGET_DISK}p2"

VG_NAME="vg_system"
TARGET_MOUNT="/mnt/ubuntu_install"
UBUNTU_RELEASE="noble"

SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFsMgUSJ7k/8gSZ2tbUUGfZjF/AtBAp/5EE/vBoZhS2y ewen@inspiron"

#Partitionnement
prepare_disk_lvm() {

    # Nettoyage
    wipefs -a "$TARGET_DISK"
    sgdisk --zap-all "$TARGET_DISK"

    # Cree une partition EFI de 512MB sur $TARGET_DISK:
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
    # Cree une seconde partition sur $TARGET_DISK avec toute la place restante
    sgdisk -n 2:0:0 -t 2:8e00 -c 2:"LVM" "$TARGET_DISK"

    # Informer le kernel des modifications apportees a la table de partitions
    partprobe "$TARGET_DISK"
    sleep 3

    # Formater le disque $PART_EFI (nvme0n1p1)
    mkfs.fat -F32 "$PART_EFI"
    sleep 3

    # Installer le peripherique de stockage pour qu'il soit reconnu et utilise par LVM
    pvcreate -y "$PART_LVM"

    # cree un stockage a partir de la partition $PART_LVM (nvme0n1p2) pour etre decoupe en plusieurs volumes virtuels
    vgcreate -y "$VG_NAME" "$PART_LVM"

    # Decoupe le stockage nouvellement cree en deux parties, une partie de 50GB pour installer le root avec le chiffrement et une autre partie de 8G pour installer le swap
    lvcreate -y -L 50G -n root_luks "$VG_NAME"	#LUKS
    lvcreate -y -L 8G -n swap "$VG_NAME"

    # Decoupe en une troisième partie non chiffrée qui contient un Noyau Linux et Dropbear juste pour pouvoir taper le mots de passe LUKS au démarrage du serveur 
    lvcreate -y -L 2G -n boot "$VG_NAME"        #LUKS

    # Applique le chiffrement(LUKS) sur la partie root_luks de 50GB
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat /dev/$VG_NAME/root_luks	#LUKS

    # Deverrouille le volume chiffré et le rend accèssible a l'aide du mot de passe sous le nom de "crypt_root" pour pouvoir y installer le système 
    echo -n "$LUKS_PASSWORD" | cryptsetup open /dev/$VG_NAME/root_luks crypt_root	#LUKS


    # Prepare les deux volumes nouvellement crees a etre utilises en leur appliquant le bon format:
    # Le format EXT4 pour le root
    # Le format special swap pour la memoire de secours
    mkfs.ext4 -F /dev/mapper/crypt_root #LUKS
    mkfs.ext4 -F /dev/$VG_NAME/boot	#LUKS
    mkswap /dev/$VG_NAME/swap
}

# Telechargement
run_debootstrap() {

    # Installation de debootstrap
    apt-get update -qq
    apt-get install -y debootstrap

    # Le systeme de Rescue de OVH tourne sur une version ancienne et elle ne connait pas le mot de passe noble de Ubuntu 24.04 car c'est une version trop recente
    # Cette commande cree un simple lien virtuel : quand le script cherchera "noble" il lira "gutsy" et l'installation fonctionnera
    ln -sf /usr/share/debootstrap/scripts/gutsy /usr/share/debootstrap/scripts/"$UBUNTU_RELEASE"

    # cree le dossier d'installation (/mnt/ubuntu_install)
    mkdir -p "$TARGET_MOUNT"

    # Attache la partition crypt_root de 50GB au dossier $TARGET_MOUNT (/mnt/ubuntu_install)
    mount /dev/mapper/crypt_root "$TARGET_MOUNT"	#LUKS

    # cree le dossier /boot dans le dossier d'installation et attache la partition de demarrage temporaire (juste pour taper le mots de passe LUKS au démarrage)
    mkdir -p "$TARGET_MOUNT/boot"			#LUKS
    mount /dev/$VG_NAME/boot "$TARGET_MOUNT/boot"	#LUKS
   

    # cree le dossier /boot/efi dans le dossier d'installation et attache la partition de demarrage $PART_EFI (nvme0n1)
    mkdir -p "$TARGET_MOUNT/boot/efi"
    mount "$PART_EFI" "$TARGET_MOUNT/boot/efi"

    # Allume et rend utilisable le swap
    swapon /dev/$VG_NAME/swap

    # Telechargement de ubuntu depuis les depots officiels
    debootstrap --arch=amd64 "$UBUNTU_RELEASE" "$TARGET_MOUNT" http://archive.ubuntu.com/ubuntu/
}

# Prepare le nouveau systeme a etre lance
prepare_chroot() {

        # Copie le resolv.conf de rescue vers le noyau systeme
        cp /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"

        # Cree le fichier qui va dire au nouveau systeme de monter automatiquement les partitions a chaque demarrage
        cat <<EOF > "$TARGET_MOUNT/etc/fstab"
/dev/mapper/crypt_root	/           ext4    defaults        0 1
$PART_EFI            	/boot/efi   vfat    defaults        0 2
/dev/$VG_NAME/swap   	none        swap    sw              0 0
/dev/$VG_NAME/boot	/boot       ext4    defaults        0 2 
EOF


	#chercher le "numéro de série" (UUID) de la partition root_luks
	LUKS_UUID=$(blkid -s UUID -o value /dev/$VG_NAME/root_luks)	#LUKS
	
	#écrit dans le fichier crypttab : Ouvre le disque avec l'UUID et renomme le crypt_root
	#pour qu'il demande le mot de passe à chaque démarrage de l'ordinateur
	echo "crypt_root UUID=$LUKS_UUID none luks" > "$TARGET_MOUNT/etc/crypttab"	#LUKS


        # /dev : Pour que le nouveau système voie les disques durs physiques
        mount --bind /dev "$TARGET_MOUNT/dev"
        # /dev/pts : Pour pouvoir interagir avec le terminal
        mount --bind /dev/pts "$TARGET_MOUNT/dev/pts"
        # /proc : Pour qu'il voie la RAM et le processeur
        mount -t proc proc "$TARGET_MOUNT/proc"
        # /sys : Pour qu'il voie les composants de la carte mere
        mount -t sysfs sysfs "$TARGET_MOUNT/sys"

        # Permet au nouveau systeme d'acceder aux parametres de demarrage carte mere
        mount --bind /sys/firmware/efi/efivars "$TARGET_MOUNT/sys/firmware/efi/efivars"
}

configure_chroot(){

        # Definit le nom de la machine depuis le rescue
        echo "$TARGET_HOSTNAME" > "$TARGET_MOUNT/etc/hostname"

        # Definit le fuseau horaire sur Paris
        chroot "$TARGET_MOUNT" ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime

        # Envoie le mot de passe depuis le rescue vers l'interieur
        echo "root:$ROOT_PASSWORD" | chroot "$TARGET_MOUNT" chpasswd

        # Installation des paquets
        # env DEBIAN_FRONTEND=noninteractive empeche les menus de bloquer le script
        chroot "$TARGET_MOUNT" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        chroot "$TARGET_MOUNT" env DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-generic grub-efi-amd64 openssh-server sudo vim netplan.io lvm2 cryptsetup-initramfs dropbear-initramfs busybox-initramfs

        # Creation du dossier netplan pour la configuration reseau
        mkdir -p "$TARGET_MOUNT/etc/netplan"

        # Creation et configuration du fichier netcfg.yaml
        # renderer:networkd, Precise d'utiliser systemd-networkd comme moteur de gestion du reseau
        # match: name: e*, Dis au systeme de choisir n'importe quelle carte reseau qui commence par un "e" (eth0, enp0s3, ens3... )
        # dhcp4: true, Demande automatiquement une adresse IP aupres de la box ou du routeur
        cat <<EOF > "$TARGET_MOUNT/etc/netplan/01-netcfg.yaml"
network:
  version: 2
  renderer: networkd
  ethernets:
    main_nic:
      match:
        name: e*
      dhcp4: true
EOF

        # Creation du dossier .ssh
        mkdir -p "$TARGET_MOUNT/root/.ssh"

        # Rajout de la cle publique dans le fichier authorized_keys
        echo "$SSH_PUBLIC_KEY" > "$TARGET_MOUNT/root/.ssh/authorized_keys"

        # Attribution des droits au fichier/dossier
        chmod 700 "$TARGET_MOUNT/root/.ssh"
        chmod 600 "$TARGET_MOUNT/root/.ssh/authorized_keys"



	#Crée un petit serveur ssh léger(Dropbear) temporaire au démarrage du serveur pour pouvoir taper le mot de passe LUKS 
        mkdir -p "$TARGET_MOUNT/etc/dropbear/initramfs"	#LUKS
        echo "$SSH_PUBLIC_KEY" > "$TARGET_MOUNT/etc/dropbear/initramfs/authorized_keys"	#LUKS
        chmod 600 "$TARGET_MOUNT/etc/dropbear/initramfs/authorized_keys"	#LUKS

        #Force Dropbear à écouter sur le port 2222
        echo 'DROPBEAR_OPTIONS="-p 2222 -s -j -k"' > "$TARGET_MOUNT/etc/dropbear/initramfs/dropbear.conf"	#LUKS

        #Allumer la carte réseau en DHCP dès le démarrage
        echo "IP=dhcp" >> "$TARGET_MOUNT/etc/initramfs-tools/initramfs.conf"	#LUKS
	
	#Met a jour le noyau Linux temporaire pour y inclure l'outil de déchiffrement LUKS pour que la machine puisse demander le mots de passe au démarrage
	chroot "$TARGET_MOUNT" update-initramfs -u -k all	#LUKS


        # Installation de GRUB
        chroot "$TARGET_MOUNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
        chroot "$TARGET_MOUNT" update-grub

        # Nettoyage
        umount -R "$TARGET_MOUNT"
        swapoff -a
	
	#Verrouille le volume chiffré et le rend inaccessible 
	cryptsetup close crypt_root || true #LUKS


}

#Installation
prepare_disk_lvm
run_debootstrap
prepare_chroot
configure_chroot
