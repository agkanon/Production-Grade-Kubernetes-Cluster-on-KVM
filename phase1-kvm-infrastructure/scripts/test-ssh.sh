#!/bin/bash
# Test SSH connectivity to all VMs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VMS=(
    "ubuntu@192.168.1.10:cp-01"
    "ubuntu@192.168.1.20:w-01"
    "ubuntu@192.168.1.30:w-02"
    "ubuntu@192.168.1.40:nfs-01"
    "ubuntu@192.168.1.50:lb-01"
    "ubuntu@192.168.1.60:db-01"
)

KEY_FILE="${PROJECT_ROOT}/.ssh/id_rsa"

echo "Testing SSH connectivity..."
echo ""

for vm in "${VMS[@]}"; do
    addr=$(echo "$vm" | cut -d: -f1)
    name=$(echo "$vm" | cut -d: -f2)
    
    echo -n "Testing $name ($addr)... "
    if ssh -i "$KEY_FILE" -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "$addr" "echo 'OK'" &> /dev/null; then
        echo "✓ Connected"
    else
        echo "✗ Failed"
    fi
done
