#!/bin/sh

# MTProxy Auto-Updater Script
# Downloads proxy configuration files from Telegram, with optional SOCKS5 proxy
# support via naive-proxy. POSIX-compliant (works with dash, ash, bash, etc.).

# Get the absolute directory path of this script
get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH= cd -- "${d}" && pwd -P; }
#_MTPROXY_DIR_="$(get_script_dir)"
_MTPROXY_DIR_=/opt/mtproxy

# Configuration variables
_CURL_BASE_="https://core.telegram.org/getProxy"
_SECRET_URL_="${_CURL_BASE_}Secret"
_CONFIG_URL_="${_CURL_BASE_}Config"
_SECRET_FILE_="${_MTPROXY_DIR_}/proxy-secret"
_CONFIG_FILE_="${_MTPROXY_DIR_}/proxy-multi.conf"

# Detect naive-proxy SOCKS5 port
# Search for a listening port associated with 'naive' process
# Suppress stderr in case netstat is unavailable or requires privileges
_NPORT_=$(netstat -tupln 2>/dev/null | grep naive | cut -f2 -d":" | cut -f1 -d" " | head -n1)

# Validate: keep the value only if it's a non-empty numeric string
case "${_NPORT_}" in
    ''|*[!0-9]*) _NPORT_="" ;;
esac

# Helper function: curl wrapper with optional SOCKS5 proxy
# Arguments: $1 = URL, $2 = output file path
# Returns: 0 on success, non-zero on failure
do_curl() {
    _url_="$1"
    _out_="$2"

    if [ -n "${_NPORT_}" ]; then
        # Proxy is available: use SOCKS5 via naive-proxy
        # Arguments are passed separately to avoid word-splitting issues
        echo "CMD: curl -s -x "socks5://127.0.0.1:${_NPORT_}" "${_url_}" -o "${_out_}""
        curl -s -x "socks5://127.0.0.1:${_NPORT_}" "${_url_}" -o "${_out_}"
    else
        # No proxy: direct connection
        echo "CMD: curl -s "${_url_}" -o "${_out_}""
        curl -s "${_url_}" -o "${_out_}"
    fi
}


echo "Backing up old data..."
# Backup existing files (ignore errors if they don't exist yet)
cp -f "${_SECRET_FILE_}" "${_SECRET_FILE_}.bak" 2>/dev/null
cp -f "${_CONFIG_FILE_}" "${_CONFIG_FILE_}.bak" 2>/dev/null

echo "Updating proxy-secret..."
# Try to download secret via proxy; fall back to direct connection on failure
if ! do_curl "${_SECRET_URL_}" "${_SECRET_FILE_}"; then
    echo "Proxy failed, trying direct connection for secret..."
    curl -s "${_SECRET_URL_}" -o "${_SECRET_FILE_}"
fi

echo "Updating proxy-multi.conf..."
# Same fallback logic for the configuration file
if ! do_curl "${_CONFIG_URL_}" "${_CONFIG_FILE_}"; then
    echo "Proxy failed, trying direct connection for config..."
    curl -s "${_CONFIG_URL_}" -o "${_CONFIG_FILE_}"
fi

echo "Restarting MTProxy..."
# Restart the service only if systemctl is available
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart mtproxy.service
else
    echo "Warning: systemctl not found, skipping service restart."
fi
