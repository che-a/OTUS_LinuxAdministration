#!/usr/bin/env bash

LOG_FILE=report.log

# Логирование вывода команд для последующего составления отчета в README.md
function output_log {
    echo "== CMD ==: lsblk" >> $LOG_FILE
    lsblk >> $LOG_FILE
    echo "---" >> $LOG_FILE

    echo '== CMD ==: lshw -short | grep disk' >> $LOG_FILE
    lshw -short | grep disk >> $LOG_FILE
    echo "---" >> $LOG_FILE

    echo '== CMD ==: df -h -x tmpfs -x devtmpfs' >> $LOG_FILE
    df -h -x tmpfs -x devtmpfs >> $LOG_FILE
    echo "---" >> $LOG_FILE

    echo '== CMD ==: blkid' >> $LOG_FILE
    blkid >> $LOG_FILE
    echo "---" >> $LOG_FILE

    echo '== CMD ==: cat /proc/mdstat' >> $LOG_FILE
    cat /proc/mdstat >> $LOG_FILE
    echo "---" >> $LOG_FILE
}

function init {
    yum update -y
    yum install -y mdadm smartmontools hdparm gdisk
    yum install -y nano wget tree mc

    touch $LOG_FILE
    output_log
}

# Создание RAID уровней 0/1/5/6/10 для тестирования
function raid {
    case $1 in
        0)  echo "Creating RAID 0"
            mdadm --create --verbose /dev/md$1 --force --level=0 --raid-devices=2 /dev/sd{b,c}
            ;;
        1)  echo "Creating RAID 1"
            mdadm --create --verbose --metadata=1.2 /dev/md$1 --force --level=1 --raid-devices=3 /dev/sd{b,c,d}
            mdadm /dev/md$1 --add /dev/sde
            ;;
        5)  echo "Creating RAID 5"
            mdadm --create --verbose /dev/md$1 --level=5 --raid-devices=4 /dev/sd{b,c,d,e}
            ;;
        6)  echo "Creating RAID 6"
            mdadm --create --verbose /dev/md$1 --level=6 --raid-devices=4 /dev/sd{b,c,d,e}
            ;;
        10) echo "Creating RAID 10"
            mdadm --create --verbose /dev/md$1 --level=10 --raid-devices=4 /dev/sd{b,c,d,e}
            ;;
        *)  echo "Invalid RAID level!" >&2
            exit 1
            ;;
    esac

    parted -s /dev/md$1 mktable gpt
    parted -s /dev/md$1 mkpart primary 2048s 4096s      #GPT-раздел
    parted -s /dev/md$1 set 1 bios_grub on
    parted -s /dev/md$1 mkpart primary ext4 4M 5%       #раздел №2
    parted -s /dev/md$1 mkpart primary ext4 5% 10%      #раздел №3
    parted -s /dev/md$1 mkpart primary ext4 10% 25%     #раздел №4
    parted -s /dev/md$1 mkpart primary ext4 25% 50%     #раздел №5
    parted -s /dev/md$1 mkpart primary ext4 50% 100%    #раздел №6

   for i in $(seq 2 6); do
        mkdir -p /mnt/raid/md$1p$i
        mkfs.ext4 /dev/md$1p$i
        mount /dev/md$1p$i /mnt/raid/md$1p$i
    done

    # Создание файла конфигурации mdadm.conf
    echo "DEVICE partitions" > /etc/mdadm.conf
    mdadm --detail --scan --verbose | awk '/ARRAY/ {print}' >> /etc/mdadm.conf

    output_log
}

# Подготовка "живой" системы к переносу на RAID
function transfer_to_raid {

    # Удалеям ошметки предыдущего задания
    for i in $(seq 2 6); do
        umount /dev/md$1p$i
        rmdir /mnt/raid/md$1p$i
    done
    rmdir /mnt/raid

    mkfs.ext4   /dev/md$1p2
    mkfs.ext4   /dev/md$1p3
    mkswap      /dev/md$1p4
    mkfs.ext4   /dev/md$1p5
    mkfs.ext4   /dev/md$1p6

    mkdir -p /mnt/{boot,home,var}
    mount /dev/md$1p2 /mnt/boot
    mount /dev/md$1p3 /mnt/home
    mount /dev/md$1p5 /mnt/var
    mount /dev/md$1p6 /mnt/

    # Копируем рабочую систему в /mnt.
    rsync -axu /boot/ /mnt/boot/
    rsync -axu /home/ /mnt/home/
    rsync -axu /var/ /mnt/var/
    rsync   -axu --recursive --progress \
            --exclude /vagrant \
            --exclude /boot \
            --exclude /home \
            --exclude /var \
            --exclude swapfile / /mnt/

    #
    # Формирование скрипта, который необходимо запустить вручную после
    # развертывания тестового окружения
    local OUTFILE=continued_transfer.sh
    (
    cat << '_EOF_'
#!/usr/bin/env bash
mount --bind /proc /mnt/proc
mount --bind /dev /mnt/dev
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run
chroot /mnt/ /bin/bash <<'EOT'
# Создание нового /etc/fstab
echo "# My scripted /etc/fstab" >> /etc/fstab
echo -n `blkid |grep md6p2 | cut -d" " -f 2`  >> /etc/fstab
echo '  /boot   ext4    default         0       0' >> /etc/fstab
echo -n `blkid |grep md6p3 | cut -d" " -f 2`  >> /etc/fstab
echo '  /home   ext4    default         0       0' >> /etc/fstab
echo -n `blkid |grep md6p4 | cut -d" " -f 2`  >> /etc/fstab
echo '  /swap   swap    default         0       0' >> /etc/fstab
echo -n `blkid |grep md6p5 | cut -d" " -f 2`  >> /etc/fstab
echo '  /var    ext4    default         0       0' >> /etc/fstab
echo -n `blkid |grep md6p6 | cut -d" " -f 2`  >> /etc/fstab
echo '  /       ext4    default         0       0' >> /etc/fstab
# Создание файла конфигурации mdadm.conf
echo "DEVICE partitions" > /etc/mdadm.conf
mdadm --detail --scan --verbose | awk '/ARRAY/ {print}' >> /etc/mdadm.conf
dracut --mdadmconf --force /boot/initramfs-$(uname -r).img $(uname -r)
# grub2-mkconfig -o /boot/grub2/grub.cfg && grub2-install /dev/sdb
EOT

_EOF_
    ) > $OUTFILE
    chmod +x $OUTFILE

}


init
raid 1
transfer_to_raid 1
