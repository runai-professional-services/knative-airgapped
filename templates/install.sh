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
# Usage: ./install.sh [--force]
#
# Options:
#   --force    Force push images even if they already exist in registry
#
# Environment variables for non-interactive mode:
#   CONTAINER_CMD              - Container tool (docker or podman)
#   PRIVATE_REGISTRY_URL       - Private registry URL
#
#   Push credentials (write access - for pushing images to registry):
#   PRIVATE_REGISTRY_USERNAME  - Registry username for pushing images
#   PRIVATE_REGISTRY_PASSWORD  - Registry password for pushing images
#
#   Pull credentials (read-only - for cluster ImagePullSecrets):
#   PRIVATE_REGISTRY_PULL_USERNAME  - Registry username for pull secrets (defaults to push username)
#   PRIVATE_REGISTRY_PULL_PASSWORD  - Registry password for pull secrets (defaults to push password)
#
#   FORCE_PUSH                 - Set to "true" to force push images

set -e

# Parse command line arguments
FORCE_PUSH="${FORCE_PUSH:-false}"
for arg in "$@"; do
    case $arg in
        --force)
            FORCE_PUSH="true"
            shift
            ;;
    esac
done

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNATIVE_VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "1.18.0")
ENVOY_VERSION=$(cat "${SCRIPT_DIR}/ENVOY_VERSION" 2>/dev/null || echo "v1.31.2")

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
    
    # If not logged in, attempt auto-login with provided credentials
    if [[ "${logged_in}" != "true" ]]; then
        if [[ -n "${PRIVATE_REGISTRY_USERNAME}" && -n "${PRIVATE_REGISTRY_PASSWORD}" ]]; then
            echo "Not logged in. Attempting login with provided credentials..."
            if echo "${PRIVATE_REGISTRY_PASSWORD}" | ${CONTAINER_CMD} login "${PRIVATE_REGISTRY_URL}" \
                --username "${PRIVATE_REGISTRY_USERNAME}" --password-stdin; then
                echo "Successfully logged in to ${PRIVATE_REGISTRY_URL}"
                logged_in=true
            else
                print_error "Failed to login to ${PRIVATE_REGISTRY_URL} with provided credentials"
                exit 1
            fi
        else
        print_error "Not logged in to ${PRIVATE_REGISTRY_URL}"
        echo ""
            echo "Please either:"
            echo "  1. Set PRIVATE_REGISTRY_USERNAME and PRIVATE_REGISTRY_PASSWORD environment variables, or"
            echo "  2. Log in manually: ${CONTAINER_CMD} login ${PRIVATE_REGISTRY_URL}"
        echo ""
        exit 1
    fi
    else
    echo "Registry login validated: ${PRIVATE_REGISTRY_URL}"
    fi
}

prompt_registry_credentials() {
    # Push credentials (write access) for pushing images to registry
    if [[ -n "${PRIVATE_REGISTRY_USERNAME}" && -n "${PRIVATE_REGISTRY_PASSWORD}" ]]; then
        echo "Using push credentials from environment (PRIVATE_REGISTRY_USERNAME)"
    else
        echo ""
        echo "Enter credentials for PUSHING images to registry (needs write access):"
        read -p "Push username: " PRIVATE_REGISTRY_USERNAME
        read -s -p "Push password: " PRIVATE_REGISTRY_PASSWORD
        echo ""
        
        if [[ -z "${PRIVATE_REGISTRY_USERNAME}" || -z "${PRIVATE_REGISTRY_PASSWORD}" ]]; then
            print_error "Push credentials are required for uploading images to registry."
            exit 1
        fi
    fi
    
    # Pull credentials (read-only) for Kubernetes ImagePullSecrets
    # If not specified, defaults to push credentials
    if [[ -n "${PRIVATE_REGISTRY_PULL_USERNAME}" && -n "${PRIVATE_REGISTRY_PULL_PASSWORD}" ]]; then
        echo "Using separate pull credentials from environment (PRIVATE_REGISTRY_PULL_USERNAME)"
    else
        # Check if user wants separate pull credentials
        echo ""
        echo "Pull credentials for Kubernetes ImagePullSecrets (read-only access):"
        echo "  Press Enter to use the same as push credentials, or enter different ones."
        read -p "Pull username [${PRIVATE_REGISTRY_USERNAME}]: " input_pull_user
        
        if [[ -n "${input_pull_user}" ]]; then
            PRIVATE_REGISTRY_PULL_USERNAME="${input_pull_user}"
            read -s -p "Pull password: " PRIVATE_REGISTRY_PULL_PASSWORD
            echo ""
            
            if [[ -z "${PRIVATE_REGISTRY_PULL_PASSWORD}" ]]; then
                print_error "Pull password is required when specifying a different pull user."
                exit 1
            fi
        else
            # Use push credentials as pull credentials
            PRIVATE_REGISTRY_PULL_USERNAME="${PRIVATE_REGISTRY_USERNAME}"
            PRIVATE_REGISTRY_PULL_PASSWORD="${PRIVATE_REGISTRY_PASSWORD}"
            echo "Using push credentials for pull secrets"
        fi
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

fix_storage_version_migration_job() {
    # Fix for Knative v1.18.x bug: storage-version-migration job missing SYSTEM_NAMESPACE env var
    # Instead of deleting, we patch the job to add the missing env var
    
    local job_name
    job_name=$(kubectl get job -n knative-serving -l app=storage-version-migration-serving -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "${job_name}" ]]; then
        return 0  # No job found, nothing to fix
    fi
    
    # Check if job already has the env var (already patched)
    local has_env
    has_env=$(kubectl get job "${job_name}" -n knative-serving -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SYSTEM_NAMESPACE")].name}' 2>/dev/null || echo "")
    
    if [[ -n "${has_env}" ]]; then
        return 0  # Already patched
    fi
    
    echo "    Fixing storage-version-migration job (adding missing SYSTEM_NAMESPACE env)..."
    
    # Get the job, add the env var, delete and recreate
    kubectl get job "${job_name}" -n knative-serving -o json | \
        jq '.spec.template.spec.containers[0].env = [{"name": "SYSTEM_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}}]' | \
        jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .status)' > /tmp/fixed-job.json
    
    kubectl delete job "${job_name}" -n knative-serving --ignore-not-found=true 2>/dev/null || true
    kubectl apply -f /tmp/fixed-job.json 2>/dev/null || true
    rm -f /tmp/fixed-job.json
    
    echo "    Storage-version-migration job patched successfully"
}

