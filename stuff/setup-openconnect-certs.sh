#!/bin/bash
set -e

# ============================================================
# OpenConnect (ocserv) client certificate bootstrap script
#
# Usage:
#   ./script.sh <server-domain-or-ip>
# ============================================================

# The server address must be passed as the first argument
if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: $0 <server-domain-or-ip>" >&2
    echo "Example: $0 some.server.ru" >&2
    exit 1
fi

SERVER="$1"
SERVER_USER="root"
CLIENT_NAME="$(hostname)"
OCSERV_CONF="/etc/ocserv/ocserv.conf"
CERTS_DIR="/etc/ocserv/certs"
CA_DIR="$HOME/ocserv-ca"
CLIENT_CERTS_DIR="$HOME/ocserv-certs"
RETRY_ATTEMPTS=5

# Dedicated directory for the SSH control socket
# (mktemp -u alone is prone to a race condition)
SOCKET_DIR="$(mktemp -d)"
CONTROL_PATH="$SOCKET_DIR/sshctl"

cleanup() {
    ssh -o ControlPath="$CONTROL_PATH" -O exit "$SERVER_USER@$SERVER" 2>/dev/null || true
    rm -rf "$SOCKET_DIR"
}
trap cleanup EXIT

# Make sure all required tools are available
for tool in ssh scp openssl certtool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' is not installed" >&2
        exit 1
    fi
done

# Establish the master SSH connection
echo "[Client] Connecting to $SERVER_USER@$SERVER ..."
if ! ssh -fN \
        -o ControlMaster=auto \
        -o ControlPath="$CONTROL_PATH" \
        -o ControlPersist=180 \
        "$SERVER_USER@$SERVER"; then
    echo "ERROR: unable to connect to the server" >&2
    exit 1
fi

# Try to fetch the existing CA from the server (with retries)
echo "[Client] Fetching the CA from the server..."
rm -rf "$CA_DIR"
mkdir -p "$CA_DIR"

CA_VALID=0
CA_MATCH=0
ATTEMPTS_LEFT=$RETRY_ATTEMPTS

while [ "$ATTEMPTS_LEFT" -gt 0 ]; do
    rm -f "$CA_DIR/ca-cert.pem" "$CA_DIR/ca-key.pem"

    # A failed scp is not fatal: it may simply mean the server has no CA yet
    scp -o ControlPath="$CONTROL_PATH" \
        "$SERVER_USER@$SERVER:$CERTS_DIR/ca-cert.pem" \
        "$SERVER_USER@$SERVER:$CERTS_DIR/ca-key.pem" \
        "$CA_DIR/" || true

    # Assignments are guarded with '|| VAR=$?' so that 'set -e'
    # does not terminate the script when openssl fails
    CERT_EXIT=0
    KEY_EXIT=0
    CERT_PUB="$(openssl x509 -in "$CA_DIR/ca-cert.pem" -pubkey -noout 2>/dev/null)" || CERT_EXIT=$?
    KEY_PUB="$(openssl pkey -in "$CA_DIR/ca-key.pem" -pubout 2>/dev/null)" || KEY_EXIT=$?

    CA_VALID=1
    CA_MATCH=1

    if [ "$CERT_EXIT" -ne 0 ] || [ "$KEY_EXIT" -ne 0 ]; then
        CA_VALID=0
    fi

    if [ "$CERT_PUB" != "$KEY_PUB" ]; then
        CA_MATCH=0
    fi

    if [ "$CA_VALID" -eq 1 ] && [ "$CA_MATCH" -eq 1 ]; then
        echo "[Client] Existing CA is valid, reusing it."
        break
    fi

    echo "[Client] Failed to fetch a valid CA (attempt $((RETRY_ATTEMPTS - ATTEMPTS_LEFT + 1)) of $RETRY_ATTEMPTS)"
    ATTEMPTS_LEFT=$((ATTEMPTS_LEFT - 1))
    if [ "$ATTEMPTS_LEFT" -gt 0 ]; then
        sleep 1
    fi
done

if [ "$CA_VALID" -eq 0 ]; then
    echo "[Client] WARNING: CA files are missing or corrupted; a new CA will be generated."
elif [ "$CA_MATCH" -eq 0 ]; then
    echo "[Client] WARNING: CA certificate and CA key do not match; a new CA will be generated."
fi

# STEP 1: Generate a new CA (only if the server has no usable one)
if [ "$CA_VALID" -eq 0 ] || [ "$CA_MATCH" -eq 0 ]; then
    echo "[Client] Generating a new CA..."
    echo "[Client] NOTE: all certificates issued by the previous CA become invalid."
    rm -rf "$CA_DIR"
    mkdir -p "$CA_DIR"
    cd "$CA_DIR"

    certtool --generate-privkey --outfile ca-key.pem 2>/dev/null

    cat > ca.tmpl <<EOF
