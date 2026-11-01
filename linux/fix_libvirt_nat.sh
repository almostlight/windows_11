#!/bin/bash
# Fix NAT/routing for libvirt virtual networks

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# lukasz ALL=(root) NOPASSWD: /usr/bin/virsh -c qemu:///system
# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    # exit 1
fi

# Determine which interface to use
TARGET_IFACE="${1:-}"
if [[ -z "$TARGET_IFACE" ]]; then
    # Try to find default route interface
    TARGET_IFACE=$(ip route show default | awk '{print $5}' | head -1)
    if [[ -z "$TARGET_IFACE" ]]; then
        log_error "Could not determine default interface. Please specify manually."
        echo "Usage: $0 <interface>"
        echo "Available interfaces:"
        ip -br link show | awk '{print "  " $1}'
        exit 1
    fi
    log_info "Using default interface: $TARGET_IFACE"
fi

# Verify interface exists
if ! ip link show "$TARGET_IFACE" &>/dev/null; then
    log_error "Interface $TARGET_IFACE does not exist"
    echo "Available interfaces:"
    ip -br link show | awk '{print "  " $1}'
    exit 1
fi

# Check current libvirt networks
log_info "Checking libvirt networks..."
LIBVIRT_NETS=$(virsh -c qemu:///system net-list --name 2>/dev/null || echo "")

if [[ -z "$LIBVIRT_NETS" ]]; then
    log_warn "No active libvirt networks found"
    
    # Check if default network exists but is inactive
    if virsh -c qemu:///system net-list --all | grep -q "default.*inactive"; then
        log_info "Starting default libvirt network..."
        virsh -c qemu:///system net-start default
        virsh -c qemu:///system net-autostart default
        LIBVIRT_NETS="default"
    else
        log_info "Creating default NAT network..."
        virsh -c qemu:///system net-define /dev/stdin <<EOF
<network>
  <name>default</name>
  <forward mode='nat'>
    <interface dev='$TARGET_IFACE'/>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
        virsh -c qemu:///system net-start default
        virsh -c qemu:///system net-autostart default
        LIBVIRT_NETS="default"
    fi
fi

# Function to check if sudo iptables has NAT rule for subnet
check_nat_for_subnet() {
    local subnet=$1
    if command -v sudo iptables &>/dev/null; then
        sudo iptables -t nat -L -n 2>/dev/null | grep -q "$subnet"
    elif command -v nft &>/dev/null; then
        nft list ruleset 2>/dev/null | grep -q "$subnet"
    else
        log_error "Neither sudo iptables nor nft found"
        return 1
    fi
}

# Function to add NAT rules for subnet
add_nat_for_subnet() {
    local subnet=$1
    local iface=$2
    
    log_info "Adding NAT rules for $subnet via $iface..."
    
    if command -v sudo iptables &>/dev/null; then
        # Check if rule already exists
        if ! sudo iptables -t nat -C POSTROUTING -s "$subnet" -j MASQUERADE 2>/dev/null; then
            sudo iptables -t nat -A POSTROUTING -s "$subnet" -j MASQUERADE
            log_success "Added sudo iptables NAT rule"
        else
            log_info "NAT rule already exists in sudo iptables"
        fi
        
        # Add forward rules if needed
        if ! sudo iptables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null; then
            sudo iptables -I FORWARD 1 -s "$subnet" -j ACCEPT
            sudo iptables -I FORWARD 1 -d "$subnet" -j ACCEPT
            log_success "Added sudo iptables FORWARD rules"
        fi
    elif command -v nft &>/dev/null; then
        log_warn "nftables support is basic - you may need to configure manually"
        # Basic nftables check - for advanced setup, manual configuration needed
        if ! nft list ruleset 2>/dev/null | grep -q "$subnet"; then
            log_info "Consider adding nftables rule:"
            echo "  nft add rule ip nat POSTROUTING oif $iface masquerade"
        fi
    fi
}

# Function to get subnet from libvirt network
get_network_subnet() {
    local net_name=$1
    virsh -c qemu:///system net-dumpxml "$net_name" 2>/dev/null | \
        grep -oP "ip address='\K[0-9.]+" | head -1
}

# Process each libvirt network
for NET in $LIBVIRT_NETS; do
    log_info "Processing network: $NET"
    
    # Get network info
    NET_INFO=$(virsh -c qemu:///system net-info "$NET" 2>/dev/null || true)
    if [[ -z "$NET_INFO" ]]; then
        log_warn "Could not get info for network $NET"
        continue
    fi
    
    # Check if it's a NAT network
    if echo "$NET_INFO" | grep -q "Persistent:.*yes"; then
        # Get subnet
        SUBNET_IP=$(get_network_subnet "$NET")
        if [[ -n "$SUBNET_IP" ]]; then
            # Convert to CIDR (assuming /24 for simplicity)
            # For more accuracy, parse the netmask from XML
            SUBNET_CIDR="${SUBNET_IP%.*}.0/24"
            
            log_info "Network $NET uses subnet: $SUBNET_CIDR"
            
            # Check and add NAT if needed
            if ! check_nat_for_subnet "$SUBNET_CIDR"; then
                add_nat_for_subnet "$SUBNET_CIDR" "$TARGET_IFACE"
            else
                log_info "NAT rules already present for $SUBNET_CIDR"
            fi
        fi
    fi
done

# Ensure IP forwarding is enabled
if [[ $(sysctl -n net.ipv4.ip_forward) -eq 0 ]]; then
    log_info "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    log_success "IP forwarding enabled permanently"
else
    log_info "IP forwarding is already enabled"
fi

# Check dnsmasq
if ! pgrep -x dnsmasq >/dev/null; then
    log_warn "dnsmasq not running - DNS may not work for VMs"
    log_info "Consider starting libvirtd: systemctl restart libvirtd"
fi

# Summary
log_success "Configuration complete!"
echo ""
echo "Summary:"
echo "  - Target interface: $TARGET_IFACE"
echo "  - IP forwarding: $(sysctl -n net.ipv4.ip_forward)"
echo "  - Active libvirt networks: $(echo $LIBVIRT_NETS | tr '\n' ' ')"
echo ""
echo "Current NAT rules:"
if command -v sudo iptables &>/dev/null; then
    sudo iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "(MASQUERADE|192\.168)"
elif command -v nft &>/dev/null; then
    nft list ruleset 2>/dev/null | grep -A5 -B5 "nat"
fi

