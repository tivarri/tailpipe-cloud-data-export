#!/bin/bash
#
# Tailpipe Azure Cleanup Script
#
# This script removes all Tailpipe resources from your Azure tenant:
# - Cost Management exports (billing and subscription scopes)
# - Azure Policy assignments and definitions
# - Automation Account and runbooks
# - Storage account and resource groups
# - RBAC role assignments
# - Service Principal (optional)
#
# Usage:
#   ./cleanup-tailpipe.sh                          # Interactive mode with confirmations
#   FORCE=1 ./cleanup-tailpipe.sh                  # Skip confirmations
#   DRY_RUN=1 ./cleanup-tailpipe.sh                # Preview without deleting
#   KEEP_SP=1 ./cleanup-tailpipe.sh                # Keep service principal
#   KEEP_STORAGE=1 ./cleanup-tailpipe.sh           # Keep storage account (delete exports only)
#
# Environment Variables:
#   DRY_RUN         - Set to 1 to preview deletions without executing
#   FORCE           - Set to 1 to skip all confirmations
#   KEEP_SP         - Set to 1 to preserve the service principal
#   KEEP_STORAGE    - Set to 1 to preserve storage account and data
#   TENANT_ID       - Target tenant ID (uses current if not set)
#   DEBUG           - Set to 1 for verbose output
#

#==============================================================================
# HELP
#==============================================================================

show_help() {
  cat <<EOF
Tailpipe Azure Cleanup Script

This script removes all Tailpipe resources from your Azure tenant:
  - Cost Management exports (billing and subscription scopes)
  - Azure Policy assignments and definitions
  - Automation Account and runbooks
  - Storage account and resource groups
  - RBAC role assignments
  - Service Principal (optional)

Usage:
  ./cleanup-tailpipe.sh [OPTIONS]

Options:
  -h, --help    Show this help message and exit

Environment Variables:
  DRY_RUN         Set to 1 to preview deletions without executing
  FORCE           Set to 1 to skip all confirmations
  KEEP_SP         Set to 1 to preserve the service principal
  KEEP_STORAGE    Set to 1 to preserve storage account and data
  TENANT_ID       Target tenant ID (uses current if not set)
  DEBUG           Set to 1 for verbose output

Examples:
  ./cleanup-tailpipe.sh                    # Interactive mode
  DRY_RUN=1 ./cleanup-tailpipe.sh          # Preview without deleting
  FORCE=1 ./cleanup-tailpipe.sh            # Skip confirmations
  KEEP_STORAGE=1 ./cleanup-tailpipe.sh     # Keep storage, delete exports only

EOF
  exit 0
}

# Parse command line arguments
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      ;;
    *)
      echo "Warning: Unknown option ignored: $arg"
      ;;
  esac
done

set -Eeuo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================

# Color output
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Resource names
RESOURCE_GROUP="tailpipe-dataexport"
AUTOMATION_RG="tailpipe-automation"
AUTOMATION_ACCOUNT="tailpipeAutomation"
RUNBOOK_NAME="RegisterResourceProviders"
EXPORT_NAME_PREFIX="TailpipeDataExport"
EXPORT_NAME_BILLING="TailpipeAllSubs"
POLICY_NAME="deploy-cost-export"
POLICY_ASSIGNMENT_NAME="deploy-cost-export-a"

# Tailpipe Enterprise Application IDs
TAILPIPE_UAT_APP_ID="071b0391-48e8-483c-b652-a8a6cd43a018"
TAILPIPE_PROD_APP_ID="f5f07900-0484-4506-a34d-ec781138342a"

# Options
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
KEEP_SP="${KEEP_SP:-0}"
KEEP_STORAGE="${KEEP_STORAGE:-0}"
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--debug"

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

log_info() {
  echo -e "${BLUE}ℹ${NC}  $*"
}

log_success() {
  echo -e "${GREEN}✅${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}⚠️${NC}  $*"
}

log_error() {
  echo -e "${RED}❌${NC} $*"
}