cn = "OpenConnect Client CA"
organization = "My Network"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
EOF

    certtool --generate-self-signed \
        --load-privkey ca-key.pem \
        --template ca.tmpl \
        --outfile ca-cert.pem 2>/dev/null
fi

# STEP 2: Generate the client certificate
echo "[Client] Generating the client certificate..."
mkdir -p "$CLIENT_CERTS_DIR"
cd "$CLIENT_CERTS_DIR"

# Reuse an existing certificate only if both files exist and the
# certificate is signed by the current CA (after a CA change the old
# client certificate must be re-issued)
CERT_OK=0
if [ -f "${CLIENT_NAME}-cert.pem" ] && [ -f "${CLIENT_NAME}-key.pem" ]; then
    if openssl verify -CAfile "$CA_DIR/ca-cert.pem" "${CLIENT_NAME}-cert.pem" >/dev/null 2>&1; then
        CERT_OK=1
    fi
fi

if [ "$CERT_OK" -eq 1 ]; then
    echo "[Client] Existing client certificate is valid, reusing it."
else
    # Generate a new private key only if it does not exist yet
    if [ ! -f "${CLIENT_NAME}-key.pem" ]; then
        certtool --generate-privkey --outfile "${CLIENT_NAME}-key.pem" 2>/dev/null
    fi

    cat > "${CLIENT_NAME}.tmpl" <<EOF
cn = "${CLIENT_NAME}"
unit = "servers"
expiration_days = 3650
tls_www_client
signing_key
encryption_key
EOF

    certtool --generate-request \
        --load-privkey "${CLIENT_NAME}-key.pem" \
        --template "${CLIENT_NAME}.tmpl" \
        --outfile "${CLIENT_NAME}-request.pem" 2>/dev/null

    certtool --generate-certificate \
        --load-ca-certificate "$CA_DIR/ca-cert.pem" \
        --load-ca-privkey "$CA_DIR/ca-key.pem" \
        --load-request "${CLIENT_NAME}-request.pem" \
        --template "${CLIENT_NAME}.tmpl" \
        --outfile "${CLIENT_NAME}-cert.pem" 2>/dev/null
fi

# STEP 3: Configure the server (single SSH session)
echo "[Server] Configuring ocserv..."

if [ "$CA_VALID" -eq 0 ] || [ "$CA_MATCH" -eq 0 ]; then
    # The certs directory may not exist on a fresh server
    ssh -o ControlPath="$CONTROL_PATH" "$SERVER_USER@$SERVER" "mkdir -p $CERTS_DIR"
    scp -o ControlPath="$CONTROL_PATH" \
        "$CA_DIR/ca-cert.pem" "$CA_DIR/ca-key.pem" \
        "$SERVER_USER@$SERVER:$CERTS_DIR/"
fi

ssh -o ControlPath="$CONTROL_PATH" "$SERVER_USER@$SERVER" "
  set -e

  if [ ! -f $OCSERV_CONF ]; then
      echo 'ERROR: $OCSERV_CONF not found on the server' >&2
      exit 1
  fi

  # Keep a one-time backup of the original config
  [ -f $OCSERV_CONF.bak ] || cp $OCSERV_CONF $OCSERV_CONF.bak

  chown root:root $CERTS_DIR/ca-cert.pem $CERTS_DIR/ca-key.pem
  chmod 600 $CERTS_DIR/ca-key.pem

  # Drop the old auth-related directives and append the new ones
  grep -vE '^[[:space:]]*(auth|ca-cert|cert-user-oid)[[:space:]]*=' $OCSERV_CONF > $OCSERV_CONF.new
  echo 'auth = \"certificate\"' >> $OCSERV_CONF.new
  echo 'ca-cert = $CERTS_DIR/ca-cert.pem' >> $OCSERV_CONF.new
  # cert-user-oid is required for certificate authentication (2.5.4.3 = commonName)
  echo 'cert-user-oid = 2.5.4.3' >> $OCSERV_CONF.new
  mv $OCSERV_CONF.new $OCSERV_CONF

  systemctl restart ocserv
  echo '[Server] ocserv restarted.'
"

# DONE
echo ""
echo "All done!"
echo ""
echo "Client-side files:"
echo "  CA:                 $CA_DIR/ca-cert.pem"
echo "  Client certificate: $CLIENT_CERTS_DIR/${CLIENT_NAME}-cert.pem"
echo "  Client key:         $CLIENT_CERTS_DIR/${CLIENT_NAME}-key.pem"
echo ""
echo "Connection command:"
echo "openconnect --protocol=anyconnect \\"
echo "  --certificate=\"$CLIENT_CERTS_DIR/${CLIENT_NAME}-cert.pem\" \\"
echo "  --sslkey=\"$CLIENT_CERTS_DIR/${CLIENT_NAME}-key.pem\" \\"
echo "  --cafile=\"$CA_DIR/ca-cert.pem\" \\"
echo "  https://$SERVER:4443"
