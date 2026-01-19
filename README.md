# Knative Operator Air-Gapped Installation

Automated installation of **Knative Operator** for air-gapped environments. The Knative Operator manages the lifecycle of Knative Serving (with Kourier ingress) on your cluster.

This toolkit is designed for use with NVIDIA Run:ai inference workloads.

## Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| **Knative Operator** | 1.18.0 | Supported by most Run:ai versions ([see docs](https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/system-requirements#inference)) |
| **Envoy** | v1.31.2 | Compatible with Kourier in Knative 1.18 |
| **Kubernetes** | Vanilla K8s | Tested on vanilla Kubernetes |

> **Note**: Support for newer Knative versions will come soon.

> **OpenShift**: OCP installations require the Red Hat Serverless Operator, which uses a different approach. Support for OCP will be added to this repo in the future.

## Quick Start

### 1. Prepare Bundle (Connected Host)

On a host with internet access, first clone this repository:

```bash
git clone https://github.com/runai-professional-services/knative-airgapped.git
cd knative-airgapped

./prepare.sh
```

> **Important**: The script must run from the repository directory as it copies template files from `templates/`.

This will:
- Download the Knative Operator Helm chart
- Pull all required container images (for target cluster architecture)
- Create a transferable archive: `knative-airgapped-1.18.0.tar.gz`

### 2. Transfer

Copy `knative-airgapped-1.18.0.tar.gz` to your air-gapped environment.

### 3. Install (Air-Gapped Environment)

```bash
# Extract the bundle
tar -xzf knative-airgapped-1.18.0.tar.gz
cd knative-airgapped-1.18.0/

# Run the installer
./install.sh
```

The installer will prompt for:
- Container tool (docker/podman) — auto-detected if only one is installed
- Private registry URL
- Registry credentials (for Kubernetes image pull secrets)

For non-interactive installation, set environment variables:

```bash
export CONTAINER_CMD=docker
export PRIVATE_REGISTRY_URL=registry.example.com
export PRIVATE_REGISTRY_USERNAME=admin
export PRIVATE_REGISTRY_PASSWORD=secret
./install.sh
```

It will then automatically:
1. Log in to your private registry
2. Load and push images to your private registry
3. Install Knative Operator via Helm
4. Deploy KnativeServing CR
5. Configure image pull secrets
6. Verify the installation

### 4. Configure Run:ai Registry Credentials (Required for Inference)

> **Important**: Knative injects a `queue-proxy` sidecar container into every inference workload pod. This image must be pullable from your private registry by pods in **any namespace**.

Run:ai provides a built-in solution for this via **Workload Credentials**:

1. Go to **Run:ai UI → Workload Manager → Credentials**
2. Click **+NEW CREDENTIAL** → Select **Docker registry**
3. Configure:
   - **Scope**: Select your **Cluster** (cluster-wide scope)
   - **Name**: `knative-registry` (or any descriptive name)
   - **New secret**: Enter your registry URL, username, and password
4. Click **CREATE CREDENTIAL**

This ensures that **all inference workloads** across all projects/namespaces can pull the `queue-proxy` image from your private registry.

📖 See: [Run:ai Credentials Documentation](https://run-ai-docs.nvidia.com/self-hosted/workloads-in-nvidia-run-ai/assets/credentials#docker-registry)

## Prerequisites

### Connected Host
- `podman` or `docker` CLI
- `helm` CLI (v3.14+)
- `git` CLI
- Internet access
- (Optional) `kubectl` access to target cluster for architecture auto-detection

### Air-Gapped Environment
- `podman` or `docker` CLI
- `helm` CLI (v3.14+)
- `kubectl` CLI configured to access your cluster
- Access to a private container registry

## What's Included

### Container Images

| Component | Images |
|-----------|--------|
| Knative Operator | `operator`, `operator-webhook` |
| Knative Serving | `activator`, `autoscaler`, `controller`, `webhook`, `queue` |
| Kourier Ingress | `kourier`, `envoy` |
| Post-install Jobs | `migrate`, `cleanup` |
| Optional | `autoscaler-hpa` |

### Bundle Contents

```
knative-airgapped-1.18.0/
├── install.sh                      # Installation script
├── knative-operator-v1.18.0.tgz    # Helm chart
├── knative-images.tar              # Container images
├── knative-serving.yaml.tpl        # KnativeServing template
├── VERSION                         # Knative version
└── ENVOY_VERSION                   # Envoy version
```

## Troubleshooting

```bash
# Check operator status
kubectl get pods -n knative-operator

# Check serving status
kubectl get pods -n knative-serving
kubectl get knativeserving -n knative-serving

# The installer is idempotent - safe to re-run
./install.sh
```

## References

- [Run:ai Inference System Requirements](https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/system-requirements#inference)
- [Run:ai Workload Credentials](https://run-ai-docs.nvidia.com/self-hosted/workloads-in-nvidia-run-ai/assets/credentials#docker-registry)
- [Knative Operator Documentation](https://knative.dev/docs/install/operator/knative-with-operators/)
