#!/bin/bash
# push-images.sh
#
# Script to load Knative container images and push them to a private registry.
# Run this script in the air-gapped environment with access to the private registry.
#
# Usage:
#   1. Edit PRIVATE_REGISTRY below to match your environment
#   2. Run: ./push-images.sh
#
# Prerequisites:
#   - knative-images.tar file from pull-images.sh
#   - podman CLI
#   - Network access to private registry

set -e

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================================================

# Your private container registry URL (without protocol)
PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-your-private-registry.example.com}"

# Knative version (should match the version used in pull-images.sh)
KNATIVE_VERSION="${KNATIVE_VERSION:-1.18.0}"

# Envoy version
ENVOY_VERSION="${ENVOY_VERSION:-v1.34-latest}"

# Path to the images tar file
IMAGES_TAR="${IMAGES_TAR:-knative-images.tar}"

# ============================================================================
# SCRIPT START
# ============================================================================

echo "=== Knative Image Push Script ==="
echo "Private Registry: ${PRIVATE_REGISTRY}"
echo "Knative Version: ${KNATIVE_VERSION}"
echo "Envoy Version: ${ENVOY_VERSION}"
echo "Images Archive: ${IMAGES_TAR}"
echo ""

# Check if tar file exists
if [[ ! -f "${IMAGES_TAR}" ]]; then
    echo "ERROR: Images archive not found: ${IMAGES_TAR}"
    echo "Make sure to transfer knative-images.tar from the internet-connected machine."
    exit 1
fi

# Login to private registry (if authentication required)
echo "Logging in to private registry..."
podman login "${PRIVATE_REGISTRY}"

# Load images from tar archive
echo ""
echo "Loading images from ${IMAGES_TAR}..."
podman load -i "${IMAGES_TAR}"

echo ""
echo "Tagging and pushing images to ${PRIVATE_REGISTRY}..."
echo ""

# Define source -> target mappings
# Format: source_image|target_path
IMAGE_MAPPINGS=(
    # Knative Operator
    "gcr.io/knative-releases/knative.dev/operator/cmd/operator:v${KNATIVE_VERSION}|knative/operator:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/operator/cmd/webhook:v${KNATIVE_VERSION}|knative/operator-webhook:v${KNATIVE_VERSION}"
    
    # Knative Serving Core
    "gcr.io/knative-releases/knative.dev/serving/cmd/activator:v${KNATIVE_VERSION}|knative/activator:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler:v${KNATIVE_VERSION}|knative/autoscaler:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/controller:v${KNATIVE_VERSION}|knative/controller:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/webhook:v${KNATIVE_VERSION}|knative/webhook:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/queue:v${KNATIVE_VERSION}|knative/queue:v${KNATIVE_VERSION}"
    
    # Kourier Ingress
    "gcr.io/knative-releases/knative.dev/net-kourier/cmd/kourier:v${KNATIVE_VERSION}|knative/kourier:v${KNATIVE_VERSION}"
    "docker.io/envoyproxy/envoy:${ENVOY_VERSION}|envoyproxy/envoy:${ENVOY_VERSION}"
    
    # HPA Autoscaler
    "gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler-hpa:v${KNATIVE_VERSION}|knative/autoscaler-hpa:v${KNATIVE_VERSION}"
    
    # Post-install job images
    "gcr.io/knative-releases/knative.dev/pkg/apiextensions/storageversion/cmd/migrate:v${KNATIVE_VERSION}|knative/migrate:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/pkg/cleanup/cmd/cleanup:v${KNATIVE_VERSION}|knative/cleanup:v${KNATIVE_VERSION}"
)

# Tag and push each image
for mapping in "${IMAGE_MAPPINGS[@]}"; do
    src="${mapping%%|*}"
    target_path="${mapping##*|}"
    dst="${PRIVATE_REGISTRY}/${target_path}"
    
    echo "Tagging: ${src}"
    echo "     -> ${dst}"
    podman tag "${src}" "${dst}"
    
    echo "Pushing: ${dst}"
    podman push "${dst}"
    echo ""
done

echo "=== Done ==="
echo "All images pushed to ${PRIVATE_REGISTRY}"
echo ""
echo "Next steps:"
echo "  1. Install Knative Operator with helm (see README.md Step 5)"
echo "  2. Apply knative-serving.yaml (see README.md Step 6)"

