#!/bin/bash
# bak2restic.sh
#
# Self-contained VM backup script using restic + Btrfs CoW
#
# Features:
# - Automatic restic installation if missing
# - Interactive password setup on first run
# - Password stored alongside repository (restic-repo.txt)
# - Full error handling with ddrescue fallback
# - No external dependencies except standard Linux tools
#
# Usage:
# 1. Copy this script to your system
# 2. Make it executable: chmod +x bak2restic.sh
# 3. Run manually first time (will prompt for password)
# 4. Add to cron: 0 2 * * * /path/to/bak2restic.sh
#
# Recovery commands:
#   restic snapshots --repo /mnt/bak/restic-repo --password-file /mnt/bak/restic-repo.txt
#   restic mount --repo /mnt/bak/restic-repo --password-file /mnt/bak/restic-repo.txt /mnt/restic
#   restic restore --repo /mnt/bak/restic-repo --password-file /mnt/bak/restic-repo.txt latest --target /tmp/restore

set -e

# Configuration
SOURCE="/var/lib/libvirt/images"
BAK_SUBDIR="bak"
BAK_DIR="${SOURCE}/${BAK_SUBDIR}"
REPO="/mnt/bak/restic-repo"
PASSWORD_FILE="/mnt/bak/restic-repo.txt"
RECOVER_DIR="/mnt/bak/recover"
ERROR_LIST="/tmp/restic_errors_$$.log"
COW_ERROR_LIST="/tmp/cow_errors_$$.log"
CORRUPTED_LIST="/tmp/corrupted_files_$$.log"

# Cleanup function
cleanup() {
    rm -f "${ERROR_LIST}" "${CORRUPTED_LIST}"
    if [ -d "${BAK_DIR}" ]; then
        rm -rf "${BAK_DIR}"
    fi
}

trap cleanup EXIT

# Install restic if not present
install_restic() {
    if command -v restic >/dev/null 2>&1; then
        return 0
    fi

    echo " * Installing restic..."

    # Try apt first
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y restic
        return 0
    fi

    # Fallback to binary download
    echo " * Downloading restic binary..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)
            echo " * Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    LATEST_VERSION=$(curl -s https://api.github.com/repos/restic/restic/releases/latest | grep tag_name | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        echo " * Could not determine latest restic version"
        exit 1
    fi

    URL="https://github.com/restic/restic/releases/download/${LATEST_VERSION}/restic_${LATEST_VERSION#v}_linux_${ARCH}.bz2"
    curl -L "$URL" | bunzip2 > /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
}

# Setup password file with interactive input
setup_password_file() {
    if [ -f "${PASSWORD_FILE}" ]; then
        return 0
    fi

    echo " * Setting up restic repository password"
    echo "This password will be stored in: ${PASSWORD_FILE}"
    echo ""

    while true; do
        echo -n "Enter password: "
        read -s password1
        echo

        echo -n "Confirm password: "
        read -s password2
        echo

        if [ "$password1" = "$password2" ] && [ -n "$password1" ]; then
            break
        else
            echo " * Passwords don't match or are empty. Try again."
        fi
    done

    # Create password file with usage instructions
    cat > "${PASSWORD_FILE}" << EOF
# Restic repository password file
#
# This file contains the password for the restic repository at:
# ${REPO}
#
# To use this repository manually, use commands like:
#   restic snapshots --repo ${REPO} --password-file ${PASSWORD_FILE}
#   restic mount --repo ${REPO} --password-file ${PASSWORD_FILE} /mnt/restic
#   restic restore --repo ${REPO} --password-file ${PASSWORD_FILE} latest --target /tmp/restore
#
# Backup script: $(basename "$0")
# Repository location: ${REPO}

$password1
EOF

    chmod 600 "${PASSWORD_FILE}"
    echo " * Password file created: ${PASSWORD_FILE}"
}

# Initialize restic repository
init_restic_repo() {
    if [ -d "${REPO}" ] && [ -f "${REPO}/config" ]; then
        return 0
    fi

    echo " * Initializing restic repository at: ${REPO}"
    mkdir -p "${REPO}"

    # Wait a moment to ensure filesystem is ready
    sleep 2

    restic init --repo "${REPO}" --password-file "${PASSWORD_FILE}"
    echo " * Restic repository initialized!"
}

