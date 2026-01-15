#!/bin/bash
# uninstall.sh
#
# Completely removes Knative Operator and Knative Serving from a cluster.
# This script deletes all Knative resources including CRDs and RBAC.
#
# Usage: ./uninstall.sh [--force]
#
# Options:
#   --force    Skip confirmation prompts

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

FORCE_MODE=false
if [[ "$1" == "--force" ]]; then
    FORCE_MODE=true
fi

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

print_warning() {
    echo ""
    echo "⚠️  WARNING: $1"
}

print_success() {
    echo ""
    echo "✅ $1"
}

confirm_action() {
    if [[ "${FORCE_MODE}" == "true" ]]; then
        return 0
    fi
    
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " response
    if [[ "${response}" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
}

delete_resource_if_exists() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    
    if [[ -n "${namespace}" ]]; then
        if kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" &>/dev/null; then
            kubectl delete "${resource_type}" "${resource_name}" -n "${namespace}" --timeout=60s || true
            echo "      Deleted ${resource_type}/${resource_name} in ${namespace}"
        fi
    else
        if kubectl get "${resource_type}" "${resource_name}" &>/dev/null; then
            kubectl delete "${resource_type}" "${resource_name}" --timeout=60s || true
            echo "      Deleted ${resource_type}/${resource_name}"
        fi
    fi
}

delete_by_pattern() {
    local resource_type=$1
    local pattern=$2
    
    local resources=$(kubectl get "${resource_type}" -o name 2>/dev/null | grep -i "${pattern}" || true)
    if [[ -n "${resources}" ]]; then
        echo "${resources}" | while read resource; do
            kubectl delete "${resource}" --timeout=60s 2>/dev/null || true
            echo "      Deleted ${resource}"
        done
    fi
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

print_header "Knative Uninstallation"

print_warning "This will completely remove Knative from your cluster including:"
echo "  - KnativeServing custom resources"
echo "  - KnativeEventing custom resources (if any)"
echo "  - Knative Operator (Helm release)"
echo "  - All Knative namespaces (knative-operator, knative-serving, knative-eventing)"
echo "  - All Knative CRDs"
echo "  - All Knative ClusterRoles and ClusterRoleBindings"
echo "  - All Knative webhooks and validating configurations"

confirm_action

# =============================================================================
# Step 1: Delete Knative Custom Resources
# =============================================================================
print_step "Deleting Knative Custom Resources..."

print_substep "Deleting KnativeServing resources..."
kubectl delete knativeserving --all -n knative-serving --timeout=120s 2>/dev/null || true
kubectl delete knativeserving --all -A --timeout=120s 2>/dev/null || true

print_substep "Deleting KnativeEventing resources..."
kubectl delete knativeeventing --all -n knative-eventing --timeout=120s 2>/dev/null || true
kubectl delete knativeeventing --all -A --timeout=120s 2>/dev/null || true

# Wait for resources to be deleted
print_substep "Waiting for custom resources to be removed..."
sleep 10

# =============================================================================
# Step 2: Uninstall Helm Release
# =============================================================================
print_step "Uninstalling Helm release..."

if helm list -n knative-operator 2>/dev/null | grep -q knative-operator; then
    helm uninstall knative-operator -n knative-operator --timeout 120s || true
    echo "    Helm release 'knative-operator' uninstalled"
else
    echo "    Helm release 'knative-operator' not found (already removed or not installed via Helm)"
fi

# =============================================================================
# Step 3: Delete Namespaces
# =============================================================================
print_step "Deleting Knative namespaces..."

force_delete_namespace() {
    local ns=$1
    local timeout=30
    
    echo "    Attempting to delete namespace ${ns}..."
    
    # Start deletion in background
    kubectl delete namespace "${ns}" --timeout=${timeout}s &
    local delete_pid=$!
    
    # Wait for deletion with timeout
    local elapsed=0
    while kill -0 $delete_pid 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        
        if [[ $elapsed -ge $timeout ]]; then
            echo "    ⚠️  Namespace ${ns} stuck after ${timeout}s, forcing cleanup..."
            
            # Kill the background delete
            kill $delete_pid 2>/dev/null || true
            wait $delete_pid 2>/dev/null || true
            
            # Find and remove finalizers from ALL resource types in the namespace
            echo "    Removing finalizers from stuck resources..."
            
            # Get all API resources and remove finalizers
            for resource_type in $(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null); do
                kubectl get "${resource_type}" -n "${ns}" -o name 2>/dev/null | while read resource; do
                    kubectl patch "${resource}" -n "${ns}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
                done
            done
            
            # Also patch CRDs that might be stuck (knativeserving, knativeeventing, etc.)
            for crd in knativeserving knativeeventing; do
                kubectl get "${crd}" -n "${ns}" -o name 2>/dev/null | while read resource; do
                    kubectl patch "${resource}" -n "${ns}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
                    kubectl delete "${resource}" -n "${ns}" --force --grace-period=0 2>/dev/null || true
                done
            done
            
            # Force finalize the namespace itself
            echo "    Finalizing namespace ${ns}..."
            kubectl get namespace "${ns}" -o json 2>/dev/null | \
                jq '.spec.finalizers = []' | \
                kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
            
            # Try delete again
            kubectl delete namespace "${ns}" --force --grace-period=0 2>/dev/null || true
            
            # Final check
            sleep 3
            if kubectl get namespace "${ns}" &>/dev/null; then
                echo "    ⚠️  Namespace ${ns} may still be terminating. Manual cleanup may be needed."
            else
                echo "    ✅ Namespace ${ns} deleted successfully"
            fi
            return
        fi
    done
    
    wait $delete_pid 2>/dev/null
    echo "    ✅ Namespace ${ns} deleted successfully"
}

for ns in knative-operator knative-serving knative-eventing kourier-system; do
    if kubectl get namespace "${ns}" &>/dev/null; then
        force_delete_namespace "${ns}"
    else
        echo "    Namespace ${ns} does not exist (skipping)"
    fi
done

# =============================================================================
# Step 4: Delete ClusterRoleBindings
# =============================================================================
print_step "Deleting Knative ClusterRoleBindings..."

delete_by_pattern "clusterrolebinding" "knative"
delete_by_pattern "clusterrolebinding" "kourier"

# =============================================================================
# Step 5: Delete ClusterRoles
# =============================================================================
print_step "Deleting Knative ClusterRoles..."

delete_by_pattern "clusterrole" "knative"
delete_by_pattern "clusterrole" "kourier"

# =============================================================================
# Step 6: Delete CRDs
# =============================================================================
print_step "Deleting Knative CRDs..."

print_substep "Deleting operator CRDs..."
delete_by_pattern "crd" "knative.dev"

print_substep "Deleting serving CRDs..."
delete_by_pattern "crd" "serving.knative.dev"

print_substep "Deleting eventing CRDs..."
delete_by_pattern "crd" "eventing.knative.dev"

print_substep "Deleting networking CRDs..."
delete_by_pattern "crd" "networking.internal.knative.dev"

# =============================================================================
# Step 7: Delete Webhooks
# =============================================================================
print_step "Deleting Knative webhooks..."

print_substep "Deleting ValidatingWebhookConfigurations..."
delete_by_pattern "validatingwebhookconfiguration" "knative"

print_substep "Deleting MutatingWebhookConfigurations..."
delete_by_pattern "mutatingwebhookconfiguration" "knative"

# =============================================================================
# Step 8: Cleanup any remaining resources
# =============================================================================
print_step "Cleaning up remaining resources..."

print_substep "Deleting any remaining Knative APIServices..."
delete_by_pattern "apiservice" "knative"

# =============================================================================
# Verification
# =============================================================================
print_step "Verifying cleanup..."

echo ""
echo "Remaining Knative resources (should be empty):"
echo ""

echo "Namespaces:"
kubectl get namespace | grep -E "knative|kourier" || echo "  (none)"

echo ""
echo "CRDs:"
kubectl get crd | grep -i knative || echo "  (none)"

echo ""
echo "ClusterRoles:"
kubectl get clusterrole | grep -i knative || echo "  (none)"

echo ""
echo "ClusterRoleBindings:"
kubectl get clusterrolebinding | grep -i knative || echo "  (none)"

# =============================================================================
# Done
# =============================================================================
print_success "Knative uninstallation complete!"

echo ""
echo "If any resources remain, you may need to manually delete them:"
echo "  kubectl get all -A | grep -i knative"
echo "  kubectl get crd | grep -i knative"
echo ""
