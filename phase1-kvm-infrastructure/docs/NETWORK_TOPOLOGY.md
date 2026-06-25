# Phase 1: KVM Infrastructure Setup - Network Topology Documentation

## Network Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          KVM Hypervisor Host                            │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐    │
│  │   virbr1         │  │   virbr2         │  │   virbr3         │    │
│  │ Management       │  │ Storage          │  │ External         │    │
│  │ 192.168.1.0/24   │  │ 192.168.2.0/24   │  │ 192.168.100.0/24 │    │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘    │
│         │                      │                       │              │
│      ┌──┴──┬──┬──┬──┐      ┌──┴──┬──┬──┬──┐      ┌──────┴──┐        │
│      │     │  │  │  │      │     │  │  │  │      │         │        │
│   ┌──┴──┐┌─┴─┐│  │  │   ┌──┴──┐┌─┴─┐│  │  │   ┌──┴──┐    │        │
│   │eth0 ││eth1│  │  │   │eth0 ││eth1│  │  │   │eth0 │eth1│        │
│   └──┬──┘└─┬─┘  │  │   └──┬──┘└─┬─┘  │  │   └──┬──┘└───┘        │
│      │     │    │  │      │     │    │  │      │                  │
│  ┌───┴─────┴────┴──┴──┐ ┌──┴─────┴────┴──┴──┐  │                  │
│  │   cp-01            │ │   nfs-01           │  │                  │
│  │ Control Plane      │ │ Storage Server     │  │                  │
│  │ 192.168.1.10       │ │ 192.168.1.40       │  │                  │
│  │ (4CPU, 4GB RAM)    │ │ (2CPU, 2GB RAM)    │  │                  │
│  └────────────────────┘ │ +50GB Storage Disk │  │                  │
│                         └────────────────────┘  │                  │
│                                                 │                  │
│  ┌──────────────────┐  ┌──────────────────┐    │                  │
│  │   w-01           │  │   w-02           │    │                  │
│  │ Worker Node 1    │  │ Worker Node 2    │    │                  │
│  │ 192.168.1.20     │  │ 192.168.1.30     │    │                  │
│  │ (4CPU, 4GB RAM)  │  │ (4CPU, 4GB RAM)  │    │                  │
│  └──────────────────┘  └──────────────────┘    │                  │
│                                                 │                  │
│                                             ┌───┴───┐              │
│                                             │ lb-01 │              │
│                                             │  LB   │              │
│                                             │  192.168.1.50       │
│                                             │  192.168.100.10     │
│                                             │(2CPU, 1GB RAM)     │
│                                             └───────┘              │
└─────────────────────────────────────────────────────────────────────────┘
```

## Network Configuration Details

### Management Network (virbr1)
- **CIDR**: 192.168.1.0/24
- **Gateway**: 192.168.1.1
- **Purpose**: Kubernetes API, etcd, inter-node communication, SSH management
- **DNS**: 8.8.8.8, 8.8.4.4 (external)
- **Isolation**: Internal only, no external routing
- **Connected Nodes**: All VMs (primary interface)

### Storage Network (virbr2)
- **CIDR**: 192.168.2.0/24
- **Gateway**: 192.168.2.1
- **Purpose**: NFS traffic, storage operations, high-bandwidth data transfer
- **Isolation**: Dedicated path for storage I/O to reduce contention
- **Connected Nodes**: cp-01, w-01, w-02, nfs-01 (secondary interface)
- **MTU**: 1500 (standard)

### External Network (virbr3)
- **CIDR**: 192.168.100.0/24
- **Gateway**: 192.168.100.1
- **Purpose**: External traffic ingress to load balancer
- **Connected Nodes**: lb-01 only (secondary interface)

## VM Interface Mapping

| VM      | eth0 (Primary)    | eth1 (Secondary)  | eth2              | Role          |
|---------|-------------------|-------------------|-------------------|---------------|
| cp-01   | 192.168.1.10      | 192.168.2.10      | -                 | Control Plane |
| w-01    | 192.168.1.20      | 192.168.2.20      | -                 | Worker        |
| w-02    | 192.168.1.30      | 192.168.2.30      | -                 | Worker        |
| nfs-01  | 192.168.1.40      | 192.168.2.40      | -                 | NFS Storage   |
| lb-01   | 192.168.1.50      | 192.168.100.10    | -                 | Load Balancer |
| db-01   | 192.168.1.60      | 192.168.2.60      | -                 | Standalone DB (DR) |

## Traffic Flow Patterns

### Kubernetes API Traffic
- **Path**: Worker nodes → Control Plane (port 6443 over Management network)
- **Network**: Management (virbr1)
- **Security**: mTLS by default

### Storage Traffic (NFS)
- **Path**: Worker/Control nodes ↔ NFS Server (ports 111, 2049, 20048 over Storage network)
- **Network**: Storage (virbr2)
- **Security**: iptables rules restrict to Kubernetes cluster range

### Application Traffic
- **Path**: External clients → Load Balancer (80/443)
- **Network**: External (virbr3)
- **LB Routes**: 192.168.100.10 → Ingress controller on management network

### Inter-Pod Communication
- **Path**: Pod → Pod (via CNI overlay)
- **Network**: Pod network overlay (separate from VM networks)
- **Default**: Cilium eBPF overlay (kube-proxy replacement — chosen in Phase 2)

## Network Isolation & Security

### Layer 2 Isolation
- KVM bridges prevent ARP traffic between networks
- VLAN support available but not required for this deployment
- No inter-bridge communication by default

### Layer 3 Security
- iptables rules on each VM restrict cross-network traffic
- Storage network restricted to storage operations only
- External network isolated to load balancer only

### Firewall Rules (Per VM)

**Management Network**:
```
Accept:
  - SSH (22) from management network
  - Kubernetes API (6443) from management network
  - etcd (2379/2380) within control plane
  - kubelet (10250) within cluster