wait_for_knative_serving_ready() {
    local timeout_seconds=${1:-300}
    local elapsed=0
    local interval=10
    
    echo "    Waiting for KnativeServing to be ready..."
    
    while [[ ${elapsed} -lt ${timeout_seconds} ]]; do
        # Try to fix the buggy storage-version-migration job each iteration
        fix_storage_version_migration_job
        
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
        # Use PULL credentials (read-only) for ImagePullSecrets
        local auth_string
        auth_string=$(printf '%s:%s' "${PRIVATE_REGISTRY_PULL_USERNAME}" "${PRIVATE_REGISTRY_PULL_PASSWORD}" | base64 -w0 2>/dev/null || \
                      printf '%s:%s' "${PRIVATE_REGISTRY_PULL_USERNAME}" "${PRIVATE_REGISTRY_PULL_PASSWORD}" | base64)
        
        local docker_config_json
        docker_config_json=$(printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
            "${PRIVATE_REGISTRY_URL}" \
            "${PRIVATE_REGISTRY_PULL_USERNAME}" \
            "${PRIVATE_REGISTRY_PULL_PASSWORD}" \
            "${auth_string}")
        
        local encoded_config
        encoded_config=$(printf '%s' "${docker_config_json}" | base64 -w0 2>/dev/null || \
                         printf '%s' "${docker_config_json}" | base64)
        
        # Use kubectl apply with YAML to avoid any shell escaping issues
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${encoded_config}
EOF
        echo "    Secret ${secret_name} created in ${namespace}"
    fi
}

