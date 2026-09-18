#!/bin/sh
# check_network.sh
# Checks for: >=2 public IPv4, 1 native IPv6
# Exports: IPV4_PUBLIC_1, IPV4_PUBLIC_2, IPV6_PUBLIC
# Usage: source ./check_network.sh   (required for variables in parent shell)
# Output: ipv4=addr1,addr2;ipv6=addr
# Exit: 0=all OK, 1=1v4+v6, 2=1v4 only, 3=none

command -v ip >/dev/null 2>&1 || { echo "ERR: ip utility not found" >&2; exit 3; }

pub4_count=0
IPV4_PUBLIC_1=""
IPV4_PUBLIC_2=""
IPV6_PUBLIC=""

# 1. Collect first two public IPv4 addresses
while read -r iface _ addrs; do
  [ -z "$iface" ] && continue
  for addr in $addrs; do
    ip="${addr%%/*}"
    case "$ip" in
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-7].*|0.*)
        continue ;;
    esac
    if [ "$pub4_count" -eq 0 ]; then
      IPV4_PUBLIC_1="$ip"
      pub4_count=1
    elif [ "$pub4_count" -eq 1 ]; then
      IPV4_PUBLIC_2="$ip"
      pub4_count=2
      break 2
    fi
  done
done <<EOF
$(ip -4 -br addr show scope global 2>/dev/null)
EOF

# 2. Detect native IPv6 on physical interface
has_native6=0
while read -r iface _ addrs; do
  [ -z "$iface" ] && continue
  # Skip virtual/software interfaces
  [ -e "/sys/class/net/$iface/device" ] || continue
  for addr in $addrs; do
    ipv6_cand="${addr%%/*}"
    case "$ipv6_cand" in
      fe80:*|fc*|fd*|dd*|::1|"") continue ;;
    esac
    IPV6_PUBLIC="$ipv6_cand"
    has_native6=1
    break 2
  done
done <<EOF
$(ip -6 -br addr show scope global 2>/dev/null)
EOF

# 3. Determine exit code
if [ "$pub4_count" -ge 2 ] && [ "$has_native6" -eq 1 ]; then
  exit_code=0
elif [ "$pub4_count" -eq 1 ] && [ "$has_native6" -eq 1 ]; then
  exit_code=1
elif [ "$pub4_count" -eq 1 ]; then
  exit_code=2
else
  exit_code=3
fi

# 4. Output single line
ipv4_out="$IPV4_PUBLIC_1"
[ -n "$IPV4_PUBLIC_2" ] && ipv4_out="$ipv4_out,$IPV4_PUBLIC_2"
ipv6_out="${IPV6_PUBLIC:-none}"

echo "ipv4=${ipv4_out};ipv6=${ipv6_out}"
exit $exit_code
