#!/bin/bash
# prepare-serverless.sh
#
# Downloads Red Hat Serverless Operator for air-gapped OpenShift environments.
# Run this script on a connected host with internet access.
#
# Prerequisites:
#   - oc CLI installed
#   - Red Hat pull secret configured
#   - Internet access
#
# Environment variables:
#   OCP_VERSION          - OpenShift version (default: 4.16)
#   SERVERLESS_CHANNEL   - Operator channel (default: stable)
#   OUTPUT_DIR           - Output directory (default: serverless-airgapped)
#
# Usage: ./prepare-serverless.sh

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

OCP_VERSION="${OCP_VERSION:-4.16}"
SERVERLESS_CHANNEL="${SERVERLESS_CHANNEL:-stable}"
OUTPUT_DIR="${OUTPUT_DIR:-serverless-airgapped}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# oc-mirror download URL will be set based on architecture
OC_MIRROR_BASE_URL="https://mirror.openshift.com/pub/openshift-v4"

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

check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # Check for oc CLI
    if ! command -v oc &> /dev/null; then
        print_error "oc CLI is not installed. Please install it first."
        echo "Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/"
        exit 1
    fi
    echo "    oc CLI: $(oc version --client 2>/dev/null | head -1 || echo 'installed')"
    
    # Check for pull secret
    if [[ ! -f ~/.docker/config.json ]]; then
        print_error "Docker config not found at ~/.docker/config.json"
        echo ""
        echo "Please configure your Red Hat pull secret:"
        echo "  1. Download from: https://console.redhat.com/openshift/install/pull-secret"
        echo "  2. Save to: ~/.docker/config.json"
        echo ""
        echo "Or extract from an existing cluster:"
        echo "  oc get secret/pull-secret -n openshift-config --template='{{index .data \".dockerconfigjson\" | base64decode}}' > ~/.docker/config.json"
        exit 1
    fi
    echo "    Pull secret: ~/.docker/config.json"
}

get_oc_mirror_url() {
    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    # For macOS, always use x86_64 (runs via Rosetta 2 on ARM)
    # Red Hat doesn't provide native macOS ARM binaries for oc-mirror
    if [[ "${os}" == "darwin" ]]; then
        echo "${OC_MIRROR_BASE_URL}/x86_64/clients/ocp/stable/oc-mirror.tar.gz"
        return
    fi
    
    # Linux
    case "${arch}" in
        x86_64|amd64)
            echo "${OC_MIRROR_BASE_URL}/x86_64/clients/ocp/stable/oc-mirror.tar.gz"
            ;;
        arm64|aarch64)
            echo "${OC_MIRROR_BASE_URL}/arm64/clients/ocp/stable/oc-mirror.rhel9.tar.gz"
            ;;
        *)
            print_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac
}

validate_oc_mirror_arch() {
    # Check if the existing oc-mirror binary runs without exec format error
    if oc-mirror version &>/dev/null; then
        return 0
    else
        return 1
    fi
}

