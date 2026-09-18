#!/bin/bash
set -e

# Basic PATH
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/etc/init.d

# Debug mode flag
DEBUG_MODE=0

# Systemd availability flag
SYSTEMD_AVAILABLE=0

# === CONFIGURATION SECTION ===
# Command to run when ports are free
MAIN_COMMAND="certbot renew"

# Ports to free (space-separated list)
PORTS_TO_FREE="80 443"

# Known services mapping: process_name:service_name
KNOWN_SERVICES="
nginx:nginx
apache2:apache2
httpd:apache2
lighttpd:lighttpd
tomcat:tomcat
tomcat9:tomcat9
caddy:caddy
haproxy:haproxy
"

# DNAT rule pattern for iptables rules file
DNAT_RULE_PATTERN="-A PREROUTING -i .* -p tcp -m tcp --dport [0-9]+ -j DNAT --to-destination .*:[0-9]+"

# Temporary iptables rule marker
IPTABLES_MARKER="temp-port-release-script"

# === END CONFIGURATION ===

# Debug output function
debug_print() {
    if [ $DEBUG_MODE -eq 1 ]; then
        echo "DEBUG: $*" >&2
    fi
}

# Show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Run a command with specified ports temporarily freed from services/processes.

OPTIONS:
    --help, -h          Show this help message
    --debug             Enable debug output
    --command CMD       Command to run (default: "certbot renew")
    --ports PORTS       Ports to free (space-separated, default: "80")

EXAMPLES:
    $0
    $0 --command "my-script.sh" --ports "80 443"
    $0 --debug --ports "80 443 8080"

The script will:
1. Free specified ports from running services/processes
2. Disable DNAT rules for these ports (if any)
3. Add temporary iptables ACCEPT rules
4. Run the specified command
5. Restore everything to original state
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        --command)
            MAIN_COMMAND="$2"
            shift 2
            ;;
        --ports)
            PORTS_TO_FREE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information." >&2
            exit 1
            ;;
    esac
done

