#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


ts5b_update_only=0
ts5b_check_retry=5
ts5b_check_maxtime_sec=11
ts5b_total_proxies_min=108
ts5b_checked_proxies_full_min=33
ts5b_checked_proxies_min=9
ts5b_checked_proxies_max=43
ts5b_checked_proxies_max_lowmem=21
ts5b_check_domain_proto='https://'
ts5b_check_domain='torproject.org'
ts5b_socks5_only=1

ts5b_action="${1}"
ts5b_script_path="$(readlink -f "${0}")"
ts5b_current_path="$(dirname "${ts5b_script_path}")"
ts5b_etc_srctree_path="${ts5b_current_path}/../../../root/etc"
ts5b_sources_file='socks5src.lst'
ts5b_list_file_save='socks5raw.lst'
ts5b_chklst_file_save='socks5chk.lst'
ts5b_list_file='/tmp/socks5.lst'
ts5b_tmplst_file='/tmp/socks5tmp.lst'
ts5b_chklst_file='/tmp/socks5chk.lst'
ts5b_nolst_file='/tmp/socks5no.lst'
ts5b_spdlst_file='/tmp/socks5spd.lst'
ts5b_stop_file='/tmp/ts5b-watchdog.stop'
ts5b_sshsocksport_file='/tmp/ts5b-sshsocksport.txt'
ts5b_balancer_bin_file="$(command -v Socks5BalancerAsio)"
ts5b_tor_bin_file="$(command -v tor)"
ts5b_tor_cfg_file="/etc/tor/torrc"
ts5b_balancer_cfg_file='/tmp/Socks5Balancer.json'
ts5b_balancer_log_file='/dev/null'
ts5b_sshsocksid_file="${current_user_home}"'/.ssh/ts5b-sshsocks'
ts5b_dropbear_authkeys_file="${current_user_home}"'/.ssh/authorized_keys'
ts5b_openssh_authkeys_file="${current_user_home}"'/.ssh/authorized_keys'
ts5b_socks5proxy_port=18182
ts5b_sshsocks_cmdline='/usr/libexec/ssh-openssh -TnN -i '"${ts5b_sshsocksid_file}"' -o StrictHostKeyChecking=no '"${current_user}"'@'"${localhost_address}"' -D'
ts5b_check_sshsocks_cmd='pgrep -f '"\"${ts5b_sshsocks_cmdline}\""
ts5b_check_tor_cmd='pgrep -f '"\"${ts5b_tor_bin_file} --runasdaemon\""
ts5b_cmdline="${ts5b_balancer_bin_file}"' -c '"${ts5b_balancer_cfg_file}"
ts5b_check_cmd='pgrep -f '"\"${ts5b_cmdline}\""
ts5b_download_file="$(mktemp)"
ts5b_logme_silence=0
ts5b_high_priority=1
ts5b_lists_ages_sec=259200 # 3 days
exec 3>&1

ts5b_checktool_netcat=0
ts5b_checktool_netcat_opts=
if command -v nc >/dev/null 2>&1; then
    ts5b_checktool_netcat=1
    if nc -h 2>&1 |grep -qE "[[:space:]]\-w\b"; then
        if nc -h 2>&1 |grep -qE "[[:space:]]\-z\b"; then
            ts5b_checktool_netcat_opts="-z"
        fi
        ts5b_checktool_netcat_opts="${ts5b_checktool_netcat_opts}${ts5b_checktool_netcat_opts:+ }-w"
    fi
fi
ts5b_checktool_socat=0
ts5b_checktool_socat_ssl=0
if command -v socat >/dev/null 2>&1; then
    ts5b_checktool_socat=1
    if socat -h 2>&1 |grep -qE "SSL|TLS"; then
        ts5b_checktool_socat_ssl=1
    fi
fi
ts5b_download_cmd="wget --compression=auto -T 30 -qO-"
ts5b_checktool_curl=0
ts5b_checktool_curl_ssl=0
ts5b_checktool_curl_socks=0
if command -v curl >/dev/null 2>&1; then
    ts5b_checktool_curl=1
    if curl -V 2>&1 | grep -qiE "Protocols:.*\bhttps\b"; then
        ts5b_download_cmd="curl --compressed -s -L -m 30"
        ts5b_checktool_curl_ssl=1
    else
        ts5b_check_domain_proto='http://'
    fi
    if ! curl -s -S -m 1 -x socks5://127.0.0.1:1 "${ts5b_check_domain_proto}${ts5b_check_domain}" 2>&1 |grep -qiE "Unsupported proxy.*\bsocks"; then
        ts5b_checktool_curl_socks=1
    fi
fi


exitme()
{
    exec 3>&-
    rm -f "${ts5b_list_file}.lock" "${ts5b_tmplst_file}" "${ts5b_download_file}" 2>/dev/null
    final ${1}
}

logme()
{
    case "${ts5b_logme_silence}" in "0")
        case "${ts5b_update_only}" in
        "0")
            logger -s -t ts5b-wdt "${@}" >/dev/null 2>&1;;
        *)
            echo "${@}" >&3;;
        esac
        ;;
    esac
}

stopme()
{
    if [ -f "${ts5b_stop_file}" ]; then
        logme "Stopped SOCKS5 balancing monitor for Tor connections."
        sleep 1

        grep all "${ts5b_stop_file}" >/dev/null 2>&1 && (
            socksbal_stop
            sshsocks_stop
            logme "Also stopped all SOCKS5 balancing."
        )
        rm -f "${ts5b_stop_file}" >/dev/null 2>&1
        sync

        exitme 0
    fi
}

sleepstopme()
{
    sec_cnr=${1}
    sleepme_sec=1
    while :; do
        sleepme ${sleepme_sec}
        stopme
        case "${sec_cnr}" in "-"*|"0") break;; esac
        sec_cnr=$((sec_cnr - sleepme_sec))
    done
}

sshsocks_setkey()
{
    rm -f "${ts5b_sshsocksid_file}"* 2>/dev/null

    read_file "${ts5b_sshsocksid_file}.pub" "sshsocks_key"

    case "${sshsocks_key}" in "")
        rm -f "${ts5b_sshsocksid_file}"* 2>/dev/null
        ssh-keygen -t ed25519 -f "${ts5b_sshsocksid_file}" -N ""
        logme "New SSH keys generated, files ${ts5b_sshsocksid_file}*."
        read_file "${ts5b_sshsocksid_file}.pub" "sshsocks_key"
        ;;
    esac

    grep -F "${sshsocks_key}" "${ts5b_openssh_authkeys_file}" >/dev/null 2>&1 \
        || (echo "${sshsocks_key}" >>"${ts5b_openssh_authkeys_file}"; \
            logme "Added localhost public key to authorized keys for OpenSSH.")

    grep -F "${sshsocks_key}" "${ts5b_dropbear_authkeys_file}" >/dev/null 2>&1 \
        || (echo "${sshsocks_key}" >>"${ts5b_dropbear_authkeys_file}"; \
            logme "Added localhost public key to authorized keys for Dropbear.")

    chmod 600 "${ts5b_sshsocksid_file}"
    chmod 644 "${ts5b_sshsocksid_file}".pub
    chmod 600 "${ts5b_openssh_authkeys_file}"
    chmod 600 "${ts5b_dropbear_authkeys_file}"

    return 0
}

