# Knative Operator Air-Gapped Installation

Automated installation of **Knative Operator** for air-gapped environments. The Knative Operator manages the lifecycle of Knative Serving (with Kourier ingress) on your cluster.

This toolkit is designed for use with NVIDIA Run:ai inference workloads, but can be used for any air-gapped Knative Operator deployment.

## Quick Start

### 1. Prepare Bundle (Connected Host)

On a host with internet access:

```bash
./prepare.sh
```

This will:
- Download the Knative Operator Helm chart
- Pull all required container images
- Create a transferable archive: `knative-airgapped-1.18.0.tar.gz`

### 2. Transfer

Copy `knative-airgapped-1.18.0.tar.gz` to your air-gapped environment.

### 3. Install (Air-Gapped Environment)

```bash
# Extract the bundle
tar -xzf knative-airgapped-1.18.0.tar.gz
cd knative-airgapped-1.18.0/

# Log in to your private registry first
docker login <your-registry>   # or: podman login <your-registry>

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
1. Load and push images to your private registry
2. Install Knative Operator via Helm
3. Deploy KnativeServing CR
4. Configure image pull secrets
5. Verify the installation

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
- Internet access

### Air-Gapped Environment
- `podman` or `docker` CLI
- `helm` CLI (v3.14+)
- `kubectl` CLI configured to access your cluster
- Access to a private container registry
- Logged in to the private registry

## Configuration

### Knative Operator Version

Default version is **1.18.0**. To use a different version:

```bash
export KNATIVE_VERSION=1.17.0
./prepare.sh
```

### Timeouts

The installer waits for resources to be ready. Default timeouts:
- Operator: 300s
- Serving: 300s

Override with environment variables:

```bash
export OPERATOR_TIMEOUT=600s
export SERVING_TIMEOUT=600s
./install.sh
```

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

After running `prepare.sh`:

```
knative-airgapped-1.18.0.tar.gz
└── knative-airgapped-1.18.0/
    ├── install.sh                      # Installation script
    ├── knative-operator-1.18.0.tgz     # Helm chart
    ├── knative-images.tar              # Container images
    ├── knative-serving.yaml.tpl        # KnativeServing template
    ├── VERSION                         # Knative Operator version
    └── ENVOY_VERSION                   # Envoy version
```

## Troubleshooting

### Check Operator Status

```bash
kubectl get pods -n knative-operator
kubectl logs -n knative-operator -l app.kubernetes.io/name=knative-operator
```

### Check Serving Status

```bash
kubectl get pods -n knative-serving
kubectl get knativeserving -n knative-serving -o yaml
```

### Image Pull Errors

If pods fail with `ImagePullBackOff`:

1. Verify images are in your private registry
2. Check image pull secrets exist:
   ```bash
   kubectl get secrets -n knative-serving knative-registry-creds
   ```
3. Verify ServiceAccounts have the secret:
   ```bash
   kubectl get sa -n knative-serving -o yaml | grep imagePullSecrets
   ```

### Re-run Installation

The installer is idempotent - safe to run multiple times:

```bash
./install.sh
```

## References

- [Knative Operator Documentation](https://knative.dev/docs/install/operator/knative-with-operators/)
- [Run:ai Workload Credentials](https://run-ai-docs.nvidia.com/self-hosted/workloads-in-nvidia-run-ai/assets/credentials#docker-registry)
- [NVIDIA Run:ai System Requirements](https://docs.run.ai/latest/admin/runai-setup/cluster-setup/cluster-prerequisites/)
