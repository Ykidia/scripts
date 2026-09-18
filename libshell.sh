#!/bin/sh

LC_ALL=C
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

re_ip4s='([0-1]([0-9][0-9]?)?|2([0-4][0-9]?|5[0-5]?|[6-9])?|[3-9][0-9]?)'
re_ip4address='('"${re_ip4s}"'\.){3,3}'"${re_ip4s}"
re_ip4nopub='(^0\.0\.0\.0)|(^127\.)|(^10\.)|(^192\.168\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)'
re_ip4subnet='([0-2][0-9]?|3[0-2]?|[3-9])'
re_ip6s='[0-9a-fA-F]{1,4}'
re_ip6address='(('"$re_ip6s"':){7,7}'"$re_ip6s"'|('"$re_ip6s"':){1,7}:|('"$re_ip6s"':){1,6}:'"$re_ip6s"'|('"$re_ip6s"':){1,5}(:'"$re_ip6s"'){1,2}|('"$re_ip6s"':){1,4}(:'"$re_ip6s"'){1,3}|('"$re_ip6s"':){1,3}(:'"$re_ip6s"'){1,4}|('"$re_ip6s"':){1,2}(:'"$re_ip6s"'){1,5}|'"$re_ip6s"':((:'"$re_ip6s"'){1,6})|:((:'"$re_ip6s"'){1,7}|:)|fe80:(:'"$re_ip6s"'){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}'"$re_ip4address"'|('"$re_ip6s"':){1,4}:'"$re_ip4address"')'
re_ipport='([0-5]([0-9]([0-9]([0-9][0-9]?)?)?)?|6([0-4]([0-9]([0-9][0-9]?)?)?|5([0-4]([0-9][0-9]?)?|5([0-2][0-9]?|3[0-5]?|[4-9])?|[6-9][0-9]?)?|[6-9]([0-9][0-9]?)?)?|[7-9]([0-9]([0-9][0-9]?)?)?)'
re_domain='([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}'

byte_hexvalues_lowcase="\
00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f \
20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f 30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f \
40 41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50 51 52 53 54 55 56 57 58 59 5a 5b 5c 5d 5e 5f \
60 61 62 63 64 65 66 67 68 69 6a 6b 6c 6d 6e 6f 70 71 72 73 74 75 76 77 78 79 7a 7b 7c 7d 7e 7f \
80 81 82 83 84 85 86 87 88 89 8a 8b 8c 8d 8e 8f 90 91 92 93 94 95 96 97 98 99 9a 9b 9c 9d 9e 9f \
a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 aa ab ac ad ae af b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 ba bb bc bd be bf \
c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 ca cb cc cd ce cf d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 da db dc dd de df \
e0 e1 e2 e3 e4 e5 e6 e7 e8 e9 ea eb ec ed ee ef f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff"
byte_hexvalues_upcase="\
00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F \
20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F \
40 41 42 43 44 45 46 47 48 49 4A 4B 4C 4D 4E 4F 50 51 52 53 54 55 56 57 58 59 5A 5B 5C 5D 5E 5F \
60 61 62 63 64 65 66 67 68 69 6A 6B 6C 6D 6E 6F 70 71 72 73 74 75 76 77 78 79 7A 7B 7C 7D 7E 7F \
80 81 82 83 84 85 86 87 88 89 8A 8B 8C 8D 8E 8F 90 91 92 93 94 95 96 97 98 99 9A 9B 9C 9D 9E 9F \
A0 A1 A2 A3 A4 A5 A6 A7 A8 A9 AA AB AC AD AE AF B0 B1 B2 B3 B4 B5 B6 B7 B8 B9 BA BB BC BD BE BF \
C0 C1 C2 C3 C4 C5 C6 C7 C8 C9 CA CB CC CD CE CF D0 D1 D2 D3 D4 D5 D6 D7 D8 D9 DA DB DC DD DE DF \
E0 E1 E2 E3 E4 E5 E6 E7 E8 E9 EA EB EC ED EE EF F0 F1 F2 F3 F4 F5 F6 F7 F8 F9 FA FB FC FD FE FF"

localhost_address=$(resolveip -4 localhost 2>/dev/null ||ip addr show dev lo |grep -Eo "${re_ip4address}")
any_address="0.0.0.0"

conn_stat_file="/var/tmp/connstat"
current_connstat=
checkinetaddrs="ipecho.net/plain icanhazip.com checkip.amazonaws.com wtfismyip.com/text api.ipify.org www.myexternalip.com/raw checkip.dyndns.com ipinfo.io/ip api.seeip.org my.ip.fi"
checkinetaddrs_queries=2
noinet_logged=0
checkinet_maxtime_sec=3
sys_uptime_ms=0