# Function: check if required commands are available
check_dependencies() {
    local missing_deps=""

    # Essential tools (excluding systemctl if not needed)
    essential_tools="ss iptables sed grep cut tr cat"

    # Check systemd availability
    if command -v systemctl >/dev/null 2>&1; then
        SYSTEMD_AVAILABLE=1
        essential_tools="$essential_tools systemctl"
        debug_print "Systemd is available"
    else
        SYSTEMD_AVAILABLE=0
        debug_print "Systemd is NOT available, using init.d only"
    fi

    for cmd in $essential_tools; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps="$missing_deps $cmd"
        fi
    done

    # Check if main command is available (if it's a single command without arguments)
    main_cmd_base="${MAIN_COMMAND%% *}"
    if [ "$main_cmd_base" != "${MAIN_COMMAND}" ] || [ -x "$(command -v "$main_cmd_base" 2>/dev/null)" ]; then
        # Either it's a complex command or the base command exists
        :
    else
        if ! command -v "$main_cmd_base" >/dev/null 2>&1; then
            missing_deps="$missing_deps $main_cmd_base"
        fi
    fi

    if [ -n "$missing_deps" ]; then
        echo "Error: Required programs not found:" >&2
        for dep in $missing_deps; do
            echo "  - $dep" >&2
        done
        echo "" >&2
        echo "Please install the missing packages and try again." >&2
        echo "On Debian/Ubuntu, you might need:" >&2
        echo "  apt install iproute2 iptables sed grep coreutils procps" >&2
        if [ $SYSTEMD_AVAILABLE -eq 1 ]; then
            echo "  apt install systemd" >&2
        fi
        if echo "$missing_deps" | grep -q "certbot"; then
            echo "  apt install certbot" >&2
        fi
        exit 1
    fi

    echo "All dependencies satisfied."
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root to detect processes using ports." >&2
    echo "Use: sudo $0 [OPTIONS]" >&2
    exit 1
fi

# State tracking variables
STOPPED_SERVICES=""
STOPPED_PROCESSES=""
TEMP_RULE_ADDED=0
RULE_ACTIVE=0
RULES_FILE="/etc/iptables/rules.v4"

# Function: find all IPs listening on specified ports
find_listening_ips() {
    local target_ports="$1"
    debug_print "Checking for ports: $target_ports"

    ss -tulnH 2>/dev/null | while read -r line; do
        debug_print "Processing line: '$line'"

        # Split into fields
        set -- $line
        field_count=$#
        debug_print "Field count: $field_count"

        if [ $field_count -lt 5 ]; then
            debug_print "Skipping line (too few fields)"
            continue
        fi

        # Field 5 is Local Address:Port
        local_addr="$5"
        debug_print "Local address: '$local_addr'"

        for port in $target_ports; do
            debug_print "Checking if local_addr '$local_addr' matches port $port"
            if echo "$local_addr" | grep -qE ":$port\$"; then
                debug_print "MATCH FOUND for port $port!"
                ip_part="${local_addr%:*}"
                if [ "$ip_part" = "[::]" ]; then
                    echo "::"
                else
                    echo "$ip_part"
                fi
                break
            else
                debug_print "No match for port $port"
            fi
        done
    done | sort -u
}

# Function: get PIDs for specific IP and ports
get_pids_for_ip() {
    local target_ip="$1"
    local target_ports="$2"
    debug_print "Getting PIDs for IP: $target_ip, ports: $target_ports"

    ss -tulnp 2>/dev/null | while read -r line; do
        debug_print "PID line: $line"

        # Split into fields
        set -- $line
        if [ $# -lt 5 ]; then
            continue
        fi

        # Field 5 is Local Address:Port
        local_addr="$5"
        # Last field contains PID info
        pid_info="${!#}"

        debug_print "Local addr: $local_addr, PID info: $pid_info"

        # Check if this line matches any of our target ports
        port_match=0
        for port in $target_ports; do
            if echo "$local_addr" | grep -qE ":$port\$"; then
                port_match=1
                break
            fi
        done
        if [ $port_match -eq 0 ]; then
            continue
        fi

        # Check IP
        local_ip="${local_addr%:*}"
        if [ "$target_ip" = "0.0.0.0" ] || [ "$target_ip" = "::" ] || [ "$local_ip" = "$target_ip" ]; then
            debug_print "IP matches, extracting PIDs"
            # Extract all PIDs from the pid_info
            echo "$pid_info" | tr ',' '\n' | grep -o 'pid=[0-9]*' | cut -d'=' -f2
        fi
    done
}

# Function: stop known service (systemd or init.d)
stop_service() {
    local service_name="$1"

    if [ $SYSTEMD_AVAILABLE -eq 1 ]; then
        # Use systemd
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo "Stopping service: $service_name"
            systemctl stop "$service_name"
            STOPPED_SERVICES="$STOPPED_SERVICES $service_name"
            return 0
        fi
    else
        # Use init.d
        if [ -x "/etc/init.d/$service_name" ]; then
            echo "Stopping service: $service_name"
            "/etc/init.d/$service_name" stop
            STOPPED_SERVICES="$STOPPED_SERVICES $service_name"
            return 0
        fi
    fi
    return 1
}

# Function: kill process and save command line
kill_process() {
    local pid="$1"
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    cmdline=""
    if [ -f "/proc/$pid/cmdline" ]; then
        cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
    fi
    if [ -z "$cmdline" ]; then
        cmdline="unknown"
    fi

    echo "Killing process PID $pid: $cmdline"
    kill "$pid"
    sleep 2

    # Check if it respawned
    if kill -0 "$pid" 2>/dev/null; then
        echo "Process $pid respawned, killing forcefully"
        kill -9 "$pid" 2>/dev/null || true
    fi

    STOPPED_PROCESSES="$STOPPED_PROCESSES $pid|$cmdline"
}

# Function: get service name for process
get_service_for_process() {
    local proc_name="$1"
    local line

    debug_print "Looking up service for process: '$proc_name'"

    # Use here-document to avoid subshell issues
    while IFS= read -r line; do
        # Skip empty lines and comments
        case "$line" in
            ""|"#"*) continue ;;
        esac

        # Find the first colon to split
        case "$line" in
            *:* )
                # Extract everything before first colon
                proc_part="${line%%:*}"
                # Extract everything after first colon
                service_part="${line#*:}"

                # Trim whitespace
                proc_part="$(echo "$proc_part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                service_part="$(echo "$service_part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

                debug_print "Checking mapping: '$proc_part' -> '$service_part'"

                if [ "$proc_name" = "$proc_part" ]; then
                    debug_print "Found match! Service: '$service_part'"
                    printf '%s\n' "$service_part"
                    return 0
                fi
                ;;
        esac
    done << __KNOWN_SERVICES_EOF
$KNOWN_SERVICES
__KNOWN_SERVICES_EOF

    debug_print "No service found for process: '$proc_name'"
}