sshsocks_stop()
{
    for sshsocks_pid in $(eval ${ts5b_check_sshsocks_cmd}); do
        logme "Stopping local SOCKS5 emulator, PID=${sshsocks_pid}."
        kill ${sshsocks_pid} 2>/dev/null
        wait ${sshsocks_pid} 2>/dev/null
        remove_pids_from_list ${sshsocks_pid}
    done

    return 0
}

sshsocks_getpidport()
{
    retrycnr=0

    while :; do
        case "$((13 - retrycnr))" in "-"*|"0") break;; esac
        sshsocks_pid=$(eval ${ts5b_check_sshsocks_cmd})
        read_file "${ts5b_sshsocksport_file}" "ts5b_sshsocks_port"
        case "${sshsocks_pid}" in "");; *)
            case "${ts5b_sshsocks_port}" in "");; *)
                logme "SOCKS5 emulator PID=${sshsocks_pid}, port=${ts5b_sshsocks_port}"
                return 0
                ;;
            esac
            ;;
        esac
        sleepstopme 1
        retrycnr=$((retrycnr + 1))
    done

    case "${sshsocks_pid}" in "")
        logme "Could not get SOCKS5 emulator PID, failed CMD: ${ts5b_check_sshsocks_cmd}";;
    esac
    case "${ts5b_sshsocks_port}" in "")
        logme "Could not get SOCKS5 emulator port";;
    esac

    return 1
}

sshsocks_start()
{
    case "${1}" in "norestart")
        sshsocks_pids=$(eval ${ts5b_check_sshsocks_cmd})
        case "${sshsocks_pids}" in "");; *)
            sshsocks_getpidport
            return $?
            ;;
        esac
        ;;
    esac

    sshsocks_stop
    sshsocks_setkey

    ts5b_sshsocks_port=$(getfrndport.sh -m8192)
    echo "${ts5b_sshsocks_port}" >"${ts5b_sshsocksport_file}"
    sync

    l_now_ms=
    localssh_retries=
    while :; do
        case "${localssh_retries}" in "")
            localssh_retries=0;;
        esac

        case "${l_now_ms}" in "")
            update_sysuptime_ms
            l_now_ms=${sys_uptime_ms}
        esac

        ssh_found=0
        for ssh_service in dropbear sshd; do
            localssh_port=$(netstat -ntulp 2>/dev/null |grep "/${ssh_service}" |tr -s " \t" " " |cut -sd" " -f4 |grep -Eo "${re_ipport}$" |sort -u)
            case "${localssh_port}" in "");; *)
                ssh_found=1
                logme "CMD: ${ts5b_sshsocks_cmdline} ${localhost_address}:${ts5b_sshsocks_port} -p ${localssh_port}"
                eval ${ts5b_sshsocks_cmdline} ${localhost_address}:${ts5b_sshsocks_port} -p ${localssh_port} >/dev/null 2>&1 && break 2
                logme "Local SOCKS5 emulator terminated with an error $?, restarting."
                ;;
            esac
        done

        case "${ssh_found}" in "0")
            logme "Cannot detect SSH server port, local SOCKS5 emulator will not be used."
            echo >"${ts5b_sshsocksport_file}"
            sync
            break
            ;;
        esac

        sleepstopme 1
        localssh_retries=$((localssh_retries + 1))
        case "$((11 - localssh_retries))" in "-"*|"0")
            update_sysuptime_ms
            case "$((sys_uptime_ms - l_now_ms - 30000))" in "-"*);; *)
                logme "Too much errors seen last time in local SOCKS5 emulator, stop trying to use it."
                echo >"${ts5b_sshsocksport_file}"
                sync
                break
                ;;
            esac
            l_now_ms=
            localssh_retries=
            ;;
        esac
    done &
    add_pids_to_list $!

    sleepstopme 3

    sshsocks_getpidport
    return $?
}

sockslist_checkcontents()
{
    cidrcnr=0
    while IFS= read -r cidrline; do
        check_ipv4_or_domain "${cidrline}"
        upstream_addr="${result_ipaddr}"
        upstream_port="${result_port}"
        case "${upstream_addr}" in "");; *)
            case "${upstream_port}" in "");; *)
                cidrcnr=$((cidrcnr + 1))
                case $((ts5b_checked_proxies_min / 2 - cidrcnr)) in "-"*|0) return 0;; esac
                ;;
            esac
            ;;
        esac
    done <"${1}"

    return 1
}

sockslist_checkvalid()
{
    case ${ts5b_update_only} in 0);; *)
        return 1;;
    esac

    l_now_sec=$(date +%s)
    file_tocheck="${ts5b_chklst_file}"

    checkages=1
    oksilent=0
    while :; do
        case "${1}" in
        "nocheckages")
            checkages=0;;
        "oksilent")
            oksilent=1;;
        "")
            break;;
        esac
        shift
    done

    if [ -s "${file_tocheck}" ]; then
        file_sec=$(date -r "${file_tocheck}" +%s)
        case "$((l_now_sec - file_sec - ts5b_lists_ages_sec))" in
        "-"*|"0")
            case "${oksilent}" in "0")
                logme "Found file ${file_tocheck} that is up-to-date.";;
            esac
            ;;
        *)
            case "${checkages}" in "0");; *)
                logme "Found file ${file_tocheck} but it is too old."
                return 1
                ;;
            esac
            logme "Found old file ${file_tocheck}."
            ;;
        esac
        if sockslist_checkcontents "${file_tocheck}"; then
            case "${oksilent}" in "0")
                logme "File ${file_tocheck} contains sufficient proxies information.";;
            esac
            return 0
        fi
        logme "File ${file_tocheck} does not contain sufficient proxies information."
        return 1
    fi

#    logme "File ${file_tocheck} not found."
    return 1
}

socks_scanlist()
{
    l_ssl_scanphase=1
    l_ssl_listfile="${1}"
    logme "Phase ${l_ssl_scanphase}: online proxies pre-scan..."
    socks_scanlist_method "${l_ssl_listfile}" "netcat"
    case "${ts5b_checktool}" in
    "socat"|"netcat")
        l_ssl_listfile="${ts5b_chklst_file}";;
    "")
        logme "Pre-scan skipped.";;
    esac
    l_ssl_scanphase=$((l_ssl_scanphase + 1))
    logme "Phase ${l_ssl_scanphase}: working proxies full check..."
    socks_scanlist_method "${l_ssl_listfile}" "curl"
}

