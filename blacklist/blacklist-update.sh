#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


# Atomically update iptables/ip6tables-nft blacklist sets from remote sources
# Designed for cron execution, uses ipset swap for zero-downtime updates
# Supports both IPv4 and IPv6 addresses

# Save stdout to file descriptor 3 for verbose output (ts5b style)
exec 3>&1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Ipset and iptables settings - IPv4
BL4_SETNAME="blacklist"
BL4_TABLE="raw"
BL4_CHAIN="PREROUTING"
BL4_TMPSET="${BL4_SETNAME}_tmp"

# Ipset and ip6tables settings - IPv6
BL6_SETNAME="blacklist6"
BL6_TABLE="raw"
BL6_CHAIN="PREROUTING"
BL6_TMPSET="${BL6_SETNAME}_tmp"

# File paths
BL_TMPFILE="/tmp/blacklist.new"
BL_TMPFILE4="/tmp/blacklist4.new"
BL_TMPFILE6="/tmp/blacklist6.new"
BL_LOCKFILE="/tmp/blacklist.lock"
BL_LOGTAG="blacklist-upd"

# Source URLs
BL_SOURCES='
# FireHOL
https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset
https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/dshield.netset
https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/greensnow.ipset

# Malware/botnets
https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/feodo.ipset
https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/et_compromised.ipset

# CriticalPathSecurity
https://raw.githubusercontent.com/CriticalPathSecurity/Public-Intelligence-Feeds/master/compromised-ips.txt
https://raw.githubusercontent.com/CriticalPathSecurity/Public-Intelligence-Feeds/master/binarydefense.txt
https://raw.githubusercontent.com/CriticalPathSecurity/Public-Intelligence-Feeds/master/alienvault.txt
https://raw.githubusercontent.com/CriticalPathSecurity/Public-Intelligence-Feeds/master/abuse-ch-ipblocklist.txt
https://raw.githubusercontent.com/CriticalPathSecurity/Public-Intelligence-Feeds/master/threatfox.txt
https://raw.githubusercontent.com/CriticalPathSecurity/Public-Intelligence-Feeds/master/cobaltstrike_ips.txt

# Scanners/bruteforce
https://raw.githubusercontent.com/stamparm/ipsum/master/levels/1.txt

# RKN scanners
https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/blacklist.txt
https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt
'

# Operational limits
BL_DOWNLOAD_TIMEOUT=30
BL_MAX_ENTRIES=1048576
BL_MIN_VALID_ENTRIES=1
BL_VERBOSE=0
BL_LOGME_SILENCE=0

# Runtime flags (set at startup)
BL_HAS_LOGGER=0
BL_SOURCES_COUNT=0
BL_HAS_IPV6_SUPPORT=0
BL_HAS_IPV4=0

# =============================================================================
# STARTUP CHECKS (ts5b style - check tools once)
# =============================================================================

# Check for logger command (once at startup, not every logme call)
if command -v logger >/dev/null 2>&1; then
    BL_HAS_LOGGER=1
fi

# Check required tools
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl not found, cannot download blacklists" >&3
    exit 1
fi

if ! command -v ipset >/dev/null 2>&1; then
    echo "ERROR: ipset not found, cannot manage hash:net sets" >&3
    exit 1
fi

# Check iptables
if command -v iptables >/dev/null 2>&1; then
    BL_HAS_IPV4=1
fi

# Check ip6tables for IPv6 support
if command -v ip6tables >/dev/null 2>&1; then
    if [ -f /proc/net/ip6_tables_names ] || ip6tables -L -n >/dev/null 2>&1; then
        BL_HAS_IPV6_SUPPORT=1
    fi
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Log message (logger checked once at startup, ts5b style)
logme()
{
    case "${BL_LOGME_SILENCE}" in 0);; *) return 0;; esac

    case "${BL_HAS_LOGGER}" in 1)
        logger -t "${BL_LOGTAG}" "${@}" 2>/dev/null;;
    esac

    case "${BL_VERBOSE}" in
    1)
        echo "${@}" >&3;;
    0)
        [ -t 3 ] && echo "${@}" >&3 2>/dev/null;;
    esac
}