child_pids_list=
current_user="$(id -u -n)"
current_user_params="$(grep -F 'root:' /etc/passwd)"
current_user_params_noshell="${current_user_params%:*}"
current_user_home="${current_user_params_noshell##*:}"
case "${current_user_home}" in "") current_user_home="$(readlink -f ~)";; esac


stop_childs()
{
    case "${child_pids_list}" in "") return;; esac

    kill ${child_pids_list} 2>/dev/null
    wait ${child_pids_list} 2>/dev/null
    child_pids_list=
}

final()
{
    stop_childs
    exit ${1}
}

logme_def()
{
    if type logme >/dev/null 2>&1; then
        logme "${@}"
    else
        echo "${@}"
    fi
}

# ${1} = on(1)/off(0), ${2} = led index, -1: system (usually always on in loaded OpenWrt),
#  0: main indicator (also selected if blank), 1: sub indicator
set_led()
{
    l_sl_state=${1}
    l_sl_led=${2:-0}
    l_sl_ledfile=""
    case "${l_sl_led}" in
    "system"|"sys"|-1)
        case "${led_system_path}" in "");; *) l_sl_ledfile="${led_system_path}/brightness";; esac
        ;;
    "main"|0)
        case "${led_main_path}" in "");; *) l_sl_ledfile="${led_main_path}/brightness";; esac
        ;;
    "sub"|1)
        case "${led_sub_path}" in "");; *) l_sl_ledfile="${led_sub_path}/brightness";; esac
        ;;
    esac
    case "${l_sl_ledfile}" in "") return;; esac

    case "${l_sl_state}" in
    "off"|0)
        echo 0 >"${l_sl_ledfile}";;
    *)
        echo 1 >"${l_sl_ledfile}";;
    esac
}

# ${1} = file, ${2} = result variable name
read_file()
{
    [ -f "${1}" ] || return 1
    read ${2} 2>/dev/null <"${1}" || :
}

# ${1} = file, ${2} = result variable name
count_file_lines()
{
    case "${2}" in
    "")
        wc -l 2>/dev/null <"${1}" || echo 0;;
    *)
        export "${2}=$(wc -l 2>/dev/null <"${1}" || echo 0)";;
    esac
}

add_pids_to_list()
{
#    remove_pids_from_list "$@"
    child_pids_list="${child_pids_list} $@"
}

remove_pids_from_list()
{
    case $# in 0) return 0;; esac
    l_rp_del_pids="$@"
    l_rp_del_pids=${l_rp_del_pids%"${l_rp_del_pids##*[![:space:]]}"}
    l_rp_new_list=

#    set -- ${child_pids_list}
#    while case $# in 0) false;; *) true;; esac; do
#        l_rp_pid=$1
#        shift
    for l_rp_pid in ${child_pids_list}; do
        l_rp_keep=1
        for l_rp_del in $l_rp_del_pids; do
            case $l_rp_pid in ""|*[!0-9]*|"$l_rp_del") l_rp_keep=0; break;; esac
        done

        case $l_rp_keep in 1) l_rp_new_list="$l_rp_new_list $l_rp_pid";; esac
    done

    child_pids_list=${l_rp_new_list%"${l_rp_new_list##*[![:space:]]}"}
}

cleanup_pids()
{
    l_cp_zpids=
    l_cp_nopids=
#    set -- ${child_pids_list}
#    while case $# in 0) break;; esac; do
#        l_cp_pid=${1}
#        shift
    for l_cp_pid in ${child_pids_list}; do
        if ! IFS=" " read -r _ _ l_cp_stat _ 2>/dev/null <"/proc/${l_cp_pid}/stat"; then
            l_cp_nopids="${l_cp_nopids} ${l_cp_pid}"
            continue
        fi
        case "${l_cp_stat}" in "Z") l_cp_zpids="${l_cp_zpids} ${l_cp_pid}";; esac
    done
    remove_pids_from_list "${l_cp_nopids}"
    case "${l_cp_zpids}" in "") return;; esac
    wait ${l_cp_zpids}
    remove_pids_from_list "${l_cp_zpids}"
}

check_pids_running()
{
    while case $# in 0) break;; esac; do
        l_cpr_stat=
        if IFS=" " read -r _ _ l_cpr_stat _ 2>/dev/null <"/proc/${1}/stat"; then
            case "${l_cpr_stat}" in "Z");; *) return 0;; esac
        fi
        shift
    done

    return 1
}

