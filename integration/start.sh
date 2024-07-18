#!/bin/bash
set -ex

CLUSTER=ceph
HOSTNAME=$(hostname -s)
ADMIN_KEYRING=/etc/ceph/${CLUSTER}.client.admin.keyring
ADMIN_SECRET=${ADMIN_SECRET:-}
MON_NAME=${HOSTNAME}
MON_KEYRING=/etc/ceph/${CLUSTER}.mon.keyring
MONMAP=/etc/ceph/monmap-${CLUSTER}
MON_DATA_DIR=/var/lib/ceph/mon/${CLUSTER}-${MON_NAME}
MGR_NAME=${HOSTNAME}
MGR_PATH="/var/lib/ceph/mgr/${CLUSTER}-${MGR_NAME}"
MON_IP=$(getent ahostsv4 $HOSTNAME | grep STREAM | head -n 1 | cut -d ' ' -f 1)
OSD_COUNT=1
OSD_MAX_OBJECT_SIZE=${OSD_MAX_OBJECT_SIZE:-134217728}
DAEMON_OPTS=(--cluster "${CLUSTER}" --setuser ceph --setgroup ceph --default-log-to-stderr=true --err-to-stderr=true --default-log-to-file=false)

function log {
    if [ -z "$*" ]; then
        return 1
    fi

    local timestamp
    timestamp=$(date '+%F %T')
    echo "$timestamp  $0: $*"
    return 0
}

function get_mon_config {
    # IPv4 is the default unless we specify it

    if [ ! -e /etc/ceph/"${CLUSTER}".conf ]; then
        local fsid
        fsid=$(uuidgen)
        cat <<ENDHERE >/etc/ceph/"${CLUSTER}".conf
[global]
fsid = $fsid
mon initial members = ${MON_NAME}
mon host = v2:${MON_IP}:${MON_PORT}/0
public network = ${CEPH_PUBLIC_NETWORK}
cluster network = ${CEPH_PUBLIC_NETWORK}
osd pool default size = 1
osd_crush_chooseleaf_type = {0}
osd_max_object_size = ${OSD_MAX_OBJECT_SIZE}
ENDHERE

    else
        # extract fsid from ceph.conf
        fsid=$(grep "fsid" /etc/ceph/"${CLUSTER}".conf | awk '{print $NF}')
    fi

    if [ ! -e "$ADMIN_KEYRING" ]; then
        if [ -z "$ADMIN_SECRET" ]; then
            # Automatically generate administrator key
            CLI+=(--gen-key)
        else
            # Generate custom provided administrator key
            CLI+=("--add-key=$ADMIN_SECRET")
        fi
        ceph-authtool "$ADMIN_KEYRING" --create-keyring -n client.admin "${CLI[@]}" --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
    fi

    if [ ! -e "$MON_KEYRING" ]; then
        # Generate the mon. key
        ceph-authtool "$MON_KEYRING" --create-keyring --gen-key -n mon. --cap mon 'allow *'
    fi

    # Apply proper permissions to the keys
    chown "${CHOWN_OPT[@]}" ceph. "$MON_KEYRING" "$ADMIN_KEYRING"

    if [ ! -e "$MONMAP" ]; then
        if [ -e /etc/ceph/monmap ]; then
            # Rename old monmap
            mv /etc/ceph/monmap "$MONMAP"
        else
            # Generate initial monitor map
            monmaptool --create --add "${MON_NAME}" "${MON_IP}:${MON_PORT}" --fsid "${fsid}" "$MONMAP"
        fi
        chown "${CHOWN_OPT[@]}" ceph. "$MONMAP"
    fi
}

function start_mon {
    # If we don't have a monitor keyring, this is a new monitor
    if [ ! -e "$MON_DATA_DIR/keyring" ]; then
        mkdir -p "$MON_DATA_DIR"
        chown 167:167 "$MON_DATA_DIR"
        get_mon_config

        if [ ! -e "$MON_KEYRING" ]; then
            log "ERROR- $MON_KEYRING must exist.  You can extract it from your current monitor by running 'ceph auth get mon. -o $MON_KEYRING' or use a KV Store"
            exit 1
        fi

        if [ ! -e "$MONMAP" ]; then
            log "ERROR- $MONMAP must exist.  You can extract it from your current monitor by running 'ceph mon getmap -o $MONMAP' or use a KV Store"
            exit 1
        fi

        # Testing if it's not the first monitor, if one key doesn't exist we assume none of them exist
        for keyring in $OSD_BOOTSTRAP_KEYRING $ADMIN_KEYRING; do
            if [ -f "$keyring" ]; then
                ceph-authtool "$MON_KEYRING" --import-keyring "$keyring"
            fi
        done

        # Prepare the monitor daemon's directory with the map and keyring
        ceph-mon --setuser ceph --setgroup ceph --cluster "${CLUSTER}" --mkfs -i "${MON_NAME}" --inject-monmap "$MONMAP" --keyring "$MON_KEYRING" --mon-data "$MON_DATA_DIR"

        # Never re-use that monmap again, otherwise we end up with partitioned Ceph monitor
        # The initial mon **only** contains the current monitor, so this is useful for initial bootstrap
        # Always rely on what has been populated after the other monitors joined the quorum
        rm -f "$MONMAP"
    else
        log "Existing mon, trying to rejoin cluster..."
    fi

    # start MON
    /usr/bin/ceph-mon "${DAEMON_OPTS[@]}" -i "${MON_NAME}" --mon-data "$MON_DATA_DIR" --public-addr "${MON_IP}"

    if [ -n "$NEW_USER_KEYRING" ]; then
        echo "$NEW_USER_KEYRING" | ceph "${CLI_OPTS[@]}" auth import -i -
    fi
}