# Cleanup temporary files
cleanup_tmp()
{
    rm -f "${BL_TMPFILE}" "${BL_TMPFILE}.sorted" "${BL_TMPFILE}.lock" 2>/dev/null
    rm -f "${BL_TMPFILE4}" "${BL_TMPFILE4}.sorted" 2>/dev/null
    rm -f "${BL_TMPFILE6}" "${BL_TMPFILE6}.sorted" 2>/dev/null
}

# Final exit handler
exitme()
{
    cleanup_tmp
    stop_childs
    exec 3>&-
    final "${1}"
}

# Count lines matching pattern (fixed: grep -c returns 0 count but exit code 1)
count_pattern()
{
    l_cp_pattern="${1}"
    l_cp_file="${2}"
    l_cp_result=0
    l_cp_result="$(grep -c "${l_cp_pattern}" "${l_cp_file}" 2>/dev/null)" || l_cp_result=0
    case "${3}" in
    "")
        echo "${l_cp_result}";;
    *)
        eval "${3}=${l_cp_result}";;
    esac
}

# Check if ipset exists (FIXED: use ipset list, not ipset test)
ipset_exists()
{
    ipset list "${1}" >/dev/null 2>&1
}

# Get current entry count from ipset (FIXED: use "Number of entries:" not "Size:")
ipset_get_count()
{
    l_igc_name="${1}"
    l_igc_count=0
    l_igc_count="$(ipset list "${l_igc_name}" 2>/dev/null | grep -E "^Number of entries:" | grep -oE "[0-9]+" | head -1)"
    case "${l_igc_count}" in "") l_igc_count=0;; esac
    case "${2}" in
    "")
        echo "${l_igc_count}";;
    *)
        eval "${2}=${l_igc_count}";;
    esac
}

# Check if string looks like IPv6 (contains ":" and hex digits)
is_ipv6()
{
    case "${1}" in
    *:*[0-9a-fA-F]*|*[0-9a-fA-F]*:*)
        return 0;;
    *)
        return 1;;
    esac
}

# Validate and normalize a single CIDR entry (IPv4 or IPv6)
# Only public addresses are accepted (result_iptype == 0)
# Returns: "4 <cidr>" for IPv4, "6 <cidr>" for IPv6, empty on failure
normalize_cidr()
{
    l_input="${1}"

    # Skip empty lines and comments
    l_line="${l_input%%#*}"
    l_line="${l_line#"${l_line%%[![:space:]]*}"}"
    l_line="${l_line%"${l_line##*[![:space:]]}"}"
    case "${l_line}" in "") return 1;; esac

    # Detect IPv6 FIRST (before calling check_ipv4_or_domain)
    l_is_ipv6=0
    case "${l_line}" in
    */*)
        l_addr="${l_line%/*}"; l_mask="${l_line##*/}";;
    *)
        l_addr="${l_line}"; l_mask="";;
    esac

    if is_ipv6 "${l_addr}"; then
        l_is_ipv6=1
    fi

    # Process IPv6 separately (check_ipv4_or_domain doesn't handle IPv6 properly)
    if [ "${l_is_ipv6}" = "1" ]; then
        # Validate IPv6 mask
        case "${l_mask}" in
        "")
            l_mask="128"
            ;;
        *[!0-9]*)
            return 1
            ;;
        *)
            case "${l_mask}" in [0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]);; *)
                return 1;;
            esac
            ;;
        esac

        # Basic IPv6 format check (must contain :, only hex and :)
        case "${l_addr}" in
        *[!0-9a-fA-F:]*)
            return 1;;
        *:*)
            ;;
        *)
            return 1;;
        esac

        # Check if public (skip localhost ::1, link-local fe80::, etc.)
        case "${l_addr}" in
        ::1|0:0:0:0:0:0:0:1)
            case "${BL_VERBOSE}" in 1)
                logme "DEBUG: Skipping IPv6 localhost: ${l_addr}/${l_mask}";;
            esac
            return 1
            ;;
        fe80:*|FE80:*)
            case "${BL_VERBOSE}" in 1)
                logme "DEBUG: Skipping IPv6 link-local: ${l_addr}/${l_mask}";;
            esac
            return 1
            ;;
        fc00:*|FC00:*|fd00:*|FD00:*)
            case "${BL_VERBOSE}" in 1)
                logme "DEBUG: Skipping IPv6 unique-local: ${l_addr}/${l_mask}";;
            esac
            return 1
            ;;
        esac

        echo "6 ${l_addr}/${l_mask}"
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Normalized IPv6 ${l_addr} -> ${l_addr}/${l_mask}";;
        esac
        return 0
    fi

    # Process IPv4 using library function
    check_ipv4_or_domain "${l_line}"

    # Accept only valid IPv4 results
    case $? in 0);; *) 
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Skipping non-IPv4 entry: ${l_line}";;
        esac
        return 1
        ;;
    esac

    # Only allow PUBLIC addresses (result_iptype: 0=public, 1=private, 2=localhost, 3=any)
    case "${result_iptype}" in 0);;
    1)
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Skipping private address: ${result_ipaddr}/${result_subnet:-32}";;
        esac
        return 1
        ;;
    2)
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Skipping localhost address: ${result_ipaddr}/${result_subnet:-32}";;
        esac
        return 1
        ;;
    *)
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Skipping invalid/any address: ${result_ipaddr:-unknown}";;
        esac
        return 1
        ;;
    esac

    # Build normalized CIDR
    case "${result_subnet}" in
    "")
        echo "4 ${result_ipaddr}/32"
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Normalized IPv4 ${result_ipaddr} -> ${result_ipaddr}/32";;
        esac
        ;;
    *)
        echo "4 ${result_ipaddr}/${result_subnet}"
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Using IPv4 CIDR ${result_ipaddr}/${result_subnet}";;
        esac
        ;;
    esac
    return 0
}

