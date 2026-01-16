#!/bin/bash

#######################################
# Knative Registry Cleanup Script
# 
# This script removes all Knative-related images from:
# 1. Local container runtime (podman/docker)
# 2. Remote private registry
#
# Run this before install.sh if you need a clean slate
# for image pushing.
#######################################

set -e

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

print_header() {
    echo "\n${BLUE}=============================================="
    echo "$1"
    echo "==============================================${NC}\n"
}

print_step() {
    echo "${GREEN}>>> $1${NC}"
}

print_substep() {
    echo "    ${YELLOW}- $1${NC}"
}

print_error() {
    echo "${RED}ERROR: $1${NC}"
}

print_warning() {
    echo "${YELLOW}WARNING: $1${NC}"
}

# Detect container tool (same logic as install.sh)
detect_container_tool() {
    if [[ -n "${CONTAINER_CMD:-}" ]]; then
        echo "$CONTAINER_CMD"
    elif command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        print_error "Neither podman nor docker found"
        exit 1
    fi
}

CONTAINER_CMD=$(detect_container_tool)
echo "Using container tool: $CONTAINER_CMD"

# Get private registry from environment or prompt (same var as install.sh)
get_private_registry() {
    if [[ -n "${PRIVATE_REGISTRY_URL:-}" ]]; then
        echo "$PRIVATE_REGISTRY_URL"
    else
        read -p "Enter private registry URL (e.g., registry.example.com): " registry
        echo "$registry"
    fi
}

PRIVATE_REGISTRY_URL=$(get_private_registry)
echo "Target registry: $PRIVATE_REGISTRY_URL"

# Knative image repositories to clean
KNATIVE_REPOS=(
    "knative/activator"
    "knative/autoscaler"
    "knative/autoscaler-hpa"
    "knative/controller"
    "knative/webhook"
    "knative/queue"
    "knative/kourier"
    "knative/net-kourier-controller"
    "knative/migrate"
    "knative/cleanup"
    "knative/operator"
    "knative/knative-operator"
    "knative/operator-webhook"
    "envoyproxy/envoy"
)

# Additional patterns to match
KNATIVE_PATTERNS=(
    "knative"
    "kourier"
    "envoy"
)

print_header "Knative Registry Cleanup"

#######################################
# Step 1: Clean local container images
#######################################
print_step "Cleaning local container images..."

clean_local_images() {
    local pattern=$1
    local images
    
    # Find images matching pattern
    images=$($CONTAINER_CMD images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -i "$pattern" || true)
    
    if [[ -n "$images" ]]; then
        echo "$images" | while read -r image; do
            if [[ -n "$image" && "$image" != "<none>:<none>" ]]; then
                print_substep "Removing: $image"
                $CONTAINER_CMD rmi -f "$image" 2>/dev/null || true
            fi
        done
    fi
}

# Clean images matching each pattern
for pattern in "${KNATIVE_PATTERNS[@]}"; do
    print_substep "Cleaning images matching: $pattern"
    clean_local_images "$pattern"
done

# Also clean images from the private registry that are cached locally
print_substep "Cleaning cached images from $PRIVATE_REGISTRY_URL"
cached_images=$($CONTAINER_CMD images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "$PRIVATE_REGISTRY_URL" || true)
if [[ -n "$cached_images" ]]; then
    echo "$cached_images" | while read -r image; do
        if [[ -n "$image" && "$image" != "<none>:<none>" ]]; then
            print_substep "Removing cached: $image"
            $CONTAINER_CMD rmi -f "$image" 2>/dev/null || true
        fi
    done
fi

# Clean dangling images
print_substep "Cleaning dangling images..."
$CONTAINER_CMD image prune -f 2>/dev/null || true

echo "${GREEN}Local image cleanup complete${NC}"

#######################################
# Step 2: Clean remote registry images
#######################################
print_step "Cleaning remote registry images..."

# Check if we're logged in
check_registry_login() {
    if $CONTAINER_CMD login --get-login "$PRIVATE_REGISTRY_URL" &>/dev/null; then
        return 0
    fi
    
    # Try to login if credentials are provided
    if [[ -n "${PRIVATE_REGISTRY_USERNAME:-}" && -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]]; then
        print_substep "Logging in to registry..."
        echo "$PRIVATE_REGISTRY_PASSWORD" | $CONTAINER_CMD login "$PRIVATE_REGISTRY_URL" \
            -u "$PRIVATE_REGISTRY_USERNAME" --password-stdin 2>/dev/null
        return $?
    fi
    
    print_warning "Not logged in to registry. Some cleanup operations may fail."
    return 1
}

# Delete image from registry using the registry API
delete_from_registry() {
    local repo=$1
    local tag=$2
    local full_image="${PRIVATE_REGISTRY_URL}/${repo}:${tag}"
    
    print_substep "Deleting from registry: $full_image"
    
    # Method 1: Try skopeo if available
    if command -v skopeo &> /dev/null; then
        skopeo delete "docker://${full_image}" 2>/dev/null && return 0
    fi
    
    # Method 2: Try using registry API directly
    # Get the manifest digest first
    local digest
    digest=$($CONTAINER_CMD manifest inspect "$full_image" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null || true)
    
    if [[ -n "$digest" ]]; then
        # Construct the delete URL
        local registry_url="https://${PRIVATE_REGISTRY_URL}/v2/${repo}/manifests/${digest}"
        
        # Get auth token if available
        local auth_header=""
        if [[ -n "${PRIVATE_REGISTRY_USERNAME:-}" && -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]]; then
            auth_header="-u ${PRIVATE_REGISTRY_USERNAME}:${PRIVATE_REGISTRY_PASSWORD}"
        fi
        
        # Try to delete
        curl -s -X DELETE $auth_header "$registry_url" 2>/dev/null || true
    fi
    
    # Method 3: If this is OpenShift internal registry, use oc if available
    if command -v oc &> /dev/null && [[ "$PRIVATE_REGISTRY_URL" == *"openshift"* ]]; then
        # Extract namespace and image name
        local namespace=$(echo "$repo" | cut -d'/' -f1)
        local imagename=$(echo "$repo" | cut -d'/' -f2-)
        oc delete imagestreamtag "${imagename}:${tag}" -n "$namespace" 2>/dev/null || true
    fi
}

