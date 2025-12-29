#!/bin/bash
# pull-images.sh
#
# Script to pull Knative container images and save them as a tar archive.
# Run this script on a connected host with internet access.
#
# Usage: ./pull-images.sh

set -e

# Configuration - adjust version as needed
KNATIVE_VERSION="${KNATIVE_VERSION:-1.18.0}"
ENVOY_VERSION="${ENVOY_VERSION:-v1.34-latest}"
OUTPUT_DIR="${OUTPUT_DIR:-knative-images}"

echo "=== Knative Image Pull Script ==="
echo ""

# Ask user for container utility preference
echo "Which container utility would you like to use?"
echo "  1) podman"
echo "  2) docker"
echo ""
read -p "Enter choice [1/2]: " choice

case "$choice" in
    1|podman)
        CONTAINER_CMD="podman"
        ;;
    2|docker)
        CONTAINER_CMD="docker"
        ;;
    *)
        echo "Invalid choice. Defaulting to podman."
        CONTAINER_CMD="podman"
        ;;
esac

# Verify the chosen tool is available
if ! command -v "${CONTAINER_CMD}" &> /dev/null; then
    echo "ERROR: ${CONTAINER_CMD} is not installed or not in PATH."
    exit 1
fi

echo ""
echo "Using: ${CONTAINER_CMD}"
echo "Knative Version: ${KNATIVE_VERSION}"
echo "Envoy Version: ${ENVOY_VERSION}"
echo "Output Directory: ${OUTPUT_DIR}"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Define all required images
IMAGES=(
    # Knative Operator
    "gcr.io/knative-releases/knative.dev/operator/cmd/operator:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/operator/cmd/webhook:v${KNATIVE_VERSION}"
    
    # Knative Serving Core
    "gcr.io/knative-releases/knative.dev/serving/cmd/activator:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/controller:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/webhook:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/cmd/queue:v${KNATIVE_VERSION}"
    
    # Kourier Ingress
    "gcr.io/knative-releases/knative.dev/net-kourier/cmd/kourier:v${KNATIVE_VERSION}"
    "docker.io/envoyproxy/envoy:${ENVOY_VERSION}"
    
    # HPA Autoscaler (optional but included)
    "gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler-hpa:v${KNATIVE_VERSION}"
    
    # Post-install job images
    "gcr.io/knative-releases/knative.dev/pkg/apiextensions/storageversion/cmd/migrate:v${KNATIVE_VERSION}"
    "gcr.io/knative-releases/knative.dev/serving/pkg/cleanup/cmd/cleanup:v${KNATIVE_VERSION}"
)

# Pull all images
echo "Pulling ${#IMAGES[@]} images..."
echo ""

for img in "${IMAGES[@]}"; do
    echo "Pulling: $img"
    ${CONTAINER_CMD} pull "$img"
done

echo ""
echo "All images pulled successfully."
echo ""

# Save all images to a single tar archive
OUTPUT_FILE="${OUTPUT_DIR}/knative-images.tar"
echo "Saving images to ${OUTPUT_FILE}..."
${CONTAINER_CMD} save -o "${OUTPUT_FILE}" "${IMAGES[@]}"

echo ""
echo "=== Done ==="
echo "Transfer the following to your air-gapped environment:"
echo "  - ${OUTPUT_FILE}"
echo "  - push-images.sh"
echo "  - knative-serving.yaml"
echo "  - knative-charts/knative-operator-${KNATIVE_VERSION}.tgz"

