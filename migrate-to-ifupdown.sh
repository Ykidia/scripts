#!/bin/bash
set -e

# Default values
MODE="test"
INTERFACE=""
DNS_SERVERS=()

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Migrate server to classic network configuration via /etc/network/interfaces.

OPTIONS:
  -h, --help            Show this help message
  -a, --apply           Apply real changes (default: test mode)
  -i, --interface NAME  Manually specify network interface
  -d, --dns SERVER      Specify DNS server (can be used multiple times)

By default, the script auto-detects the primary interface with public IPv4
and current DNS servers, then runs in test mode.

Examples:
  $0                    # Auto-detect + test mode
  $0 --apply           # Auto-detect + apply changes
  $0 --apply --interface eno1 --dns 8.8.8.8 --dns 1.1.1.1
EOF
}

# Function to convert CIDR to netmask
cidr2mask() {
    local i mask=""
    local full_octets=$(($1/8))
    local partial_octet=$(($1%8))

    for ((i=0;i<4;i++)); do
        if [ $i -lt $full_octets ]; then
            mask+=255
        elif [ $i -eq $full_octets ]; then
            mask+=$((256 - 2**(8-$partial_octet)))
        else
            mask+=0
        fi
        test $i -lt 3 && mask+=.
    done
    echo $mask
}

# Function to detect primary interface with public IPv4
# Returns only the interface name to stdout, logs to stderr
detect_interface() {
    >&2 echo "🔍 Detecting primary interface with public IPv4..."
    
    # Get default route interface
    DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -1)
    if [ -n "$DEFAULT_IFACE" ]; then
        # Check if it's not an enx* interface
        if [[ ! "$DEFAULT_IFACE" =~ ^enx[0-9a-fA-F]+$ ]]; then
            >&2 echo "✅ Found interface via default route: $DEFAULT_IFACE"
            echo "$DEFAULT_IFACE"
            return
        fi
    fi
    
    # Fallback: find first interface with public IPv4 that's not enx*
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        if [[ "$iface" =~ ^enx[0-9a-fA-F]+$ ]]; then
            continue
        fi
        
        ip addr show "$iface" 2>/dev/null | grep -q 'inet ' || continue
        
        # Check if has public IPv4 (not private ranges)
        PUBLIC_IP=$(ip addr show "$iface" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | \
            grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
        
        if [ -n "$PUBLIC_IP" ]; then
            >&2 echo "✅ Found interface with public IPv4: $iface"
            echo "$iface"
            return
        fi
    done
    
    >&2 echo "❌ Could not auto-detect interface with public IPv4"
    exit 1
}

