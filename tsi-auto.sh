#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


tsi_update_only=0
tsi_retrycnt=999
tsi_sleep_sec=3

tsi_script_path="$(readlink -f "${0}")"
tsi_current_path="$(dirname "${tsi_script_path}")"
tsi_etc_srctree_path="${tsi_current_path}/../../../root/etc"
tsi_etc_path="$(ls "${tsi_etc_srctree_path}" >/dev/null 2>&1 && readlink -f "${tsi_etc_srctree_path}" || readlink -f "${tsi_current_path}/../../etc")"
tsi_action="$(ls "${tsi_etc_srctree_path}" >/dev/null 2>&1 && echo "updateonly" || echo "${1:-start}")"
tsi_dns="dnsmasq"
tsi_pidfile="/var/run/tsi-auto.pid"
tsi_tsx_path="$(ls "${tsi_etc_path}/tsx" >/dev/null 2>&1 && readlink -f "${tsi_etc_path}/tsx" || readlink -f "${_THIS_DIR_}")"
tsi_namesetfile_static="${tsi_tsx_path}/tsi-manual-names.lst"
tsi_netsetfile_static="${tsi_tsx_path}/tsi-manual-ips.lst"
tsi_dnscfgfile_temp="/tmp/${tsi_dns}-tmp.conf"
tsi_dnscfgfile="${tsi_etc_path}/${tsi_dns}.conf"
tsi_netsetfile="${tsi_tsx_path}/tsi-auto-ips.lst"
tsi_namesetfile="${tsi_tsx_path}/tsi-auto-names.lst"
tsi_dnsfile_minsize=256
tsi_netsetname=tsi_nets
tsi_logme_silence=0
tsi_lists_ages_sec=86400 # 1 day
#tsi_download="curl -s -L -m 30 --keepalive-time 5"
#tsi_download="wget T 30 -qO-"
exec 3>&1


exitme()
{
    exec 3>&-
    final ${1}
}

logme()
{
    case ${tsi_logme_silence} in 0)
        case ${tsi_update_only} in 0)
            case "${tsi_tsx_path}" in "${_THIS_DIR_}");; *)
                logger -s -t tsi-auto "${@}" >/dev/null 2>&1
                return 0
                ;;
            esac
            ;;
        esac
        echo "${@}" >&3
        ;;
    esac
}

tsi_check_ipset()
{
    case ${tsi_update_only} in 0);; *)
        return 1;;
    esac

    now_sec=$(date +%s)
    file_tocheck="${1}"
    if [ -s "${file_tocheck}" ]; then
        file_sec=$(date -r "${file_tocheck}" +%s)
        case "$((now_sec - file_sec - tsi_lists_ages_sec))" in
        "-"*|"0")
            logme "Found file ${file_tocheck} that is up-to-date."
            while IFS= read -r cidrline; do
                check_ipv4_or_domain "${cidrline%%#*}"
                case $? in 0|1)
                    logme "File ${file_tocheck} contains valid information."
                    return 0
                    ;;
                esac
            done <"${file_tocheck}" >/dev/null 2>&1
            logme "File ${file_tocheck} does not contain valid information."
            ;;
        *)
            logme "Found file ${file_tocheck} but it is too old."
            ;;
        esac
    fi

    return 1
}

tsi_config_set()
{
    nftset_name="${1}"
    nftset_prefix="nftset="
    nftset_suffix="4#inet#fw4#${nftset_name}"
    domains_count=${2}
    input_source="${3}"

    case ${tsi_update_only} in 0)
        nft add set "inet" "fw4" "${nftset_name}" \
            "{type ipv4_addr; flags interval,timeout; auto-merge; timeout 1h;}"
        ;;
    esac
    sed -i -E "/^[[:space:]]*${nftset_prefix}\/.*\/${nftset_suffix}[[:space:]]*$/d" "${tsi_dnscfgfile_temp}"

    if type awk >/dev/null 2>&1 && awk 'BEGIN{exit 0}' 2>/dev/null; then
        # Use godless awk, but much faster
        count_file="$(mktemp)"
        awk -v count="${domains_count}" -v name="${nftset_name}" -v countfile="${count_file}" '
            function is_valid_domain(s) {
                return s ~ /^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$/
            }
            {
                gsub(/#.*/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                if (length($0) == 0) next
                if (is_valid_domain($0)) {
                    domains[++n] = $0
                }
            }
            END {
                for (i = 1; i <= n; i += count) {
                    printf "nftset="
                    for (j = 0; j < count && (i + j) <= n; j++) {
                        printf "/" domains[i + j]
                    }
                    printf "/4#inet#fw4#%s\n", name
                }
                print n > countfile
                close(countfile)
            }
        ' "${input_source}" >>"${tsi_dnscfgfile_temp}"
        # Get counter
        if [ -s "${count_file}" ]; then
            read domains_total <"${count_file}"
        fi
        rm -f "${count_file}"
    else
        # Fallback to god-pleasing pure shell
        domains_cnr=0
        domains_total=0
        domains_contents=
        while IFS= read -r domainline; do
            if check_ipv4_or_domain "${domainline%%#*}" 1; then
                case ${domains_cnr} in
                0)
                    domains_cnr=${domains_count}
                    domains_contents="${domains_contents}nftset=/${result_domain}"
                    ;;
                *)
                    domains_contents="${domains_contents}/${result_domain}"
                    ;;
                esac
                domains_cnr=$((domains_cnr - 1))
                domains_total=$((domains_total + 1))
                case ${domains_cnr} in 0)
