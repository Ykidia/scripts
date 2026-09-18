#!/bin/sh

PATH=/usr/bin:/usr/sbin:/bin:/sbin
CONF_FILE="/etc/dnsmasq-hosts.conf"
DNSMASQ_LISTS="
https://raw.githubusercontent.com/notracking/hosts-blocklists/master/dnsmasq/dnsmasq.blacklist.txt
"
HOSTS_LISTS="
https://adaway.org/hosts.txt
https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews/hosts
https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&mimetype=plaintext
"
TMP_RAW_ALL="$(mktemp)"
TMP_RAW_SINGLE="$(mktemp)"
TMP_SORTED="$(mktemp)"

: >$TMP_RAW_ALL
: >$TMP_RAW_SINGLE
: >$TMP_SORTED

# Downloading raw (dnsmasq-format) lists
DOWN_TRIES=10
for url in $DNSMASQ_LISTS; do
    while ! curl -fsSL "$url" 2>/dev/null >$TMP_RAW_SINGLE; do
        DOWN_TRIES=$((DOWN_TRIES - 1))
        if [ $DOWN_TRIES -le 0 ]; then
            break
        fi
        sleep 6
    done
    cat $TMP_RAW_SINGLE >>$TMP_RAW_ALL
done

# Downloading and processing hosts-format lists
for url in $HOSTS_LISTS; do
    curl -fsSL "$url" 2>/dev/null | \
    awk '
        {
            # no DOS
            gsub(/\r/, "")
            # no comments
            sub(/#.*/, "")
            if ($1 ~ /^!/) next
            # no whitespaces
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            # no blanks
            if (length($0) == 0) next
            # no dummies
            if (NF < 2) next
            # no locals
            if ($2 ~ /^(localhost|broadcasthost|ip6-.*|ipv6-.*|localdomain)$/) next

            if ($1 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) {
                # All domains
                for (i = 2; i <= NF; i++) {
                    # Check for local domains
                    if ($i ~ /^(localhost|broadcasthost|ip6-.*|ipv6-.*|localdomain)$/) continue
                    print "address=/" $i "/0.0.0.0"
                }
            }
        }
        ' >> "$TMP_RAW_ALL"
done

# Sorting keeping only uniques
sort -u "$TMP_RAW_ALL" | \
awk '
{
    sub(/#.*/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    if (length($0) > 0) print
}
' > "$TMP_SORTED"

if [ -s "$TMP_SORTED" ]; then
    mv -f "$TMP_SORTED" "$CONF_FILE"
    rm -f "$TMP_RAW_ALL" "$TMP_RAW_SINGLE" "$TMP_SORTED"

    # Reloading dnsmasq
    systemctl reload dnsmasq 2>/dev/null || /etc/init.d/dnsmasq reload 2>/dev/null

    echo "Updated $(wc -l < "$CONF_FILE") hosts"
    exit 0
else

    echo "NOT updated"
    exit 1
fi