stop_pids_after_timeout() # $1 = timeout in sec, $2 $3 $4 etc = pids
{
    case $(($# - 1)) in "-"*|0) return;; esac
    S_to_ms ${1}
    shift
    l_spat_ms=${result_ms}
    update_sysuptime_ms
    l_spat_t0=${sys_uptime_ms}
    while check_pids_running $@; do
        sleepme 1
        update_sysuptime_ms
        case $((l_spat_t0 - sys_uptime_ms + l_spat_ms)) in "-"*)
            kill $@ 2>/dev/null
            wait $@ 2>/dev/null
            break
            ;;
        esac
    done
}

update_sysuptime_ms()
{
    l_usm_s=
    l_usm_ss=
    IFS=" ." read l_usm_s l_usm_ss _ </proc/uptime
    l_usm_ss=${l_usm_ss#${l_usm_ss%%[!0]*}}
    sys_uptime_ms=$((l_usm_s * 1000 + ${l_usm_ss:-0} * 10))
    case ${cleanup_timer_ms} in
    "")
        cleanup_timer_ms=${sys_uptime_ms}
        ;;
    *)
        case $((cleanup_timer_ms - sys_uptime_ms + 20000)) in "-"*)
            cleanup_timer_ms=${sys_uptime_ms}
            cleanup_pids
            ;;
        esac
        ;;
    esac
}

math_pow()
{
    l_mp_cnr=${2}
    l_mp_exp=1
    while case "${l_mp_cnr}" in "0") break;; *) l_mp_cnr=$((l_mp_cnr - 1));; esac; do
        l_mp_exp=$((l_mp_exp * ${1}))
    done
    case "${3}" in
    "")
        echo "${l_mp_exp}";;
    *)
        export "${3}=${l_mp_exp}";;
    esac
}

norm_dec() # $1 = value to normalize, $2 = result variable name, echo if blank
{
    l_nd_val="${1#${1%%[!0]*}}"
    l_nd_val="${l_nd_val:-0}"
    case "${2}" in
    "")
        echo "${l_nd_val}";;
    *)
        export "${2}=${l_nd_val}";;
    esac
}

rand_u16()
{
    if command -v hexdump >/dev/null 2>&1; then
        dd if=/dev/urandom bs=2 count=1 2>/dev/null |hexdump -n2 -e '/2 "%u\n"'
    else
        l_ru16_data=$(dd if=/dev/urandom bs=2 count=1 2>/dev/null)
        l_ru16_b1=$(printf "%d" "'${l_ru16_data%?}")
        l_ru16_b2=$(printf "%d" "'${l_ru16_data#?}")
        echo $((l_ru16_b1 + l_ru16_b2 * 256))
    fi
}

S_to_ms()
{
    l_s2m_arg="${1}"
    l_s2m_arg_s="${l_s2m_arg%%.*}"
    l_s2m_arg_fp="${l_s2m_arg##${l_s2m_arg_s}}"
    norm_dec "${l_s2m_arg_fp##*.}" "l_s2m_arg_ds"
    l_s2m_arg_sds="${#l_s2m_arg_ds}"
    math_pow 10 $((3-l_s2m_arg_sds)) "l_s2m_arg_sds"
    result_ms=$((${l_s2m_arg_s:-0}*1000 + ${l_s2m_arg_ds:-0}*(l_s2m_arg_sds)))
}

ms_to_S()
{
    l_m2s_arg="${1}"
    l_m2s_arg=${l_m2s_arg#${l_m2s_arg%%[!0]*}}
    l_m2s_arg=${l_m2s_arg:-0}
    l_m2s_arg_rem="$((l_m2s_arg % 1000))"
    l_m2s_arg_fp="000${l_m2s_arg_rem}"
    l_m2s_arg_fp="${l_m2s_arg_fp#"${l_m2s_arg_fp%???}"}"
    l_m2s_arg_fp="${l_m2s_arg_fp%"${l_m2s_arg_fp##*[!0]}"}"
    result_S=$(((l_m2s_arg - l_m2s_arg_rem) / 1000))${l_m2s_arg_fp:+.}${l_m2s_arg_fp}
}

sleepme()
{
    update_sysuptime_ms
    sleepme_t0_ms=${sys_uptime_ms}
    S_to_ms ${1}
    sleepme_ms=${result_ms}
    case ${sleep_method} in 0)
        read -t ${1} >/dev/null 2>&1 </dev/ptmx;;
    esac
    update_sysuptime_ms
    sleepme_le_ms=$((sleepme_ms - (sys_uptime_ms - sleepme_t0_ms)))
    case "${sleepme_le_ms}" in "-"*|"0");; *)
        ms_to_S ${sleepme_le_ms}
        sleep ${result_S} &
        wait $!
        ;;
    esac
}

dec_to_hex_uc() # $1 = decimal value, $2 = number of hex digits
{
    l_d2h_dec=${1}
    l_d2h_len=${2}
    case "${l_d2h_len}" in "") l_d2h_len=8;; esac

    result_hex=""
    while case $((l_d2h_len - ${#result_hex} - 2)) in "-"*|0) break;; esac; do
        l_d2h_oct=$(((l_d2h_dec & 255) + 1))
        l_d2h_dec=$((l_d2h_dec >> 8))
        set -- ${byte_hexvalues_upcase}
        eval "l_d2h_octh=\${$l_d2h_oct}"
        result_hex="${l_d2h_octh}${result_hex}"
    done
    while case ${#result_hex} in ${l_d2h_len}) break;; esac; do
        l_d2h_dig=$((l_d2h_dec & 15))
        l_d2h_dec=$((l_d2h_dec >> 4))
        case ${l_d2h_dig} in
        10) l_d2h_dig="A";; 11) l_d2h_dig="B";; 12) l_d2h_dig="C";;
        13) l_d2h_dig="D";; 14) l_d2h_dig="E";; 15) l_d2h_dig="F";;
        esac
        result_hex="${l_d2h_dig}${result_hex}"
    done
}