# Function: free all specified ports
free_specified_ports() {
    local target_ports="$1"
    local max_attempts=5
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        echo "Attempt $((attempt + 1)): freeing ports $target_ports..."

        debug_print "Calling find_listening_ips with ports: $target_ports"
        listening_ips=$(find_listening_ips "$target_ports")
        debug_print "find_listening_ips returned: '$listening_ips'"

        if [ -z "$listening_ips" ]; then
            echo "Ports $target_ports are free!"
            return 0
        else
            debug_print "Ports are NOT free, found IPs: $listening_ips"
        fi

        for ip in $listening_ips; do
            debug_print "Processing IP: $ip"
            pids=$(get_pids_for_ip "$ip" "$target_ports")
            debug_print "Found PIDs: $pids"

            for pid in $pids; do
                debug_print "Processing PID: $pid"
                proc_name=""
                if [ -f "/proc/$pid/comm" ]; then
                    proc_name=$(cat "/proc/$pid/comm" 2>/dev/null)
                fi
                if [ -z "$proc_name" ]; then
                    proc_name="unknown"
                fi

                debug_print "Process name: '$proc_name'"
                service_name=$(get_service_for_process "$proc_name")
                debug_print "Service name: '$service_name'"
                service_stopped=0

                if [ -n "$service_name" ]; then
                    if stop_service "$service_name"; then
                        service_stopped=1
                    fi
                fi

                if [ $service_stopped -eq 0 ]; then
                    kill_process "$pid"
                fi
            done
        done

        sleep 3
        attempt=$((attempt + 1))
    done

    if [ -z "$(find_listening_ips "$target_ports")" ]; then
        return 0
    else
        echo "Failed to free ports $target_ports after $max_attempts attempts!" >&2
        return 1
    fi
}

# Function: add temporary iptables ACCEPT rules for all ports
add_temp_iptables_rules() {
    echo "Adding temporary iptables ACCEPT rules for ports: $PORTS_TO_FREE..."

    # Show what rules will be added
    echo "The following iptables rules will be added:"
    for port in $PORTS_TO_FREE; do
        echo "  iptables -I INPUT -p tcp --dport $port -m comment --comment \"$IPTABLES_MARKER\" -j ACCEPT"
    done
    echo ""

    # Remove any existing rules with this marker
    for port in $PORTS_TO_FREE; do
        iptables -D INPUT -p tcp --dport "$port" -m comment --comment "$IPTABLES_MARKER" -j ACCEPT 2>/dev/null || true
    done

    # Add new rules at the beginning of INPUT chain
    for port in $PORTS_TO_FREE; do
        iptables -I INPUT -p tcp --dport "$port" -m comment --comment "$IPTABLES_MARKER" -j ACCEPT
    done

    TEMP_RULE_ADDED=1
    echo "Temporary iptables rules added successfully"
}

# Function: remove temporary iptables rules
remove_temp_iptables_rules() {
    if [ $TEMP_RULE_ADDED -ne 0 ]; then
        echo "Removing temporary iptables rules..."

        # Show what rules will be removed
        echo "The following iptables rules will be removed:"
        for port in $PORTS_TO_FREE; do
            echo "  iptables -D INPUT -p tcp --dport $port -m comment --comment \"$IPTABLES_MARKER\" -j ACCEPT"
        done
        echo ""

        for port in $PORTS_TO_FREE; do
            iptables -D INPUT -p tcp --dport "$port" -m comment --comment "$IPTABLES_MARKER" -j ACCEPT 2>/dev/null || true
        done
        TEMP_RULE_ADDED=0
        echo "Temporary iptables rules removed successfully"
    fi
}

# Function: disable DNAT rules for our ports
disable_dnat_rules() {
    if [ ! -f "$RULES_FILE" ]; then
        return 0
    fi

    # Build regex pattern for our specific ports
    port_pattern=""
    for port in $PORTS_TO_FREE; do
        if [ -z "$port_pattern" ]; then
            port_pattern="$port"
        else
            port_pattern="$port_pattern|$port"
        fi
    done

    # Check if any DNAT rules exist for our ports
    matching_rules=$(grep -E "$DNAT_RULE_PATTERN" "$RULES_FILE" 2>/dev/null || true)
    if [ -n "$matching_rules" ]; then
        echo "Temporarily disabling DNAT rules for ports: $PORTS_TO_FREE..."

        # Show which rules will be disabled
        echo "The following DNAT rules will be commented out:"
        echo "$matching_rules" | while read -r rule; do
            echo "  #$rule"
        done
        echo ""

        # Comment out DNAT rules that match our ports
        sed -E "s/($DNAT_RULE_PATTERN)/#\1/g" -i "$RULES_FILE"
        netfilter-persistent reload
        RULE_ACTIVE=1
        echo "DNAT rules disabled successfully"
    fi
}