#######
# MON #
#######
function bootstrap_mon {
    # shellcheck disable=SC2034
    MON_PORT=3300
    # shellcheck disable=SC1091

    start_mon

    chown --verbose ceph. /etc/ceph/*
}

#######
# OSD #
#######

function bootstrap_osd {
    OSD_COUNT=1
    for i in $(seq 1 1 "$OSD_COUNT"); do
        ((OSD_ID = "$i" - 1)) || true
        OSD_PATH="/var/lib/ceph/osd/${CLUSTER}-${OSD_ID}"

        if [ ! -e "$OSD_PATH"/keyring ]; then
            if ! grep -qE "osd data = $OSD_PATH" /etc/ceph/"${CLUSTER}".conf; then
                cat <<ENDHERE >>/etc/ceph/"${CLUSTER}".conf

[osd.${OSD_ID}]
osd data = ${OSD_PATH}

ENDHERE
            fi
            # bootstrap OSD
            mkdir -p "$OSD_PATH"
            chown --verbose -R ceph. "$OSD_PATH"

            # if $OSD_DEVICE exists we deploy with ceph-volume
            if [[ -n "$OSD_DEVICE" ]]; then
                ceph-volume lvm prepare --data "$OSD_DEVICE"
            else
                # we go for a 'manual' bootstrap
                log "Boostraping OSD..."
                ceph "${CLI_OPTS[@]}" auth get-or-create osd."$OSD_ID" mon 'allow profile osd' osd 'allow *' mgr 'allow profile osd' -o "$OSD_PATH"/keyring
                ceph-osd --conf /etc/ceph/"${CLUSTER}".conf --osd-data "$OSD_PATH" --mkfs -i "$OSD_ID"
            fi
        fi

        # activate OSD
        if [[ -n "$OSD_DEVICE" ]]; then
            OSD_FSID="$(ceph-volume lvm list --format json | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"][0][\"tags\"][\"ceph.osd_fsid\"])")"
            ceph-volume lvm activate --no-systemd --bluestore "${OSD_ID}" "${OSD_FSID}"
        fi

        # start OSD
        log "Starting OSD..."
        chown --verbose -R ceph. "$OSD_PATH"
        ceph-osd "${DAEMON_OPTS[@]}" -i "$OSD_ID"
    done
}

########
# MGR  #
########
function bootstrap_mgr {
    mkdir -p "$MGR_PATH"
    ceph "${CLI_OPTS[@]}" auth get-or-create mgr."$MGR_NAME" mon 'allow profile mgr' mds 'allow *' osd 'allow *' -o "$MGR_PATH"/keyring
    chown --verbose -R ceph. "$MGR_PATH"

    # start ceph-mgr
    ceph-mgr "${DAEMON_OPTS[@]}" -i "$MGR_NAME"
}

###################
# BUILD BOOTSTRAP #
###################

function build_bootstrap {
    bootstrap_mon
    bootstrap_mgr
    bootstrap_osd
}

# For a 'demo' container, we must ensure there is no Ceph files
function detect_ceph_files {
    if [ -f /etc/ceph/I_AM_A_DEMO ] || [ -f /var/lib/ceph/I_AM_A_DEMO ]; then
        log "Found residual files of a demo container."
        log "This looks like a restart, processing."
        return 0
    fi
    if [ -d /var/lib/ceph ] || [ -d /etc/ceph ]; then
        # For /etc/ceph, it always contains a 'rbdmap' file so we must check for length > 1
        if [[ "$(find /var/lib/ceph/ -mindepth 3 -maxdepth 3 -type f | wc -l)" != 0 ]] || [[ "$(find /etc/ceph -mindepth 1 -type f | wc -l)" -gt "1" ]]; then
            log "I can see existing Ceph files, please remove them!"
            log "To run the demo container, remove the content of /var/lib/ceph/ and /etc/ceph/"
            log "Before doing this, make sure you are removing any sensitive data."
            exit 1
        fi
    fi
}

#########
# WATCH #
#########
detect_ceph_files
build_bootstrap

# create 2 files so we can later check that this is a demo container
touch /var/lib/ceph/I_AM_A_DEMO /etc/ceph/I_AM_A_DEMO

log "SUCCESS"
exec ceph "${CLI_OPTS[@]}" -w