check_file_notblank()
{
    read -r _ 2>/dev/null <"${1}" && return 0
    return 1
}

check_ipv4_or_domain()
{
    result_ipaddr=
    result_domain=
    result_port=
    result_subnet=
    result_iptype=
    case ${2} in
    ""|0)
        _retcode_ipaddr=0; _retcode_domain=1;;
    *)
        _retcode_ipaddr=${2}; _retcode_domain=0;;
    esac

    _line="${1%%#*}"
    _line="${_line#"${_line%%[![:space:]]*}"}" # remove leading spaces
    _line="${_line%%[[:space:]]*}" # remove something after the first space
    _line="${_line%"${_line##*[![:space:]]}"}" # remove trailing spaces
    case "${_line}" in "") return 2;; esac

    _port=
    case "${_line}" in *:*)
        _port="${_line#*:}" # till first ":" from beginning
        _port="${_port%%[!0-9]*}"
        _port_valid=1
        case "${_port}" in ""|0) _port_valid=0;; *)
            norm_dec "${_port}" "_port"
            case $((65535 - _port)) in "-"*) _port_valid=0=;; esac
            ;;
        esac
        _line="${_line%%:*}"
        case ${_port_valid} in 0) _port=;; esac
        ;;
    esac
    _mask=
    case "${_line}" in */*)
        _mask="${_line##*/}" # till last "/" from beginning
        _mask="${_mask%%[!0-9]*}"
        _mask_valid=1
        case "${_mask}" in "") _mask_valid=0;; *)
            norm_dec "${_mask}" "_mask"
            case $((32 - _mask)) in "-"*) _mask_valid=0=;; esac
            ;;
        esac
        _line="${_line%/*}"
        case ${_mask_valid} in 0) _mask=; _port=;; esac # mask is invalid, therefore port is also invalid if any
        ;;
    esac

    _oct1=
    _oct2=
    _dots=0
    _rest="${_line}"
    while :; do
        _part="${_rest%%.*}"
        # check: only digits, not blank, no leading zeroes (except "0"), 0-255
        case "${_part}" in ""|*[!0-9]*|?*[!0-9]*) _dots=0; break;; esac
#        case "${_part}" in "${_part#0}"|"0");; *) _dots=0; break;; esac
        norm_dec "${_part}" "_part"
        case "$((255 - _part))" in "-"*) _dots=0; break;; esac
        case "${_oct1}" in
        "")
            _oct1=${_part}
            result_ipaddr=${_part}
            ;;
        *)
            case "${_oct2}" in "") _oct2=${_part};; esac
            result_ipaddr="${result_ipaddr}.${_part}"
            ;;
        esac
        case "${_rest}" in *.*) _rest="${_rest#*.}";; *) break;; esac
        _dots=$((_dots + 1))
    done

    result_port=${_port}
    case ${_dots} in 3)
#        result_ipaddr="${_line}"
        result_subnet="${_mask}"
        result_iptype=0 # public by default
        case ${_oct1} in
        127)
            result_iptype=2;; # localhost
        10)
            result_iptype=1;; # private
        172)
            case ${_oct2} in [1-9]|1[0-9]|2[0-9]|3[0-1]) result_iptype=1;; esac;;
        192)
            case ${_oct2} in 168) result_iptype=1;; esac;;
        esac
        case "${result_ipaddr}" in "0.0.0.0"|"255.255.255.255")
            result_iptype=3;; # any/invalid
        esac
        return ${_retcode_ipaddr}
        ;;
    esac

    result_ipaddr=
    case "${_mask}" in "");; *) return 2;; esac
    case "${_line}" in ""|.*|-*|*.-|*.-*|*..*|*[!-0-9A-Za-z_.]*) return 2;; esac
    case "${_line}" in *.*) result_domain="${_line}"; return ${_retcode_domain};; esac

    return 2
}

set_connstat()
{
    update_sysuptime_ms
    case ${1} in "");; *)
        current_connstat=${1};;
    esac
    set_retries=0
    while :; do
        if [ -f "${conn_stat_file}.lock" -a ! -e "${conn_stat_file}" ]; then
            sleepme 1
            set_retries=$((set_retries + 1))
            case "$((3 - set_retries))" in "-"*)
                rm -f "${conn_stat_file}.lock"
                break
                ;;
            esac
        else
            break
        fi
    done
    flock "${conn_stat_file}.lock" echo "${current_connstat}