socks_scanlist_method()
{
    update_sysuptime_ms
    ts5b_proxieslist_check_t0_ms=${sys_uptime_ms}
    l_sslm_lowmem_cnr=0
    l_sslm_lowmem_max=9
    l_sslm_pids=
    l_sslm_listfile="${1}"
    l_sslm_listfile_nresp=
    l_sslm_retry_cnr=0
    l_sslm_checkproto="tcp"
    l_sslm_freemem_min=$((total_memory_kb / 6))
    case ${ts5b_high_priority} in 0) l_sslm_freemem_min=$((total_memory_kb / 4));; esac
    l_sslm_checkdomain_port=80
    case "${ts5b_check_domain_proto}" in "https") l_sslm_checkdomain_port=443;; esac

    case "${2}" in
    "nc"|"netcat")
        # Pre-scan: netcat -> socat
        ts5b_checktool="netcat"
        case ${ts5b_checktool_netcat} in 0)
            logme "Netcat not found, falling back to socat."
            ts5b_checktool="socat"
            case ${ts5b_checktool_socat} in 0)
                logme "Socat not found."
                ts5b_checktool=
                ;;
            esac
            ;;
        esac
        ;;
    "socat")
        # Pre-scan: socat -> netcat
        ts5b_checktool="socat"
        case ${ts5b_checktool_socat} in 0)
            logme "Socat not found, falling back to netcat."
            ts5b_checktool="netcat"
            case ${ts5b_checktool_netcat} in 0)
                logme "Netcat not found."
                ts5b_checktool=
                ;;
            esac
            ;;
        esac
        ;;
    "socurl")
        # Full-scan: socat -> curl
        l_sslm_checkproto=
        ts5b_checktool="socurl"
        case ${ts5b_checktool_socat} in 0)
            logme "Socat not found, falling back to curl."
            ts5b_checktool="curl"
            case $((1 - ts5b_checktool_curl - ts5b_checktool_curl_socks)) in "-"*);; *)
                logme "Curl not found or without SOCKS support."
                ts5b_checktool=
                ;;
            esac
            ;;
        esac
        ;;
    *)
        # Full-scan: curl -> socat
        l_sslm_checkproto=
        ts5b_checktool="curl"
        case $((1 - ts5b_checktool_curl - ts5b_checktool_curl_socks)) in "-"*);; *)
            logme "Curl not found or without SOCKS support, falling back to socat."
            ts5b_checktool="socurl"
            case ${ts5b_checktool_socat} in 0)
                logme "Socat not found."
                ts5b_checktool=
                ;;
            esac
            ;;
        esac
        ;;
    esac

    l_sslm_trackpids=1
    case "${ts5b_checktool}" in
    "")
        logme "No suitable tool found, exiting."
        return 1
        ;;
    "netcat")
        case "${ts5b_checktool_netcat_opts}" in
        "")
            logme "Using tool: netcat."
            ;;
        *)
#            l_sslm_trackpids=0
            logme "Using tool: netcat, options: ${ts5b_checktool_netcat_opts}."
            ;;
        esac
        l_sslm_pidsbatch=43
        l_sslm_pids_max=1024
        l_sslm_timeout_sec=$((ts5b_check_maxtime_sec / 12 + 1))
        l_sslm_cooldown_period_ms=$((l_sslm_timeout_sec * 1000 * 3))
        l_sslm_sameip_max=65535
        ;;
    "socat")
        l_sslm_pidsbatch=27
        l_sslm_pids_max=512
        l_sslm_timeout_sec=$((ts5b_check_maxtime_sec / 9 + 1))
        l_sslm_cooldown_period_ms=$((l_sslm_timeout_sec * 1000))
        l_sslm_sameip_max=65535
        logme "Using tool: socat, mode: TCP."
        ;;
    "socurl")
        l_sslm_pidsbatch=19
        l_sslm_pids_max=384
        l_sslm_timeout_sec=$((ts5b_check_maxtime_sec / 2 + 1))
        l_sslm_cooldown_period_ms=$((l_sslm_timeout_sec * 1000 / 5))
        l_sslm_sameip_max=2
        logme "Using tool: socat, mode: SOCKS."
        ;;
    "curl")
        l_sslm_pidsbatch=13
        l_sslm_pids_max=256
        l_sslm_timeout_sec=${ts5b_check_maxtime_sec}
        l_sslm_cooldown_period_ms=$((l_sslm_timeout_sec * 1000 / 3))
        l_sslm_sameip_max=2
        logme "Using tool: curl."
        ;;
    esac

    l_sslm_trackpids_dir=
    case ${l_sslm_trackpids} in 0);; *)
