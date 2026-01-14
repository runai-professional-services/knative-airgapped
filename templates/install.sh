#!/bin/bash
# install.sh
#
# Installs Knative Serving in an air-gapped environment.
# Run this script after extracting the knative-airgapped bundle.
#
# Prerequisites:
#   - podman or docker CLI
#   - helm CLI (v3.14+)
#   - kubectl CLI configured to access your cluster
#   - Already logged in to your private registry
#
# Usage: ./install.sh
#
# Environment variables for non-interactive mode:
#   CONTAINER_CMD              - Container tool (docker or podman)
#   PRIVATE_REGISTRY_URL       - Private registry URL
#   PRIVATE_REGISTRY_USERNAME  - Registry username for pull secrets
#   PRIVATE_REGISTRY_PASSWORD  - Registry password for pull secrets

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNATIVE_VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "1.18.0")
ENVOY_VERSION=$(cat "${SCRIPT_DIR}/ENVOY_VERSION" 2>/dev/null || echo "v1.34-latest")

# Timeouts
OPERATOR_TIMEOUT="${OPERATOR_TIMEOUT:-300s}"
SERVING_TIMEOUT="${SERVING_TIMEOUT:-300s}"

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

print_substep() {
    echo "    - $1"
}

print_error() {
    echo ""
    echo "ERROR: $1" >&2
}

detect_container_runtime() {
    # If CONTAINER_CMD is already set via env var, validate and use it
    if [[ -n "${CONTAINER_CMD}" ]]; then
        if ! command -v "${CONTAINER_CMD}" &> /dev/null; then
            print_error "${CONTAINER_CMD} is not installed or not in PATH."
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
        print_error "No container tool found. Please install docker or podman."
        exit 1
    fi
}

prompt_registry() {
    # If PRIVATE_REGISTRY_URL is already set via env var, use it
    if [[ -n "${PRIVATE_REGISTRY_URL}" ]]; then
        echo "Using private registry: ${PRIVATE_REGISTRY_URL} (from environment)"
        return
    fi
    
    echo ""
    read -p "Enter your private registry URL (e.g., registry.example.com): " PRIVATE_REGISTRY_URL

    if [[ -z "${PRIVATE_REGISTRY_URL}" ]]; then
        print_error "Private registry URL is required."
        exit 1
    fi
}

validate_registry_login() {
    print_step "Validating registry login..."
    
    # Try to get login status - method varies by tool
    local logged_in=false
    
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
        # Check if credentials exist in auth file
        if podman login --get-login "${PRIVATE_REGISTRY_URL}" &>/dev/null; then
            logged_in=true
        fi
    else
        # For docker, check config.json
        if grep -q "${PRIVATE_REGISTRY_URL}" ~/.docker/config.json 2>/dev/null; then
            logged_in=true
        fi
    fi
    
    if [[ "${logged_in}" != "true" ]]; then
        print_error "Not logged in to ${PRIVATE_REGISTRY_URL}"
        echo ""
        echo "Please log in first:"
        echo "  ${CONTAINER_CMD} login ${PRIVATE_REGISTRY_URL}"
        echo ""
        exit 1
    fi
    
    echo "Registry login validated: ${PRIVATE_REGISTRY_URL}"
}

prompt_registry_credentials() {
    # If credentials are already set via env vars, use them
    if [[ -n "${PRIVATE_REGISTRY_USERNAME}" && -n "${PRIVATE_REGISTRY_PASSWORD}" ]]; then
        echo "Using registry credentials from environment"
        return
    fi
    
    echo ""
    echo "Enter credentials for creating Kubernetes image pull secrets:"
    read -p "Registry username: " PRIVATE_REGISTRY_USERNAME
    read -s -p "Registry password: " PRIVATE_REGISTRY_PASSWORD
    echo ""
    
    if [[ -z "${PRIVATE_REGISTRY_USERNAME}" || -z "${PRIVATE_REGISTRY_PASSWORD}" ]]; then
        print_error "Username and password are required for image pull secrets."
        exit 1
    fi
}