# Create CoW snapshot
create_cow_snapshot() {
    echo " * Creating CoW snapshot of VM images..."
    mkdir -p "${BAK_DIR}"
    : >"${COW_ERROR_LIST}"

    # Copy everything recursively with CoW
    find "${SOURCE}" -mindepth 1 -maxdepth 1 ! -name "${BAK_SUBDIR}" -exec sh -c '
        _SRCDIR="$1"
        _BAKSUBDIR="$2"
        _ERRLIST="$3"
        shift 3
        for f in "$@"; do
            chattr -C "$f" 2>/dev/null || true
            cp --reflink=auto -rf "$f" "${_SRCDIR}/${_BAKSUBDIR}/" 2>>"${_ERRLIST}"
        done
    ' _ "${SOURCE}" "${BAK_SUBDIR}" "${COW_ERROR_LIST}" {} +

    if [ $(wc -l 2>/dev/null <"${COW_ERROR_LIST}" || echo 0) -ne 0 ]; then
        echo " ! CoW copy completed with errors:"
        cat "${COW_ERROR_LIST}"
    fi

    # Remove bak directory from snapshot if it exists
    if [ -d "${BAK_DIR}/${BAK_SUBDIR}" ]; then
        rm -rf "${BAK_DIR}/${BAK_SUBDIR}"
    fi

    echo " * CoW snapshot created at: ${BAK_DIR}"
}

# Check if file is readable
check_file_readable() {
    local file="$1"
    if ! cp "$file" /dev/null 2>/dev/null; then
        return 1
    fi
    return 0
}

# Find corrupted files after partial backup
find_corrupted_files() {
    echo " * Finding corrupted files in snapshot..."
    > "${CORRUPTED_LIST}"

    find "${BAK_DIR}" -type f | while read -r file; do
        if ! check_file_readable "$file"; then
            rel_path="${file#${BAK_DIR}/}"
            echo "$rel_path" >> "${CORRUPTED_LIST}"
            echo " ! Corrupted file: $rel_path"
        fi
    done
}

# Recover corrupted files
recover_corrupted_files() {
    if [ ! -s "${CORRUPTED_LIST}" ]; then
        return 0
    fi

    echo " * Recovering corrupted files..."
    mkdir -p "${RECOVER_DIR}"

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue

        src_file="${SOURCE}/$rel_path"
        recover_file="${RECOVER_DIR}/$rel_path"

        if [ ! -f "$src_file" ]; then
            echo " ! Source file not found: $src_file"
            continue
        fi

        echo " * Recovering: $rel_path"
        mkdir -p "$(dirname "$recover_file")"

        mapfile="/tmp/ddrescue_$(basename "$rel_path").map"
        if ddrescue "$src_file" "$recover_file" "$mapfile"; then
            echo " * Recovered: $rel_path"
        else
            echo " ! Failed to recover: $rel_path"
        fi
        rm -f "$mapfile"

    done < "${CORRUPTED_LIST}"
}

# Backup recovered files
backup_recovered_files() {
    if [ ! -d "${RECOVER_DIR}" ] || [ -z "$(ls -A "${RECOVER_DIR}" 2>/dev/null)" ]; then
        return 0
    fi

    echo " * Backing up recovered files..."
    restic backup --repo "${REPO}" \
        --password-file "${PASSWORD_FILE}" \
        --verbose \
        --compression max \
        --verbose \
        "${RECOVER_DIR}"

    rm -rf "${RECOVER_DIR}"
}

# Main backup function
perform_backup() {
    echo " * Starting restic backup..."

    if restic backup --repo "${REPO}" \
        --password-file "${PASSWORD_FILE}" \
        --verbose \
        --compression max \
        --verbose \
        "${BAK_DIR}" 2>"${ERROR_LIST}"; then

        echo " * Full backup completed successfully!"
        return 0
    else
        echo " ! Backup completed with errors, checking for corrupted files..."
        find_corrupted_files
        recover_corrupted_files
        backup_recovered_files
        return 1
    fi
}

# Other dirs and files backup
addition_backup() {
    echo " * Continuing restic backup..."
    restic backup --repo "${REPO}" \
        --password-file "${PASSWORD_FILE}" \
        --verbose \
        --compression max \
        --verbose \
        --exclude "${SOURCE}" \
        --exclude "/var/lock" \
        --exclude "/var/run" \
        --exclude "/var/tmp" \
        --exclude "/var/cache" \
        --exclude "/var/log" \
        --exclude "/var/lib/systemd" \
        /etc /home /opt /root /srv /usr/local /var 2>>"${ERROR_LIST}"
}

# Cleanup old backups
cleanup_old_backups() {
    echo " * Cleaning up old backups..."
    restic forget --group-by "" \
        --repo "${REPO}" \
        --password-file "${PASSWORD_FILE}" \
        --keep-last 10 \
        --prune
#        --keep-daily 7 \
#        --keep-weekly 4 \
#        --keep-monthly 12 \
}

# Main execution
main() {
    echo " * Starting VM backup process..."
    echo "Source: ${SOURCE}"
    echo "Repository: ${REPO}"
    echo ""

    # Ensure dependencies
    install_restic

    # Setup password and repository
    setup_password_file
    init_restic_repo

    # Create snapshot
    create_cow_snapshot

    # Perform backup
    perform_backup
    addition_backup

    # Cleanup
    cleanup_old_backups

    echo ""
    echo " * Backup process completed successfully!"
    echo "Repository location: ${REPO}"
    echo "Password file: ${PASSWORD_FILE}"
}

# Run main function
main
