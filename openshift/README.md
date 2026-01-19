# Red Hat Serverless Operator - Air-Gapped Installation

This directory contains tooling for installing the **Red Hat Serverless Operator** in air-gapped **OpenShift** environments using the `oc-mirror` plugin.

> **Note:** This is separate from the main Knative Operator installation in the parent directory. Use this for OpenShift environments where you want to install Knative via the Red Hat Serverless Operator from OperatorHub.

## Overview

The Red Hat Serverless Operator is the officially supported way to run Knative on OpenShift. In air-gapped environments, it must be mirrored from the Red Hat registry to your private registry using `oc-mirror`.

## Quick Start

### 1. Prepare Bundle (Connected Host)

```bash
./prepare-serverless.sh
```

This will:
- Install `oc-mirror` plugin (if not present)
- Create an ImageSetConfiguration
- Mirror the Serverless Operator and all container images
- Create a transferable bundle directory

### 2. Transfer

Copy the generated `serverless-airgapped/` directory to your air-gapped environment.

### 3. Install (Air-Gapped Environment)

```bash
cd serverless-airgapped/
./install-serverless.sh
```

This will:
- Push images to your private registry
- Apply ImageContentSourcePolicy/ImageDigestMirrorSet
- Create CatalogSource for OperatorHub
- Verify the operator is available

Then install the operator from OperatorHub in the OpenShift Web Console.

## Prerequisites

### Connected Host
- `oc` CLI
- Red Hat pull secret (from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))
- Internet access

### Air-Gapped Environment
- `oc` CLI (logged into cluster with cluster-admin)
- `oc-mirror` plugin
- `podman` or `docker` CLI
- Private container registry
- Logged in to the private registry

## Configuration

### OpenShift Version

Default is **4.16**. To use a different version:

```bash
export OCP_VERSION=4.15
./prepare-serverless.sh
```

### Operator Channel

Default is **stable**. To use a different channel:

```bash
export SERVERLESS_CHANNEL=stable-1.33
./prepare-serverless.sh
```

### Non-Interactive Installation

```bash
export PRIVATE_REGISTRY_URL=registry.example.com
export CONTAINER_CMD=podman
./install-serverless.sh
```

## What Gets Mirrored

The `oc-mirror` tool downloads:

| Component | Description |
|-----------|-------------|
| Operator Catalog | Red Hat operator index for your OCP version |
| Serverless Operator | The operator itself |
| Knative Serving | All Knative Serving container images |
| Knative Eventing | All Knative Eventing container images |
| Kourier | Default ingress for Knative |

## Differences from Upstream Knative

| Aspect | Red Hat Serverless | Upstream Knative Operator |
|--------|-------------------|---------------------------|
| Installation | OperatorHub (OLM) | Helm chart |
| Support | Red Hat supported | Community |
| Platform | OpenShift only | Any Kubernetes |
| Updates | Managed by OLM | Manual Helm upgrade |
| Networking | Kourier or Service Mesh | Kourier |

## Troubleshooting

### CatalogSource not ready

```bash
oc get catalogsource -n openshift-marketplace
oc describe catalogsource <name> -n openshift-marketplace
oc logs -n openshift-marketplace -l olm.catalogSource=<name>
```

### Operator not visible in OperatorHub

```bash
oc get packagemanifest serverless-operator
```

If not found, the CatalogSource may not be ready or the mirroring may have failed.

### Image pull errors

Verify ImageContentSourcePolicy/ImageDigestMirrorSet:
```bash
oc get imagecontentsourcepolicy
oc get imagedigestmirrorset
```

Check node status (nodes restart after ICSP/IDMS changes):
```bash
oc get nodes
oc get mcp
```

## References

- [Red Hat Serverless Documentation](https://docs.openshift.com/serverless/latest/about/about-serverless.html)
- [oc-mirror Plugin Documentation](https://docs.openshift.com/container-platform/latest/installing/disconnected_install/installing-mirroring-disconnected.html)
- [Air-Gapped Operator Installation](https://docs.openshift.com/container-platform/latest/operators/admin/olm-restricted-networks.html)
