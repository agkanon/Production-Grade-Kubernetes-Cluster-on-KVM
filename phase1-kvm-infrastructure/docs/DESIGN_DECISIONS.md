# Phase 1: KVM Infrastructure Setup - Design Decisions

## 1. Linux Distribution Selection: Ubuntu 24.04 LTS

### Decision
**Ubuntu 24.04 LTS** selected as the base operating system for all VMs.

### Rationale

| Criteria | Ubuntu 24.04 | CentOS 9 | Debian 12 |
|----------|--------------|----------|----------|
| LTS Support | 5 years (until Apr 2034) | 9 months | 5 years |
| Kubernetes Support | Excellent | Good | Good |
| Container Runtime | containerd, Docker | containerd, podman | containerd, Docker |
| Package Freshness | Balanced | Conservative | Conservative |
| Community Size | Very Large | Medium | Large |
| systemd Integration | Excellent | Good | Good |
| Cloud-init Support | Native | Native | Native |
| Enterprise Support | Available (Canonical) | Available (RHEL) | Community |

**Why Ubuntu 24.04 LTS?**
- 5-year LTS ensures stability in production (until 2034)
- Latest LTS with improved Kubernetes ecosystem support
- Excellent cloud-init integration for automation
- Large community for troubleshooting
- Regular security patches
- Balanced between stability and package freshness

## 2. Container Runtime: containerd

### Decision
**containerd** selected as the container runtime for all Kubernetes nodes.

### Rationale

| Aspect | containerd | Docker | CRI-O |
|--------|-----------|--------|-------|
| Kubernetes Support | Native CRI | Via cri-dockerd (deprecated) | Native CRI |
| Size | ~50MB | ~400MB | ~100MB |
| Performance | Excellent | Good (heavier) | Excellent |
| Security | Minimal attack surface | Larger daemon | Minimal |
| Resource Usage | Low | High | Medium |
| Maintenance | CNCF maintained | Docker Inc | Red Hat |
| Community | Growing | Established | Growing |

**Why containerd?**
- CNCF-maintained, industry standard
- Minimal resource footprint (critical for 4GB RAM VMs)
- Native Kubernetes CRI support (no deprecated bridges)
- Excellent security posture
- High performance for workloads
- Lower memory overhead than Docker daemon

### Configuration Details
- **systemd cgroup driver**: Ensures proper resource limiting
- **CRI plugin**: Enabled for Kubernetes kubelet integration
- **OCI runtimes**: runc for standard containers, gVisor available for sandboxing

## 3. Network Architecture: Three Isolated Networks

### Decision
Deploy three separate virtual networks:
- **Management Network** (192.168.1.0/24): Kubernetes control plane, API, management
- **Storage Network** (192.168.2.0/24): NFS traffic isolation
- **External Network** (192.168.100.0/24): Ingress traffic only

### Rationale

**Why separate networks?**
1. **Performance**: Storage I/O doesn't contend with API traffic
2. **Security**: Network-level isolation of traffic types
3. **Compliance**: Allows per-network firewall policies
4. **Scalability**: Easier to add high-speed storage networks later
5. **Troubleshooting**: Clear traffic boundaries simplify debugging

**Why not use VLANs?**
- KVM bridge-based networks are simpler for non-VLAN environments
- VLANs require physical switch support on host
- For this topology, bridges provide adequate isolation
- Could be upgraded to VLANs for shared host environments

**Why not use single network?**
- NFS traffic can saturate link
- Kubernetes API traffic needs predictable latency
- No network isolation between concerns
- Harder to debug multi-protocol issues

## 4. Storage Server: Dedicated NFS VM

### Decision
Deploy a dedicated NFS server on separate VM (`nfs-01`) with dedicated storage disk.

### Alternatives Considered

| Option | Pros | Cons | Selected |
|--------|------|------|----------|
| **NFS Server (Dedicated VM)** | Isolated, scalable, simple backup | Extra VM overhead | ✓ YES |
| Distributed Storage (Ceph/Longhorn) | Resilient, no single point of failure | Complex, higher overhead | No |
| In-cluster NFS via hostPath | Simple, no extra VM | All data lost on node failure | No |
| iSCSI on dedicated target | Good performance | More complex than NFS | No |

**Why NFS on dedicated VM?**
1. **Production-grade**: Proven, stable technology
2. **Simplicity**: Easy to configure and debug
3. **Compliance**: Meets basic HA requirements
4. **Scalability**: Can add redundancy later (HA-NFS)
5. **Operations**: Standard backup/restore procedures
6. **Cost**: Minimal overhead compared to distributed solutions

### Storage Disk Configuration
- **Type**: QCOW2 virtual disk (50GB)
- **Filesystem**: XFS (better for large files than ext4)
- **Mount Path**: `/nfs/kubernetes`
- **Exports**: Entire volume to cluster subnet with no_root_squash (required for Kubernetes)

### Future Enhancements
- Add secondary NFS server for HA (requires additional VM + heartbeat)
- Implement snapshot-based backups using LVM
- Add persistent storage monitoring via Prometheus

## 5. Load Balancer: HAProxy on Dedicated VM

### Decision
Deploy HAProxy on dedicated load balancer VM for ingress traffic.