#        l_sslm_trackpids_dir="$(mktemp -d)"
        ;;
    esac

    while case "$((ts5b_check_retry - l_sslm_retry_cnr))" in "-"*|"0") break;; esac; do

        case "${l_sslm_listfile_nresp}" in
        "")
            l_sslm_listfile_nresp="${ts5b_nolst_file}"
            ;;
        "${ts5b_nolst_file}")
            l_sslm_listfile="${ts5b_nolst_file}"
            l_sslm_listfile_nresp="${ts5b_nolst_file}.0"
            ;;
        *)
            l_sslm_listfile="${ts5b_nolst_file}.0"
            l_sslm_listfile_nresp="${ts5b_nolst_file}"
            ;;
        esac
        rm -f "${ts5b_list_file}.lock" "${ts5b_tmplst_file}" "${l_sslm_listfile_nresp}" 2>/dev/null
        case "${l_sslm_checkproto}" in
        "tcp")
            ;;
        "socks5")
            case "${ts5b_socks5_only}" in "0") l_sslm_checkproto="socks4";; esac;;
        *)
            l_sslm_checkproto="socks5";;
        esac
        l_sslm_processed_cnr=0
        l_sslm_pids_cnr=0
        update_sysuptime_ms
        gt0=${sys_uptime_ms}
        while IFS= read -r cidrline; do

            #
            # Check inet and wait if needed
            #
            update_sysuptime_ms
            case "$((gt0 - sys_uptime_ms + l_sslm_cooldown_period_ms))" in "-"*)
                l_ssl_to=${l_sslm_timeout_sec}
                case ${l_sslm_trackpids} in
                0)
                    sleepstopme ${l_ssl_to}
                    ;;
                *)
                    case "${l_sslm_trackpids_dir}" in "");; *)
                        l_sslm_pids="$(ls l_sslm_trackpids_dir)"
                        rm -f "${l_sslm_trackpids_dir}/"*
                        ;;
                    esac
                    stop_pids_after_timeout ${l_ssl_to} ${l_sslm_pids}
                    ;;
                esac
                l_sslm_pids=
                l_sslm_pids_cnr=0
                inet_waitconnection
                update_sysuptime_ms
                gt0=${sys_uptime_ms}
                ;;
            esac

            #
            # Check socks server: ok >> ts5b_tmplst_file, bad >> l_sslm_listfile_nresp
            #
            t0=${sys_uptime_ms}
            check_ipv4_or_domain "${cidrline}"
            addr0="${result_ipaddr}"
            case "${addr0}" in "") addr0="${result_domain}";; esac
            port0="${result_port:-1080}"
            {
                case ${l_sslm_trackpids} in 0);; *)
                    case "${l_sslm_trackpids_dir}" in "");; *)
                        read selfpid _ </proc/self/stat
                        : >"${l_sslm_trackpids_dir}/${selfpid}" 2>&1
                        ;;
                    esac
                    ;;
                esac

                case "${ts5b_checktool}" in
                "netcat")
                    nc ${ts5b_checktool_netcat_opts}${ts5b_checktool_netcat_opts:+ ${l_sslm_timeout_sec} }${addr0} ${port0} >/dev/null 2>&1 </dev/null
                    ;;
                "socat")
                    socat -u -b 256 -T ${l_sslm_timeout_sec} -t ${l_sslm_timeout_sec} TCP-CONNECT:${addr0}:${port0},connect-timeout=${l_sslm_timeout_sec} - \
                        >/dev/null 2>&1 </dev/null
                    ;;
                "socurl")
                    socat -u -b 256 -T ${l_sslm_timeout_sec} -t ${l_sslm_timeout_sec} SOCKS5-CONNECT:${addr0}:${port0}:${ts5b_check_domain}:${l_sslm_checkdomain_port} - \
                        >/dev/null 2>&1 </dev/null
                    ;;
                *)
                    curl -N -q -s -k --no-keepalive --max-filesize 1 --max-time ${l_sslm_timeout_sec} --connect-timeout ${l_sslm_timeout_sec} \
                        -x ${l_sslm_checkproto}://${addr0}:${port0} -I "${ts5b_check_domain_proto}${ts5b_check_domain}" >/dev/null 2>&1
                    ;;
                esac
                case $? in
                0)
                    update_sysuptime_ms
                    t=$((sys_uptime_ms - t0))
                    flock "${ts5b_list_file}.lock" printf "${addr0}=%06d:${port0},${l_sslm_checkproto}\n" ${t} >>"${ts5b_tmplst_file}" 2>/dev/null && sync
                    ;;
                *)
                    flock "${ts5b_list_file}.lock" echo ${cidrline} >>"${l_sslm_listfile_nresp}" 2>/dev/null && sync
                    ;;
                esac
                case ${l_sslm_trackpids} in 0);; *)
                    case "${l_sslm_trackpids_dir}" in "");; *) rm -f "${l_sslm_trackpids_dir}/${selfpid}" >/dev/null 2>&1;; esac
                    ;;
                esac
            } &
            case ${l_sslm_trackpids} in 0);; *)
                case "${l_sslm_trackpids_dir}" in
                "")
                    l_sslm_pids="${l_sslm_pids} $!";;
                esac
                ;;
            esac
            l_sslm_pids_cnr=$((l_sslm_pids_cnr + 1))
            l_sslm_processed_cnr=$((l_sslm_processed_cnr + 1))

            #
            # Some complicated wait magic
            #
            case $((l_sslm_processed_cnr % l_sslm_pidsbatch)) in 0)
                case ${ts5b_update_only} in
                0)
