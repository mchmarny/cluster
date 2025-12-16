# GPU Operator Runtime Dependencies

```mermaid
flowchart LR
  %% =========================================================
  %% GPU Operator Runtime Dependency Graph (with DRA + IMEX)
  %% =========================================================

  %% -------------------------
  %% Kubernetes prerequisites
  %% -------------------------
  subgraph K8S["Kubernetes cluster prerequisites"]
    API["Kubernetes API server / etcd"]
    CTRL["Controllers (deploy, ds, rs, jobs, crd, etc.)"]
    SCH["Scheduler"]
    RBAC["RBAC: ClusterRoles/Bindings + ServiceAccounts"]
    CRD["CRDs supported/allowed"]
    DS["DaemonSet support"]
    PRIV["Privileged pods allowed"]
    HOSTM["HostPath mounts allowed (/dev, /proc, /sys, /lib/modules, /usr, etc.)"]
    PSPA["Policy controls (PSA/PSP/OPA) allow required perms"]
    NETPOL["Network policies (if used) allow image pulls / node comms"]
    DRAAPI["Kubernetes Dynamic Resource Allocation APIs (if using DRA)"]
  end

  %% -------------------------
  %% Node prerequisites
  %% -------------------------
  subgraph NODES["GPU node prerequisites"]
    GPUHW["NVIDIA GPU hardware present"]
    BIOS["Platform/firmware supports GPU mode (as applicable)"]
    OSK["Linux OS + kernel"]
    KMOD["Kernel module build capability (if driver built on node)"]
    RUNTIME["Container runtime (containerd/CRI-O/etc.)"]
    CNI["CNI networking functional"]
    DNS["DNS resolution functional"]
    TIME["Time sync (NTP/chrony) sane"]
    DISK["Disk space for driver/toolkit artifacts"]
    PULL["Registry/network access to pull images"]
  end

  %% -------------------------
  %% GPU Operator control plane
  %% -------------------------
  subgraph OP["Operator control plane"]
    GPUOP["GPU Operator (controller)"]
    VAL["Operator validator / preflight checks"]
  end

  %% -------------------------
  %% Discovery / node labeling
  %% -------------------------
  subgraph DISC["Discovery / node labeling"]
    NFD["Node Feature Discovery (NFD)"]
    GFD["GPU Feature Discovery (GFD)"]
    LABELS["Node labels/taints used for scheduling & placement"]
  end

  %% -------------------------
  %% Classic GPU allocation path
  %% -------------------------
  subgraph CLASSIC["Classic GPU allocation path (device plugin)"]
    DRV["NVIDIA GPU Driver (container-installed OR pre-installed)"]
    TOOLKIT["NVIDIA Container Toolkit / runtime integration"]
    DEVPLUG["NVIDIA Kubernetes Device Plugin"]
    MIGM["MIG Manager (optional)"]
    VGPU["vGPU Manager (optional)"]
  end

  %% -------------------------
  %% DRA allocation path (optional)
  %% -------------------------
  subgraph DRA["DRA allocation path (optional)"]
    DRADRV["NVIDIA DRA Driver for GPUs"]
    DRANODE["DRA kubelet plugin(s) on nodes"]
    DRACONT["DRA controller components (cluster-side)"]
    DRAOBJ["DRA objects (ResourceClaims / Parameters / Classes)"]
    CD["ComputeDomain subsystem (MNNVL / multi-node NVLink) (optional)"]
  end

  %% -------------------------
  %% IMEX (optional, host/system-level)
  %% -------------------------
  subgraph IMEX["IMEX (optional, for ComputeDomains/MNNVL flows)"]
    IMEXP["IMEX host packages (nvidia-imex-*)"]
    IMEXD["IMEX daemon (nvidia-imex systemd service)"]
    IMEXCH["IMEX channels / topology coordination (conceptual)"]
  end

  %% -------------------------
  %% Observability (optional)
  %% -------------------------
  subgraph OBS["Observability (optional)"]
    DCGM["DCGM (GPU telemetry/health)"]
    DCGMEXP["DCGM Exporter (Prometheus metrics)"]
    PROM["Prometheus / scraper (external)"]
    DASH["Dashboards / alerts (external)"]
  end

  %% -------------------------
  %% Consumers
  %% -------------------------
  subgraph CONS["Consumers"]
    PODS["GPU workloads (Pods)"]
    SCHEDHINTS["Scheduling constraints (requests/limits, node selectors, affinity)"]
  end

  %% =========================================================
  %% Edges: Kubernetes prereqs -> Operator
  %% =========================================================
  API --> GPUOP
  CTRL --> GPUOP
  SCH --> GPUOP
  RBAC --> GPUOP
  CRD --> GPUOP
  DS --> GPUOP
  PRIV --> GPUOP
  HOSTM --> GPUOP
  PSPA --> GPUOP
  NETPOL --> GPUOP

  %% =========================================================
  %% Edges: Node prereqs -> Validator
  %% =========================================================
  GPUHW --> VAL
  BIOS --> VAL
  OSK --> VAL
  KMOD --> VAL
  RUNTIME --> VAL
  CNI --> VAL
  DNS --> VAL
  TIME --> VAL
  DISK --> VAL
  PULL --> VAL

  %% Validator informs Operator reconciliation
  VAL --> GPUOP

  %% =========================================================
  %% Edges: Operator -> Discovery
  %% =========================================================
  GPUOP --> NFD
  GPUOP --> GFD
  NFD --> LABELS
  GFD --> LABELS
  LABELS --> SCHEDHINTS

  %% =========================================================
  %% Edges: Operator -> Classic path
  %% =========================================================
  GPUOP --> DRV
  GPUOP --> TOOLKIT
  GPUOP --> DEVPLUG

  %% Classic chain
  DRV --> TOOLKIT
  TOOLKIT --> DEVPLUG

  %% Optional classic features
  GPUOP --> MIGM
  MIGM --> DEVPLUG
  GPUOP --> VGPU
  VGPU --> DEVPLUG

  %% Workloads via classic path
  DEVPLUG --> PODS
  TOOLKIT --> PODS
  DRV --> PODS
  SCHEDHINTS --> PODS

  %% =========================================================
  %% Edges: Operator -> Observability
  %% =========================================================
  GPUOP --> DCGM
  DRV --> DCGM
  DCGM --> DCGMEXP
  DCGMEXP --> PROM
  PROM --> DASH

  %% =========================================================
  %% Edges: DRA path
  %% =========================================================
  %% DRA requires cluster DRA APIs
  DRAAPI --> DRADRV

  %% Operator manages NVIDIA DRA driver components
  GPUOP --> DRADRV
  DRADRV --> DRANODE
  DRADRV --> DRACONT

  %% DRA objects used by workloads
  DRACONT --> DRAOBJ
  DRANODE --> DRAOBJ
  DRAOBJ --> PODS

  %% ComputeDomains (optional subsystem) as part of DRA/MNNVL flows
  DRADRV --> CD
  CD --> PODS

  %% =========================================================
  %% Edges: IMEX path (optional)
  %% =========================================================
  %% IMEX is typically host/system-level and feeds ComputeDomain workflows
  IMEXP --> IMEXD
  IMEXD --> IMEXCH
  IMEXCH --> CD
  ```