# Fetch and parse a single source URL
fetch_source()
{
    l_url="${1}"
    l_tmp="$(mktemp)" || return 1
    l_linecount=0
    l_validcount=0
    l_v4count=0
    l_v6count=0

    case "${BL_VERBOSE}" in 1)
        logme "INFO: Fetching source: ${l_url}";;
    esac

    # Wait for internet connectivity
    inet_waitconnection

    # Download with timeout
    if ! curl -fsSL --connect-timeout "${BL_DOWNLOAD_TIMEOUT}" \
         --max-time "$((BL_DOWNLOAD_TIMEOUT * 2))" \
         "${l_url}" >"${l_tmp}" 2>/dev/null; then
        logme "WARN: Failed to fetch ${l_url}"
        rm -f "${l_tmp}"
        return 1
    fi

    logme "INFO: Downloaded ${l_url} successfully"

    # Process each line
    while IFS= read -r l_line || [ -n "${l_line}" ]; do
        l_linecount=$((l_linecount + 1))
        l_result="$(normalize_cidr "${l_line}")"
        case "${l_result}" in "");;
        4\ *)
            echo "${l_result}"
            l_validcount=$((l_validcount + 1))
            l_v4count=$((l_v4count + 1))
            ;;
        6\ *)
            echo "${l_result}"
            l_validcount=$((l_validcount + 1))
            l_v6count=$((l_v6count + 1))
            ;;
        esac
    done <"${l_tmp}"

    rm -f "${l_tmp}"
    
    case "${BL_VERBOSE}" in 1)
        logme "DEBUG: Source ${l_url}: ${l_linecount} lines -> ${l_validcount} valid (${l_v4count} IPv4, ${l_v6count} IPv6)";;
    esac
    
    return 0
}