${sys_uptime_ms}" >"${conn_stat_file}"
    sync
}

get_checkinetaddrs()
{
    l_gc_inetaddrscnr=${checkinetaddrs_queries}
    result_checkinetaddrs=
    while :; do
        checkinetaddrs="${checkinetaddrs#"${checkinetaddrs%%[![:space:]]*}"}" # remove leading spaces
        checkinetaddrs="${checkinetaddrs%"${checkinetaddrs##*[![:space:]]}"}" # remove trailing spaces
        l_gc_checkinetaddr="${checkinetaddrs%%[[:space:]]*}"
        result_checkinetaddrs="${result_checkinetaddrs} ${l_gc_checkinetaddr}"
        checkinetaddrs="${checkinetaddrs#"${l_gc_checkinetaddr}"} ${l_gc_checkinetaddr}" # """
        l_gc_inetaddrscnr=$((l_gc_inetaddrscnr - 1))
        case ${l_gc_inetaddrscnr} in 0) break;; esac
    done

    return 0
}

inet_checkexistingstatus()
{
    if read -r _ 2>/dev/null <"${conn_stat_file}"; then
        while :; do
            valcnr=0
            connstat0=
            connstatup=
            while IFS= read -r value; do
                case ${valcnr} in
                0)
                    connstat0=${value};;
                1)
                    connstatup=${value}; break;;
                esac
                valcnr=$((valcnr + 1))
            done <"${conn_stat_file}"
            update_sysuptime_ms
            case "${connstatup}" in "") break;; *)
                case "$((sys_uptime_ms - connstatup))" in "-"*)
                    return 1;; # connection status timestamp is in future - error
                esac
                case "$((connstatup + checkinet_maxtime_sec * 2000 - sys_uptime_ms))" in
                "-"*)
                    return 1 # connection status is outdated - error
                    ;;
                *)
                    case "${connstat0}" in
                    "")
                        break;; # connection status is unknown - error
                    0)
                        continue;; # mo internet - continue waiting for internet is up
                    *)
                        return 0;; # internet is up - ok
                    esac
                    ;;
                esac
                ;;
            esac
        done
    fi
    return 1
}

inet_checkconnection() # $1 = on:off, # $2 = check timeout, $3 = additional options for curl
{
    l_ic_onoff_codes="${1}"
    l_ic_on="${l_ic_onoff_codes%%:*}"
    l_ic_off="${l_ic_onoff_codes#*:}"

    l_ic_timeout_sec=${2}
    l_ic_curl_opts="${3}"

    get_checkinetaddrs
    set -- ${result_checkinetaddrs}
    case $# in 0)
        logme_def "FATAL: no check URLs defined in checkinetaddrs"
        set_connstat ${l_ic_off}
        exit 1
        ;;
    esac

    l_ic_tmp_file="$(mktemp)" || { sleepme 1; return 1; }
    l_ic_pids_list=
    l_ic_timeout_ms=$((l_ic_timeout_sec * 1000))
    update_sysuptime_ms
    l_ic_t0_ms=${sys_uptime_ms}
    l_ic_rc=1 # return code, 1 = no connection

    while :; do
        l_ic_d="${1}"
        case "$l_ic_d" in "");; *)
            shift
            case "$l_ic_d" in
            "http://"*|"https://"*)
                l_ic_url="$l_ic_d";;
            *)
                l_ic_url="http://$l_ic_d";;
            esac
            {
                l_ic_success=0
                if command -v curl >/dev/null 2>&1; then
                    curl -s -f -I $l_ic_curl_opts \
                        --max-time $l_ic_timeout_sec \
                        --connect-timeout $l_ic_timeout_sec \
                        -o /dev/null \
                        -w '%{http_code}' \
                        "$l_ic_url" 2>/dev/null |
                    {
                        IFS= read -r l_ic_code
                        case "$l_ic_code" in [1-9][0-9][0-9])
                            rm -f "$l_ic_tmp_file" 2>/dev/null;;
                        esac
                    }
                elif command -v wget >/dev/null 2>&1; then
                    if wget -q -T "$l_ic_timeout_sec" -O /dev/null "$l_ic_url" 2>/dev/null; then
                        rm -f "$l_ic_tmp_file" 2>/dev/null
                    fi
                elif command -v busybox >/dev/null 2>&1; then
                    if busybox wget -q -T "$l_ic_timeout_sec" -O /dev/null "$l_ic_url" 2>/dev/null; then
                        rm -f "$l_ic_tmp_file" 2>/dev/null
                    fi
                elif command -v uclient-fetch >/dev/null 2>&1; then
                    if uclient-fetch -q -T "$l_ic_timeout_sec" -O /dev/null "$l_ic_url" 2>/dev/null; then
                        rm -f "$l_ic_tmp_file" 2>/dev/null
                    fi
                fi
            } &
            l_ic_new_pid=$!
            add_pids_to_list $l_ic_new_pid
            l_ic_pids_list="$l_ic_pids_list $l_ic_new_pid"
            ;;
        esac

        update_sysuptime_ms # also use this here as soft yield()
        if ! [ -e "$l_ic_tmp_file" ]; then
            l_ic_rc=0 # 0 = connection is up
            break
        fi
        case "$l_ic_d" in "");; *) continue;; esac

        l_ic_elapsed=$((sys_uptime_ms - l_ic_t0_ms))
        case "$((l_ic_elapsed - l_ic_timeout_ms))" in "-"*);; *) break;; esac
        sleepme 0.01
    done

    case "$l_ic_pids_list" in "");; *)
        kill -9 $l_ic_pids_list 2>/dev/null
        ;;
    esac
    rm -f "$l_ic_tmp_file" 2>/dev/null

    case $l_ic_rc in 0) set_connstat $l_ic_on;; *) set_connstat $l_ic_off;; esac
    return $l_ic_rc
}