#                    domains_contents="${domains_contents}/4#inet#fw4#${nftset_name}\n";;
                    printf "${domains_contents}/4#inet#fw4#${nftset_name}\n"
                    domains_contents=
                    ;;
                esac
            fi
        done <"${input_source}"
        case ${domains_cnr} in 0);; *)
            case ${domains_total} in 0);; *)
                domains_contents="${domains_contents}/4#inet#fw4#${nftset_name}\n"
            esac
        esac
        printf "${domains_contents}" >>"${tsi_dnscfgfile_temp}"
    fi
}

tsi_load()
{
    return_code=1

    case ${tsi_update_only} in 0)
        logme "Pidding..."
        if [ ! -f "${tsi_pidfile}" -o ! -s "${tsi_pidfile}" ]; then
            printf "%s" "${$}" >"${tsi_pidfile}"
        fi
        read_file "${tsi_pidfile}" "resultpid"

        logme "Working: pidfile=${tsi_pidfile} (pid=${resultpid})."

        case "${tsi_tsx_path}" in "${_THIS_DIR_}");; *)
            logme "Trying to use existing list."

            set_led on sub

            if tsi_check_ipset "${tsi_netsetfile}"; then
                logme "Using previously generated list."
                return_code=0
            fi
            ;;
        esac
        ;;
    esac

    tsi_netsetfile_temp="$(mktemp)"
    tsi_namesetfile_temp="$(mktemp)"
    iplinescnt=0
    namelinescnt=0
    totallinescnt=0
    case ${return_code} in 0);; *)
        logme "Trying to update list from external sources."

        update_sysuptime_ms
        t0=${sys_uptime_ms}
        : >"${tsi_netsetfile}"

        totalcnr=0
        while :; do
            case "$((tsi_retrycnt - totalcnr))" in "-"*|"0") break;; esac
            for downdata in \
                "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/refs/heads/main/domains_all.lst+ipsum.lst" \
                "https://antifilter.download/list/ipresolve.lst+subnet.lst+https://community.antifilter.download/list/domains.lst" \
                "https://antifilter.network/download/ipsmart.lst+subnet.lst+https://community.antifilter.download/list/domains.lst" \
                "https://antifilter.download/list/allyouneed.lst+https://community.antifilter.download/list/domains.lst" \
                "https://antifilter.download/list/ipresolve.lst+subnet.lst" \
                "https://antifilter.network/download/ipsmart.lst+subnet.lst" \
                "https://antifilter.download/list/allyouneed.lst"; \
            do
                downfileurls=$(echo ${downdata} |tr "+" "\n")
                downurl=
                downfiles=
                for downfileurl in ${downfileurls}; do
                    case "${downfileurl%/*}" in
                    "${downfileurl}")
                        downfile="${downfileurl}"
                        ;;
                    *)
                        downurl="${downfileurl%/*}"
                        downfile="${downfileurl##*/}"
                        ;;
                    esac
                    case "${downfiles}" in
                    "")
                        downfiles="${downfile}"
                        ;;
                    *)
                        downfiles="${downfiles}+${downfile}"
                        ;;
                    esac
                    logme "Downloading ${downurl}/${downfile}."
                    retrycnr=0
                    while :; do
                        case $((4 - retrycnr)) in "-"*|0) break 2;; esac
                        inet_waitconnection
                        set_led on sub