log_section() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}$*${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

execute() {
  if [ "$DRY_RUN" = "1" ]; then
    echo -e "${YELLOW}[DRY RUN]${NC} $*"
    return 0
  else
    "$@"
  fi
}

confirm() {
  if [ "$FORCE" = "1" ]; then
    return 0
  fi

  local prompt="$1"
  read -rp "$prompt [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

delete_role_assignments() {
  local principal_id="$1"
  local description="$2"

  if [ -z "$principal_id" ] || [ "$principal_id" = "null" ]; then
    log_info "No principal ID for $description, skipping role cleanup"
    return 0
  fi

  log_info "Removing role assignments for $description..."

  local assignments
  assignments=$(az role assignment list --assignee-object-id "$principal_id" --query "[].id" -o tsv 2>/dev/null || echo "")

  if [ -z "$assignments" ]; then
    log_info "No role assignments found for $description"
    return 0
  fi

  local count=0
  while IFS= read -r assignment_id; do
    [ -z "$assignment_id" ] && continue
    execute az role assignment delete --ids "$assignment_id" --only-show-errors $DEBUG_FLAG && \
      count=$((count + 1))
  done <<< "$assignments"

  log_success "Removed $count role assignment(s) for $description"
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

log_section "Tailpipe Azure Cleanup"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No resources will be deleted"
fi

if [ "$KEEP_SP" = "1" ]; then
  log_warning "KEEP_SP set - Service principal will be preserved"
fi

if [ "$KEEP_STORAGE" = "1" ]; then
  log_warning "KEEP_STORAGE set - Storage account and data will be preserved"
fi

# Show Azure CLI version
AZ_VER=$(az version --query "\"azure-cli\"" -o tsv 2>/dev/null || echo "unknown")
log_info "Azure CLI version: $AZ_VER"

# Get target tenant
TARGET_TENANT=${TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || echo "")}
if [ -n "$TARGET_TENANT" ]; then
  log_info "Targeting tenant: $TARGET_TENANT"
fi

# Enumerate subscriptions
log_info "Enumerating subscriptions..."

MAP=$(az account list --all --refresh --query "[?state!='Disabled'].{id:id,tenantId:tenantId}" -o tsv 2>/dev/null || echo "")
if [ -n "$TARGET_TENANT" ]; then
  SUB_IDS=$(echo "$MAP" | awk -v t="$TARGET_TENANT" '$2==t {print $1}')
else
  SUB_IDS=$(echo "$MAP" | awk '{print $1}')
fi

if [ -z "$SUB_IDS" ]; then
  log_warning "No subscriptions found"
  SUB_IDS=""
fi

SUB_COUNT=$(echo "$SUB_IDS" | wc -w | tr -d ' ')
log_info "Found $SUB_COUNT subscription(s)"

# Find service principals
log_info "Looking for Tailpipe service principals..."

SP_UAT=$(az ad sp list --filter "appId eq '$TAILPIPE_UAT_APP_ID'" --query "[0].id" -o tsv 2>/dev/null || echo "")
SP_PROD=$(az ad sp list --filter "appId eq '$TAILPIPE_PROD_APP_ID'" --query "[0].id" -o tsv 2>/dev/null || echo "")

if [ -n "$SP_UAT" ]; then
  log_info "Found UAT service principal: $SP_UAT"
fi

if [ -n "$SP_PROD" ]; then
  log_info "Found PROD service principal: $SP_PROD"
fi

# Find management groups with policies
log_info "Checking for management group policy deployments..."

ROOT_MG=$(az account management-group list --query "[?properties.details.parent==null].name | [0]" -o tsv 2>/dev/null || echo "")
if [ -n "$ROOT_MG" ] && [ "$ROOT_MG" != "null" ]; then
  log_info "Root management group: $ROOT_MG"
fi

#==============================================================================
# CONFIRMATION
#==============================================================================

if [ "$FORCE" != "1" ]; then
  log_section "Resources to be Deleted"

  echo "The following resources will be removed:"
  echo ""
  echo "  📋 Cost Management Exports:"
  echo "     - Billing-scope exports (if any)"
  echo "     - Subscription-scope exports across $SUB_COUNT subscription(s)"
  echo ""
  echo "  📜 Azure Policies:"
  echo "     - Policy definitions and assignments"
  echo "     - Remediation tasks"
  echo ""
  echo "  ⚙️  Automation:"
  echo "     - Automation Account: $AUTOMATION_ACCOUNT"
  echo "     - Resource Group: $AUTOMATION_RG"
  echo ""

  if [ "$KEEP_STORAGE" != "1" ]; then
    echo "  💾 Storage:"
    echo "     - Storage accounts matching 'tailpipedataexport*'"
    echo "     - Resource Group: $RESOURCE_GROUP"
    echo "     - ALL COST DATA WILL BE DELETED"
    echo ""
  fi

  if [ "$KEEP_SP" != "1" ]; then
    echo "  🔑 Service Principals:"
    [ -n "$SP_UAT" ] && echo "     - Tailpipe UAT ($TAILPIPE_UAT_APP_ID)"
    [ -n "$SP_PROD" ] && echo "     - Tailpipe PROD ($TAILPIPE_PROD_APP_ID)"
    echo ""
  fi

  echo "  🔐 RBAC:"
  echo "     - All role assignments for Tailpipe service principals"
  echo "     - Policy managed identity role assignments"
  echo "     - Automation managed identity role assignments"
  echo ""

  if ! confirm "Do you want to proceed with cleanup?"; then
    log_warning "Cleanup cancelled by user"
    exit 0
  fi
fi

#==============================================================================
# DELETE COST EXPORTS
#==============================================================================

log_section "Deleting Cost Management Exports"

# Delete billing-scope exports
log_info "Checking for billing-scope exports..."

for SUBID in $SUB_IDS; do
  # Try to find billing accounts
  BA_ID=$(az rest --method GET \
    --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01" \
    --query "value[0].name" -o tsv 2>/dev/null || true)

  if [ -n "$BA_ID" ]; then
    BILLING_PROFILES=$(az rest --method GET \
      --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BA_ID/billingProfiles?api-version=2024-04-01" \
      --query "value[].id" -o tsv 2>/dev/null || true)

    for BILLING_SCOPE in $BILLING_PROFILES; do
      [ -z "$BILLING_SCOPE" ] && continue

      log_info "Deleting export '$EXPORT_NAME_BILLING' from billing scope..."
      execute az rest --method DELETE \
        --url "https://management.azure.com/$BILLING_SCOPE/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_BILLING?api-version=2023-08-01" \
        --only-show-errors $DEBUG_FLAG 2>/dev/null && \
        log_success "Deleted billing export: $EXPORT_NAME_BILLING" || \
        log_info "Billing export not found or already deleted"
    done
  fi
  break  # Only need to check once
done

# Delete subscription-scope exports
log_info "Deleting subscription-scope exports..."

DELETED_COUNT=0
for SUBID in $SUB_IDS; do
  [ -z "$SUBID" ] && continue

  # List all exports in subscription
  EXPORTS=$(az rest --method GET \
    --url "https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports?api-version=2023-08-01" \
    --query "value[?starts_with(name, '$EXPORT_NAME_PREFIX')].name" -o tsv 2>/dev/null || echo "")

  for EXPORT_NAME in $EXPORTS; do
    [ -z "$EXPORT_NAME" ] && continue

    execute az rest --method DELETE \
      --url "https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports/$EXPORT_NAME?api-version=2023-08-01" \
      --only-show-errors $DEBUG_FLAG 2>/dev/null && \
      DELETED_COUNT=$((DELETED_COUNT + 1))
  done
done

log_success "Deleted $DELETED_COUNT subscription-scope export(s)"

#==============================================================================
# DELETE AZURE POLICIES
#==============================================================================

log_section "Deleting Azure Policies"

# Function to delete policy at a scope
delete_policy_at_scope() {
  local scope="$1"
  local scope_param="$2"
  local scope_name="$3"

  log_info "Checking for policy at $scope_name..."

  # Delete remediation tasks
  REMEDIATIONS=$(az policy remediation list $scope_param --query "[?contains(policyAssignmentId, '$POLICY_ASSIGNMENT_NAME')].name" -o tsv 2>/dev/null || echo "")
  for rem in $REMEDIATIONS; do
    [ -z "$rem" ] && continue
    log_info "Deleting remediation task: $rem"
    execute az policy remediation delete --name "$rem" $scope_param --only-show-errors 2>/dev/null || true
  done

  # Delete policy assignment
  if az policy assignment show --name "$POLICY_ASSIGNMENT_NAME" --scope "$scope" &>/dev/null; then
    # Get managed identity before deleting
    POLICY_MI=$(az policy assignment show --name "$POLICY_ASSIGNMENT_NAME" --scope "$scope" --query 'identity.principalId' -o tsv 2>/dev/null || echo "")

    log_info "Deleting policy assignment: $POLICY_ASSIGNMENT_NAME"
    execute az policy assignment delete --name "$POLICY_ASSIGNMENT_NAME" --scope "$scope" --only-show-errors $DEBUG_FLAG

    # Delete role assignments for policy managed identity
    if [ -n "$POLICY_MI" ] && [ "$POLICY_MI" != "null" ]; then
      delete_role_assignments "$POLICY_MI" "Policy managed identity"
    fi

    log_success "Policy assignment deleted at $scope_name"
  else
    log_info "No policy assignment found at $scope_name"
  fi

  # Delete policy definition
  if az policy definition show --name "$POLICY_NAME" $scope_param &>/dev/null; then
    log_info "Deleting policy definition: $POLICY_NAME"
    execute az policy definition delete --name "$POLICY_NAME" $scope_param --only-show-errors $DEBUG_FLAG
    log_success "Policy definition deleted at $scope_name"
  else
    log_info "No policy definition found at $scope_name"
  fi
}

# Try management group scope first
if [ -n "$ROOT_MG" ] && [ "$ROOT_MG" != "null" ]; then
  MG_SCOPE="/providers/Microsoft.Management/managementGroups/$ROOT_MG"
  delete_policy_at_scope "$MG_SCOPE" "--management-group $ROOT_MG" "management group"
fi

# Try subscription scopes
for SUBID in $SUB_IDS; do
  [ -z "$SUBID" ] && continue
  SUB_SCOPE="/subscriptions/$SUBID"
  delete_policy_at_scope "$SUB_SCOPE" "--subscription $SUBID" "subscription $SUBID"
done

#==============================================================================
# DELETE AUTOMATION ACCOUNT
#==============================================================================

log_section "Deleting Automation Account"

if az group exists --name "$AUTOMATION_RG" 2>/dev/null | grep -q true; then
  # Get managed identity before deleting
  AUTO_MI=$(az automation account show \
    --name "$AUTOMATION_ACCOUNT" \
    --resource-group "$AUTOMATION_RG" \
    --query "identity.principalId" -o tsv 2>/dev/null || echo "")

  log_info "Deleting resource group: $AUTOMATION_RG"
  execute az group delete --name "$AUTOMATION_RG" --yes --no-wait --only-show-errors $DEBUG_FLAG

  # Delete role assignments for automation managed identity
  if [ -n "$AUTO_MI" ] && [ "$AUTO_MI" != "null" ]; then
    delete_role_assignments "$AUTO_MI" "Automation managed identity"
  fi

  log_success "Automation resource group deletion initiated"
else
  log_info "Automation resource group not found"
fi

#==============================================================================
# DELETE STORAGE & RESOURCE GROUP
#==============================================================================

if [ "$KEEP_STORAGE" != "1" ]; then
  log_section "Deleting Storage and Resource Group"

  if az group exists --name "$RESOURCE_GROUP" 2>/dev/null | grep -q true; then
    if [ "$FORCE" != "1" ]; then
      log_warning "This will DELETE ALL COST DATA in the storage account"
      if ! confirm "Are you sure you want to delete the storage account and all data?"; then
        log_warning "Storage deletion skipped"
      else
        log_info "Deleting resource group: $RESOURCE_GROUP"
        execute az group delete --name "$RESOURCE_GROUP" --yes --no-wait --only-show-errors $DEBUG_FLAG
        log_success "Storage resource group deletion initiated"
      fi
    else
      log_info "Deleting resource group: $RESOURCE_GROUP"
      execute az group delete --name "$RESOURCE_GROUP" --yes --no-wait --only-show-errors $DEBUG_FLAG
      log_success "Storage resource group deletion initiated"
    fi
  else
    log_info "Storage resource group not found"
  fi
else
  log_info "Skipping storage deletion (KEEP_STORAGE=1)"
fi

#==============================================================================
# DELETE SERVICE PRINCIPAL ROLE ASSIGNMENTS
#==============================================================================

log_section "Cleaning Up Service Principal RBAC"

if [ -n "$SP_UAT" ]; then
  delete_role_assignments "$SP_UAT" "Tailpipe UAT service principal"
fi

if [ -n "$SP_PROD" ]; then
  delete_role_assignments "$SP_PROD" "Tailpipe PROD service principal"
fi

#==============================================================================
# DELETE SERVICE PRINCIPALS (OPTIONAL)
#==============================================================================

if [ "$KEEP_SP" != "1" ]; then
  log_section "Deleting Service Principals"

  if [ "$FORCE" != "1" ]; then
    log_warning "The Tailpipe service principal is used to read cost data"
    log_warning "Deleting it will break the Tailpipe integration"
    if ! confirm "Do you want to delete the service principal?"; then
      log_warning "Service principal deletion skipped"
      KEEP_SP=1
    fi
  fi

  if [ "$KEEP_SP" != "1" ]; then
    if [ -n "$SP_UAT" ]; then
      log_info "Deleting UAT service principal..."
      execute az ad sp delete --id "$SP_UAT" --only-show-errors 2>/dev/null && \
        log_success "UAT service principal deleted" || \
        log_warning "Failed to delete UAT service principal"
    fi

    if [ -n "$SP_PROD" ]; then
      log_info "Deleting PROD service principal..."
      execute az ad sp delete --id "$SP_PROD" --only-show-errors 2>/dev/null && \
        log_success "PROD service principal deleted" || \
        log_warning "Failed to delete PROD service principal"
    fi

    if [ -z "$SP_UAT" ] && [ -z "$SP_PROD" ]; then
      log_info "No service principals found to delete"
    fi
  fi
else
  log_info "Skipping service principal deletion (KEEP_SP=1)"
fi

#==============================================================================
# SUMMARY
#==============================================================================

log_section "Cleanup Summary"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN COMPLETE - No resources were deleted"
  log_info "Run without DRY_RUN=1 to perform actual cleanup"
else
  log_success "Tailpipe cleanup complete!"
  echo ""
  log_info "Resources deleted:"
  log_info "  ✓ Cost Management exports"
  log_info "  ✓ Azure Policy assignments and definitions"
  log_info "  ✓ Automation Account (deletion in progress)"
  [ "$KEEP_STORAGE" != "1" ] && log_info "  ✓ Storage account (deletion in progress)"
  [ "$KEEP_SP" != "1" ] && log_info "  ✓ Service principals"
  log_info "  ✓ RBAC role assignments"
  echo ""
  log_warning "Note: Resource group deletions run asynchronously and may take several minutes"
  echo ""
  log_info "To check deletion status:"
  log_info "  az group list --query \"[?starts_with(name, 'tailpipe')].{Name:name, State:properties.provisioningState}\" -o table"
fi

log_info ""
log_info "Cleanup script finished"