wait_for_pods_ready() {
    local namespace=$1
    local label_selector=$2
    local timeout=$3
    local description=$4
    
    echo "    Waiting for ${description} to be ready (timeout: ${timeout})..."
    
    if ! kubectl wait --for=condition=Ready pods \
        -l "${label_selector}" \
        -n "${namespace}" \
        --timeout="${timeout}" 2>/dev/null; then
        
        # If no pods found or timeout, check status
        echo "    Checking pod status..."
        kubectl get pods -n "${namespace}" -l "${label_selector}" 2>/dev/null || true
        return 1
    fi
    
    echo "    ${description} ready!"
    return 0
}

wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=$3
    
    echo "    Waiting for deployment ${deployment}..."
    
    kubectl rollout status deployment/"${deployment}" \
        -n "${namespace}" \
        --timeout="${timeout}"
}

wait_for_all_deployments() {
    local namespace=$1
    local timeout=$2
    
    echo "    Waiting for all deployments in ${namespace}..."
    
    # Get all deployments and wait for each
    local deployments
    deployments=$(kubectl get deployments -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "${deployments}" ]]; then
        echo "    No deployments found yet, waiting..."
        sleep 10
        deployments=$(kubectl get deployments -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    fi
    
    for deploy in ${deployments}; do
        kubectl rollout status deployment/"${deploy}" -n "${namespace}" --timeout="${timeout}"
    done
}

wait_for_knative_serving_ready() {
    local timeout_seconds=${1:-300}
    local elapsed=0
    local interval=10
    
    echo "    Waiting for KnativeServing to be ready..."
    
    while [[ ${elapsed} -lt ${timeout_seconds} ]]; do
        local status
        status=$(kubectl get knativeserving knative-serving -n knative-serving \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "${status}" == "True" ]]; then
            echo "    KnativeServing is ready!"
            return 0
        fi
        
        echo "    Status: ${status} (${elapsed}s/${timeout_seconds}s)"
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for KnativeServing to be ready"
    kubectl get knativeserving -n knative-serving -o yaml
    return 1
}

create_namespace_if_not_exists() {
    local namespace=$1
    
    if kubectl get namespace "${namespace}" &>/dev/null; then
        echo "    Namespace ${namespace} already exists"
    else
        kubectl create namespace "${namespace}"
        echo "    Namespace ${namespace} created"
    fi
}

create_image_pull_secret() {
    local namespace=$1
    local secret_name="knative-registry-creds"
    
    if kubectl get secret "${secret_name}" -n "${namespace}" &>/dev/null; then
        echo "    Secret ${secret_name} already exists in ${namespace}"
    else
        kubectl create secret docker-registry "${secret_name}" \
            --namespace "${namespace}" \
            --docker-server="${PRIVATE_REGISTRY_URL}" \
            --docker-username="${PRIVATE_REGISTRY_USERNAME}" \
            --docker-password="${PRIVATE_REGISTRY_PASSWORD}"
        echo "    Secret ${secret_name} created in ${namespace}"
    fi
}

patch_service_accounts() {
    local namespace=$1
    shift
    local service_accounts=("$@")
    
    for sa in "${service_accounts[@]}"; do
        if kubectl get serviceaccount "${sa}" -n "${namespace}" &>/dev/null; then
            kubectl patch serviceaccount "${sa}" -n "${namespace}" \
                -p '{"imagePullSecrets": [{"name": "knative-registry-creds"}]}' 2>/dev/null || true
            echo "    Patched ServiceAccount: ${sa}"
        fi
    done
}

# =============================================================================
# MAIN
# =============================================================================

print_header "Knative Air-Gapped Installation"

echo "Knative Version: ${KNATIVE_VERSION}"
echo "Envoy Version: ${ENVOY_VERSION}"

# Verify required files exist
if [[ ! -f "${SCRIPT_DIR}/knative-images.tar" ]]; then
    print_error "knative-images.tar not found. Make sure you extracted the bundle correctly."
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/knative-operator-${KNATIVE_VERSION}.tgz" ]]; then
    print_error "knative-operator-${KNATIVE_VERSION}.tgz not found."
    exit 1
fi

# Collect configuration
detect_container_runtime
prompt_registry
validate_registry_login
prompt_registry_credentials

# =============================================================================
# Step 1: Load and push images
# =============================================================================
print_step "Loading and pushing images to private registry..."

print_substep "Loading images from tar archive..."
${CONTAINER_CMD} load -i "${SCRIPT_DIR}/knative-images.tar"

# Define image mappings
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