inet_checkconnection_synced() # $1 = on:off, $2 = check timeout, $3 = additional options for curl
{
    l_iccs_onoff_codes="${1}"
    l_iccs_on="${l_iccs_onoff_codes%%:*}"
    l_iccs_off="${l_iccs_onoff_codes#*:}"

    exec 9>"${conn_stat_file}0.lock" 2>/dev/null || return ${l_iccs_off}
    if flock -n 9; then
        inet_checkconnection "${1}" "${2}" "${3}"
        l_iccs_rc=$?
        exec 9>&-
        rm -f "${conn_stat_file}0.lock" 2>/dev/null
        return ${l_iccs_rc}
    fi

    exec 9>&-
    rm -f "${conn_stat_file}0.lock" 2>/dev/null
    l_iccs_wait_cnr=3
    while :; do
        sleepme 1
        if read_file "${conn_stat_file}" "l_iccs_connstat0" 2>/dev/null; then
            case "${l_iccs_connstat0}" in
            0)
                return ${l_iccs_off};;
            *)
                return ${l_iccs_on};;
            esac
        fi
        l_iccs_wait_cnr=$((l_iccs_wait_cnr - 1))
        case ${l_iccs_wait_cnr} in 0) break;; esac
    done

    return ${l_iccs_off}
}

inet_waitconnection()
{
    case "${1}" in "nocheckstat");; *)
        if inet_checkexistingstatus; then
            return 0
        fi
        ;;
    esac

    while :; do
        if inet_checkconnection_synced "1:0" "${checkinet_maxtime_sec}"; then
            case ${noinet_logged} in 0);; *)
                logme_def "Internet connection seems good."; noinet_logged=0;;
            esac
            return 0
        fi

        case ${noinet_logged} in 0)
            logme_def "Waiting for Internet connection to wake up..."; noinet_logged=1;;
        esac
        sleepme 1
    done
}

port_checklistening() # $1 = port (in dec)
{
    dec_to_hex_uc "${1}" 4
    l_pcl_expr=":${result_hex} 00000000:0000 0A "
    l_pcl_expr6=":${result_hex} 00000000000000000000000000000000:0000 0A "

    for l_pcl_file in /proc/net/tcp /proc/net/tcp6; do
        while IFS= read -r l_pcl_line; do
            case "${l_pcl_line}" in *"${l_pcl_expr}"*|*"${l_pcl_expr6}"*)
                return 0;;
            esac
        done <"${l_pcl_file}" 2>/dev/null
    done

    return 1
}

