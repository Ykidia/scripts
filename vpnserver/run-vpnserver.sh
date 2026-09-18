#!/bin/sh

DAEMONNAME=vpnserver
DAEMONDIR="/opt/${DAEMONNAME}"
DAEMONCFG="${DAEMONDIR}/vpn_server.config"
LOCKDIR="/var/lock/subsys"
LOCKFILE="${LOCKDIR}/${DAEMONNAME}"
regex_ipaddress='(([0-1]([0-9][0-9]?)?|2([0-4][0-9]?|5[0-5]?|[6-9])?|[3-9][0-9]?)\.){3}([0-1]([0-9][0-9]?)?|2([0-4][0-9]?|5[0-5]?|[6-9])?|[3-9][0-9]?)'
regex_ifname='[a-zA-Z0-9\-_\@\.]*'
TAPIF="tap_$(cat $DAEMONCFG |tr -s "[ \t]" " " |sed -e "s/^ //" |grep "DeviceName " |cut -d" " -f3 |grep -Eo "${regex_ifname}")"

test -x "${DAEMONDIR}/${DAEMONNAME}" || exit -1

start()
{
    TAPADDR="$(cat $DAEMONCFG |tr -s "[ \t]" " " |sed -e "s/^ //" |grep "VirtualHostIp " |cut -d" " -f3 |grep -Eo "${regex_ipaddress}")"
    TAPMASK="$(cat $DAEMONCFG |tr -s "[ \t]" " " |sed -e "s/^ //" |grep "VirtualHostIpSubnetMask " |cut -d" " -f3 |grep -Eo "${regex_ipaddress}")"
    echo "Tuntap interface name = ${TAPIF}"
    echo "Tuntap interface address = ${TAPADDR}/${TAPMASK}"
    if [ -n ${TAPIF} ] && [ -n ${TAPADDR} ] && [ -n ${TAPMASK} ]; then
        ip link show ${TAPIF} >/dev/null 2>&1 || ip tuntap add ${TAPIF} mode tap user root
        ip addr add ${TAPADDR}/${TAPMASK} dev ${TAPIF}
        ip link set dev ${TAPIF} up
        PWDSAVE=$(pwd)
        cd ${DAEMONDIR}
        ./${DAEMONNAME} start
        cd ${PWDSAVE}
        mkdir -p ${LOCKDIR}
        touch ${LOCKFILE}

        TIMEOUT=15
        while [ $TIMEOUT -gt 0 ] && ! ip link show tap_vpn >/dev/null 2>&1; do
            sleep 1
            TIMEOUT=$((TIMEOUT - 1))
        done

        INTERNET_IFACE=""
        for iface in $(ls /sys/class/net/ |grep -E '^(eth|en|wlan)'); do
            if ip link show "$iface" up >/dev/null 2>&1; then
                INTERNET_IFACE="$iface"
                break
            fi
        done
        if [ -z "$INTERNET_IFACE" ]; then
            for iface in $(ip -br link show up | cut -d' ' -f1); do
                if [ "$iface" != "lo" ] && [ "$iface" != "tap_vpn" ]; then
                    INTERNET_IFACE="$iface"
                    break
                fi
            done
        fi

        # IPv6-address for $TAPIF
        if ip link show tap_vpn >/dev/null 2>&1; then
            if [ -n "$INTERNET_IFACE" ] && [ -f "/sys/class/net/$INTERNET_IFACE/address" ]; then
                MAC=$(cat "/sys/class/net/$INTERNET_IFACE/address" | tr -d ':')
                if [ -n "$MAC" ]; then
                    # Generate
                    B1=$(echo "$MAC" | cut -c1-2)
                    B2=$(echo "$MAC" | cut -c3-4)
                    B3=$(echo "$MAC" | cut -c5-6)
                    B4=$(echo "$MAC" | cut -c7-8)
                    B5=$(echo "$MAC" | cut -c9-10)
                    ULA="fd${B1}:${B2}${B3}:${B4}${B5}"
                    # Check if already assigned
                    if ! ip -6 addr show tap_vpn | grep -q "${ULA}::1/64"; then
                        # Assign
                        ip -6 addr add ${ULA}::1/64 dev tap_vpn || true
                        echo "Tuntap interface ipv6 address = ${ULA}::1/64"
                        # Update dnsmasq config
                        DHCPOPT_STR="dhcp-option=option6:dns-server"
                        sed -i "/^[[:space:]]*${DHCPOPT_STR}/c\\${DHCPOPT_STR},[${ULA}::1]" /etc/dnsmasq.conf 2>/dev/null || true
                        # Restart/reload dnsmasq
                        systemctl reload dnsmasq 2>/dev/null || true
                    fi
                fi
            fi
        fi
    else
        echo "Cannot start, some configuration is missing."
    fi

    return 0
}

stop()
{
    PWDSAVE=$(pwd)
    cd ${DAEMONDIR}
    ./${DAEMONNAME} stop
    cd ${PWDSAVE}
    rm ${LOCKFILE} 2>/dev/null
    ip link delete ${TAPIF}

    return 0
}

case "$1" in
""|start)
    start
    ;;
stop)
    stop
    ;;
restart)
    stop
    sleep 1
    start
    sleep 1
    ;;
*)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
esac

exit 0