#                        ${tsi_download} "${downurl}/${downfile}" |while IFS= read -r cidrline; do
                        get_content "${downurl}/${downfile}" |while IFS= read -r cidrline; do
                            if check_ipv4_or_domain "${cidrline%%#*}"; then
                                echo "${result_ipaddr}" >>"${tsi_netsetfile_temp}"
                            else
                                case "${result_domain}" in "");; *)
                                    echo "${result_domain}" >>"${tsi_namesetfile_temp}";;
                                esac
                            fi
                        done
                        iplinescnt=$(sort -u "${tsi_netsetfile_temp}" |wc -l)
                        namelinescnt=$(sort -u "${tsi_namesetfile_temp}" |wc -l)
                        totallinescnt=$((iplinescnt + namelinescnt))
                        set_led off sub
                        case "$((0 - totallinescnt))" in "-"*)
                            logme "File ${downfile} downloaded OK."
                            break
                            ;;
                        esac
                        retrycnr=$((retrycnr + 1))

                        logme "Will keep trying after a short pause."
                        sleepme ${tsi_sleep_sec}
                    done
                done

                case "$((0 - totallinescnt))" in "-"*)
                    update_sysuptime_ms
                    t=$((sys_uptime_ms - t0))
                    ms_to_S ${t}
                    logme "Automatic list containing ${totallinescnt} IPs/subnets/domains downloaded OK in ${result_S} sec(s) from file(s): ${downfiles}."
                    return_code=0
                    break 2
                    ;;
                esac
            done
            totalcnr=$((totalcnr + 1))
        done
        ;;
    esac

    case ${return_code} in 0);; *)
        logme "Failed getting automatic lists. Using backups.";;
    esac

    case "${tsi_tsx_path}" in "${_THIS_DIR_}")
        sort -u "${tsi_netsetfile_temp}" >"${tsi_netsetfile}"
        sort -u "${tsi_namesetfile_temp}" >"${tsi_namesetfile}"
        rm -f "${tsi_netsetfile_temp}" 2>/dev/null
        rm -f "${tsi_namesetfile_temp}" 2>/dev/null
        logme "Environment is unknown, downloaded IPs/subnets/domains was only saved to "${tsi_netsetfile}" and "${tsi_namesetfile}", exiting."
        return ${return_code}
        ;;
    esac

    # Generate names set file and save it if already saved is different
    cp -f "${tsi_dnscfgfile}" "${tsi_dnscfgfile_temp}" >/dev/null 2>&1
    tsi_config_set "tsi_manual" 7 "${tsi_namesetfile_static}"
    case ${domains_total} in 0);; *)
        logme "Total ${domains_total} manually specified domain(s) processed.";;
    esac
    case ${namelinescnt} in 0);; *)
        tsi_tmpnamesetfile_sorted="$(mktemp)"
        sort -u "${tsi_namesetfile_temp}" >"${tsi_tmpnamesetfile_sorted}"
        tsi_config_set "tsi_auto" 11 "${tsi_tmpnamesetfile_sorted}"
        case ${domains_total} in 0);; *)
            logme "Total ${domains_total} auto downloaded domain(s) processed.";;
        esac
        rm -f "${tsi_tmpnamesetfile_sorted}" >/dev/null 2>&1
        ;;
    esac
    rm -f "${tsi_namesetfile_temp}" >/dev/null 2>&1
    tsi_dnscfgfile_changed=0
    if ! cat "${tsi_dnscfgfile_temp}" 2>/dev/null |diff -b -B "${tsi_dnscfgfile}" - >/dev/null; then
        cp -f "${tsi_dnscfgfile_temp}" "${tsi_dnscfgfile}" >/dev/null 2>&1
        tsi_dnscfgfile_changed=1
    fi
    rm -f "${tsi_dnscfgfile_temp}" >/dev/null 2>&1
    if [ -s "${tsi_dnscfgfile}" -a ${tsi_dnscfgfile_changed} -ne 0 -a ${tsi_update_only} -eq 0 ]; then
        /etc/init.d/${tsi_dns} reload >/dev/null 2>&1
    fi

    # Generate IPs/subnets set file and save it if already saved is different
    tsi_setfile_changed=0
    if ! cat "${tsi_netsetfile_temp}" 2>/dev/null |diff -b -B "${tsi_netsetfile}" - >/dev/null; then
        cp -f "${tsi_netsetfile_temp}" "${tsi_netsetfile}" >/dev/null 2>&1
        tsi_setfile_changed=1
    fi
    rm -f "${tsi_netsetfile_temp}" >/dev/null 2>&1
    if [ -s "${tsi_netsetfile}" -a ${tsi_setfile_changed} -ne 0 -a ${tsi_update_only} -eq 0 ]; then
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi

    set_led off sub

    return ${return_code}
}

tsi_stop()
{
    if [ -f "${tsi_pidfile}" -a -s "${tsi_pidfile}" ]; then
        read_file "${tsi_pidfile}" "pid_to_stop"
        case "${pid_to_stop}" in "$$");; *)
            logme "Trying to kill already working instance."
#            child_pids="$(cat /proc/${pid_to_stop}/children 2>/dev/null)"
            child_pids=""
            for proc_dir in /proc/[0-9]*; do
                pid="${proc_dir##*/}"
                read -r _ _ _ ppid _ 2>/dev/null <"/proc/${pid}/stat" && \
                    case "${ppid}" in "${pid_to_stop}") child_pids="${child_pids} ${pid}";; esac
            done
            kill ${child_pids} ${pid_to_stop} >/dev/null 2>&1
            : >"${tsi_pidfile}"
            logme "Stopped."
            ;;
        esac
    fi

    set_led off sub
}

tsi_check_started()
{
    if pgrep "${0}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}


case "${tsi_action}" in
"stop")
    logme "Stopping tsi-auto."
    tsi_stop
    ;;
"start"|"reload"|"restart")
    tsi_stop
    logme "Starting tsi-auto."
    tsi_load
    logme "Work completed."
    ;;
"updateonly"|"getonly"|"checkonly")
    if tsi_check_started; then
        logme "Another instance of tsi-auto is already running."
    else
        tsi_update_only=1
        tsi_load
        logme "Work completed."
    fi
    ;;
esac

set_led off sub


exitme 0
