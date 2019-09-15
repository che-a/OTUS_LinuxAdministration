#!/usr/bin/env bash

SRV="fake_srv"
SRV_DIR="/opt/"$SRV"/"
SRV_NAME=$SRV".sh"
SRV_NAME_FULL=$SRV_DIR$SRV_NAME

SCRIPT="script"
SCRIPT_DIR="/opt/mail_stat/"
SCRIPT_NAME=$SCRIPT".sh"
SCRIPT_NAME_FULL=$SCRIPT_DIR$SCRIPT_NAME

LOG_NAME=$SRV".log"
LOG_NAME_FULL=$SRV_DIR$LOG_NAME

SOURCE_LOG_NAME="access.log"
SOURCE_LOG_NAME_FULL=$SRV_DIR$SOURCE_LOG_NAME

UNIT_NAME=$SRV".service"
UNIT_NAME_FULL="/etc/systemd/system/"$UNIT_NAME

function prepare_system {
    mkdir -p ~root/.ssh
    cp ~vagrant/.ssh/auth* ~root/.ssh

    mkdir -p {$SRV_DIR,$SCRIPT_DIR}
    cp /vagrant/access.log $SRV_DIR
    cp /vagrant/script.sh $SCRIPT_DIR
    ln -sf $SCRIPT_NAME_FULL $SCRIPT_DIR$SCRIPT
    chown -R vagrant: {$SRV_DIR,$SCRIPT_DIR}

    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    yum install -y mailx nano tree tmux
}

function create_systemd_unit {

    touch $UNIT_NAME_FULL
    chmod 664 $UNIT_NAME_FULL

cat > $UNIT_NAME_FULL <<'_EOF_'
[Unit]
Description=Fake Web Server
After=network.target

[Service]
Type=simple
ExecStart=
Restart=always
User=vagrant

[Install]
WantedBy=multi-user.target
_EOF_

    sed -i "s#ExecStart=#ExecStart=$SRV_NAME_FULL#" $UNIT_NAME_FULL

    systemctl enable $UNIT_NAME
    systemctl start $UNIT_NAME
}

function create_srv_file {

(
cat <<- '_EOF_'
#!/usr/bin/env bash

function read_file {
    local Z=

    while read LINE; do
        Z=`LC_TIME=en_US date "+%d/%b/%Y:%T %z"`
        echo $LINE | sed "s#\[../.../....:..:..:.*]#\[$Z\]#" >> OutputLog
        sleep `shuf -i 1-10 -n 1`
    done < SourceLog
}

while [ true ]; do
    read_file
done

_EOF_
) > $SRV_NAME_FULL

    sed -i "s#OutputLog#$LOG_NAME_FULL#" $SRV_NAME_FULL
    sed -i "s#SourceLog#$SOURCE_LOG_NAME_FULL#" $SRV_NAME_FULL

    chown -R vagrant: $SRV_NAME_FULL
    chmod +x $SRV_NAME_FULL
}

function cron_tuning {
    #crontab -l | { cat; echo "*/2 * * * * $SCRIPT_DIR$SCRIPT"; } | crontab -

su vagrant <<'_EOF_'
crontab -l | { cat; echo "*/1 * * * * /opt/mail_stat/script"; } | crontab -
_EOF_


#cat > /etc/cron.d/0minutely << '_EOF_'
#SHELL=/bin/bash
#PATH=/sbin:/bin:/usr/sbin:/usr/bin
#MAILTO=root HOME=/
#*/2 * * * * vagrant /opt/mail_stat/script
#
#_EOF_

}


prepare_system
create_systemd_unit
create_srv_file
cron_tuning