#                    l_sslm_pidsbatch_mul=2
#                    case ${ts5b_high_priority} in 0) l_sslm_pidsbatch_mul=1;; esac
#                    case $((l_sslm_processed_cnr % (l_sslm_pidsbatch * l_sslm_pidsbatch_mul))) in 0)
#                        sleepstopme 1;;
#                    esac
                    ;;
                *)
                    count_file_lines "${ts5b_tmplst_file}" "nlines"
                    case ${l_sslm_retry_cnr} in 0) retrystr="";; *) retrystr=" (try $((l_sslm_retry_cnr + 1)))";; esac
                    printf "\rChecking proxies${retrystr}: %d from %d are good." "${nlines}" "${l_sslm_processed_cnr}" >&3
                    ;;
                esac
                stopme
                get_freemem_kb "l_sslm_freemem"
                lowmemflag=0
                case $((l_sslm_freemem - l_sslm_freemem_min)) in "-"*) lowmemflag=1;; esac
                procslimflag=0
                case $((l_sslm_pids_max - l_sslm_pids_cnr)) in "-"*) procslimflag=1;; esac
                case $((0 - procslimflag - lowmemflag)) in "-"*)
                    l_ssl_to=${l_sslm_timeout_sec}
                    case ${l_sslm_trackpids} in
                    0)
                        sleepstopme ${l_ssl_to}
                        ;;
                    *)
                        case "${l_sslm_trackpids_dir}" in "");; *)
                            l_sslm_pids="$(ls l_sslm_trackpids_dir)"
                            rm -f "${l_sslm_trackpids_dir}/"*
                            ;;
                        esac
                        stop_pids_after_timeout ${l_ssl_to} ${l_sslm_pids}
                        ;;
                    esac
                    l_sslm_pids=
                    l_sslm_pids_cnr=0
                    ;;
                esac
                case ${lowmemflag} in 0);; *)
                    get_freemem_kb "l_sslm_freemem"
                    lowmemflag=0
                    case $((l_sslm_freemem - l_sslm_freemem_min)) in "-"*)
                        l_sslm_lowmem_cnr=$((l_sslm_lowmem_cnr + 1))
                        case $((l_sslm_lowmem_max - l_sslm_lowmem_cnr)) in "-"*|0)
                            l_sslm_lowmem_cnr=0
                            logme "Free memory runs out ($((freephysmem / 1024)) MB), the system may be unstable."
                            echo 3 >/proc/sys/vm/drop_caches
                            ;;
                        esac
                        ;;
                    esac
                    ;;
                esac
                ;;
            esac
        done <"${l_sslm_listfile}"
        sleepstopme ${l_sslm_timeout_sec}

        #
        # Add new proxies to already discovered and sorted
        #  (on previous global scan try), then sort again
        #
        cat "${ts5b_tmplst_file}" "${ts5b_spdlst_file}" 2>/dev/null >"${ts5b_spdlst_file}.u"
        sort "${ts5b_spdlst_file}.u" -o "${ts5b_spdlst_file}.u"
        sameipcnr=0
        currentaddr=
        currentport=
        while IFS= read -r addrtimeportproto; do
            addr0="${addrtimeportproto%=*}"
            timeportproto="${addrtimeportproto##*=}"
            tresponse="${timeportproto%:*}"
            portproto="${timeportproto##*:}"
            port0="${portproto%,*}"
            proto="${portproto##*,}"
            check_ipv4_or_domain "${addr0}"
            case $? in
            0)
                case "${result_iptype}" in "0") addr="${result_ipaddr}";; *) continue;; esac;;
            1)
                addr="${result_domain}";;
            *)
                continue;;
            esac
            port="${port0:-1080}"
            newline=0
            case "${addr}" in "");;
            "${currentaddr}")
                case "${port}" in "${currentport}");; *)
                    sameipcnr=$((sameipcnr + 1))
                    case "$((sameipcnr - l_sslm_sameip_max))" in "-"*|"0") newline=1;; esac
                    ;;
                esac
                ;;
            *)
                newline=1
                sameipcnr=0
                currentaddr="${addr}"
                currentport="${port}"
                ;;
            esac
            case "${newline}" in "0");; *)
                echo "${addr}=${tresponse}:${port},${proto}";;
            esac
        done <"${ts5b_spdlst_file}.u" |sort >"${ts5b_spdlst_file}"

        #
        # Final checks
        #
        count_file_lines "${ts5b_spdlst_file}" "nlines"
        count_file_lines "${ts5b_spdlst_file}.u" "nlines_u"
        filteredstr=
        case "${nlines}" in "${nlines_u}");; *)
            filteredstr=" after filtering out $((nlines_u - nlines)) proxies with same IP(s).";;
        esac
        case "${ts5b_update_only}" in 0);; *)
            case "${l_sslm_retry_cnr}" in 0) retrystr="";; *) retrystr=" (in $((l_sslm_retry_cnr + 1)) tries)";; esac
            ts5b_proxieslist_check_t_ms=$((sys_uptime_ms - ts5b_proxieslist_check_t0_ms))
            ms_to_S ${ts5b_proxieslist_check_t_ms}
            printf "\rChecked total %d proxies in ${result_S} sec(s), %d are good${filteredstr}${retrystr}.\n" \
                "$(count_file_lines "${1}")" "${nlines}" >&3
            ;;
        esac
        flock "${ts5b_list_file}.lock" rm -f "${ts5b_list_file}.lock"
        count_file_lines "${ts5b_spdlst_file}" "checkedcnt"
        case "$((${2} - checkedcnt))" in "-"*) break;; esac
        l_sslm_retry_cnr=$((l_sslm_retry_cnr + 1))
        l_sslm_timeout_sec=$((l_sslm_timeout_sec * 3 / 2 + 1))
    done

    #
    # Sort final checked list by response time
    #
    while IFS= read -r addrtimeportproto; do
        addr0="${addrtimeportproto%=*}"
        timeportproto="${addrtimeportproto##*=}"
        tresponse="${timeportproto%:*}"
        portproto="${timeportproto##*:}"
        port0="${portproto%,*}"
        proto="${portproto##*,}"
        check_ipv4_or_domain "${addr0}"
        case $? in
        0)
            addr="${result_ipaddr}"
            case "${result_iptype}" in 0);; *) continue;; esac
            ;;
        1)
            addr="${result_domain}"
            ;;
        *)
            continue
            ;;
        esac
        port="${port0:-1080}"
        newline=0
        case "${addr}" in "");;
        "${currentaddr}")
            case "${port}" in "${currentport}");; *)
                sameipcnr=$((sameipcnr + 1))
                case "$((sameipcnr - l_sslm_sameip_max))" in "-"*|"0") newline=1;; esac
                ;;
            esac
            ;;
        *)
            newline=1
            sameipcnr=0
            currentaddr="${addr}"
            currentport="${port}"
            ;;
        esac
        case "${newline}" in "0");; *)
            echo "${tresponse}=${addr}:${port},${proto}";;
        esac
    done <"${ts5b_spdlst_file}" |sort >"${ts5b_spdlst_file}.u"

    #
    # Finally, convert the list from complicated format to human-readable
    #
    while IFS= read -r timeaddrportproto; do
        tresponse="${timeaddrportproto%=*}"
        addrportproto="${timeaddrportproto##*=}"
        addrport="${addrportproto%,*}"
        proto="${addrportproto##*,}"
        addr0="${addrport%:*}"
        port0="${addrport##*:}"
        check_ipv4_or_domain "${addr0}"
        case $? in
        0)
            addr="${result_ipaddr}"
            case "${result_iptype}" in 0);; *) continue;; esac
            ;;
        1)
            addr="${result_domain}"
            ;;
        *)
            continue
            ;;
        esac
        port="${port0:-1080}"
        ms_to_S ${tresponse}
        newline=0
        case "${addr}" in "");;
        "${currentaddr}")
            case "${port}" in "${currentport}");; *)
                sameipcnr=$((sameipcnr + 1))
                case "$((sameipcnr - l_sslm_sameip_max))" in "-"*|"0") newline=1;; esac
                ;;
            esac
            ;;
        *)
            newline=1
            sameipcnr=0
            currentaddr="${addr}"
            currentport="${port}"
            ;;
        esac
        case "${newline}" in "0");; *)
            case "${proto}" in
            "socks4")
                printf "${addr}:${port}\t# ${result_S}s, socks4\n";;
            *)
                printf "${addr}:${port}\t# ${result_S}s\n";;
            esac
            ;;
        esac
    done <"${ts5b_spdlst_file}.u" >"${ts5b_chklst_file}"

    rm -f "${ts5b_tmplst_file}" "${ts5b_spdlst_file}" "${ts5b_spdlst_file}.u" \
        "${ts5b_nolst_file}" "${ts5b_nolst_file}.0" 2>/dev/null
}

socks_updatelist()
{
    if ! cat "${ts5b_chklst_file_save}" 2>/dev/null |diff -b -B "${ts5b_chklst_file}" - >/dev/null; then
        if cp -f "${ts5b_chklst_file}" "${ts5b_chklst_file_save}"; then
            logme "SOCKS5 checked proxies list was updated."
        else
            logme "Error saving updated SOCKS5 checked proxies list."
        fi
        return 1 # list changed
    fi

    logme "SOCKS5 checked proxies list was NOT changed."
    return 0
}

socks_getlist()
{
    oksilent=0
    case "${1}" in "oksilent") oksilent=1;; esac
    case "${oksilent}" in "0")
        logme "Checking existing SOCKS5 proxies list...";;
    esac
    if sockslist_checkvalid "${1}"; then
        case "${oksilent}" in "0")
            logme "Using previously generated SOCKS5 proxies list.";;
        esac
        return 0
    fi
    if cp -f "${ts5b_chklst_file_save}" "${ts5b_chklst_file}" 2>/dev/null; then
        touch -r "${ts5b_chklst_file_save}" "${ts5b_chklst_file}"
        if sockslist_checkvalid "${1}"; then
            case "${oksilent}" in "0")
                logme "Using previously saved SOCKS5 proxies list.";;
            esac
            return 0
        fi
    fi

    ts5b_logme_silence=0

    update_sysuptime_ms
    ts5b_proxieslist_download_t0_ms=${sys_uptime_ms}
    logme "Getting SOCKS5 proxies list from specified sources."

    ts5b_sources=$(sed -e "/^ *#/d; /^ *$/d" -e "s/[ \t]*$//" -e "s/^[ \t]*//" "${ts5b_sources_file}" 2>/dev/null)
    case "${ts5b_sources}" in "")
        logme "Source URLs list not found, using default."
        rm -f "${ts5b_list_file}" 2>/dev/null
        ts5b_sources='