# Function to detect current DNS servers
# Returns space-separated DNS servers to stdout, logs to stderr
detect_dns_servers() {
    >&2 echo "🔍 Detecting current DNS servers..."
    local dns_list=()
    
    # Check /etc/resolv.conf first
    if [ -f /etc/resolv.conf ]; then
        while IFS= read -r line; do
            if [[ $line =~ ^nameserver[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                dns_list+=("${BASH_REMATCH[1]}")
            fi
        done < /etc/resolv.conf
    fi
    
    # If no DNS found, use fallback
    if [ ${#dns_list[@]} -eq 0 ]; then
        dns_list=("8.8.8.8" "1.1.1.1")
        >&2 echo "⚠️  No DNS servers found, using fallback: ${dns_list[*]}"
    else
        >&2 echo "✅ Found DNS servers: ${dns_list[*]}"
    fi
    
    # Return as space-separated string
    echo "${dns_list[*]}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -a|--apply)
            MODE="apply"
            shift
            ;;
        -i|--interface)
            INTERFACE="$2"
            shift 2
            ;;
        -d|--dns)
            DNS_SERVERS+=("$2")
            shift 2
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Auto-detect interface if not specified
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(detect_interface)
fi

# Auto-detect DNS if not specified
if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
    DETECTED_DNS=$(detect_dns_servers)
    read -ra DNS_SERVERS <<< "$DETECTED_DNS"
fi

# Validate interface exists
if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "❌ Interface $INTERFACE does not exist!" >&2
    exit 1
fi

# Gather current network settings
>&2 echo "🔍 Gathering current network settings for interface $INTERFACE..."

CURRENT_IP=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
CURRENT_PREFIX=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f2)
CURRENT_GATEWAY=$(ip route show default | awk '{print $3}')

if [ -z "$CURRENT_IP" ] || [ -z "$CURRENT_GATEWAY" ]; then
    >&2 echo "❌ Could not determine IP or gateway for interface $INTERFACE"
    >&2 echo "IP: '$CURRENT_IP', Gateway: '$CURRENT_GATEWAY'"
    exit 1
fi

MASK=$(cidr2mask $CURRENT_PREFIX)

>&2 echo "✅ Detected settings:"
>&2 echo "   Interface: $INTERFACE"
>&2 echo "   IP: $CURRENT_IP/$CURRENT_PREFIX"
>&2 echo "   Netmask: $MASK"
>&2 echo "   Gateway: $CURRENT_GATEWAY"
>&2 echo "   DNS: ${DNS_SERVERS[*]}"
>&2 echo ""

# Generate DNS nameservers line
DNS_NAMESERVERS=""
for dns in "${DNS_SERVERS[@]}"; do
    DNS_NAMESERVERS="$DNS_NAMESERVERS $dns"
done
DNS_NAMESERVERS=$(echo $DNS_NAMESERVERS) # Trim whitespace

# Generate /etc/network/interfaces configuration
cat <<EOF
📋 Proposed /etc/network/interfaces configuration:

# Loopback
auto lo
iface lo inet loopback

# Primary interface
auto $INTERFACE
iface $INTERFACE inet static
    address $CURRENT_IP
    netmask $MASK
    gateway $CURRENT_GATEWAY
    dns-nameservers $DNS_NAMESERVERS

EOF

# List packages to be removed
cat <<EOF
🗑️ The following packages and services will be removed:
   - network-manager
   - systemd-networkd  
   - systemd-resolved

📁 /etc/resolv.conf will be replaced with a regular file (not a symlink) containing:
$(for dns in "${DNS_SERVERS[@]}"; do echo "nameserver $dns"; done)
# Additional DNS servers can be added manually

EOF

if [ "$MODE" == "test" ]; then
    >&2 echo "🧪 Mode: TEST (no real changes will be made)"
    >&2 echo "💡 To apply changes, run: $0 --apply"
    if [ ${#DNS_SERVERS[@]} -gt 1 ]; then
        DNS_OPTS=""
        for dns in "${DNS_SERVERS[@]}"; do
            DNS_OPTS="$DNS_OPTS --dns $dns"
        done
        >&2 echo "   Or with manual settings: $0 --apply --interface $INTERFACE $DNS_OPTS"
    fi
    exit 0
fi

# === APPLY MODE ===
>&2 echo "🚀 Mode: APPLY CHANGES"
>&2 echo "⚠️  Warning: This operation is irreversible. Ensure you have console access to the server!"
read -p "Continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    >&2 echo "❌ Cancelled by user."
    exit 1
fi

>&2 echo ""
>&2 echo "🔧 Performing migration..."

# 1. Install ifupdown
>&2 echo "📦 Installing ifupdown..."
apt update
apt install -y ifupdown

# 2. Create /etc/network/interfaces
>&2 echo "📝 Creating /etc/network/interfaces..."
{
    echo "# Loopback"
    echo "auto lo"
    echo "iface lo inet loopback"
    echo ""
    echo "# Primary interface"
    echo "auto $INTERFACE"
    echo "iface $INTERFACE inet static"
    echo "    address $CURRENT_IP"
    echo "    netmask $MASK"
    echo "    gateway $CURRENT_GATEWAY"
    echo "    dns-nameservers $DNS_NAMESERVERS"
} > /etc/network/interfaces

# 3. Remove NetworkManager
>&2 echo "🗑️ Removing NetworkManager..."
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true
apt purge -y network-manager network-manager-config-connectivity-* 2>/dev/null || true

# 4. Remove systemd-networkd
>&2 echo "🗑️ Removing systemd-networkd..."
systemctl stop systemd-networkd 2>/dev/null || true
systemctl disable systemd-networkd 2>/dev/null || true
apt purge -y systemd-networkd 2>/dev/null || true

# 5. Remove systemd-resolved
>&2 echo "🗑️ Removing systemd-resolved..."
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
apt purge -y systemd-resolved 2>/dev/null || true

# 6. Remove others
>&2 echo "🗑️ Removing remaining bullshit..."
apt purge -y netplan.io 2>/dev/null || true
apt purge -y cloud-init 2>/dev/null || true
rm -rf /var/lib/cloud/*
rm -rf /etc/netplan/*

# 7. Fix /etc/resolv.conf
>&2 echo "🔧 Fixing /etc/resolv.conf..."

# Check if it's a symlink - only remove if it is
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi

# Try to make file writable (in case it's immutable)
if [ -f /etc/resolv.conf ]; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
fi

# Write new content
{
    for dns in "${DNS_SERVERS[@]}"; do
        echo "nameserver $dns"
    done
    echo "# Additional DNS servers can be added manually:"
    echo "# nameserver 8.8.4.4"
} > /etc/resolv.conf || {
    >&2 echo "⚠️  Warning: Could not write to /etc/resolv.conf, continuing anyway..."
}

# Make it immutable to prevent accidental changes
chattr +i /etc/resolv.conf 2>/dev/null || {
    >&2 echo "⚠️  Warning: Could not make /etc/resolv.conf immutable"
}

# 8. Restart network
>&2 echo "🔄 Restarting network..."
(sleep 2 && ifdown "$INTERFACE" && ifup "$INTERFACE") &

# 9. Verification
sleep 5
>&2 echo ""
>&2 echo "✅ Configuration verification:"
>&2 echo "Interface: $INTERFACE"
>&2 echo "IP: $(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}')"
>&2 echo "Gateway: $(ip route show default | awk '{print $3}')"
if [ -f /etc/resolv.conf ]; then
    >&2 echo "DNS: $(grep nameserver /etc/resolv.conf | head -1)"
fi
if ping -c 2 "${DNS_SERVERS[0]}" >/dev/null; then
    >&2 echo "🌐 Internet connectivity confirmed"
else
    >&2 echo "❌ Internet connectivity issues – please check configuration!"
fi

>&2 echo ""
>&2 echo "🎉 Migration completed successfully!"
>&2 echo "💡 You can now edit /etc/network/interfaces and /etc/resolv.conf as needed."