print_substep "Tagging and pushing images..."
for mapping in "${IMAGE_MAPPINGS[@]}"; do
    src="${mapping%%|*}"
    target_path="${mapping##*|}"
    dst="${PRIVATE_REGISTRY_URL}/${target_path}"
    
    echo "      ${src} -> ${dst}"
    ${CONTAINER_CMD} tag "${src}" "${dst}"
    ${CONTAINER_CMD} push "${dst}"
done

echo "All images pushed successfully!"

# =============================================================================
# Step 2: Install Knative Operator
# =============================================================================
print_step "Installing Knative Operator..."

print_substep "Creating namespace and secrets..."
create_namespace_if_not_exists "knative-operator"
create_image_pull_secret "knative-operator"

print_substep "Installing Helm chart..."
helm upgrade --install knative-operator \
    "${SCRIPT_DIR}/knative-operator-${KNATIVE_VERSION}.tgz" \
    --namespace knative-operator \
    --set knative_operator.knative_operator.image="${PRIVATE_REGISTRY_URL}/knative/operator" \
    --set knative_operator.knative_operator.tag="v${KNATIVE_VERSION}" \
    --set knative_operator.operator_webhook.image="${PRIVATE_REGISTRY_URL}/knative/operator-webhook" \
    --set knative_operator.operator_webhook.tag="v${KNATIVE_VERSION}" \
    --wait

print_substep "Patching ServiceAccounts..."
patch_service_accounts "knative-operator" "default" "knative-operator" "operator-webhook"

print_substep "Restarting deployments..."
kubectl rollout restart deployment -n knative-operator

print_substep "Waiting for Operator to be ready..."
wait_for_all_deployments "knative-operator" "${OPERATOR_TIMEOUT}"

echo "Knative Operator installed successfully!"

# =============================================================================
# Step 3: Deploy KnativeServing
# =============================================================================
print_step "Deploying KnativeServing..."

print_substep "Creating namespace and secrets..."
create_namespace_if_not_exists "knative-serving"
create_image_pull_secret "knative-serving"

print_substep "Generating KnativeServing manifest..."
export PRIVATE_REGISTRY_URL
export KNATIVE_VERSION
export ENVOY_VERSION

envsubst < "${SCRIPT_DIR}/knative-serving.yaml.tpl" > "${SCRIPT_DIR}/knative-serving.yaml"

print_substep "Applying KnativeServing CR..."
kubectl apply -f "${SCRIPT_DIR}/knative-serving.yaml"

print_substep "Waiting for KnativeServing to initialize..."
# Give the operator time to create resources
sleep 10

print_substep "Patching ServiceAccounts..."
# Wait a bit for ServiceAccounts to be created
for i in {1..6}; do
    if kubectl get serviceaccount controller -n knative-serving &>/dev/null; then
        break
    fi
    echo "    Waiting for ServiceAccounts to be created... (${i}/6)"
    sleep 5
done

patch_service_accounts "knative-serving" "activator" "controller" "default" "net-kourier"

print_substep "Restarting deployments..."
kubectl rollout restart deployment -n knative-serving 2>/dev/null || true

print_substep "Waiting for KnativeServing to be ready..."
wait_for_knative_serving_ready 300

# =============================================================================
# Step 4: Verify Installation
# =============================================================================
print_step "Verifying installation..."

echo ""
echo "Knative Operator pods:"
kubectl get pods -n knative-operator

echo ""
echo "Knative Serving pods:"
kubectl get pods -n knative-serving

echo ""
echo "Kourier service:"
kubectl get svc -n knative-serving kourier 2>/dev/null || echo "  (Kourier service not yet available)"

echo ""
echo "KnativeServing status:"
kubectl get knativeserving -n knative-serving

# =============================================================================
# Done
# =============================================================================
print_header "Installation Complete"

echo ""
echo "Knative Serving has been installed successfully!"
echo ""
echo "Knative Version: ${KNATIVE_VERSION}"
echo "Private Registry: ${PRIVATE_REGISTRY_URL}"
echo ""
echo "Next steps:"
echo "  - Verify all pods are running: kubectl get pods -n knative-serving"
echo "  - Check KnativeServing status: kubectl get knativeserving -n knative-serving"
echo "  - Configure ingress as needed for your environment"
echo ""