install_oc_mirror() {
    print_step "Checking oc-mirror plugin..."
    
    local need_install=false
    
    if command -v oc-mirror &> /dev/null; then
        # Check if the binary is the correct architecture
        if validate_oc_mirror_arch; then
            echo "    oc-mirror already installed: $(oc-mirror version 2>/dev/null | head -1 || echo 'installed')"
            return
        else
            echo "    oc-mirror found but wrong architecture. Reinstalling..."
            need_install=true
        fi
    else
        echo "    oc-mirror not found. Installing..."
        need_install=true
    fi
    
    if [[ "${need_install}" != "true" ]]; then
        return
    fi
    
    local temp_dir=$(mktemp -d)
    trap "rm -rf ${temp_dir}" RETURN
    
    local download_url=$(get_oc_mirror_url)
    local arch=$(uname -m)
    local os=$(uname -s)
    
    print_substep "Detected: ${os} ${arch}"
    if [[ "${os}" == "Darwin" && "${arch}" == "arm64" ]]; then
        echo "    (Using x86_64 binary via Rosetta 2 - no native ARM build available)"
    fi
    print_substep "Downloading oc-mirror from: ${download_url}"
    
    local http_code
    http_code=$(curl -sL -w "%{http_code}" "${download_url}" -o "${temp_dir}/oc-mirror.tar.gz")
    
    if [[ "${http_code}" != "200" ]] || [[ ! -s "${temp_dir}/oc-mirror.tar.gz" ]]; then
        echo ""
        echo "    Failed to download from: ${download_url}"
        echo "    HTTP status: ${http_code}"
        echo ""
        
        # For macOS ARM, suggest alternatives
        if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
            echo "    NOTE: oc-mirror may not have a native macOS ARM64 build."
            echo ""
            echo "    Alternatives:"
            echo "      1. Run this script on a Linux x86_64 machine"
            echo "      2. Use a Linux container with oc-mirror installed"
            echo "      3. Try installing via Homebrew: brew install openshift-cli"
            echo ""
            echo "    Or manually download oc-mirror from:"
            echo "      https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/"
            echo ""
        fi
        
        print_error "Failed to download oc-mirror"
        exit 1
    fi
    
    print_substep "Extracting..."
    if ! tar -xzf "${temp_dir}/oc-mirror.tar.gz" -C "${temp_dir}" 2>&1; then
        print_error "Failed to extract oc-mirror archive"
        exit 1
    fi
    
    # Check what was extracted
    if [[ ! -f "${temp_dir}/oc-mirror" ]]; then
        echo "    Contents of archive:"
        ls -la "${temp_dir}/"
        print_error "oc-mirror binary not found in archive"
        exit 1
    fi
    
    print_substep "Installing to /usr/local/bin..."
    if [[ -w /usr/local/bin ]]; then
        mv "${temp_dir}/oc-mirror" /usr/local/bin/
        chmod +x /usr/local/bin/oc-mirror
    else
        sudo mv "${temp_dir}/oc-mirror" /usr/local/bin/
        sudo chmod +x /usr/local/bin/oc-mirror
    fi
    
    # Verify installation
    if ! validate_oc_mirror_arch; then
        echo ""
        echo "    The installed oc-mirror binary may be for the wrong architecture."
        
        if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
            echo ""
            echo "    On Apple Silicon Macs, oc-mirror may need to run under Rosetta 2."
            echo "    Try running: arch -x86_64 oc-mirror version"
            echo ""
            echo "    Or run this entire script under Rosetta:"
            echo "    arch -x86_64 ./prepare-serverless.sh"
        fi
        
        print_error "oc-mirror installation failed or wrong architecture"
        exit 1
    fi
    
    echo "    oc-mirror installed successfully: $(oc-mirror version 2>/dev/null | head -1 || echo 'installed')"
}

create_imageset_config() {
    print_step "Creating ImageSetConfiguration..."
    
    local config_file="${OUTPUT_DIR}/imageset-config.yaml"
    
    cat > "${config_file}" << EOF
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
storageConfig:
  local:
    path: ./metadata
mirror:
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_VERSION}
      packages:
        - name: serverless-operator
          channels:
            - name: ${SERVERLESS_CHANNEL}
EOF

    echo "    Created: ${config_file}"
    echo ""
    echo "    Configuration:"
    echo "      - OCP Version: v${OCP_VERSION}"
    echo "      - Channel: ${SERVERLESS_CHANNEL}"
    echo "      - Package: serverless-operator"
}

mirror_to_disk() {
    print_step "Mirroring operator and images to disk..."
    echo "    This may take a while depending on your internet connection..."
    echo ""
    
    cd "${OUTPUT_DIR}"
    
    oc mirror --config imageset-config.yaml file://mirror-output
    
    cd - > /dev/null
    
    echo ""
    echo "    Mirroring complete!"
}