# Function: restore DNAT rules
restore_dnat_rules() {
    if [ $RULE_ACTIVE -ne 0 ] && [ -f "$RULES_FILE" ]; then
        echo "Restoring DNAT rules..."

        # Show which rules will be restored
        restored_rules=$(grep -E "#$DNAT_RULE_PATTERN" "$RULES_FILE" 2>/dev/null || true)
        if [ -n "$restored_rules" ]; then
            echo "The following DNAT rules will be uncommented:"
            echo "$restored_rules" | while read -r rule; do
                echo "  ${rule#\#}"
            done
            echo ""
        fi

        sed -E "/$DNAT_RULE_PATTERN/s/^#//" -i "$RULES_FILE"
        netfilter-persistent reload
        RULE_ACTIVE=0
        echo "DNAT rules restored successfully"
    fi
}

# Function: restore all stopped services and processes
restore_everything() {
    # Restore services
    if [ -n "$STOPPED_SERVICES" ]; then
        echo "Restoring services..."
        echo "The following services will be started:"
        for service in $STOPPED_SERVICES; do
            if [ -n "$service" ]; then
                echo "  $service"
            fi
        done
        echo ""

        for service in $STOPPED_SERVICES; do
            if [ -n "$service" ]; then
                echo "Starting service: $service"
                if [ $SYSTEMD_AVAILABLE -eq 1 ]; then
                    systemctl start "$service" || echo "Error starting $service" >&2
                else
                    if [ -x "/etc/init.d/$service" ]; then
                        "/etc/init.d/$service" start || echo "Error starting $service" >&2
                    fi
                fi
            fi
        done
    fi

    # Restore processes
    if [ -n "$STOPPED_PROCESSES" ]; then
        echo "Restoring processes..."
        echo "The following processes will be restarted:"
        echo "$STOPPED_PROCESSES" | while IFS='|' read -r pid cmdline; do
            if [ -n "$pid" ] && [ "$cmdline" != "unknown" ]; then
                echo "  $cmdline"
            elif [ -n "$pid" ]; then
                echo "  PID $pid (command unknown)"
            fi
        done
        echo ""

        echo "$STOPPED_PROCESSES" | while IFS='|' read -r pid cmdline; do
            if [ -n "$pid" ] && [ "$cmdline" != "unknown" ]; then
                echo "Restoring process: $cmdline"
                eval "$cmdline" &
            elif [ -n "$pid" ]; then
                echo "Cannot restore process PID $pid (command unknown)"
            fi
        done
    fi
}

# === MAIN EXECUTION ===

# Check dependencies first
check_dependencies

echo "Starting port release script..."
echo "Command to run: $MAIN_COMMAND"
echo "Ports to free: $PORTS_TO_FREE"
if [ $SYSTEMD_AVAILABLE -eq 0 ]; then
    echo "Systemd not available, using init.d scripts only"
fi
echo ""

# Cleanup function for graceful exit
cleanup() {
    echo "Performing cleanup..."
    remove_temp_iptables_rules
    restore_dnat_rules
    restore_everything
}
trap cleanup EXIT INT TERM

# STEP 1: Free the specified ports from services/processes
if ! free_specified_ports "$PORTS_TO_FREE"; then
    echo "Error: failed to free ports $PORTS_TO_FREE!" >&2
    exit 1
fi

# STEP 2: Disable DNAT rules for these ports
disable_dnat_rules

# STEP 3: Add temporary iptables ACCEPT rules
add_temp_iptables_rules

# Run the main command
echo "Running main command: $MAIN_COMMAND"
echo "========================================"
if eval "$MAIN_COMMAND"; then
    echo "========================================"
    echo "*** Main command completed successfully! ***"
else
    echo "========================================"
    echo "Warning: main command exited with errors, but continuing cleanup..." >&2
fi

echo "Done!"