# ${1} - "user/repo", ${2} - place result in var name or to console if blank
get_github_latest_release_urls_list()
{
    l_glru_result=""
    l_glru_log="/dev/null" ### TODO!!!
    l_glru_url1="https://api.github.com/repos/${1}/releases/latest"
    l_glru_url2tags="https://github.com/${1}/releases.atom"
    l_glru_url2="https://github.com/${1}/releases/expanded_assets"
    l_glru_header="Accept: application/vnd.github+json"
    l_glru_filter="browser_download_url"
    for l_glru_tries in 0 1 2 3; do
        case ${l_glru_tries} in 0);; *)
            echo "Downloadable URLs list is empty, retrying...";;
        esac
        inet_waitconnection
        if command -v curl >/dev/null 2>&1; then
            l_glru_result="$(curl -sS -H "${l_glru_header}" "${l_glru_url1}" 2>>"${l_glru_log}" \
                |grep "${l_glru_filter}" |cut -d"\"" -f4)"
            case "${l_glru_result}" in "");; *) break;; esac
            l_glru_latest="$(curl -sSL "${l_glru_url2tags}" 2>>"${l_glru_log}" \
                |grep "/releases/tag/" |head -n 1 |sed "s|.*/releases/tag/||; s|\".*||")"
            case "${l_glru_latest}" in "");; *)
                l_glru_result="$(curl -sSL "${l_glru_url2}/${l_glru_latest}" 2>>"${l_glru_log}" \
                    |grep "/releases/download/" |grep -o "href=\"[^\"]*\"" |sed "s/href=\"//; s/\"//" |sed "s|^|https://github.com|")"
                case "${l_glru_result}" in "");; *) break;; esac
                ;;
            esac
            l_glru_result="$(curl -k -sS -H "${l_glru_header}" "${l_glru_url1}" 2>>"${l_glru_log}" \
                |grep "${l_glru_filter}" |cut -d"\"" -f4)"
            case "${l_glru_result}" in "");; *) break;; esac
        fi
        if command -v wget >/dev/null 2>&1; then
            l_glru_result="$(wget -nv -O - --header="${l_glru_header}" "${l_glru_url1}" 2>>"${l_glru_log}" \
                |grep "${l_glru_filter}" |cut -d"\"" -f4)"
            case "${l_glru_result}" in "");; *) break;; esac
            l_glru_latest="$(wget -nv -O - "${l_glru_url2tags}" 2>>"${l_glru_log}" \
                |grep "/releases/tag/" |head -n 1 |sed "s|.*/releases/tag/||; s|\".*||")"
            case "${l_glru_latest}" in "");; *)
                l_glru_result="$(wget -nv -O - "${l_glru_url2}/${l_glru_latest}" 2>>"${l_glru_log}" \
                    |grep "/releases/download/" |grep -o "href=\"[^\"]*\"" |sed "s/href=\"//; s/\"//" |sed "s|^|https://github.com|")"
                case "${l_glru_result}" in "");; *) break;; esac
                ;;
            esac
            l_glru_result="$(wget --no-check-certificate -nv -O - --header="${l_glru_header}" "${l_glru_url1}" 2>>"${l_glru_log}" \
                    |grep "${l_glru_filter}" |cut -d"\"" -f4)"
            case "${l_glru_result}" in "");; *) break;; esac
        fi
        if command -v busybox >/dev/null 2>&1; then
            l_glru_result="$(busybox wget -q -O - --header="${l_glru_header}" "${l_glru_url1}" 2>>"${l_glru_log}" \
                |grep "${l_glru_filter}" |cut -d"\"" -f4)"
            case "${l_glru_result}" in "");; *) break;; esac
        fi
        if command -v uclient-fetch >/dev/null 2>&1; then
            l_glru_result="$(uclient-fetch -q -O - --header="${l_glru_header}" "${l_glru_url1}" 2>>"${l_glru_log}" \
                |grep "${l_glru_filter}" |cut -d"\"" -f4)"
            case "${l_glru_result}" in "");; *) break;; esac
        fi
    done

    case "${2}" in
    "")
        echo "${l_glru_result}";;
    *)
        export "${2}=${l_glru_result}";;
    esac

    case "${l_glru_result}" in "") return 1;; *) return 0;; esac
}

# ${1} = url, ${2} = filepath (or blank if output to console), ${3} = timeout (default if empty)
get_content()
{
    l_gc_url="${1}"
    l_gc_fp="${2}"
    l_gc_log="/dev/null" ### TODO!!!
    l_gc_to_sec="${3:-${BL_DOWNLOAD_TIMEOUT:-10}}"
    inet_waitconnection
    if command -v curl >/dev/null 2>&1; then
        case "${l_gc_fp}" in
        "")
            if curl -fSL --connect-timeout ${l_gc_to_sec} -m ${l_gc_to_sec} "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        *)
            if curl -fsSL --connect-timeout ${l_gc_to_sec} -m ${l_gc_to_sec} -o "${l_gc_fp}" "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        esac
    fi
    if command -v wget >/dev/null 2>&1; then
        case "${l_gc_fp}" in
        "")
            if wget -q -T ${l_gc_to_sec} -O - "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        *)
            if wget -q -T ${l_gc_to_sec} -O "${l_gc_fp}" "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        esac
    fi
    if command -v busybox >/dev/null 2>&1; then
        case "${l_gc_fp}" in
        "")
            if busybox wget -q -T ${l_gc_to_sec} -O - "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        *)
            if busybox wget -q -T ${l_gc_to_sec} -O "${l_gc_fp}" "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        esac
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        case "${l_gc_fp}" in
        "")
            if uclient-fetch -q -T "${l_gc_to_sec}" -O - "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        *)
            if uclient-fetch -q -T "${l_gc_to_sec}" -O "${l_gc_fp}" "${l_gc_url}" 2>>"${l_gc_log}"; then
                return 0
            fi
            ;;
        esac
    fi

    return 1
}

