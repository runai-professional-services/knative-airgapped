#!/bin/bash
# prepare.sh
#
# Prepares a Knative air-gapped installation bundle.
# Run this script on a connected host with internet access.
#
# Usage: ./prepare.sh
#
# Environment variables:
#   CONTAINER_CMD    - Container tool (docker or podman)
#   KNATIVE_VERSION  - Knative version to download (default: 1.18.0)
#
# Output: knative-airgapped-${KNATIVE_VERSION}.tar.gz

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

KNATIVE_VERSION="${KNATIVE_VERSION:-1.18.0}"
ENVOY_VERSION="${ENVOY_VERSION:-v1.34-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo "=============================================="
    echo "$1"
    echo "=============================================="
}

print_step() {
    echo ""
    echo ">>> $1"
}

detect_container_runtime() {
    # If CONTAINER_CMD is already set via env var, validate and use it
    if [[ -n "${CONTAINER_CMD}" ]]; then
        if ! command -v "${CONTAINER_CMD}" &> /dev/null; then
            echo "ERROR: ${CONTAINER_CMD} is not installed or not in PATH."
            exit 1
        fi
        echo "Using container tool: ${CONTAINER_CMD} (from environment)"
        return
    fi
    
    # Auto-detect available runtime
    local has_docker=false
    local has_podman=false
    
    command -v docker &> /dev/null && has_docker=true
    command -v podman &> /dev/null && has_podman=true
    
    if [[ "${has_docker}" == "true" && "${has_podman}" == "false" ]]; then
        CONTAINER_CMD="docker"
        echo "Using container tool: docker (auto-detected)"
    elif [[ "${has_podman}" == "true" && "${has_docker}" == "false" ]]; then
        CONTAINER_CMD="podman"
        echo "Using container tool: podman (auto-detected)"
    elif [[ "${has_docker}" == "true" && "${has_podman}" == "true" ]]; then
        # Both available, prompt user
        echo ""
        echo "Multiple container tools detected. Which would you like to use?"
        echo "  1) docker"
        echo "  2) podman"
        echo ""
        read -p "Enter choice [1/2]: " choice
        
        case "$choice" in
            1|docker) CONTAINER_CMD="docker" ;;
            2|podman) CONTAINER_CMD="podman" ;;
            *)
                echo "Invalid choice. Defaulting to docker."
                CONTAINER_CMD="docker"
                ;;
        esac
        echo "Using container tool: ${CONTAINER_CMD}"
    else
        echo "ERROR: No container tool found. Please install docker or podman."
        exit 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

print_header "Knative Air-Gapped Bundle Preparation"

echo "Knative Version: ${KNATIVE_VERSION}"
echo "Envoy Version: ${ENVOY_VERSION}"

detect_container_runtime

# Create temporary build directory
BUILD_DIR=$(mktemp -d)
BUNDLE_NAME="knative-airgapped-${KNATIVE_VERSION}"
BUNDLE_DIR="${BUILD_DIR}/${BUNDLE_NAME}"
mkdir -p "${BUNDLE_DIR}"

trap "rm -rf ${BUILD_DIR}" EXIT

# -----------------------------------------------------------------------------
# Step 1: Download Helm chart
# -----------------------------------------------------------------------------
print_step "Downloading Knative Operator Helm chart..."

helm repo add knative-operator https://knative.github.io/operator --force-update
helm repo update

helm pull knative-operator/knative-operator \
    --version "${KNATIVE_VERSION}" \
    --destination "${BUNDLE_DIR}/"

echo "Helm chart downloaded: knative-operator-${KNATIVE_VERSION}.tgz"

# -----------------------------------------------------------------------------
# Step 2: Pull container images
# -----------------------------------------------------------------------------
print_step "Pulling container images..."

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

for img in "${IMAGES[@]}"; do
    echo "Pulling: ${img}"
    ${CONTAINER_CMD} pull "${img}"
done

# -----------------------------------------------------------------------------
# Step 3: Save images to tar
# -----------------------------------------------------------------------------
print_step "Saving images to tar archive..."

${CONTAINER_CMD} save -o "${BUNDLE_DIR}/knative-images.tar" "${IMAGES[@]}"

echo "Images saved: knative-images.tar"

# -----------------------------------------------------------------------------
# Step 4: Copy install script and templates
# -----------------------------------------------------------------------------
print_step "Copying installation scripts and templates..."

cp "${SCRIPT_DIR}/templates/install.sh" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/templates/knative-serving.yaml.tpl" "${BUNDLE_DIR}/"

chmod +x "${BUNDLE_DIR}/install.sh"

# Write version info
echo "${KNATIVE_VERSION}" > "${BUNDLE_DIR}/VERSION"
echo "${ENVOY_VERSION}" > "${BUNDLE_DIR}/ENVOY_VERSION"

# -----------------------------------------------------------------------------
# Step 5: Create final archive
# -----------------------------------------------------------------------------
print_step "Creating final archive..."

ARCHIVE_NAME="${BUNDLE_NAME}.tar.gz"

(cd "${BUILD_DIR}" && tar -czf "${SCRIPT_DIR}/${ARCHIVE_NAME}" "${BUNDLE_NAME}")

print_header "Bundle Created Successfully"

echo ""
echo "Archive: ${ARCHIVE_NAME}"
echo ""
echo "Contents:"
echo "  - install.sh                           (installation script)"
echo "  - knative-operator-${KNATIVE_VERSION}.tgz    (Helm chart)"
echo "  - knative-images.tar                   (container images)"
echo "  - knative-serving.yaml.tpl             (KnativeServing template)"
echo "  - VERSION                              (version info)"
echo ""
echo "Next steps:"
echo "  1. Transfer ${ARCHIVE_NAME} to your air-gapped environment"
echo "  2. Extract: tar -xzf ${ARCHIVE_NAME}"
echo "  3. Run: cd ${BUNDLE_NAME} && ./install.sh"
echo ""
