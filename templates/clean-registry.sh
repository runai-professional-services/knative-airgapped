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
# Uses Docker Registry HTTP API v2
# Works with any compliant registry
#######################################
print_step "Cleaning remote registry images..."

# Build auth header for registry API calls
get_auth_header() {
    if [[ -n "${PRIVATE_REGISTRY_USERNAME:-}" && -n "${PRIVATE_REGISTRY_PASSWORD:-}" ]]; then
        echo "-u ${PRIVATE_REGISTRY_USERNAME}:${PRIVATE_REGISTRY_PASSWORD}"
    else
        # Try to extract credentials from podman/docker config
        local auth_file=""
        if [[ -f "${XDG_RUNTIME_DIR}/containers/auth.json" ]]; then
            auth_file="${XDG_RUNTIME_DIR}/containers/auth.json"
        elif [[ -f "$HOME/.docker/config.json" ]]; then
            auth_file="$HOME/.docker/config.json"
        fi
        
        if [[ -n "$auth_file" ]]; then
            local encoded_auth=$(jq -r --arg reg "$PRIVATE_REGISTRY_URL" '.auths[$reg].auth // empty' "$auth_file" 2>/dev/null || true)
            if [[ -n "$encoded_auth" ]]; then
                echo "-H \"Authorization: Basic ${encoded_auth}\""
            fi
        fi
    fi
}

AUTH_HEADER=$(get_auth_header)

# Check if we can reach the registry
print_substep "Testing registry connectivity..."
if curl -sf ${AUTH_HEADER} "https://${PRIVATE_REGISTRY_URL}/v2/" &>/dev/null; then
    echo "      Registry is accessible"
else
    print_warning "Cannot reach registry API. Will try deletion anyway."
fi

# Delete a specific image tag from registry
delete_image_from_registry() {
    local repo=$1
    local tag=$2
    local full_image="${PRIVATE_REGISTRY_URL}/${repo}:${tag}"
    
    echo "      Deleting: ${repo}:${tag}"
    
    # Step 1: Get the manifest digest using podman/docker
    local digest=""
    
    # Try to get digest from container tool
    digest=$($CONTAINER_CMD manifest inspect "${full_image}" 2>/dev/null | grep -o '"digest"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    
    # If that didn't work, try the registry API directly
    if [[ -z "$digest" ]]; then
        digest=$(curl -sf ${AUTH_HEADER} \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            -I "https://${PRIVATE_REGISTRY_URL}/v2/${repo}/manifests/${tag}" 2>/dev/null \
            | grep -i "docker-content-digest" | awk '{print $2}' | tr -d '\r' || true)
    fi
    
    if [[ -z "$digest" ]]; then
        echo "        Could not get digest, skipping"
        return 1
    fi
    
    # Step 2: Delete the manifest by digest
    local response
    response=$(curl -sf -X DELETE ${AUTH_HEADER} \
        "https://${PRIVATE_REGISTRY_URL}/v2/${repo}/manifests/${digest}" 2>&1) && {
        echo "        Deleted (digest: ${digest:0:20}...)"
        return 0
    } || {
        echo "        Delete failed (registry may not support deletion)"
        return 1
    }
}

# List and delete all tags for a repository
delete_all_tags_for_repo() {
    local repo=$1
    
    print_substep "Processing repository: $repo"
    
    # Get list of tags from registry API
    local tags_json
    tags_json=$(curl -sf ${AUTH_HEADER} "https://${PRIVATE_REGISTRY_URL}/v2/${repo}/tags/list" 2>/dev/null || true)
    
    if [[ -z "$tags_json" ]]; then
        echo "      Repository not found or no access"
        return
    fi
    
    local tags
    tags=$(echo "$tags_json" | jq -r '.tags[]?' 2>/dev/null || true)
    
    if [[ -z "$tags" ]]; then
        echo "      No tags found"
        return
    fi
    
    # Delete each tag
    echo "$tags" | while read -r tag; do
        if [[ -n "$tag" ]]; then
            delete_image_from_registry "$repo" "$tag"
        fi
    done
}

# Process each repository
for repo in "${KNATIVE_REPOS[@]}"; do
    delete_all_tags_for_repo "$repo"
done

echo ""
echo "${GREEN}Remote registry cleanup complete${NC}"

#######################################
# Summary
#######################################
print_header "Cleanup Complete"

echo "The following has been cleaned:"
echo "  ✓ Local container images matching knative/kourier/envoy patterns"
echo "  ✓ Cached images from $PRIVATE_REGISTRY_URL"
echo "  ✓ Remote registry images (via Registry HTTP API v2)"

echo ""
echo "You can now run install.sh to push fresh images to the registry."
echo ""
print_warning "If registry deletion failed:"
echo "  - Your registry may have deletion disabled (common default)"
echo "  - Enable deletion in your registry config, or delete via registry UI"
echo ""
print_warning "If pods still pull wrong images after cleanup + reinstall:"
echo "  - Kubernetes nodes may have cached corrupt images"
echo "  - SSH to affected nodes and run: crictl rmi --all"