### Rationale
- **Separation of concerns**: LB runs on separate VM, not on control plane
- **High availability**: Can add second LB with keepalived for redundancy
- **Flexibility**: Can route to multiple backend services
- **Performance**: HAProxy excellent for HTTP(S) routing
- **Simplicity**: Well-understood alternative to Kubernetes Gateway API for Phase 1

### Configuration
- **HAProxy Config**: `/etc/haproxy/haproxy.cfg`
- **Binding**: HTTP (80), HTTPS (443) on external interface
- **Backend Selection**: Round-robin by default
- **Logging**: Centralized to stdout for monitoring

### Phase 2 Integration
- HAProxy will proxy to Ingress controller (deployed on Kubernetes)
- Ingress controller runs on worker nodes
- Dynamic backend configuration via Kubernetes Ingress resources

## 6. VM Resource Allocation

### Decision
Asymmetric resource allocation based on workload:
- **Control Plane**: 4 CPU, 4GB RAM
- **Workers**: 4 CPU, 4GB RAM each
- **Storage**: 2 CPU, 2GB RAM
- **Load Balancer**: 2 CPU, 1GB RAM

### Rationale

| Node | CPU | RAM | Justification |
|------|-----|-----|---------------|
| Control Plane | 4 | 4GB | Runs etcd, API server, scheduler - high concurrency |
| Workers | 4 | 4GB | Runs application pods - needs headroom for containers |
| Storage | 2 | 2GB | NFS server - I/O bound, not CPU bound |
| Load Balancer | 2 | 1GB | HAProxy + keepalived - lightweight, low overhead |

**Why these allocations?**
1. **Production minimum**: 4 cores for control plane (industry standard)
2. **Worker sizing**: Match control plane (can be heterogeneous in prod)
3. **Over-provisioning**: 1:1 CPU-to-RAM ratio standard for Kubernetes
4. **Storage efficiency**: NFS more I/O than CPU bound
5. **LB simplicity**: HAProxy very lightweight

## 7. Kernel Parameters & System Tuning

### Decision
Apply standard Kubernetes kernel parameters via `/etc/sysctl.d/99-k8s.conf`

### Applied Parameters

```
net.bridge.bridge-nf-call-iptables=1      # Allow iptables through bridges
net.bridge.bridge-nf-call-ip6tables=1     # Same for IPv6
net.ipv4.ip_forward=1                      # Enable forwarding for pod networking
net.ipv4.tcp_slow_start_after_idle=0       # Improve TCP performance
fs.inotify.max_user_watches=524288         # Required for watch operations
fs.file-max=2097152                        # Support many open files
vm.max_map_count=262144                    # Support container volume mappings
```

### Rationale
- **bridge-nf-call-iptables**: Required for Cilium eBPF network policies
- **ip_forward**: Essential for container routing
- **tcp_slow_start_after_idle**: Improves API server responsiveness
- **inotify**: Prevents "no space left on device" errors for file watches
- **file-max**: Supports many containers with many file descriptors
- **max_map_count**: Required for container memory management

## 8. SSH Security Configuration

### Decision
Ed25519 keys only, password authentication disabled.

### Rationale
- **Ed25519**: Modern ECDSA-based, smaller keys, better security than RSA
- **Key-based only**: No password guessing attacks possible
- **Disabled root**: All operations via sudo with explicit commands logged
- **Automated key distribution**: Cloud-init handles key provisioning

## 9. High Availability Considerations

### Phase 1 (Current)
- Single control plane node (acceptable for development)
- Single storage server (documented backup strategy)
- Single load balancer

### Phase 2+ Roadmap
- Add second control plane node (etcd HA)
- Add second storage server (NFS failover)
- Add second load balancer with keepalived virtual IP

## 10. Security Posture Summary

### Network Level
- ✓ Traffic isolation between network planes
- ✓ No direct internet routing to cluster
- ✓ Load balancer as single entry point

### OS Level
- ✓ Key-based SSH only
- ✓ Root account disabled
- ✓ Automatic security updates
- ✓ UFW firewall (optional, can be enabled)

### Container Level
- ✓ containerd (minimal attack surface)
- ✓ Non-root container users enforced in Kubernetes manifests
- ✓ Pod Security Policies (Phase 2)

### Kubernetes Level
- ✓ RBAC enabled by default
- ✓ Network policies (Phase 2)
- ✓ Resource quotas (Phase 2)
- ✓ Secret encryption at rest (Phase 2)

## 11. Disaster Recovery Strategy

### Backup & Recovery
1. **Infrastructure**: Terraform state + `.deployment_output.json`
2. **Cluster state**: etcd backups (Phase 2)
3. **Application data**: NFS snapshots via LVM (Phase 4)
4. **Recovery time**: 15-30 minutes from backup

### RTO/RPO Targets
- **RTO** (Recovery Time Objective): 30 minutes to full cluster (see Phase 6 Runbooks 6.4 / 6.5)
- **RPO** (Recovery Point Objective): 24 hours — daily pg_dump CronJob at 02:00 UTC (Phase 4)

## 12. Monitoring & Observability

### Phase 1 Included
- VM status via `virsh`
- SSH connectivity tests
- Cloud-init logs on each VM

### Phase 2/4 Planned
- Prometheus for metrics
- Loki for centralized logging
- Grafana dashboards
- Alert manager for notifications