Block:
  - All NFS traffic (redirect to storage network)
  - External traffic
```

**Storage Network**:
```
Accept:
  - NFS (111, 2049, 20048) between Kubernetes nodes and storage
Block:
  - All other traffic
```

**External Network**:
```
Accept:
  - HTTP (80) to load balancer
  - HTTPS (443) to load balancer
Block:
  - SSH access
  - Direct API access
```

## IP Address Planning

### Management Network (192.168.1.0/24)
```
192.168.1.1     Gateway
192.168.1.10    cp-01 (Control Plane)
192.168.1.20    w-01 (Worker 1)
192.168.1.30    w-02 (Worker 2)
192.168.1.40    nfs-01 (NFS Storage)
192.168.1.50    lb-01 (Load Balancer)
192.168.1.60    db-01 (Standalone PostgreSQL 17 — DR target)
192.168.1.61-254 Reserved for future expansion
```

### Storage Network (192.168.2.0/24)
```
192.168.2.1     Gateway
192.168.2.10    cp-01
192.168.2.20    w-01
192.168.2.30    w-02
192.168.2.40    nfs-01
192.168.2.60    db-01
192.168.2.61-254 Reserved for future expansion
```

### External Network (192.168.100.0/24)
```
192.168.100.1   Gateway
192.168.100.10  lb-01
192.168.100.11-254 Reserved
```

## Service Discovery

### Internal DNS
- Kubernetes CoreDNS for service discovery
- Pod-to-pod via overlay network (ClusterIP)
- External DNS records for ingress endpoints

### Hostname Resolution
- Static entries in `/etc/hosts` for stability
- Kubernetes DNS for service names
- NFS server hostname: `nfs-01.kubernetes.local`

## Performance Considerations

### Network Optimization
1. **Separate storage network**: Reduces I/O contention
2. **Host-passthrough CPU mode**: Better network performance
3. **Virtio network interfaces**: Para-virtualized for efficiency
4. **Large receive offload (LRO)**: Enabled for bulk transfers

### Bottleneck Analysis
- KVM bridges handle ~40-50 Gbps (non-blocking)
- Host NIC is typical 1-10 Gbps
- Storage network can saturate at high I/O operations
- Recommendation: Monitor with iftop, netperf during load

## Disaster Recovery

### Network Backup
- Manual network documentation in this file
- Terraform state stores configuration
- Bridge configuration in netplan (persisted on host)

### Recovery Procedure
1. Redeploy VMs with `deploy-phase1.sh`
2. Networks auto-created by Terraform
3. Static IPs restored from cloud-init configs
4. DNS/service discovery reconfigures automatically