# Delete all tags from a repository
delete_repo_tags() {
    local repo=$1
    local full_repo="${PRIVATE_REGISTRY_URL}/${repo}"
    
    print_substep "Checking repository: $repo"
    
    # Get list of tags
    local tags
    
    # Try skopeo first
    if command -v skopeo &> /dev/null; then
        tags=$(skopeo list-tags "docker://${full_repo}" 2>/dev/null | jq -r '.Tags[]?' 2>/dev/null || true)
    fi
    
    # If skopeo didn't work, try the registry API
    if [[ -z "$tags" ]]; then
        local auth_header=""
        if [[ -n "${PRIVATE_REGISTRY_USERNAME:-}" && -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]]; then
            auth_header="-u ${PRIVATE_REGISTRY_USERNAME}:${PRIVATE_REGISTRY_PASSWORD}"
        fi
        tags=$(curl -s $auth_header "https://${PRIVATE_REGISTRY_URL}/v2/${repo}/tags/list" 2>/dev/null | jq -r '.tags[]?' 2>/dev/null || true)
    fi
    
    if [[ -n "$tags" ]]; then
        echo "$tags" | while read -r tag; do
            if [[ -n "$tag" ]]; then
                delete_from_registry "$repo" "$tag"
            fi
        done
    else
        print_substep "No tags found or unable to list tags for $repo"
    fi
}

# Check login status
check_registry_login || true

# Delete each knative repo
for repo in "${KNATIVE_REPOS[@]}"; do
    delete_repo_tags "$repo"
done

echo "${GREEN}Remote registry cleanup complete${NC}"

#######################################
# Step 3: OpenShift-specific cleanup
#######################################
print_step "OpenShift ImageStream cleanup..."

# Try oc first, fall back to kubectl
OC_CMD=""
if command -v oc &> /dev/null && oc whoami &>/dev/null 2>&1; then
    OC_CMD="oc"
elif command -v kubectl &> /dev/null; then
    # Check if this cluster has ImageStream CRD (OpenShift)
    if kubectl api-resources 2>/dev/null | grep -q "imagestreams"; then
        OC_CMD="kubectl"
    fi
fi

if [[ -n "$OC_CMD" ]]; then
    print_substep "Using $OC_CMD for ImageStream cleanup..."
    
    # Delete ImageStreams in knative namespace
    print_substep "Deleting ImageStreams in 'knative' namespace..."
    $OC_CMD delete imagestream --all -n knative 2>/dev/null && echo "      Deleted all in knative" || echo "      No imagestreams in knative or namespace doesn't exist"
    
    # Delete ImageStreams in envoyproxy namespace
    print_substep "Deleting ImageStreams in 'envoyproxy' namespace..."
    $OC_CMD delete imagestream --all -n envoyproxy 2>/dev/null && echo "      Deleted all in envoyproxy" || echo "      No imagestreams in envoyproxy or namespace doesn't exist"
    
    # Also try to delete individual imagestreams by name in case they're in different namespaces
    print_substep "Searching for knative-related ImageStreams in all namespaces..."
    IMAGESTREAM_NAMES="activator autoscaler autoscaler-hpa controller webhook queue kourier migrate cleanup operator operator-webhook envoy"
    
    for isname in $IMAGESTREAM_NAMES; do
        # Find and delete imagestreams with this name in any namespace
        found_is=$($OC_CMD get imagestream "$isname" --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
        if [[ -n "$found_is" ]]; then
            echo "$found_is" | while read -r ns_is; do
                ns="${ns_is%%/*}"
                is="${ns_is##*/}"
                echo "      Deleting imagestream $is in namespace $ns"
                $OC_CMD delete imagestream "$is" -n "$ns" 2>/dev/null || true
            done
        fi
    done
    
    echo "${GREEN}OpenShift ImageStream cleanup complete${NC}"
else
    print_warning "No oc/kubectl with ImageStream support found. Skipping OpenShift cleanup."
    echo ""
    echo "    If your registry is on OpenShift, manually delete ImageStreams:"
    echo "      oc delete imagestream --all -n knative"
    echo "      oc delete imagestream --all -n envoyproxy"
fi

#######################################
# Summary
#######################################
print_header "Cleanup Complete"

echo "The following has been cleaned:"
echo "  ✓ Local container images matching knative/kourier/envoy patterns"
echo "  ✓ Cached images from $PRIVATE_REGISTRY_URL"
echo "  ✓ Remote registry images (where accessible)"
echo "  ✓ OpenShift ImageStreams (if applicable)"

echo ""
echo "You can now run install.sh to push fresh images to the registry."
echo ""
print_warning "If pods still pull wrong images after cleanup + reinstall:"
echo "  1. The Kubernetes nodes may have cached corrupt images"
echo "  2. SSH to affected nodes and run: crictl rmi --all"
echo "  3. Or delete and recreate the node"