create_install_script() {
    print_step "Creating installation script for air-gapped environment..."
    
    cat > "${OUTPUT_DIR}/install-serverless.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
# install-serverless.sh
#
# Installs Red Hat Serverless Operator in an air-gapped OpenShift environment.
# Run this script after transferring the bundle to the air-gapped environment.
#
# Prerequisites:
#   - oc CLI installed and logged into the cluster (cluster-admin)
#   - podman or docker CLI
#   - Access to your private registry
#   - Already logged in to the private registry
#
# Environment variables:
#   PRIVATE_REGISTRY_URL  - Private registry URL (required)
#   MIRROR_PATH           - Path in registry for mirrored content (default: mirror)
#
# Usage: ./install-serverless.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_PATH="${MIRROR_PATH:-mirror}"

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

detect_container_tool() {
    if [[ -n "${CONTAINER_CMD}" ]]; then
        if ! command -v "${CONTAINER_CMD}" &> /dev/null; then
            print_error "${CONTAINER_CMD} is not installed or not in PATH."
            exit 1
        fi
        echo "Using container tool: ${CONTAINER_CMD} (from environment)"
        return
    fi
    
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
    
    local logged_in=false
    
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
        if podman login --get-login "${PRIVATE_REGISTRY_URL}" &>/dev/null; then
            logged_in=true
        fi
    else
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

check_oc_login() {
    print_step "Checking OpenShift cluster access..."
    
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift cluster."
        echo ""
        echo "Please log in first:"
        echo "  oc login <cluster-api-url>"
        echo ""
        exit 1
    fi
    
    local user=$(oc whoami)
    local server=$(oc whoami --show-server)
    echo "    Logged in as: ${user}"
    echo "    Cluster: ${server}"
}

# =============================================================================
# MAIN
# =============================================================================

print_header "Red Hat Serverless Operator - Air-Gapped Installation"

# Check prerequisites
if ! command -v oc &> /dev/null; then
    print_error "oc CLI is not installed."
    exit 1
fi

if ! command -v oc-mirror &> /dev/null; then
    print_error "oc-mirror is not installed. Please transfer and install the oc-mirror binary."
    exit 1
fi

# Check for mirror-output directory
if [[ ! -d "${SCRIPT_DIR}/mirror-output" ]]; then
    print_error "mirror-output directory not found."
    echo "Make sure you transferred the complete bundle from the connected host."
    exit 1
fi

# Collect configuration
detect_container_tool
prompt_registry
validate_registry_login
check_oc_login

# =============================================================================
# Step 1: Mirror images to private registry
# =============================================================================
print_step "Mirroring images to private registry..."
echo "    This may take a while..."
echo ""

cd "${SCRIPT_DIR}"

oc mirror --from file://mirror-output docker://${PRIVATE_REGISTRY_URL}/${MIRROR_PATH}

# Find the results directory (most recent)
RESULTS_DIR=$(ls -td oc-mirror-workspace/results-* 2>/dev/null | head -1)

if [[ -z "${RESULTS_DIR}" ]]; then
    print_error "Could not find oc-mirror results directory."
    exit 1
fi

echo ""
echo "    Images mirrored successfully!"
echo "    Results directory: ${RESULTS_DIR}"

# =============================================================================
# Step 2: Apply ImageContentSourcePolicy / ImageDigestMirrorSet
# =============================================================================
print_step "Applying image mirror configuration to cluster..."

# Check for ICSP or IDMS (depends on OCP version)
if [[ -f "${RESULTS_DIR}/imageContentSourcePolicy.yaml" ]]; then
    print_substep "Applying ImageContentSourcePolicy..."
    oc apply -f "${RESULTS_DIR}/imageContentSourcePolicy.yaml"
elif [[ -f "${RESULTS_DIR}/imageDigestMirrorSet.yaml" ]]; then
    print_substep "Applying ImageDigestMirrorSet..."
    oc apply -f "${RESULTS_DIR}/imageDigestMirrorSet.yaml"
else
    echo "    No ICSP/IDMS file found - may need manual configuration"
fi

# =============================================================================
# Step 3: Apply CatalogSource
# =============================================================================
print_step "Creating CatalogSource for Serverless Operator..."

CATALOG_FILE=$(find "${RESULTS_DIR}" -name "catalogSource*.yaml" 2>/dev/null | head -1)

if [[ -n "${CATALOG_FILE}" ]]; then
    print_substep "Applying: ${CATALOG_FILE}"
    oc apply -f "${CATALOG_FILE}"
else
    print_error "CatalogSource file not found in results directory."
    echo "You may need to create it manually."
    exit 1
fi

# =============================================================================
# Step 4: Wait for CatalogSource to be ready
# =============================================================================
print_step "Waiting for CatalogSource to be ready..."

# Extract catalog source name from the file
CATALOG_NAME=$(grep -oP '(?<=name: ).*' "${CATALOG_FILE}" | head -1 | tr -d ' ')

echo "    CatalogSource: ${CATALOG_NAME}"

# Wait for the catalog to be ready (up to 5 minutes)
for i in {1..30}; do
    STATUS=$(oc get catalogsource "${CATALOG_NAME}" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "NotFound")
    
    if [[ "${STATUS}" == "READY" ]]; then
        echo "    CatalogSource is ready!"
        break
    fi
    
    echo "    Status: ${STATUS} (attempt ${i}/30)"
    sleep 10
done

if [[ "${STATUS}" != "READY" ]]; then
    echo ""
    echo "    WARNING: CatalogSource may not be ready yet."
    echo "    Check status with: oc get catalogsource ${CATALOG_NAME} -n openshift-marketplace"
fi

# =============================================================================
# Done
# =============================================================================
print_header "Installation Complete"

echo ""
echo "The Red Hat Serverless Operator is now available in OperatorHub!"
echo ""
echo "Next steps:"
echo "  1. Open the OpenShift Web Console"
echo "  2. Navigate to: Operators -> OperatorHub"
echo "  3. Search for 'Red Hat Serverless'"
echo "  4. Click Install"
echo ""
echo "After installing the operator, you can create:"
echo "  - KnativeServing instance for serverless workloads"
echo "  - KnativeEventing instance for event-driven architecture"
echo ""
echo "Verify CatalogSource:"
echo "  oc get catalogsource -n openshift-marketplace"
echo ""
echo "Verify PackageManifest:"
echo "  oc get packagemanifest serverless-operator"
echo ""
INSTALL_SCRIPT

    chmod +x "${OUTPUT_DIR}/install-serverless.sh"
    echo "    Created: ${OUTPUT_DIR}/install-serverless.sh"
}

create_readme() {
    print_step "Creating README..."
    
    cat > "${OUTPUT_DIR}/README.md" << 'EOF'
# Red Hat Serverless Operator - Air-Gapped Installation Bundle

This bundle contains everything needed to install the Red Hat Serverless Operator
in an air-gapped OpenShift environment.

## Contents

| File/Directory | Description |
|----------------|-------------|
| `mirror-output/` | Mirrored operator catalog and container images |
| `imageset-config.yaml` | ImageSetConfiguration used for mirroring |
| `install-serverless.sh` | Installation script for air-gapped environment |
| `metadata/` | oc-mirror metadata (required for incremental updates) |

## Prerequisites (Air-Gapped Environment)

- `oc` CLI installed and logged into the cluster (cluster-admin)
- `oc-mirror` plugin installed
- `podman` or `docker` CLI
- Access to a private container registry
- Already logged in to the private registry

## Installation

1. Transfer this entire directory to your air-gapped environment

2. Log in to your private registry:
   ```bash
   podman login <your-registry>
   # or
   docker login <your-registry>
   ```

3. Log in to your OpenShift cluster:
   ```bash
   oc login <cluster-api-url>
   ```

4. Run the installation script:
   ```bash
   ./install-serverless.sh
   ```

   Or for non-interactive mode:
   ```bash
   export PRIVATE_REGISTRY_URL=registry.example.com
   export CONTAINER_CMD=podman
   ./install-serverless.sh
   ```

5. After the script completes:
   - Open the OpenShift Web Console
   - Navigate to Operators -> OperatorHub
   - Search for "Red Hat Serverless"
   - Click Install

## Post-Installation

After installing the operator from OperatorHub, create Knative instances:

### Knative Serving
```yaml
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec:
  ingress:
    kourier:
      enabled: true
  config:
    network:
      ingress-class: kourier.ingress.networking.knative.dev
```

### Knative Eventing
```yaml
apiVersion: operator.knative.dev/v1beta1
kind: KnativeEventing
metadata:
  name: knative-eventing
  namespace: knative-eventing
spec: {}
```

## Troubleshooting

### Check CatalogSource status
```bash
oc get catalogsource -n openshift-marketplace
oc describe catalogsource <name> -n openshift-marketplace
```

### Check if operator is available
```bash
oc get packagemanifest serverless-operator
```

### Check operator pod logs
```bash
oc logs -n openshift-marketplace -l olm.catalogSource=<catalog-name>
```
EOF

    echo "    Created: ${OUTPUT_DIR}/README.md"
}

# =============================================================================
# MAIN
# =============================================================================

print_header "Red Hat Serverless Operator - Air-Gapped Preparation"

echo "OCP Version: ${OCP_VERSION}"
echo "Channel: ${SERVERLESS_CHANNEL}"
echo "Output Directory: ${OUTPUT_DIR}"

check_prerequisites
install_oc_mirror

# Create output directory
print_step "Creating output directory..."
mkdir -p "${OUTPUT_DIR}"
echo "    Created: ${OUTPUT_DIR}"

create_imageset_config
mirror_to_disk
create_install_script
create_readme

# Calculate size
BUNDLE_SIZE=$(du -sh "${OUTPUT_DIR}" 2>/dev/null | cut -f1)

print_header "Preparation Complete"

echo ""
echo "Bundle created: ${OUTPUT_DIR}/"
echo "Bundle size: ${BUNDLE_SIZE}"
echo ""
echo "Contents:"
ls -la "${OUTPUT_DIR}/"
echo ""
echo "Next steps:"
echo "  1. Transfer the '${OUTPUT_DIR}/' directory to your air-gapped environment"
echo "  2. Also transfer the 'oc-mirror' binary if not already installed there"
echo "  3. Run: ./install-serverless.sh"
echo ""