https://raw.githubusercontent.com/Anonym0usWork1221/Free-Proxies/main/socks4.txt
https://raw.githubusercontent.com/Anonym0usWork1221/Free-Proxies/main/socks5.txt
https://raw.githubusercontent.com/databay-labs/free-proxy-list/master/socks4.txt
https://raw.githubusercontent.com/databay-labs/free-proxy-list/master/socks5.txt
https://raw.githubusercontent.com/ebrasha/abdal-proxy-hub/main/socks4-proxy-list-by-EbraSha.txt
https://raw.githubusercontent.com/ebrasha/abdal-proxy-hub/main/socks5-proxy-list-by-EbraSha.txt
https://raw.githubusercontent.com/fyvri/fresh-proxy-list/archive/storage/classic/socks4.txt
https://raw.githubusercontent.com/fyvri/fresh-proxy-list/archive/storage/classic/socks5.txt
https://raw.githubusercontent.com/gitrecon1455/fresh-proxy-list/main/proxylist.txt
https://raw.githubusercontent.com/handeveloper1/Proxy/main/Proxies-Ercin/socks4.txt
https://raw.githubusercontent.com/handeveloper1/Proxy/main/Proxies-Ercin/socks5.txt
https://raw.githubusercontent.com/hookzof/socks5_list/master/proxy.txt
https://raw.githubusercontent.com/HyperBeats/proxy-list/main/socks4.txt
https://raw.githubusercontent.com/HyperBeats/proxy-list/main/socks5.txt
https://raw.githubusercontent.com/iplocate/free-proxy-list/main/protocols/socks4.txt
https://raw.githubusercontent.com/iplocate/free-proxy-list/main/protocols/socks5.txt
https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-socks4.txt
https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-socks5.txt
https://raw.githubusercontent.com/manuGMG/proxy-365/main/SOCKS4.txt
https://raw.githubusercontent.com/manuGMG/proxy-365/main/SOCKS5.txt
https://raw.githubusercontent.com/mmpx12/proxy-list/master/socks4.txt
https://raw.githubusercontent.com/mmpx12/proxy-list/master/socks5.txt
https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks4.txt
https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt
https://raw.githubusercontent.com/MuRongPIG/Proxy-Master/main/socks4.txt
https://raw.githubusercontent.com/MuRongPIG/Proxy-Master/main/socks5.txt
https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/socks4/data.txt
https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/socks5/data.txt
https://raw.githubusercontent.com/roosterkid/openproxylist/main/SOCKS4_RAW.txt
https://raw.githubusercontent.com/roosterkid/openproxylist/main/SOCKS5_RAW.txt
https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/socks4.txt
https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/socks5.txt
https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks4.txt
https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt
https://raw.githubusercontent.com/UptimerBot/proxy-list/main/proxies/socks4.txt
https://raw.githubusercontent.com/UptimerBot/proxy-list/main/proxies/socks5.txt
https://raw.githubusercontent.com/UserR3X/proxy-list/main/socks4.txt
https://raw.githubusercontent.com/UserR3X/proxy-list/main/socks5.txt
https://raw.githubusercontent.com/vakhov/fresh-proxy-list/master/socks4.txt
https://raw.githubusercontent.com/vakhov/fresh-proxy-list/master/socks5.txt
https://raw.githubusercontent.com/vmheaven/VMHeaven-Free-Proxy-Updated/main/socks4.txt
https://raw.githubusercontent.com/vmheaven/VMHeaven-Free-Proxy-Updated/main/socks5.txt
https://raw.githubusercontent.com/vmheaven/VMHeaven-Free-Proxy-Updated/main/socks4_anonymous.txt
https://raw.githubusercontent.com/vmheaven/VMHeaven-Free-Proxy-Updated/main/socks5_anonymous.txt
https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/socks4.txt
https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/socks5.txt
https://raw.githubusercontent.com/Zaeem20/FREE_PROXIES_LIST/master/socks4.txt
https://raw.githubusercontent.com/Zaeem20/FREE_PROXIES_LIST/master/socks5.txt
https://raw.githubusercontent.com/zevtyardt/proxy-list/main/socks4.txt
https://raw.githubusercontent.com/zevtyardt/proxy-list/main/socks5.txt
https://raw.githubusercontent.com/zloi-user/hideip.me/master/socks4.txt
https://raw.githubusercontent.com/zloi-user/hideip.me/master/socks5.txt
'
        echo "${ts5b_sources}" >"${ts5b_sources_file}"
        ;;
    esac

    sortedcnt=0
    while :; do
        case "${sortedcnt}" in "0");; *) break;; esac
        retrycnr=0
        while :; do
            processedcnt=0
            list_contents=
            for current_source in ${ts5b_sources}; do
                inet_waitconnection
                current_source="${current_source%%#*}"
                current_source="${current_source#"${current_source%%[![:space:]]*}"}" # remove leading spaces
                current_source="${current_source%%[[:space:]]*}" # remove something after the first space
                current_source="${current_source%"${current_source##*[![:space:]]}"}" # remove trailing spaces
                case "${current_source}" in "") continue;; esac
                logme "Downloading ${current_source}"
#                ${ts5b_download_cmd} "${current_source}" |while IFS= read -r cidrline; do
                ${ts5b_download_cmd} "${current_source}" >"${ts5b_download_file}"
                while IFS= read -r cidrline; do
                    guess_port=1080
                    case "${cidrline}" in *"://"*) cidrline="${cidrline#*://}";; esac
                    check_ipv4_or_domain "${cidrline}"
                    case $? in
                    0)
                        case "${result_iptype}" in
                        0)
                            echo "${list_contents}${result_ipaddr}:${result_port:-${guess_port}}";;
                        *)
                            continue;;
                        esac
                        ;;
                    1)
                        echo "${list_contents}${result_domain}:${result_port:-${guess_port}}"
                        ;;
                    2)
                        continue
                        ;;
                    esac
                    processedcnt=$((processedcnt + 1))
                    case $((processedcnt % 29)) in 0) stopme;; esac