# Check if iptables/ip6tables rule exists (improved detection)
check_iptables_rule()
{
    l_ipt_cmd="${1}"
    l_ipt_table="${2}"
    l_ipt_chain="${3}"
    l_ipt_setname="${4}"

    # Method 1: Try -C (check) - most reliable if supported
    if "${l_ipt_cmd}" -t "${l_ipt_table}" -C "${l_ipt_chain}" \
         -m set --match-set "${l_ipt_setname}" src -j DROP 2>/dev/null; then
        return 0
    fi

    # Method 2: Check if rule exists in chain output (more robust grep)
    if "${l_ipt_cmd}" -t "${l_ipt_table}" -L "${l_ipt_chain}" -n 2>/dev/null | \
         grep -q "set.*${l_ipt_setname}.*DROP" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Add iptables/ip6tables rule with better error handling
add_iptables_rule()
{
    l_ipt_cmd="${1}"
    l_ipt_table="${2}"
    l_ipt_chain="${3}"
    l_ipt_setname="${4}"

    # First check if rule already exists
    if check_iptables_rule "${l_ipt_cmd}" "${l_ipt_table}" "${l_ipt_chain}" "${l_ipt_setname}"; then
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Rule already exists for ${l_ipt_setname} in ${l_ipt_table}:${l_ipt_chain}";;
        esac
        return 0
    fi

    # Try to add the rule (insert at position 1, no priority number)
    if "${l_ipt_cmd}" -t "${l_ipt_table}" -I "${l_ipt_chain}" \
         -m set --match-set "${l_ipt_setname}" src -j DROP 2>/dev/null; then
        # Verify rule was added (give it a moment)
        sleepme 0.1
        if check_iptables_rule "${l_ipt_cmd}" "${l_ipt_table}" "${l_ipt_chain}" "${l_ipt_setname}"; then
            return 0
        fi
    fi

    return 1
}

# Update ipset for specific IP version (4 or 6)
update_ipset_version()
{
    l_ver="${1}"
    l_setname="${2}"
    l_tmpset="${3}"
    l_tmpfile="${4}"
    l_ipt_cmd="${5}"
    l_ipt_table="${6}"
    l_ipt_chain="${7}"

    l_entry_count=0
    l_family="inet"
    case "${l_ver}" in 6) l_family="inet6";; esac

    # Filter entries for this IP version
    grep "^${l_ver} " "${BL_TMPFILE}" 2>/dev/null | cut -d' ' -f2- | sort -u | \
        head -n "${BL_MAX_ENTRIES}" >"${l_tmpfile}"

    count_pattern "" "${l_tmpfile}" "l_entry_count"

    # Skip if no entries for this version
    case "${l_entry_count}" in 0)
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: No IPv${l_ver} entries to process";;
        esac
        return 0
        ;;
    esac

    logme "INFO: IPv${l_ver}: ${l_entry_count} entries for set ${l_setname}"

    # Check if set already exists
    l_set_exists=0
    if ipset_exists "${l_setname}"; then
        l_set_exists=1
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Set ${l_setname} already exists, will perform atomic swap";;
        esac
        # Show current set info
        ipset_get_count "${l_setname}" "l_current_count"
        logme "INFO: IPv${l_ver}: Current set ${l_setname} has ${l_current_count} entries, updating to ${l_entry_count}"
    else
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Set ${l_setname} does not exist, will create new";;
        esac
    fi

    # Create temporary set
    ipset destroy "${l_tmpset}" 2>/dev/null
    if ! ipset create "${l_tmpset}" hash:net family "${l_family}" maxelem "${BL_MAX_ENTRIES}" 2>/dev/null; then
        logme "ERROR: IPv${l_ver}: Failed to create temporary ipset ${l_tmpset}"
        return 1
    fi
    case "${BL_VERBOSE}" in 1)
        logme "DEBUG: IPv${l_ver}: Created temporary set ${l_tmpset}";;
    esac

    # Populate temporary set using ipset restore (BULK LOAD - much faster)
    # Format required: "add <setname> <cidr>" per line
    logme "INFO: IPv${l_ver}: Bulk loading ${l_entry_count} entries via ipset restore..."

    # Transform CIDR file to ipset restore format
    # Using sed to prefix each line with "add <tmpset> "
    sed "s/^/add ${l_tmpset} /" "${l_tmpfile}" >"${l_tmpfile}.restore"

    # Execute bulk load
    # -exist: skip entries that already exist (idempotent)
    # Errors are suppressed, we check result via set size later
    if ipset restore -exist <"${l_tmpfile}.restore" 2>/dev/null; then
        l_add_success="${l_entry_count}"
        l_add_failed=0
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: IPv${l_ver}: Bulk load completed successfully" ;;
        esac
    else
        # Fallback: count what we could add (should not happen often)
        l_add_success=0
        l_add_failed=0
        while IFS= read -r l_cidr; do
            case "${l_cidr}" in "") continue ;; esac
            if ipset add "${l_tmpset}" "${l_cidr}" -exist 2>/dev/null; then
                l_add_success=$((l_add_success + 1))
            else
                l_add_failed=$((l_add_failed + 1))
            fi
        done <"${l_tmpfile}"
        case "${BL_VERBOSE}" in 1)
            case "${l_add_failed}" in 0);; *)
                logme "WARN: IPv${l_ver}: Bulk load had issues, ${l_add_failed} entries failed" ;;
            esac ;;
        esac
    fi

    # Cleanup restore file
    rm -f "${l_tmpfile}.restore" 2>/dev/null

    case "${BL_VERBOSE}" in 1)
        logme "DEBUG: IPv${l_ver}: Loaded ${l_add_success} entries, ${l_add_failed} failed" ;;
    esac

    # Atomic swap or initial creation
    case "${l_set_exists}" in
    1)
        if ! ipset swap "${l_setname}" "${l_tmpset}" 2>/dev/null; then
            logme "ERROR: IPv${l_ver}: Failed to swap ipset ${l_setname} <-> ${l_tmpset}"
            ipset destroy "${l_tmpset}" 2>/dev/null
            return 1
        fi
        logme "INFO: IPv${l_ver}: Atomically swapped set ${l_setname} with ${l_entry_count} entries"
        ;;
    *)
        ipset destroy "${l_setname}" 2>/dev/null || :
        if ! ipset create "${l_setname}" hash:net family "${l_family}" maxelem "${BL_MAX_ENTRIES}" 2>/dev/null; then
            logme "ERROR: IPv${l_ver}: Failed to create main ipset ${l_setname}"
            ipset destroy "${l_tmpset}" 2>/dev/null
            return 1
        fi
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: IPv${l_ver}: Created main set ${l_setname}";;
        esac

        # Copy entries from temp to main set
        ipset save "${l_tmpset}" 2>/dev/null | grep "^add ${l_tmpset}" | \
            sed "s/^add ${l_tmpset}/add ${l_setname}/" | ipset restore -exist 2>/dev/null
        logme "INFO: IPv${l_ver}: Created new set ${l_setname} with ${l_entry_count} entries"

        # Add iptables/ip6tables rule if not present
        case "${l_ver}" in
        4)
            if [ "${BL_HAS_IPV4}" = "1" ]; then
                if ! add_iptables_rule "${l_ipt_cmd}" "${l_ipt_table}" "${l_ipt_chain}" "${l_setname}"; then
                    logme "WARN: IPv${l_ver}: Failed to add ${l_ipt_cmd} rule for set ${l_setname}"
                    case "${BL_VERBOSE}" in 1) 
                        logme "DEBUG: IPv${l_ver}: Command tried: ${l_ipt_cmd} -t ${l_ipt_table} -I ${l_ipt_chain} -m set --match-set ${l_setname} src -j DROP"
                        logme "DEBUG: IPv${l_ver}: Current rules in ${l_ipt_table}:${l_ipt_chain}:"
                        "${l_ipt_cmd}" -t "${l_ipt_table}" -L "${l_ipt_chain}" -n 2>/dev/null | head -20 >&3
                        ;;
                    esac
                else
                    logme "INFO: IPv${l_ver}: Added ${l_ipt_cmd} rule for set ${l_setname} in ${l_ipt_table}:${l_ipt_chain}"
                fi
            fi
            ;;
        6)
            if [ "${BL_HAS_IPV6_SUPPORT}" = "1" ]; then
                if ! add_iptables_rule "${l_ipt_cmd}" "${l_ipt_table}" "${l_ipt_chain}" "${l_setname}"; then
                    logme "WARN: IPv${l_ver}: Failed to add ${l_ipt_cmd} rule for set ${l_setname}"
                    case "${BL_VERBOSE}" in 1) 
                        logme "DEBUG: IPv${l_ver}: Command tried: ${l_ipt_cmd} -t ${l_ipt_table} -I ${l_ipt_chain} -m set --match-set ${l_setname} src -j DROP"
                        logme "DEBUG: IPv${l_ver}: Current rules in ${l_ipt_table}:${l_ipt_chain}:"
                        "${l_ipt_cmd}" -t "${l_ipt_table}" -L "${l_ipt_chain}" -n 2>/dev/null | head -20 >&3
                        ;;
                    esac
                else
                    logme "INFO: IPv${l_ver}: Added ${l_ipt_cmd} rule for set ${l_setname} in ${l_ipt_table}:${l_ipt_chain}"
                fi
            fi
            ;;
        esac
        ;;
    esac

    # Cleanup temporary set
    ipset destroy "${l_tmpset}" 2>/dev/null || :
    case "${BL_VERBOSE}" in 1)
        logme "DEBUG: IPv${l_ver}: Destroyed temporary set ${l_tmpset}";;
    esac

    # Show final set statistics
    case "${BL_VERBOSE}" in 1)
        l_set_info="$(ipset list "${l_setname}" 2>/dev/null | grep -E "^(Name|Number of entries|Maxelem|Family):" | tr '\n' ' ')"
        logme "DEBUG: IPv${l_ver}: Final set info: ${l_set_info}"
        ;;
    esac

    return 0
}

