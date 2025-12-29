# Installing Knative Serving in Air-Gapped Environments

This guide describes how to install Knative Serving with Kourier ingress in an air-gapped environment for use with NVIDIA Run:ai inference workloads.

## Prerequisites

- An internet-connected machine for downloading images and charts
- Access to a private container registry in your air-gapped environment
- `podman` CLI
- `helm` CLI (v3.14+)
- `kubectl` CLI configured to access your air-gapped cluster
- Kubernetes cluster meeting [Run:ai system requirements](../system-requirements.md)

## Supported Versions

NVIDIA Run:ai supports Knative versions **1.11 to 1.18**. This guide uses version **1.18** as the reference.

## Files in this Directory

| File | Description |
|------|-------------|
| `pull-images.sh` | Script to pull and save Knative images (run on internet-connected machine) |
| `push-images.sh` | Script to load and push images to private registry (run in air-gapped environment) |
| `knative-serving.yaml` | KnativeServing CR configured for private registry |

---

## Step 1: Download Knative Helm Chart (Internet-Connected Machine)

On a machine with internet access, download the Knative Operator Helm chart:

```bash
# Set the Knative version
export KNATIVE_VERSION=1.18.0

# Add the Knative Operator Helm repository
helm repo add knative-operator https://knative.github.io/operator
helm repo update

# Download the chart to a local directory
helm pull knative-operator/knative-operator --version ${KNATIVE_VERSION} --destination ./knative-charts/
```

This will create `./knative-charts/knative-operator-${KNATIVE_VERSION}.tgz`.

---

## Step 2: Pull and Save Images (Internet-Connected Machine)

Use the provided script to pull all required images and save them as tar archives:

```bash
chmod +x pull-images.sh
./pull-images.sh
```

See [pull-images.sh](./pull-images.sh) for the list of images.

---

## Step 3: Transfer Artifacts to Air-Gapped Environment

Transfer the following to your air-gapped environment:

1. `knative-charts/knative-operator-${KNATIVE_VERSION}.tgz` - Helm chart
2. `knative-images/knative-images.tar` - Container images
3. `push-images.sh` - Script to push images to private registry
4. `knative-serving.yaml` - KnativeServing CR

---

## Step 4: Load and Push Images to Private Registry

Edit `push-images.sh` to set your `PRIVATE_REGISTRY` URL, then run:

```bash
chmod +x push-images.sh
./push-images.sh
```

See [push-images.sh](./push-images.sh) for details.

---

## Step 5: Install Knative Operator with Private Registry

Create the `knative-operator` namespace:

```bash
kubectl create ns knative-operator
```

Create the image pull secret for the private registry:

```bash
kubectl create secret docker-registry knative-registry-creds \
    --namespace knative-operator \
    --docker-server=<PRIVATE_REGISTRY> \
    --docker-username=<your-username> \
    --docker-password=<your-password>
```

Install the Knative Operator using the downloaded Helm chart and override the image registry:

```bash
# Set your private registry
export PRIVATE_REGISTRY="your-private-registry.example.com"

# Set version
export KNATIVE_VERSION="1.18.0"

# Install Knative Operator
helm install knative-operator ./knative-charts/knative-operator-${KNATIVE_VERSION}.tgz \
    --namespace knative-operator \
    --set knative_operator.knative_operator.image=${PRIVATE_REGISTRY}/knative/operator \
    --set knative_operator.knative_operator.tag=v${KNATIVE_VERSION} \
    --set knative_operator.operator_webhook.image=${PRIVATE_REGISTRY}/knative/operator-webhook \
    --set knative_operator.operator_webhook.tag=v${KNATIVE_VERSION}
```

Immediately after installation, patch the ServiceAccounts to include the image pull secret:

```bash
for sa in default knative-operator operator-webhook; do
    kubectl patch serviceaccount ${sa} -n knative-operator \
        -p '{"imagePullSecrets": [{"name": "knative-registry-creds"}]}'
done
```

Restart deployments:

```bash
kubectl -n knative-operator rollout restart deploy
```

Verify the operator is running:

```bash
kubectl get pods -n knative-operator
```

---

## Step 6: Create KnativeServing with Private Registry

Create the `knative-serving` namespace:

```bash
kubectl create ns knative-serving
```

Create the image pull secret for the private registry:

```bash
kubectl create secret docker-registry knative-registry-creds \
    --namespace knative-serving \
    --docker-server=<PRIVATE_REGISTRY> \
    --docker-username=<your-username> \
    --docker-password=<your-password>
```

Edit `knative-serving.yaml` to replace `<PRIVATE_REGISTRY>` with your private registry URL, then apply:

```bash
kubectl apply -f knative-serving.yaml
```

Patch the ServiceAccounts to use the image pull secret (the CR setting doesn't propagate to pods):

```bash
# Patch all ServiceAccounts in knative-serving namespace
for sa in activator controller default net-kourier; do
    kubectl patch serviceaccount ${sa} -n knative-serving \
        -p '{"imagePullSecrets": [{"name": "knative-registry-creds"}]}'
done
```

Restart the deployments to pick up the changes:

```bash
kubectl rollout restart deployment -n knative-serving
```

---

## Step 7: Verify Installation

Check that all Knative Serving pods are running:

```bash
kubectl get pods -n knative-serving
```

Expected output (all pods should be `Running`):

```
NAME                                      READY   STATUS    RESTARTS   AGE
activator-xxxxxxxxxx-xxxxx                1/1     Running   0          2m
autoscaler-xxxxxxxxxx-xxxxx               1/1     Running   0          2m
controller-xxxxxxxxxx-xxxxx               1/1     Running   0          2m
net-kourier-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
webhook-xxxxxxxxxx-xxxxx                  1/1     Running   0          2m
3scale-kourier-gateway-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

Verify Kourier service:

```bash
kubectl get svc -n knative-serving kourier
```

---

## Image Reference

Knative Serving requires the following container images. Replace `${KNATIVE_VERSION}` with your target version (e.g., `1.18.0`):

### Knative Operator Images

> **Note:** The operator webhook (`operator/cmd/webhook`) is different from the serving webhook (`serving/cmd/webhook`). Push the operator webhook to a separate path like `knative/operator-webhook` to avoid conflicts.

```bash
gcr.io/knative-releases/knative.dev/operator/cmd/operator:v${KNATIVE_VERSION}
gcr.io/knative-releases/knative.dev/operator/cmd/webhook:v${KNATIVE_VERSION}
```

### Knative Serving Core Images

```bash
gcr.io/knative-releases/knative.dev/serving/cmd/activator:v${KNATIVE_VERSION}
gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler:v${KNATIVE_VERSION}
gcr.io/knative-releases/knative.dev/serving/cmd/controller:v${KNATIVE_VERSION}
gcr.io/knative-releases/knative.dev/serving/cmd/webhook:v${KNATIVE_VERSION}
gcr.io/knative-releases/knative.dev/serving/cmd/queue:v${KNATIVE_VERSION}
```

### Kourier Ingress Images

```bash
gcr.io/knative-releases/knative.dev/net-kourier/cmd/kourier:v${KNATIVE_VERSION}
docker.io/envoyproxy/envoy:v1.34-latest
```

### Post-Install Job Images

```bash
gcr.io/knative-releases/knative.dev/pkg/apiextensions/storageversion/cmd/migrate:latest
gcr.io/knative-releases/knative.dev/serving/pkg/cleanup/cmd/cleanup:latest
```

### Optional: HPA Autoscaler Images (for custom metrics)

```bash
gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler-hpa:v${KNATIVE_VERSION}
```

