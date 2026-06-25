#!/bin/bash
# Generate SSH key if not exists
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEY_DIR="${PROJECT_ROOT}/.ssh"
KEY_FILE="${KEY_DIR}/id_rsa"

mkdir -p "$KEY_DIR"

if [[ -f "$KEY_FILE" ]]; then
    echo "SSH key already exists at $KEY_FILE"
else
    echo "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "kubernetes@agk"
    chmod 600 "$KEY_FILE"
    chmod 644 "${KEY_FILE}.pub"
    echo "SSH key generated successfully"
fi

# Print public key
echo ""
echo "Public key:"
cat "${KEY_FILE}.pub"