# Main update logic
update_ipset()
{
    logme "INFO: Starting blacklist update from ${BL_SOURCES_COUNT} source(s)..."
    case "${BL_VERBOSE}" in
    1) 
        logme "DEBUG: Configuration: IPv4 set=${BL4_SETNAME}, IPv6 set=${BL6_SETNAME}"
        logme "DEBUG: IPv4: table=${BL4_TABLE}, chain=${BL4_CHAIN}"
        logme "DEBUG: IPv6: table=${BL6_TABLE}, chain=${BL6_CHAIN}"
        ;;
    esac

    # Collect all valid entries (both IPv4 and IPv6)
    : >"${BL_TMPFILE}"
    l_fetch_success=0
    l_fetch_failed=0
    l_total_v4=0
    l_total_v6=0
    for l_src in ${BL_SOURCES}; do
        l_src="${l_src#"${l_src%%[![:space:]]*}"}"
        l_src="${l_src%"${l_src##*[![:space:]]}"}"
        case "${l_src}" in "") continue ;; esac
        if fetch_source "${l_src}" >>"${BL_TMPFILE}"; then
            l_fetch_success=$((l_fetch_success + 1))
        else
            l_fetch_failed=$((l_fetch_failed + 1))
        fi
    done

    case "${BL_VERBOSE}" in 1)
        logme "DEBUG: Fetch complete: ${l_fetch_success} succeeded, ${l_fetch_failed} failed";;
    esac

    # Sort and deduplicate ALL entries together (preserves 4/6 prefix)
    sort -u "${BL_TMPFILE}" | head -n "${BL_MAX_ENTRIES}" >"${BL_TMPFILE}.sorted"
    mv "${BL_TMPFILE}.sorted" "${BL_TMPFILE}"

    # Count total entries (lines in final file)
    count_pattern "" "${BL_TMPFILE}" "l_total_count"

    # Count IPv4 and IPv6 entries from FINAL sorted file
    count_pattern "^4 " "${BL_TMPFILE}" "l_count4"
    count_pattern "^6 " "${BL_TMPFILE}" "l_count6"

    # Sanity check
    case "$((BL_MIN_VALID_ENTRIES - l_total_count))" in "-"*|0);; *)
        logme "ERROR: Too few valid entries (${l_total_count}), aborting update"
        case "${BL_VERBOSE}" in 1)
            logme "DEBUG: Minimum required: ${BL_MIN_VALID_ENTRIES}";;
        esac
        return 1
        ;;
    esac

    logme "INFO: Prepared ${l_total_count} unique public CIDR entries (IPv4: ${l_count4}, IPv6: ${l_count6})"

    # Update IPv4 set
    l_upd4_ok=0
    case "${BL_HAS_IPV4}" in
    1)
        if update_ipset_version "4" "${BL4_SETNAME}" "${BL4_TMPSET}" "${BL_TMPFILE4}" \
             "iptables" "${BL4_TABLE}" "${BL4_CHAIN}"; then
            l_upd4_ok=1
        fi
        ;;
    0)
        logme "WARN: IPv4: iptables not available, skipping IPv4 set update"
        ;;
    esac

    # Update IPv6 set
    l_upd6_ok=0
    case "${BL_HAS_IPV6_SUPPORT}" in
    1)
        if update_ipset_version "6" "${BL6_SETNAME}" "${BL6_TMPSET}" "${BL_TMPFILE6}" \
             "ip6tables" "${BL6_TABLE}" "${BL6_CHAIN}"; then
            l_upd6_ok=1
        fi
        ;;
    0)
        logme "WARN: IPv6: ip6tables not available, skipping IPv6 set update"
        ;;
    esac

    # Check if at least one version succeeded
    case "$((l_upd4_ok + l_upd6_ok))" in 0)
        logme "ERROR: Both IPv4 and IPv6 updates failed"
        return 1
        ;;
    esac

    logme "INFO: Blacklist update completed: IPv4=${l_count4} entries, IPv6=${l_count6} entries, $(date '+%Y-%m-%d %H:%M:%S')"
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Parse command line arguments
case "${1}" in
-v|--verbose) 
    BL_VERBOSE=1
    logme "INFO: Verbose mode enabled"
    shift
    ;;
