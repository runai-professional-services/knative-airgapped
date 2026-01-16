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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}=============================================="
    echo -e "$1"
    echo -e "==============================================${NC}\n"
}

print_step() {
    echo -e "${GREEN}>>> $1${NC}"
}

print_substep() {
    echo -e "    ${YELLOW}- $1${NC}"
}

print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Detect container tool
detect_container_tool() {
    if [[ -n "${CONTAINER_TOOL:-}" ]]; then
        echo "$CONTAINER_TOOL"
    elif command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        print_error "Neither podman nor docker found"
        exit 1
    fi
}

CONTAINER_TOOL=$(detect_container_tool)
echo "Using container tool: $CONTAINER_TOOL"

# Get private registry from environment or prompt
get_private_registry() {
    if [[ -n "${PRIVATE_REGISTRY:-}" ]]; then
        echo "$PRIVATE_REGISTRY"
    else
        read -p "Enter private registry URL (e.g., registry.example.com): " registry
        echo "$registry"
    fi
}

PRIVATE_REGISTRY=$(get_private_registry)
echo "Target registry: $PRIVATE_REGISTRY"

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
    images=$($CONTAINER_TOOL images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -i "$pattern" || true)
    
    if [[ -n "$images" ]]; then
        echo "$images" | while read -r image; do
            if [[ -n "$image" && "$image" != "<none>:<none>" ]]; then
                print_substep "Removing: $image"
                $CONTAINER_TOOL rmi -f "$image" 2>/dev/null || true
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
print_substep "Cleaning cached images from $PRIVATE_REGISTRY"
cached_images=$($CONTAINER_TOOL images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "$PRIVATE_REGISTRY" || true)
if [[ -n "$cached_images" ]]; then
    echo "$cached_images" | while read -r image; do
        if [[ -n "$image" && "$image" != "<none>:<none>" ]]; then
            print_substep "Removing cached: $image"
            $CONTAINER_TOOL rmi -f "$image" 2>/dev/null || true
        fi
    done
fi

# Clean dangling images
print_substep "Cleaning dangling images..."
$CONTAINER_TOOL image prune -f 2>/dev/null || true

echo -e "${GREEN}Local image cleanup complete${NC}"

#######################################
# Step 2: Clean remote registry images
#######################################
print_step "Cleaning remote registry images..."

# Check if we're logged in
check_registry_login() {
    if $CONTAINER_TOOL login --get-login "$PRIVATE_REGISTRY" &>/dev/null; then
        return 0
    fi
    
    # Try to login if credentials are provided
    if [[ -n "${PRIVATE_REGISTRY_USERNAME:-}" && -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]]; then
        print_substep "Logging in to registry..."
        echo "$PRIVATE_REGISTRY_PASSWORD" | $CONTAINER_TOOL login "$PRIVATE_REGISTRY" \
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
    local full_image="${PRIVATE_REGISTRY}/${repo}:${tag}"
    
    print_substep "Deleting from registry: $full_image"
    
    # Method 1: Try skopeo if available
    if command -v skopeo &> /dev/null; then
        skopeo delete "docker://${full_image}" 2>/dev/null && return 0
    fi
    
    # Method 2: Try using registry API directly
    # Get the manifest digest first
    local digest
    digest=$($CONTAINER_TOOL manifest inspect "$full_image" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null || true)
    
    if [[ -n "$digest" ]]; then
        # Construct the delete URL
        local registry_url="https://${PRIVATE_REGISTRY}/v2/${repo}/manifests/${digest}"
        
        # Get auth token if available
        local auth_header=""
        if [[ -n "${PRIVATE_REGISTRY_USERNAME:-}" && -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]]; then
            auth_header="-u ${PRIVATE_REGISTRY_USERNAME}:${PRIVATE_REGISTRY_PASSWORD}"
        fi
        
        # Try to delete
        curl -s -X DELETE $auth_header "$registry_url" 2>/dev/null || true
    fi
    
    # Method 3: If this is OpenShift internal registry, use oc if available
    if command -v oc &> /dev/null && [[ "$PRIVATE_REGISTRY" == *"openshift"* ]]; then
        # Extract namespace and image name
        local namespace=$(echo "$repo" | cut -d'/' -f1)
        local imagename=$(echo "$repo" | cut -d'/' -f2-)
        oc delete imagestreamtag "${imagename}:${tag}" -n "$namespace" 2>/dev/null || true
    fi
}

# Delete all tags from a repository
delete_repo_tags() {
    local repo=$1
    local full_repo="${PRIVATE_REGISTRY}/${repo}"
    
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
        tags=$(curl -s $auth_header "https://${PRIVATE_REGISTRY}/v2/${repo}/tags/list" 2>/dev/null | jq -r '.tags[]?' 2>/dev/null || true)
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

echo -e "${GREEN}Remote registry cleanup complete${NC}"

#######################################
# Step 3: OpenShift-specific cleanup
#######################################
if command -v oc &> /dev/null; then
    print_step "OpenShift-specific cleanup..."
    
    # Check if we can access the cluster
    if oc whoami &>/dev/null; then
        print_substep "Cleaning ImageStreams in 'knative' namespace..."
        oc delete imagestream --all -n knative 2>/dev/null || true
        
        print_substep "Cleaning ImageStreams in 'envoyproxy' namespace..."
        oc delete imagestream --all -n envoyproxy 2>/dev/null || true
        
        # Clean up image stream tags that might be in default namespace
        print_substep "Cleaning any stray ImageStreamTags..."
        for repo in "${KNATIVE_REPOS[@]}"; do
            local name=$(basename "$repo")
            oc delete imagestreamtag "${name}" --all-namespaces 2>/dev/null || true
        done
        
        echo -e "${GREEN}OpenShift cleanup complete${NC}"
    else
        print_warning "Not logged into OpenShift cluster, skipping OCP-specific cleanup"
    fi
fi

#######################################
# Summary
#######################################
print_header "Cleanup Complete"

echo "The following has been cleaned:"
echo "  ✓ Local container images matching knative/kourier/envoy patterns"
echo "  ✓ Cached images from $PRIVATE_REGISTRY"
echo "  ✓ Remote registry images (where accessible)"
if command -v oc &> /dev/null; then
    echo "  ✓ OpenShift ImageStreams"
fi

echo ""
echo "You can now run install.sh to push fresh images to the registry."
echo ""
print_warning "If some remote deletions failed, you may need to:"
echo "  1. Manually delete images from the registry UI"
echo "  2. Or use 'skopeo delete' with proper authentication"
echo "  3. For OpenShift: 'oc delete imagestream <name> -n <namespace>'"