#                done
                done <"${ts5b_download_file}"
                rm -f "${ts5b_download_file}"
            done |sort -u >"${ts5b_list_file}"
            count_file_lines "${ts5b_list_file}" "sortedcnt"
            case "$((ts5b_total_proxies_min - sortedcnt))" in "-"*|"0")
                update_sysuptime_ms
                ts5b_proxieslist_download_t_ms=$((sys_uptime_ms - ts5b_proxieslist_download_t0_ms))
                ms_to_S ${ts5b_proxieslist_download_t_ms}
                logme "SOCKS5 proxies list downloaded OK (${sortedcnt} total) in ${result_S} sec(s)."
                if [ -s "${ts5b_list_file}" ]; then
                    if ! cat "${ts5b_list_file_save}" 2>/dev/null |diff -b -B "${ts5b_list_file}" - >/dev/null; then
                        if cp -f "${ts5b_list_file}" "${ts5b_list_file_save}"; then
                            logme "SOCKS5 proxies list was updated."
                        else
                            logme "Error saving updated SOCKS5 proxies list."
                        fi
                    fi
                fi
                break
                ;;
            esac
            retrycnr=$((retrycnr + 1))
        done
        case "${sortedcnt}" in "0")
            logme "No any SOCKS5 proxies, trying to get again after pause..."
            sleepstopme 10
            ;;
        esac
    done

    case "$((sortedcnt - ts5b_checked_proxies_max))" in "-"*|"0")
        logme "Using ${sortedcnt} SOCKS5 proxies from raw downloaded list."
        cp -f "${ts5b_list_file_save}" "${ts5b_chklst_file}"
        return 0
        ;;
    esac

    logme "SOCKS5 proxies fast&dirty check."

    socks_scanlist "${ts5b_list_file_save}" ${ts5b_checked_proxies_full_min}
    count_file_lines "${ts5b_chklst_file}" "checkedcnt"
    case "$((ts5b_checked_proxies_full_min / 2 - checkedcnt))" in
    "-"*)
        logme "Using ${checkedcnt} responsive SOCKS5 proxies."
        ;;
    *)
        case "$((1 - checkedcnt))" in
        "-"*)
            logme "Insufficient responsive SOCKS5 proxies, only ${checkedcnt} proxies were discovered.";;
        *)
            logme "Cannot discover responsive SOCKS5 proxies.";;
        esac
        logme "Using ${sortedcnt} SOCKS5 proxies from raw downloaded list."
        cp -f "${ts5b_list_file_save}" "${ts5b_chklst_file}"
        ;;
    esac

    socks_updatelist
    return $?
}

socksbal_gencfg()
{
    logme "Writing ${ts5b_balancer_cfg_file}."

    cat >"${ts5b_balancer_cfg_file}" <<EOF
{
  "listenHost": "${localhost_address}",
  "listenPort": ${1},
  "upstreamSelectRule": "random",
  "connectCheckPeriod": 300000,
  "connectTimeout": $((ts5b_check_maxtime_sec * 1234)),
  "serverChangeTime": 30000,
  "sleepTime": 3600000,
  "testRemoteHost": "${ts5b_check_domain}",
  "threadNum": 10,
  "upstream": [
EOF

    cidrcnr=0
    while IFS= read -r cidrline; do
        check_ipv4_or_domain "${cidrline%%#*}"
        case $? in
        0)
            case "${result_iptype}" in
            0)
                upstream_addr="${result_ipaddr}"
                case "${result_port}" in
                "")
                    upstream_port=1080;;
                *)
                    upstream_port=${result_port};;
                esac
                ;;
            *)
                continue
                ;;
            esac
            ;;
        1)
            upstream_addr="${result_domain}"
            case "${result_port}" in
            "")
                upstream_port=1080;;
            *)
                upstream_port=${result_port};;
            esac
            ;;
        *)
            continue
            ;;
        esac
        case "${upstream_addr}" in "");; *)
            case "${upstream_port}" in "");; *)
                case "${cidrcnr}" in "0");; *)
                    cat >>"${ts5b_balancer_cfg_file}" <<EOF
    },
EOF
                    ;;
                esac
                cat >>"${ts5b_balancer_cfg_file}" <<EOF
    {
      "host": "${upstream_addr}",
      "port": "${upstream_port}"
EOF
                cidrcnr=$((cidrcnr + 1))
                case "$((ts5b_checked_proxies_max - cidrcnr))" in "-"*)
                    logme "Reached maximum of ${ts5b_checked_proxies_max} proxies."
                    break
                    ;;
                esac
                ;;
            esac
            ;;
        esac
    done <"${ts5b_chklst_file}"

#    ts5b_sshsocks_port=$(eval ${ts5b_get_sshsocksport_cmd})
    read_file "${ts5b_sshsocksport_file}" "ts5b_sshsocks_port"
    case "${localhost_address}" in "");; *)
        case "${ts5b_sshsocks_port}" in "");; *)
            case "${cidrcnr}" in "0");; *)
                cat >>"${ts5b_balancer_cfg_file}" <<EOF
    },
EOF
                ;;
            esac
            cat >>"${ts5b_balancer_cfg_file}" <<EOF
    {
      "host": "${localhost_address}",
      "port": "${ts5b_sshsocks_port}"
EOF
            cidrcnr=$((cidrcnr + 1))
            ;;
        esac
        ;;
    esac
    case "${cidrcnr}" in "0");; *)
        cat >>"${ts5b_balancer_cfg_file}" <<EOF
    }
EOF
        ;;
    esac
    cat >>"${ts5b_balancer_cfg_file}" <<EOF
  ]
}
EOF

    return 0
}

socksbal_stop()
{
    for socksbal_pid in $(eval ${ts5b_check_cmd}); do
        logme "Stopping Socks5BalancerAsio, PID=${socksbal_pid}."
        kill ${socksbal_pid} 2>/dev/null
        wait ${socksbal_pid} 2>/dev/null
        remove_pids_from_list ${socksbal_pid}
    done

    return 0
}

socksbal_start()
{
    socksbal_stop
    logme "Generating new Socks5BalancerAsio config."
    socksbal_gencfg ${ts5b_socks5proxy_port}
    logme "Starting Socks5BalancerAsio."
    if ! eval ${ts5b_check_cmd}; then
        while :; do
            logme "CMD: ${ts5b_cmdline}"
            eval ${ts5b_cmdline} >${ts5b_balancer_log_file} 2>&1 && break
            logme "Socks5BalancerAsio terminated with an error $?, restarting."
        done &
        add_pids_to_list $!
    fi

    retrycnr=0
    while :; do
        case "$((23 - retrycnr))" in "-"*|"0") break;; esac
        socksbal_pid=$(eval ${ts5b_check_cmd})
        case "${socksbal_pid}" in "");; *)
            logme "Socks5BalancerAsio PID=${socksbal_pid}, port=${ts5b_socks5proxy_port}."
            if sockslist_checkvalid oksilent; then
                ts5b_high_priority=0
            fi
            return 0
            ;;
        esac
        sleepstopme 1
        retrycnr=$((retrycnr + 1))
    done

    logme "Could not get Socks5BalancerAsio PID, failed CMD: ${ts5b_check_cmd}"
    return 1
}


exitme_signals_list="SIGTERM SIGINT"
trap exitme ${exitme_signals_list} >/dev/null 2>&1 \
    || trap exitme $(echo "${exitme_signals_list}" |sed 's/SIG//g')

case "${ts5b_action}" in "updateonly"|"getonly"|"checkonly")
    ts5b_update_only=1
    ;;
esac