get_totalmem_kb()
{
    l_gtk_mem=0
    l_gtk_rc=1
    while IFS= read -r l_gtk_line; do
        case "${l_gtk_line}" in
        "MemTotal:"*)
            l_gtk_val="${l_gtk_line#MemTotal:}"
            l_gtk_val="${l_gtk_val#* }"
            l_gtk_val="${l_gtk_val%% *}"
            l_gtk_mem="${l_gtk_val}"
            l_gtk_rc=0
            break
            ;;
        esac
    done </proc/meminfo

    case "${1}" in
    "")
        echo "${l_gtk_mem}";;
    *)
        export "${1}=${l_gtk_mem}";;
    esac
    return ${l_gtk_rc}
}

get_freemem_kb()
{
    l_gfk_free=
    l_gfk_avail=
    while IFS= read -r l_gfk_line; do
        case "${l_gfk_line}" in
        "MemFree:"*)
            l_gfk_val="${l_gfk_line#MemFree:}"
            l_gfk_val="${l_gfk_val#* }"
            l_gfk_val="${l_gfk_val%% *}"
            norm_dec "${l_gfk_val}" "l_gfk_free"
            case "${l_gfk_avail}" in "");; *) break;; esac
            ;;
        "MemAvailable:"*)
            l_gfk_val="${l_gfk_line#MemAvailable:}"
            l_gfk_val="${l_gfk_val#* }"
            l_gfk_val="${l_gfk_val%% *}"
            norm_dec "${l_gfk_val}" "l_gfk_avail"
            case "${l_gfk_free}" in "");; *) break;; esac
            ;;
        esac
    done </proc/meminfo

    l_gfk_mem=
    l_gfk_rc=0
    case "${l_gfk_free}" in
    "")
        case "${l_gfk_avail}" in
        "")
            get_totalmem_kb "l_gfk_mem"
            l_gfk_mem=$((l_gfk_mem / 16))
            l_gfk_rc=1
            ;;
        *)
            l_gfk_mem=${l_gfk_avail}
            ;;
        esac
        ;;
    *)
        case "${l_gfk_avail}" in
        "")
            l_gfk_mem=${l_gfk_free}
            ;;
        *)
            case $((l_gfk_avail - l_gfk_free)) in
            "-"*)
                l_gfk_mem=${l_gfk_avail};;
            *)
                l_gfk_mem=${l_gfk_free};;
            esac
            ;;
        esac
        ;;
    esac

    case "${1}" in
    "")
        echo "${l_gfk_mem}";;
    *)
        export "${1}=${l_gfk_mem}";;
    esac
    return ${l_gfk_rc}
}

get_option_value()
{
    _optsfile="${1}"
    _optname="${2}"
    _optdelim="${3}"
    result_value=

    while read -r _optline; do
        _optline="${_optline%%#*}" # remove comments
        _optline="${_optline#"${_optline%%[![:space:]]*}"}" # remove leading spaces
        _optline="${_optline%"${_optline##*[![:space:]]}"}" # remove trailing spaces
        _optfoundval="${_optline#"${_optname}"}" ###"""
        case "${_optfoundval}" in "${_optline}") continue;; esac
        _optdelimval="${_optfoundval#"${_optfoundval%%[![:space:]]*}"}" ###"""
        case "${_optdelimval}" in
        "${_optfoundval}")
            case "${_optdelim}" in ""|" ") return 0;; esac # empty value
            ;;
        *)
            case "${_optdelim}" in ""|" ")
                result_value="${_optdelimval}"
                return 0
                ;;
            esac
            ;;
        esac
        _optfoundval="${_optdelimval#"${_optdelim}"}" ###"""
        case "${_optfoundval}" in "${_optdelimval}") continue;; esac
        result_value="${_optfoundval#"${_optfoundval%%[![:space:]]*}"}" ###"""
    done 2>/dev/null <"${_optsfile}"

    return 1
}


get_totalmem_kb "total_memory_kb"
ls /dev/ptmx >/dev/null 2>&1
sleep_method=$?

led_system_path=""
led_main_path=""
led_sub_path=""
os_arch_name="$(grep "DISTRIB_ARCH=" "/rom/etc/openwrt_release" 2>/dev/null |cut -d"'" -f2)"
case "${os_arch_name}" in
"")
    os_arch_name="linux-$(uname -m)"
    os_is_openwrt=0
    ;;
*)
    openwrt_board_name="$({ strings /proc/device-tree/compatibles || cat /tmp/sysinfo/board_name; } 2>/dev/null |head -1)"
    case "${openwrt_board_name}" in
    "xiaomi,mi-router-3-pro"|"xiaomi,mi-router-3-pro")
        led_system_path="/sys/class/leds/blue:status"
        led_main_path="/sys/class/leds/yellow:status"
        led_sub_path="/sys/class/leds/red:status"
        ;;
    "glinet,gl-mt6000")
        led_system_path="/sys/class/leds/white:system"
        led_main_path="/sys/class/leds/blue:run"
        ;;
    esac
    os_is_openwrt=1
esac
