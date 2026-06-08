#!/bin/bash

set -e

# Définitions des variables


TARGET_HOSTNAME="test-OVH"
ROOT_PASSWORD="123"

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

	#Crére une partition EFI de 512MB sur $TARGET_DISK:
	sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
	#Crér une seconde partition sur $TARGET_DISK avec toute la place restante
	sgdisk -n 2:0:0 -t 2:8e00 -c 2:"LVM" "$TARGET_DISK"

	#Informer le kernel des modifications apportées a la table de partitions
	partprobe "$TARGET_DISK"
	sleep 3

	#Formater le disque $PART_EFI (nvme0n1p1)
	mkfs.fat -F32 "$PART_EFI"
	sleep 3

	#Installer le  peripherique de stockage pour qu'il soit reconnu et utilisé par LVM
	pvcreate -y "$PART_LVM"

	#crée un stockage a partir de la partition $PART_LVM (nvme0n1p2) pour être decoupe en plusieurs volumes virtuels
	vgcreate -y "$VG_NAME" "$PART_LVM"

	#Decoupe le stockage nouvellement crée en deux parties, une partie de 50GB pour installer le root et une autre partie de 8G pour installer le swap
	lvcreate -y -L 50G -n root "$VG_NAME"
	lvcreate -y -L 8G -n swap "$VG_NAME"

	#Prepare les deux volumes nouvellement crée a tre utiliser en leur appliquant le bon format:
	#Le format EXT4 pour le root
	#Le format special swap pour la memoire de secours
	mkfs.ext4 -F /dev/$VG_NAME/root
	mkswap /dev/$VG_NAME/swap
}



#Télechargement
run_debootstrap() {

	#Installation de debootstrap
	apt-get update -qq
	apt-get install -y debootstrap

	#Le systeme de Rescue de OVH tourne sur une version ancienne et elle ne connait pas le mot de passe noble de Ubuntu 24.04 car c'est une version trop recente
	#Cette commande crée un simple lien virtuel : quand le script cherchera "noble" il lira "gutsy" et l'installation fonctionnera
	ln -sf /usr/share/debootstrap/scripts/gutsy /usr/share/debootstrap/scripts/"$UBUNTU_RELEASE"

	#crée le dossier d'instalation (/mnt/ubuntu_install)
	mkdir -p "$TARGET_MOUNT"

	#Attache la partition root de 50GB au dossier $TARGET_MOUNT (/mnt/ubuntu_install)
	mount /dev/$VG_NAME/root "$TARGET_MOUNT"

	#crée le dossier /boot/efi dans le dossier d'installation et attache la partition de demarrage $PART_EFI (nvme0n1)
	mkdir -p "$TARGET_MOUNT/boot/efi"
	mount "$PART_EFI" "$TARGET_MOUNT/boot/efi"

	#Allume et rend utilisable le swap
	swapon /dev/$VG_NAME/swap

	#Telechargement de ubuntu depuis les depots officiels
	debootstrap --arch=amd64 "$UBUNTU_RELEASE" "$TARGET_MOUNT" http://archive.ubuntu.com/ubuntu/

}

#Prépare le nouveau système�rtre lancer
prepare_chroot() {

        #Copie le resovle.conf de rescue vers le noyaux système 
        cp /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"

        #Crée le fichier qui vas dire au nouveau sysème monter automatiquement les partitions a chaque démarrage
        cat <<EOF > "$TARGET_MOUNT/etc/fstab"
/dev/$VG_NAME/root   /           ext4    defaults        0 1
$PART_EFI            /boot/efi   vfat    defaults        0 2
/dev/$VG_NAME/swap   none        swap    sw              0 0
EOF


        # /dev : Pour que le nouveau système voie les disques durs physiques
        mount --bind /dev "$TARGET_MOUNT/dev"
        # /dev/pts : Pour pouvoir interagir avec le terminale
        mount --bind /dev/pts "$TARGET_MOUNT/dev/pts"
        # /proc : Pour qu'il voie la RAM et le processeur
        mount -t proc proc "$TARGET_MOUNT/proc"
        # /sys : Pour qu'il voie les composants de la carte mère
        mount -t sysfs sysfs "$TARGET_MOUNT/sys"

        #Permet au nouveau systèmede accéder aux paramètres de démarrage la ta cartèr
        mount --bind /sys/firmware/efi/efivars "$TARGET_MOUNT/sys/firmware/efi/efivars"


}

configure_chroot(){
        
        #Définit le nom de la machine depuis le rescue
        echo "$TARGET_HOSTNAME" > "$TARGET_MOUNT/etc/hostname"     
       
        #Définit le fuseau horaire sur Paris
        chroot "$TARGET_MOUNT" ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
        
        #Envoi le mots de passe depuis le rescue vers l'interieure 
        echo "root:$ROOT_PASSWORD" | chroot "$TARGET_MOUNT" chpasswd

        #Installation des paquets
        #env DEBIAN_FRONTEND=noninteractive empêche les menus de bloquer le script
        chroot "$TARGET_MOUNT" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        chroot "$TARGET_MOUNT" env DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-generic grub-efi-amd64 openssh-server sudo vim netplan.io lvm2



        #Création du dossier netplan pour la configuration éseau 
        mkdir -p "$TARGET_MOUNT/etc/netplan"



        #Création et configuration du fichier netcfg.yaml

        #renderer:networkd, Précise d'utiliser systemd-networkd comme moteur de gestion deréseau
        #match: name: e*, Dis au systeme de choisir n'imorte quelle carte réseau qui commence par un e (eth0, enp0s3, ens3... ) 
        #dhcp4: true, Demande automatiquement une addresse IP auprès de la box ou du routeur 
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


        
        #Créatin du dossier .ssh
        mkdir -p "$TARGET_MOUNT/root/.ssh"
        
        #Rajout de la clépublique dans le fichier authorized_keys
        echo "$SSH_PUBLIC_KEY" > "$TARGET_MOUNT/root/.ssh/authorized_keys"
        
        #Attribution des droits au fichier/dossier 
        chmod 700 "$TARGET_MOUNT/root/.ssh"
        chmod 600 "$TARGET_MOUNT/root/.ssh/authorized_keys"


        #!!!!!!!!!!!!!!!!!!!!!!!!!!!!!TEMPORAIRE!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        #Autorise le compte root a se connecer en ssh avec son propre mots de passe 
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' "$TARGET_MOUNT/etc/ssh/sshd_config"


        #Installation de GRUB
        chroot "$TARGET_MOUNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
        chroot "$TARGET_MOUNT" update-grub

        


        #Nettoyage
        umount -R "$TARGET_MOUNT"
        swapoff -a


}       




#Installation
prepare_disk_lvm

run_debootstrap

prepare_chroot

configure_chroot