if ls "${ts5b_etc_srctree_path}" >/dev/null 2>&1; then
    ts5b_sources_file="${ts5b_etc_srctree_path}/tsx/${ts5b_sources_file}"
    ts5b_list_file_save="/tmp/${ts5b_list_file_save}"
    ts5b_chklst_file_save="${ts5b_etc_srctree_path}/tsx/${ts5b_chklst_file_save}"
    ts5b_update_only=1
    ts5b_high_priority=1
elif ls "/etc/tsx" >/dev/null 2>&1; then
    ts5b_sources_file="/etc/tsx/${ts5b_sources_file}"
    ts5b_list_file_save="/tmp/${ts5b_list_file_save}"
    ts5b_chklst_file_save="/etc/tsx/${ts5b_chklst_file_save}"
else
    ts5b_current_dir="$(get_script_dir)"
    ts5b_sources_file="${ts5b_current_dir}/${ts5b_sources_file}"
    ts5b_list_file_save="${ts5b_current_dir}/${ts5b_list_file_save}"
    ts5b_chklst_file_save="${ts5b_current_dir}/${ts5b_chklst_file_save}"
    ts5b_update_only=1
    ts5b_high_priority=1
fi

case ${ts5b_update_only} in 0);; *)
    logme "Started SOCKS5 balancing monitor for Tor connections, update proxies list mode only."
#    rm -rf "${ts5b_chklst_file}" "${ts5b_list_file}" "${ts5b_tmplst_file}" "${ts5b_chklst_file_save}" >/dev/null 2>&1
    rm -rf "${ts5b_chklst_file}" "${ts5b_list_file}" "${ts5b_tmplst_file}" >/dev/null 2>&1
    socks_getlist
    exitme 0
    ;;
esac

rm -f "${ts5b_stop_file}" >/dev/null 2>&1
sync
case $((ts5b_checktool_netcat + ts5b_checktool_socat + ts5b_checktool_curl)) in 0)
    logme "No tools for proxies scanning found. Will NOT continue without netcat (nc), socat or curl, exiting."
    exitme 1;;
esac

logme "Started SOCKS5 balancing monitor for Tor connections, PID=$$, user=${current_user}, homedir=${current_user_home}."
logme "To stop monitor simply create blank file ${ts5b_stop_file}, for example:"
logme "    touch ${ts5b_stop_file}"
logme "If you want also to stop all SOCKS5 balancing, create this file with contents \"all\", e.g.:"
logme "    echo \"all\" >${ts5b_stop_file}"

if [ ${total_memory_kb} -lt 262144 ]; then
    logme "Device is memory constrained."
    ts5b_checked_proxies_max=${ts5b_checked_proxies_max_lowmem}
fi

using_old_socks_list=0
tor_started=0
tor_pid=$(eval ${ts5b_check_tor_cmd})
if [ -n "${tor_pid}" ]; then
    logme "Tor is already running, PID=${tor_pid}."
    tor_started=1
fi
checkupdates_interval_sec=780

while :; do
    #
    # Wait while Tor is not active
    #
    while ! /etc/init.d/tor running; do
        case "${tor_started}" in "0");; *)
            logme "Tor stopped."
            socksbal_stop
            sshsocks_stop
            stop_childs
            ;;
        esac
        tor_started=0
        sleepstopme 3
    done

    #
    # Tor just started right now, log this, get pid
    #
    tor_pid=$(eval ${ts5b_check_tor_cmd})
    case "${tor_started}" in "0")
        logme "Tor started, PID=${tor_pid}."
        tor_started=1
        ;;
    esac

    #
    # Check if running Tor has valid configuration
    #
    get_option_value "${ts5b_tor_cfg_file}" "Socks5Proxy"
    ts5b_socks5proxy="${result_value}"
    check_ipv4_or_domain "${result_value}"
    ts5b_socks5proxy_addr="${result_ipaddr}"
    case "${ts5b_socks5proxy_addr}" in
    "${localhost_address}")
        ts5b_socks5proxy_port=${result_port}
        case "${ts5b_socks5proxy_port}" in
        "")
            logme "Tor is configured to use local SOCKS5 proxy on an invalid port."
            ;;
        *)
            #
            # Let's make some SOCKS5 magic
            #
            logme "Tor is configured to use local SOCKS5 on port ${ts5b_socks5proxy_port}."
            sshsocks_start norestart
            socks_getlist nocheckages
            socksbal_start
            tor_pid=$(eval ${ts5b_check_tor_cmd})
            ;;
        esac
        ;;
    *)
        socksbal_stop
        stop_childs
#        sshsocks_stop
        case "${ts5b_socks5proxy_addr}" in
        "")
            logme "Tor is not configured to use SOCKS5 proxy.";;
        *)
            logme "Tor is configured to use remote ${ts5b_socks5proxy_addr} SOCKS5 proxy.";;
        esac
        logme "Please specify local \"${localhost_address}\" SOCKS5 proxy."
        ;;
    esac

    update_sysuptime_ms
    sys_uptime_checkupdates_sec=$((sys_uptime_ms / 1000 + checkupdates_interval_sec))
    checkupdates_interval_sec=1200

    #
    # Wait while Tor is running
    #
    while /etc/init.d/tor running; do
        tor_name=
        read -r tor_name 2>/dev/null </proc/${tor_pid}/comm
        case "${tor_name}" in "tor");; *)
            tor_new_pid=$(eval ${ts5b_check_tor_cmd})
            case "${tor_pid}" in "${tor_new_pid}"|"");; *)
                logme "Tor restarted, old PID=${tor_pid}, new PID=${tor_new_pid}."
                break
                ;;
            esac
            ;;
        esac
        sleepstopme 5
        update_sysuptime_ms
        sys_uptime_sec=$((sys_uptime_ms / 1000))
        case "$((sys_uptime_checkupdates_sec - sys_uptime_sec))" in "-"*|"0")
            if ! sockslist_checkvalid oksilent; then
                socks_scanlist "${ts5b_chklst_file_save}" ${ts5b_checked_proxies_min}
                count_file_lines "${ts5b_chklst_file}" "checkedcnt"
                case "$((ts5b_checked_proxies_min / 2 - checkedcnt))" in
                "-"*)
                    logme "Using ${checkedcnt} previously checked responsive SOCKS5 proxies."
                    socks_updatelist
                    using_old_socks_list=$?
                    ;;
                *)
                    if ! socks_getlist oksilent; then
                        logme "SOCKS5 list was updated."
                        using_old_socks_list=1
                    fi
                    ;;
                esac
            fi
            sys_uptime_checkupdates_sec=$((sys_uptime_ms / 1000 + checkupdates_interval_sec))
            ;;
        esac

        case "${ts5b_socks5proxy_addr}" in "${localhost_address}")
            case ${using_old_socks_list} in 1)
#                inet_waitconnection
                read -r connstat0 2>/dev/null <"${conn_stat_file}"
                case "${connstat0}" in "2");; *)
                    socksbal_start
                    /etc/init.d/tor restart
                    using_old_socks_list=0
                    ;;
                esac
                ;;
            esac
            ;;
        esac

    done

done


exitme 1