patch_all_service_accounts() {
    local namespace=$1
    
    echo "    Patching all ServiceAccounts in ${namespace}..."
    
    # Get all service accounts in the namespace and patch each one
    for sa in $(kubectl get serviceaccount -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl patch serviceaccount "${sa}" -n "${namespace}" \
            -p '{"imagePullSecrets": [{"name": "knative-registry-creds"}]}' 2>/dev/null || true
        echo "      Patched: ${sa}"
    done
}


# =============================================================================
# MAIN
# =============================================================================

print_header "Knative Air-Gapped Installation"

echo "Knative Version: ${KNATIVE_VERSION}"
echo "Envoy Version: ${ENVOY_VERSION}"
if [[ "${FORCE_PUSH}" == "true" ]]; then
    echo "Force Push: ENABLED"
fi

# Verify required files exist
if [[ ! -f "${SCRIPT_DIR}/knative-images.tar" ]]; then
    print_error "knative-images.tar not found. Make sure you extracted the bundle correctly."
    exit 1
fi

HELM_CHART="${SCRIPT_DIR}/knative-operator-v${KNATIVE_VERSION}.tgz"
if [[ ! -f "${HELM_CHART}" ]]; then
    print_error "knative-operator-v${KNATIVE_VERSION}.tgz not found."
    echo "DEBUG: Looking for: ${HELM_CHART}"
    echo "DEBUG: SCRIPT_DIR=${SCRIPT_DIR}"
    echo "DEBUG: KNATIVE_VERSION=${KNATIVE_VERSION}"
    echo "DEBUG: Files in directory:"
    ls -la "${SCRIPT_DIR}"/*.tgz 2>/dev/null || echo "  No .tgz files found"
    exit 1
fi

# Collect configuration
detect_container_runtime
prompt_registry
prompt_registry_credentials
validate_registry_login

# =============================================================================
# Step 1: Load and push images
# =============================================================================
print_step "Loading and pushing images to private registry..."

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

# Check if we should skip the image existence check
if [[ "${FORCE_PUSH}" == "true" ]]; then
    echo ""
    print_substep "Force push enabled - will push all images regardless of existence"
    images_missing=true
else
    # Check if all images already exist in the registry
    print_substep "Checking if images already exist in registry..."
    images_missing=false
    for mapping in "${IMAGE_MAPPINGS[@]}"; do
        target_path="${mapping##*|}"
        dst="${PRIVATE_REGISTRY_URL}/${target_path}"
        
        # Try to inspect the remote image
        if ${CONTAINER_CMD} manifest inspect "${dst}" &>/dev/null; then
            echo "      ✓ ${target_path}"
        else
            echo "      ✗ ${target_path} (missing)"
            images_missing=true
        fi
    done
fi

if [[ "${images_missing}" == "false" ]]; then
    echo ""
    echo "    All images already exist in registry. Skipping load and push."
    echo "    (Use --force to push anyway)"
else
    print_substep "Loading images from tar archive..."
    ${CONTAINER_CMD} load -i "${SCRIPT_DIR}/knative-images.tar"
    
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
fi

# =============================================================================
# Step 2: Install Knative Operator
# =============================================================================
print_step "Installing Knative Operator..."

print_substep "Creating namespace and secrets..."
create_namespace_if_not_exists "knative-operator"
create_image_pull_secret "knative-operator"

print_substep "Installing Helm chart..."
helm upgrade --install knative-operator \
    "${SCRIPT_DIR}/knative-operator-v${KNATIVE_VERSION}.tgz" \
    --namespace knative-operator \
    --set knative_operator.knative_operator.image="${PRIVATE_REGISTRY_URL}/knative/operator" \
    --set knative_operator.knative_operator.tag="v${KNATIVE_VERSION}" \
    --set knative_operator.operator_webhook.image="${PRIVATE_REGISTRY_URL}/knative/operator-webhook" \
    --set knative_operator.operator_webhook.tag="v${KNATIVE_VERSION}"

print_substep "Patching deployments with imagePullPolicy: Always..."
for deploy in knative-operator operator-webhook; do
    kubectl patch deployment -n knative-operator "$deploy" \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"'"$deploy"'","imagePullPolicy":"Always"}]}}}}' 2>/dev/null || true
done

print_substep "Waiting for ServiceAccounts to be created..."
sleep 5

print_substep "Patching ServiceAccounts with imagePullSecrets..."
patch_all_service_accounts "knative-operator"

print_substep "Deleting pods to pick up changes..."
sleep 3
kubectl delete pods -n knative-operator --all --force --grace-period=0 2>/dev/null || true

print_substep "Waiting for Operator to be ready..."
wait_for_all_deployments "knative-operator" "${OPERATOR_TIMEOUT}"

# Sometimes operator-webhook needs an extra restart after SA patching
print_substep "Ensuring operator-webhook is healthy..."
sleep 5
if ! kubectl get pods -n knative-operator -l app.kubernetes.io/component=operator-webhook -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; then
    echo "    Restarting operator-webhook pod..."
    kubectl delete pod -n knative-operator -l app.kubernetes.io/component=operator-webhook --force --grace-period=0 2>/dev/null || true
    sleep 10
fi

echo "Knative Operator installed successfully!"

# =============================================================================
# Step 3: Deploy KnativeServing
# =============================================================================
print_step "Deploying KnativeServing..."

print_substep "Creating namespace and secrets..."
create_namespace_if_not_exists "knative-serving"
create_image_pull_secret "knative-serving"

print_substep "Generating KnativeServing manifest..."
# Use sed instead of envsubst (not available on all systems)
# Only substitute our variables, leave ${NAME} for Knative
sed -e "s|\${PRIVATE_REGISTRY_URL}|${PRIVATE_REGISTRY_URL}|g" \
    -e "s|\${KNATIVE_VERSION}|${KNATIVE_VERSION}|g" \
    -e "s|\${ENVOY_VERSION}|${ENVOY_VERSION}|g" \
    "${SCRIPT_DIR}/knative-serving.yaml.tpl" > "${SCRIPT_DIR}/knative-serving.yaml"

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

patch_all_service_accounts "knative-serving"

# Note: RBAC is managed by Knative Operator - no custom RBAC needed

print_substep "Patching deployments with imagePullPolicy: Always..."
for deploy in $(kubectl get deployments -n knative-serving -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    # Get the container name (usually same as deployment name or first container)
    container=$(kubectl get deployment -n knative-serving "$deploy" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null)
    if [[ -n "$container" ]]; then
        kubectl patch deployment -n knative-serving "$deploy" \
            -p '{"spec":{"template":{"spec":{"containers":[{"name":"'"$container"'","imagePullPolicy":"Always"}]}}}}' 2>/dev/null || true
    fi
done

print_substep "Restarting pods to pick up changes..."
sleep 3
kubectl delete pods -n knative-serving --all --force --grace-period=0 2>/dev/null || true

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
