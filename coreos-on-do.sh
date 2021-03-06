#!/bin/bash
set -e
set -x

cd $(dirname $0)

stage1()
{
    cd /root
    cat > cloud-config.yaml << EOF
#cloud-config

write_files:
  - path: /etc/systemd/network/do.network
    permissions: 0644
    content: |
      [Match]
      Name=ens3
      
      [Network]
      Address=$(ip addr show dev eth0 | grep 'inet.*eth0' | awk '{print $2}')
      Gateway=$(route | grep default | awk '{print $2}')
      DNS=8.8.4.4
      DNS=8.8.8.8

ssh_authorized_keys:
  - $(cat /root/.ssh/authorized_keys | head -1)
EOF

    wget http://alpha.release.core-os.net/amd64-usr/current/coreos_production_pxe.vmlinuz
    wget http://alpha.release.core-os.net/amd64-usr/current/coreos_production_pxe_image.cpio.gz

    cp $0 stage2.sh
    chmod +x stage2.sh

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y kexec-tools
    kexec -l coreos_production_pxe.vmlinuz --initrd coreos_production_pxe_image.cpio.gz --append='coreos.autologin=tty1'
    kexec -e
}

stage2()
{
    tar cvzf /var/tmp/modules.tar.gz -C /mnt lib/modules
    cp $0 /var/tmp
    cp $(dirname $0)/cloud-config.yaml /var/tmp
    chmod +x /var/tmp/$(basename $0)
    exec /var/tmp/$(basename $0) stage3
}

stage3()
{
    if cat /proc/mounts | awk '{print $2}' | grep -q '^/mnt$'; then
        umount /mnt
    fi

    coreos-cloudinit --from-file=cloud-config.yaml
    systemctl restart systemd-networkd

    wget --no-check-certificate https://raw.github.com/coreos/init/master/bin/coreos-install
    chmod +x coreos-install
    ./coreos-install -C alpha -d /dev/vda -c cloud-config.yaml

    cgpt repair /dev/vda
    parted -s -- /dev/vda mkpart DOROOT ext4 -500M -0
    ID=$(parted -sm /dev/vda p | grep DOROOT | cut -f1 -d:)
    mkfs.ext4 -L DOROOT /dev/vda${ID}

    mount LABEL=DOROOT /mnt
    curl -s http://cdimage.ubuntu.com/ubuntu-core/releases/14.04/release/ubuntu-core-14.04-core-amd64.tar.gz | tar xvzf - -C /mnt
    cp /etc/resolv.conf /mnt/etc/resolv.conf

    export DEBIAN_FRONTEND=noninteractive
    chroot /mnt apt-get update
    chroot /mnt apt-get install -y kexec-tools

    if [ ! -e /mnt/sbin/init.real ]; then
        mv /mnt/sbin/init{,.real}
    fi

    cat > /mnt/sbin/init << "EOF"
#!/bin/bash

if [ ! -e /boot/syslinux/vmlinuz-boot_kernel ]; then
        mount -o ro LABEL=EFI-SYSTEM /boot
fi

KERNEL=$(grep '^[[:space:]]*kernel' /boot/syslinux/boot_kernel.cfg | awk '{print $2}')
APPEND=$(grep '^[[:space:]]*append' /boot/syslinux/boot_kernel.cfg | sed 's/^[[:space:]]*append //g')

kexec -l /boot/syslinux/$KERNEL --append="$APPEND"
kexec -e

# In case something goes wrong, we drop to a shell, normally kexec would reboot the system
bash
EOF

    chmod +x /mnt/sbin/init

    tar xvzf modules.tar.gz -C /mnt
    umount /mnt

    echo Rebooting
    reboot
}

if [ $(id -u) != 0 ]; then
    echo Run as root
    exit 1
fi

if [ "$0" = "bash" ]; then
    echo "Download this script, don't pipe it to bash"
    exit 1
fi

if [ -e /etc/lsb-release ]; then
    . /etc/lsb-release
fi

if [ "$DISTRIB_ID" != "CoreOS" ]; then
    stage1
elif [ "$1" = "stage3" ]; then
    stage3
else
    stage2
fi