-s|--silent)
    BL_LOGME_SILENCE=1
    shift
    ;;
-h|--help)
    echo "Usage: ${0} [-v|--verbose] [-s|--silent] [-h|--help]" >&3
    echo "  -v, --verbose  Enable detailed output" >&3
    echo "  -s, --silent   Disable all logging" >&3
    echo "  -h, --help     Show this help message" >&3
    exitme 0
    ;;
esac

# Acquire exclusive lock
exec 9>"${BL_LOCKFILE}" 2>/dev/null || {
    logme "ERROR: Cannot acquire lock on ${BL_LOCKFILE}"
    exitme 1
}
if ! flock -n 9; then
    logme "WARN: Another instance is running, exiting"
    exitme 0
fi
case "${BL_VERBOSE}" in 1)
    logme "DEBUG: Acquired lock on ${BL_LOCKFILE}" ;;
esac

# Filter source URLs
BL_SOURCES=$(echo "${BL_SOURCES}" |sed -e "/^ *#/d; /^ *$/d" -e "s/[ \t]*$//" -e "s/^[ \t]*//" 2>/dev/null)

# Count valid source URLs
BL_SOURCES_COUNT=0
for l_s in ${BL_SOURCES}; do
    l_s="${l_s#"${l_s%%[![:space:]]*}"}"
    case "${l_s}" in "") continue;; esac
    BL_SOURCES_COUNT=$((BL_SOURCES_COUNT + 1))
done

case "${BL_VERBOSE}" in 1)
    logme "DEBUG: Found ${BL_SOURCES_COUNT} source URLs";;
esac

case "${BL_HAS_LOGGER}" in
1)
    logme "DEBUG: logger command available, will use syslog";;
0)
    logme "DEBUG: logger command NOT available, output to stream 3 only";;
esac

case "${BL_HAS_IPV4}" in
1)
    logme "DEBUG: IPv4 support enabled (iptables available)";;
0)
    logme "DEBUG: IPv4 support disabled (iptables not found)";;
esac

case "${BL_HAS_IPV6_SUPPORT}" in
1)
    logme "DEBUG: IPv6 support enabled (ip6tables available)";;
0)
    logme "DEBUG: IPv6 support disabled (ip6tables not found or kernel support missing)";;
esac

# Run update
if update_ipset; then
    logme "INFO: Blacklist update completed successfully"
    exitme 0
else
    logme "ERROR: Blacklist update FAILED"
    exitme 1
fi
