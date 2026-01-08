#!/bin/bash
#
# Tailpipe Azure Setup - Unified Installation Script
#
# This script sets up everything needed for Tailpipe cost analytics:
# 1. Service Principal for Tailpipe Enterprise Application
# 2. Resource group and storage account for cost exports
# 3. Cost Management exports (billing-scope or subscription-scope)
#    - Automatically detects if ActualCost export type is available
#    - Falls back to Usage export type if ActualCost is not supported
#    - CSP subscriptions always use Usage (ActualCost not available)
# 4. Azure Policy for automatic export creation on new subscriptions (CSP only)
# 5. Automation Account for provider registration (CSP only)
#
# Export Types:
#   ActualCost - Shows actual costs including one-time and recurring purchases
#                as they are incurred (preferred for financial reporting)
#   Usage      - Shows usage-based costs with purchases amortized across
#                their applicable time period
#
# Usage:
#   ./setup-tailpipe.sh                    # Interactive mode
#   DRY_RUN=1 ./setup-tailpipe.sh          # Preview changes without executing
#   LOCATION=uksouth ./setup-tailpipe.sh   # Non-interactive with env vars
#
# Environment Variables:
#   LOCATION              - Azure region (e.g., uksouth, westeurope)
#   ENTERPRISE_APP_ID     - Tailpipe app ID (default: UAT)
#   MANAGEMENT_GROUP_ID   - Target MG for policy deployment (auto-detected if not set)
#   BILLING_SCOPE         - Billing profile ID (auto-detected if not set)
#   STORAGE_SUBID         - Subscription for storage account (auto-detected if not set)
#   TENANT_ID             - Target tenant ID (uses current if not set)
#   DRY_RUN               - Set to 1 to preview without making changes
#   SKIP_AUTOMATION       - Set to 1 to skip Automation Account setup
#   SKIP_POLICY           - Set to 1 to skip Policy deployment
#   DEBUG                 - Set to 1 for verbose Azure CLI output
#

set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO (exit $?): see above. If you saw: The content for this response was already consumed, update Azure CLI (brew update && brew upgrade azure-cli) and re-run with DEBUG=1."' ERR

#==============================================================================
# CONFIGURATION
#==============================================================================

# Script version
VERSION="1.3.0"

#==============================================================================
# API VERSION DOCUMENTATION
#==============================================================================
# This script uses hardcoded Azure REST API versions. These should be reviewed
# periodically for deprecation status and updated as needed.
#
# API Versions Used:
#   - Microsoft.Billing (billingAccounts): 2024-04-01
#     Status: Current GA version
#     Used in: Billing scope discovery (lines ~677, ~685)
#
#   - Microsoft.CostManagement (exports): 2025-03-01
#     Status: Current GA version
#     Used in: Cost export creation (lines ~735, ~816)
#
#   - Microsoft.Resources (subscriptions): 2020-01-01
#     Status: Stable, widely supported
#     Used in: Subscription quota ID lookup (line ~422)
#
# To check for newer API versions:
#   az provider show --namespace Microsoft.CostManagement --query "resourceTypes[?resourceType=='exports'].apiVersions" -o tsv
#   az provider show --namespace Microsoft.Billing --query "resourceTypes[?resourceType=='billingAccounts'].apiVersions" -o tsv
#
# Last reviewed: 2025-01
#==============================================================================

# Color output
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m' # No Color
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Resource names
RESOURCE_GROUP="tailpipe-dataexport"
AUTOMATION_RG="tailpipe-automation"
AUTOMATION_ACCOUNT="tailpipeAutomation"
RUNBOOK_NAME="RegisterResourceProviders"
STORAGE_CONTAINER="dataexport"
EXPORT_NAME_PREFIX="TailpipeDataExport"
EXPORT_FOLDER_PREFIX="tailpipe"
POLICY_NAME="deploy-cost-export"
POLICY_ASSIGNMENT_NAME="deploy-cost-export-a"
PROVIDER_POLICY_NAME="register-providers"
PROVIDER_POLICY_ASSIGNMENT="register-providers-a"

# Tailpipe Enterprise Application IDs
TAILPIPE_UAT_APP_ID="071b0391-48e8-483c-b652-a8a6cd43a018"
TAILPIPE_PROD_APP_ID="f5f07900-0484-4506-a34d-ec781138342a"

# Default to UAT unless overridden
ENTERPRISE_APP_ID="${ENTERPRISE_APP_ID:-$TAILPIPE_UAT_APP_ID}"

# Dry run mode
DRY_RUN="${DRY_RUN:-0}"

# Debug mode
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--debug"

# Required resource providers
REQUIRED_PROVIDERS=(
  "Microsoft.Resources"
  "Microsoft.Storage"
  "Microsoft.CostManagement"
  "Microsoft.CostManagementExports"
  "Microsoft.Insights"
)

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

ensure_provider() {
  local ns="$1"
  local state
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [ "$state" != "Registered" ]; then
    log_info "Registering provider: $ns (current state: $state)"
    execute az provider register --namespace "$ns" --accept-terms --wait >/dev/null
  fi
  local new_state
  new_state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  log_info "$ns -> $new_state"
}

wait_for_sp() {
  local app_id="$1"
  local sp_id=""
  local attempts=12
  local base_sleep=2

  for i in $(seq 1 $attempts); do
    # Try both resolvers
    sp_id=$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)
    if [ -z "$sp_id" ]; then
      sp_id=$(az ad sp list --filter "appId eq '$app_id'" --query "[0].id" -o tsv 2>/dev/null || true)
    fi

    if [ -n "$sp_id" ]; then
      echo "$sp_id"
      return 0
    fi

    # Add random jitter (0-2 seconds) to prevent thundering herd
    local jitter=$(( RANDOM % 3 ))
    local sleep_time=$(( base_sleep + jitter ))

    log_info "Waiting for service principal to appear... ($i/$attempts, sleeping ${sleep_time}s)"
    sleep $sleep_time
    base_sleep=$(( base_sleep < 30 ? base_sleep * 2 : 30 ))
  done

  return 1
}

check_role_assignment() {
  local principal="$1"
  local role="$2"
  local scope="$3"

  local count
  count=$(az role assignment list \
    --assignee-object-id "$principal" \
    --role "$role" \
    --scope "$scope" \
    --query "length(@)" -o tsv 2>/dev/null || echo 0)

  [ "${count:-0}" -gt 0 ]
}

create_role_assignment() {
  local principal="$1"
  local role="$2"
  local scope="$3"
  local description="$4"

  if check_role_assignment "$principal" "$role" "$scope"; then
    log_info "$description already assigned"
    return 0
  fi

  log_info "Assigning $description..."
  execute az role assignment create \
    --assignee-object-id "$principal" \
    --role "$role" \
    --scope "$scope" \
    --only-show-errors $DEBUG_FLAG || {
      log_warning "Failed to assign $description"
      return 1
    }
  log_success "$description assigned"
}

retry_with_backoff() {
  local max_attempts="${1:-3}"
  shift
  local attempt=1
  local delay=2

  while [ $attempt -le $max_attempts ]; do
    if "$@"; then
      return 0
    fi

    if [ $attempt -eq $max_attempts ]; then
      return 1
    fi

    local jitter=$((RANDOM % 3))
    local sleep_time=$((delay + jitter))
    log_info "Attempt $attempt failed, retrying in ${sleep_time}s..."
    sleep $sleep_time
    delay=$((delay * 2))
    [ $delay -gt 30 ] && delay=30
    attempt=$((attempt + 1))
  done
  return 1
}

should_skip_subscription() {
  local sub_id="$1"
  local quota_id="$2"

  # Skip Visual Studio subscriptions (they don't support Cost Management exports)
  if echo "$quota_id" | grep -qiE "MSDN|VisualStudio|MSDNDevTest|PAYG_2014-09-01"; then
    echo "Visual Studio subscription (unsupported)"
    return 0
  fi

  # Skip free trial subscriptions
  if echo "$quota_id" | grep -qiE "FreeTrial"; then
    echo "Free trial subscription (limited features)"
    return 0
  fi

  return 1
}

# Check if a subscription supports ActualCost exports
# CSP subscriptions only support Usage, not ActualCost
is_csp_subscription() {
  local sub_id="$1"
  echo "$CSP_SUBS" | grep -q "$sub_id"
}

# Try to create an export, attempting ActualCost first for non-CSP subscriptions
# Returns: 0 on success, 1 on failure
# Outputs to stdout: the export type that was successfully created (ActualCost or Usage)
# Sets global LAST_EXPORT_ERROR on failure
create_export_with_type_fallback() {
  local url="$1"
  local payload_template="$2"  # Payload with EXPORT_TYPE_PLACEHOLDER
  local is_csp="$3"            # 1 if CSP subscription, 0 otherwise
  local error_output
  error_output=$(mktemp)

  local export_types=()

  if [ "$is_csp" = "1" ]; then
    # CSP subscriptions only support Usage
    export_types=("Usage")
  else
    # Non-CSP subscriptions: try ActualCost first, fallback to Usage
    export_types=("ActualCost" "Usage")
  fi

  for export_type in "${export_types[@]}"; do
    # Create payload with current export type
    local payload
    payload=$(echo "$payload_template" | sed "s/EXPORT_TYPE_PLACEHOLDER/$export_type/g")

    local payload_file
    payload_file=$(mktemp)
    echo "$payload" > "$payload_file"

    # In dry run mode, just return the first export type we would try
    if [ "$DRY_RUN" = "1" ]; then
      echo -e "${YELLOW}[DRY RUN]${NC} az rest --method PUT --url $url --body @$payload_file --only-show-errors" >&2
      rm -f "$payload_file" "$error_output"
      echo "$export_type"
      return 0
    fi

    if az rest --method PUT \
      --url "$url" \
      --body @"$payload_file" \
      --only-show-errors $DEBUG_FLAG 2>"$error_output"; then
      rm -f "$payload_file" "$error_output"
      echo "$export_type"
      return 0
    fi

    rm -f "$payload_file"

    # Check if error is due to unsupported export type
    local err_msg
    err_msg=$(cat "$error_output")

    # If this is ActualCost and it failed, check if we should try Usage
    if [ "$export_type" = "ActualCost" ]; then
      # Common error patterns for unsupported ActualCost:
      # - "The export type 'ActualCost' is not supported"
      # - "Invalid export type"
      # - "ActualCost is not available"
      if echo "$err_msg" | grep -qiE "not supported|invalid.*type|not available|ActualCost"; then
        log_info "ActualCost not supported, trying Usage export type..."
        continue
      fi
    fi

    # For other errors, or if Usage also fails, report the error
    LAST_EXPORT_ERROR="$err_msg"
  done

  rm -f "$error_output"
  return 1
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

# Handle --help flag
show_help() {
  cat <<'HELP'
Tailpipe Azure Setup - Unified Installation Script

USAGE:
  ./setup-tailpipe.sh [OPTIONS]

OPTIONS:
  -h, --help    Show this help message and exit

ENVIRONMENT VARIABLES:
  LOCATION              Azure region (e.g., uksouth, westeurope)
  ENTERPRISE_APP_ID     Tailpipe app ID (default: UAT)
  MANAGEMENT_GROUP_ID   Target MG for policy deployment (auto-detected if not set)
  BILLING_SCOPE         Billing profile ID (auto-detected if not set)
  STORAGE_SUBID         Subscription for storage account (auto-detected if not set)
  TENANT_ID             Target tenant ID (uses current if not set)
  DRY_RUN               Set to 1 to preview without making changes
  SKIP_AUTOMATION       Set to 1 to skip Automation Account setup
  SKIP_POLICY           Set to 1 to skip Policy deployment
  DEBUG                 Set to 1 for verbose Azure CLI output

EXAMPLES:
  Interactive mode:
    ./setup-tailpipe.sh

  Preview changes without executing:
    DRY_RUN=1 ./setup-tailpipe.sh

  Non-interactive with environment variables:
    LOCATION=uksouth ./setup-tailpipe.sh

  Skip automation components:
    SKIP_AUTOMATION=1 SKIP_POLICY=1 ./setup-tailpipe.sh

REQUIREMENTS:
  - Azure CLI version 2.50.0 or later
  - Logged in to Azure (az login)
  - Appropriate permissions in target tenant

For more information, see README.md
HELP
  exit 0
}

# Parse command line arguments
for arg in "$@"; do
  case $arg in
    -h|--help)
      show_help
      ;;
    -*)
      echo -e "${YELLOW}⚠️${NC}  Unknown option: $arg (ignored)"
      ;;
  esac
done

# Acquire file lock to prevent concurrent execution
LOCK_FILE="/tmp/tailpipe-azure-setup.lock"
acquire_lock() {
  # Try flock first (Linux), fall back to mkdir-based locking (macOS)
  if command -v flock &>/dev/null; then
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
      return 1
    fi
  else
    # macOS fallback: use mkdir as atomic lock operation
    if ! mkdir "$LOCK_FILE.d" 2>/dev/null; then
      return 1
    fi
    trap 'rmdir "$LOCK_FILE.d" 2>/dev/null' EXIT
  fi
  return 0
}

if ! acquire_lock; then
  log_error "Another instance of this script is already running"
  log_error "If you're sure no other instance is running, delete: $LOCK_FILE or $LOCK_FILE.d"
  exit 1
fi

log_section "Tailpipe Azure Setup v$VERSION"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No changes will be made"
fi

# Show and check Azure CLI version
AZ_VER=$(az version --query "\"azure-cli\"" -o tsv 2>/dev/null || echo "unknown")
log_info "Azure CLI version: $AZ_VER"

# Minimum required version is 2.50.0 (released June 2023)
# Required for: proper Cost Management export support, managed identity features
MIN_AZ_VERSION="2.50.0"

check_version() {
  local current="$1"
  local minimum="$2"

  # Handle "unknown" version
  if [ "$current" = "unknown" ]; then
    return 1
  fi

  # Compare versions using sort -V
  printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1 | grep -qx "$minimum"
}

if ! check_version "$AZ_VER" "$MIN_AZ_VERSION"; then
  log_error "Azure CLI version $MIN_AZ_VERSION or later is required (found: $AZ_VER)"
  log_info "Update with: brew update && brew upgrade azure-cli"
  log_info "Or see: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
  exit 1
fi

# Detect Azure sovereign cloud environment
detect_azure_cloud() {
  # Detect Azure cloud environment from current subscription
  local cloud_name
  cloud_name=$(az cloud show --query name -o tsv 2>/dev/null || echo "AzureCloud")

  case "$cloud_name" in
    AzureCloud)
      AZURE_ENVIRONMENT="public"
      AZURE_MGMT_ENDPOINT="management.azure.com"
      ;;
    AzureUSGovernment)
      AZURE_ENVIRONMENT="government"
      AZURE_MGMT_ENDPOINT="management.usgovcloudapi.net"
      log_warning "Azure Government cloud detected"
      ;;
    AzureChinaCloud)
      AZURE_ENVIRONMENT="china"
      AZURE_MGMT_ENDPOINT="management.chinacloudapi.cn"
      log_warning "Azure China cloud detected"
      ;;
    AzureGermanCloud)
      AZURE_ENVIRONMENT="germany"
      AZURE_MGMT_ENDPOINT="management.microsoftazure.de"
      log_warning "Azure Germany cloud detected (deprecated)"
      ;;
    *)
      AZURE_ENVIRONMENT="unknown"
      AZURE_MGMT_ENDPOINT="management.azure.com"
      log_warning "Unknown Azure cloud: $cloud_name, using public endpoints"
      ;;
  esac

  log_info "Azure environment: $AZURE_ENVIRONMENT"
}

detect_azure_cloud

# Validate location
if [ -n "${LOCATION:-}" ]; then
  log_info "Using LOCATION from environment: $LOCATION"
else
  read -rp "Enter Azure region (e.g., uksouth, westeurope): " LOCATION
fi

LOCATION=$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')
if [ -z "$LOCATION" ]; then
  log_error "No location provided. Run: az account list-locations -o table"
  exit 1
fi

if ! az account list-locations --query "[?name=='$LOCATION'] | length(@)" -o tsv | grep -q '^1$'; then
  log_error "Invalid location: '$LOCATION'"
  echo "Run 'az account list-locations -o table' to see valid regions"
  exit 1
fi

log_info "Target location: $LOCATION"

# Determine target tenant
TARGET_TENANT=${TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || echo "")}
if [ -n "$TARGET_TENANT" ]; then
  log_info "Targeting tenant: $TARGET_TENANT"
else
  log_warning "No target tenant specified, using all accessible tenants"
fi

#==============================================================================
# PHASE 1: CORE INFRASTRUCTURE
#==============================================================================

log_section "Phase 1: Core Infrastructure Setup"

# Ensure Service Principal exists
log_info "Ensuring Tailpipe service principal exists (App ID: $ENTERPRISE_APP_ID)..."

SP_OBJECT_ID=$(az ad sp show --id "$ENTERPRISE_APP_ID" --query id -o tsv 2>/dev/null || true)
if [ -z "$SP_OBJECT_ID" ]; then
  SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$ENTERPRISE_APP_ID'" --query "[0].id" -o tsv 2>/dev/null || true)
fi

if [ -z "$SP_OBJECT_ID" ]; then
  log_info "Service principal not found, creating..."
  if [ "$DRY_RUN" = "0" ]; then
    SP_OBJECT_ID=$(az ad sp create --id "$ENTERPRISE_APP_ID" --query id -o tsv --only-show-errors $DEBUG_FLAG 2>/dev/null || true)

    if [ -z "$SP_OBJECT_ID" ]; then
      log_info "Waiting for service principal creation to complete..."
      SP_OBJECT_ID=$(wait_for_sp "$ENTERPRISE_APP_ID")
    fi

    if [ -z "$SP_OBJECT_ID" ]; then
      log_error "Failed to create service principal. Check tenant permissions."
      exit 1
    fi
    log_success "Service principal created (Object ID: $SP_OBJECT_ID)"
  else
    log_info "[DRY RUN] Would create service principal"
    SP_OBJECT_ID="dry-run-sp-id"
  fi
else
  log_success "Service principal exists (Object ID: $SP_OBJECT_ID)"
fi

# Enumerate subscriptions
log_info "Enumerating subscriptions..."

if [ -n "${SUBS:-}" ]; then
  log_info "Using subscriptions from SUBS env var"
  SUB_IDS="$SUBS"
else
  MAP=$(az account list --all --refresh --only-show-errors --query "[?state!='Disabled'].{id:id,tenantId:tenantId,name:name}" -o tsv)
  if [ -n "$TARGET_TENANT" ]; then
    SUB_IDS=$(echo "$MAP" | awk -v t="$TARGET_TENANT" '$2==t {print $1}')
  else
    SUB_IDS=$(echo "$MAP" | awk '{print $1}')
  fi
fi

if [ -z "$SUB_IDS" ]; then
  log_error "No accessible subscriptions found"
  exit 1
fi

SUB_COUNT=$(echo "$SUB_IDS" | wc -w | tr -d ' ')
log_success "Found $SUB_COUNT subscription(s)"

# Classify subscriptions (CSP vs non-CSP) and filter special types
log_info "Classifying subscriptions by type..."

CSP_SUBS=""
NONCSP_SUBS=""
# Store quota IDs in a temp file (bash 3.2 compatible)
SUB_QUOTA_FILE=$(mktemp)

for SID in $SUB_IDS; do
  QID=$(az rest --method GET \
    --url "https://management.azure.com/subscriptions/$SID?api-version=2020-01-01" \
    --query "subscriptionPolicies.quotaId" -o tsv 2>/dev/null || echo "")

  # Store mapping: subscription_id|quota_id
  echo "$SID|$QID" >> "$SUB_QUOTA_FILE"

  if echo "$QID" | grep -qiE "CSP|AZURE_PLAN|MICROSOFT_AZURE_PLAN"; then
    CSP_SUBS="$CSP_SUBS $SID"
  else
    NONCSP_SUBS="$NONCSP_SUBS $SID"
  fi
done

CSP_COUNT=$(echo "$CSP_SUBS" | wc -w | tr -d ' ')
NONCSP_COUNT=$(echo "$NONCSP_SUBS" | wc -w | tr -d ' ')

log_info "CSP/Partner subscriptions: $CSP_COUNT"
log_info "MCA/EA subscriptions: $NONCSP_COUNT"

# Choose host subscription for storage
if [ -n "${STORAGE_SUBID:-}" ]; then
  HOST_SUBID="$STORAGE_SUBID"
  log_info "Using STORAGE_SUBID from environment: $HOST_SUBID"
else
  # Interactive subscription selection
  log_section "Select Storage Account Subscription"
  log_info "The storage account will be created in one of your subscriptions."
  log_info "This subscription will host all cost export data."
  echo ""

  # Build subscription list with details
  SUB_ARRAY=()
  SUB_NAMES=()
  SUB_TYPES=()
  INDEX=1

  for SID in $SUB_IDS; do
    SUB_ARRAY+=("$SID")

    # Get subscription name
    SUB_NAME=$(echo "$MAP" | awk -v sid="$SID" '$1==sid {$1=$2=""; print substr($0,3)}')
    [ -z "$SUB_NAME" ] && SUB_NAME="(Unknown)"
    SUB_NAMES+=("$SUB_NAME")

    # Determine type
    if echo "$CSP_SUBS" | grep -q "$SID"; then
      SUB_TYPES+=("CSP")
    else
      SUB_TYPES+=("MCA/EA")
    fi

    INDEX=$((INDEX + 1))
  done

  # Display table
  echo -e "${BOLD}Available Subscriptions:${NC}"
  printf "%-5s %-10s %-40s %s\n" "No." "Type" "Name" "Subscription ID"
  printf "%-5s %-10s %-40s %s\n" "---" "--------" "----------------------------------------" "------------------------------------"

  for i in "${!SUB_ARRAY[@]}"; do
    NUM=$((i + 1))
    printf "%-5s %-10s %-40.40s %s\n" "$NUM" "${SUB_TYPES[$i]}" "${SUB_NAMES[$i]}" "${SUB_ARRAY[$i]}"
  done

  echo ""

  # Suggest default (prefer non-CSP)
  if [ -n "$NONCSP_SUBS" ]; then
    for tok in $NONCSP_SUBS; do DEFAULT_SUB="$tok"; break; done
    DEFAULT_TYPE="MCA/EA (recommended for storage)"
  else
    for tok in $SUB_IDS; do DEFAULT_SUB="$tok"; break; done
    DEFAULT_TYPE="CSP"
  fi

  # Find default index
  for i in "${!SUB_ARRAY[@]}"; do
    if [ "${SUB_ARRAY[$i]}" = "$DEFAULT_SUB" ]; then
      DEFAULT_NUM=$((i + 1))
      break
    fi
  done

  log_info "Recommended: Option $DEFAULT_NUM ($DEFAULT_TYPE)"

  # Prompt for selection
  while true; do
    read -rp "Enter subscription number [${DEFAULT_NUM}]: " CHOICE
    CHOICE="${CHOICE:-$DEFAULT_NUM}"

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#SUB_ARRAY[@]}" ]; then
      ARRAY_INDEX=$((CHOICE - 1))
      HOST_SUBID="${SUB_ARRAY[$ARRAY_INDEX]}"
      HOST_SUB_NAME="${SUB_NAMES[$ARRAY_INDEX]}"
      break
    else
      log_error "Invalid selection. Please enter a number between 1 and ${#SUB_ARRAY[@]}"
    fi
  done

  log_success "Selected: $HOST_SUB_NAME ($HOST_SUBID)"
fi

if [ -z "${HOST_SUBID:-}" ]; then
  log_error "Could not determine host subscription"
  exit 1
fi
execute az account set --subscription "$HOST_SUBID"

# Register providers in host subscription
log_info "Registering required resource providers in host subscription..."
for provider in "${REQUIRED_PROVIDERS[@]}"; do
  ensure_provider "$provider"
done

# Create resource group
log_info "Creating resource group: $RESOURCE_GROUP"
execute az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --only-show-errors $DEBUG_FLAG >/dev/null || {
    log_error "Failed to create resource group"
    exit 1
  }

# Create storage account
HOST_SUFFIX=${HOST_SUBID: -6}
STORAGE_ACCOUNT_NAME="tailpipedataexport$HOST_SUFFIX"

log_info "Creating storage account: $STORAGE_ACCOUNT_NAME"

TEMP_TEMPLATE=$(mktemp)
cat > "$TEMP_TEMPLATE" <<'EOF'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "type": "string",
      "metadata": { "description": "Azure region for the deployment" }
    },
    "storageAccountName": {
      "type": "string"
    }
  },
  "resources": [
    {
      "type": "Microsoft.Storage/storageAccounts",
      "apiVersion": "2023-01-01",
      "name": "[parameters('storageAccountName')]",
      "location": "[parameters('location')]",
      "sku": { "name": "Standard_LRS" },
      "kind": "StorageV2",
      "properties": { "accessTier": "Hot" }
    },
    {
      "type": "Microsoft.Storage/storageAccounts/blobServices",
      "apiVersion": "2023-01-01",
      "name": "[format('{0}/default', parameters('storageAccountName'))]",
      "dependsOn": [
        "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
      ],
      "properties": {}
    },
    {
      "type": "Microsoft.Storage/storageAccounts/blobServices/containers",
      "apiVersion": "2023-01-01",
      "name": "[format('{0}/default/dataexport', parameters('storageAccountName'))]",
      "dependsOn": [
        "[resourceId('Microsoft.Storage/storageAccounts/blobServices', parameters('storageAccountName'), 'default')]"
      ],
      "properties": {}
    }
  ],
  "outputs": {
    "storageAccountName": {
      "type": "string",
      "value": "[parameters('storageAccountName')]"
    }
  }
}
EOF

execute az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "tailpipe-storage-deployment-$(date +%s)" \
  --template-file "$TEMP_TEMPLATE" \
  --parameters location="$LOCATION" storageAccountName="$STORAGE_ACCOUNT_NAME" \
  --only-show-errors $DEBUG_FLAG >/dev/null || {
    log_error "Failed to deploy storage account"
    rm -f "$TEMP_TEMPLATE"
    exit 1
  }

rm -f "$TEMP_TEMPLATE"
log_success "Storage account created: $STORAGE_ACCOUNT_NAME"

# Assign RBAC - Storage Blob Data Reader (CRITICAL - must succeed)
STORAGE_SCOPE="/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
if ! create_role_assignment "$SP_OBJECT_ID" "Storage Blob Data Reader" "$STORAGE_SCOPE" "Storage Blob Data Reader on storage account"; then
  log_error "CRITICAL: Failed to assign Storage Blob Data Reader role. Tailpipe cannot read cost data without this permission."
  exit 1
fi

# Assign RBAC - Monitoring Reader at Management Group or Subscription
log_info "Assigning Monitoring Reader role..."

ROOT_MG=$(az account management-group list --query "[?properties.details.parent==null].name | [0]" -o tsv 2>/dev/null || echo "")
FALLBACK_PER_SUB=0

if [ -z "$ROOT_MG" ] || [ "$ROOT_MG" = "null" ]; then
  log_warning "Could not determine Root Management Group, will assign per-subscription"
  FALLBACK_PER_SUB=1
else
  MG_SCOPE="/providers/Microsoft.Management/managementGroups/$ROOT_MG"
  if create_role_assignment "$SP_OBJECT_ID" "Monitoring Reader" "$MG_SCOPE" "Monitoring Reader at MG: $ROOT_MG"; then
    log_success "Monitoring Reader assigned at Management Group level"
  else
    log_warning "MG-scope assignment failed, falling back to per-subscription"
    FALLBACK_PER_SUB=1
  fi
fi

if [ "$FALLBACK_PER_SUB" = "1" ]; then
  log_info "Assigning Monitoring Reader per subscription..."
  MONITORING_READER_SUCCESS=0
  MONITORING_READER_FAILED=0
  for SUBID in $SUB_IDS; do
    if create_role_assignment "$SP_OBJECT_ID" "Monitoring Reader" "/subscriptions/$SUBID" "Monitoring Reader on subscription $SUBID"; then
      MONITORING_READER_SUCCESS=$((MONITORING_READER_SUCCESS + 1))
    else
      MONITORING_READER_FAILED=$((MONITORING_READER_FAILED + 1))
    fi
  done
  if [ "$MONITORING_READER_SUCCESS" -eq 0 ] && [ "$MONITORING_READER_FAILED" -gt 0 ]; then
    log_error "CRITICAL: Failed to assign Monitoring Reader role to ANY subscription. Tailpipe cannot read metrics without this permission."
    exit 1
  elif [ "$MONITORING_READER_FAILED" -gt 0 ]; then
    log_warning "Monitoring Reader assigned to $MONITORING_READER_SUCCESS subscription(s), failed on $MONITORING_READER_FAILED"
  fi
fi

log_success "Phase 1 complete: Core infrastructure deployed"

#==============================================================================
# PHASE 2: COST EXPORTS
#==============================================================================

log_section "Phase 2: Cost Management Exports"

START_DATE=$(date -u +%Y-%m-%d)
EXPORT_NAME_BILLING="TailpipeAllSubs"
FORCE_PER_SUB_EXPORTS=0

# Export tracking
EXPORT_SUCCESS=()
EXPORT_SUCCESS_TYPES=()  # Track export type (ActualCost or Usage) for each success
EXPORT_FAILED=()
EXPORT_FAILED_REASONS=()
EXPORT_SKIPPED=()
EXPORT_SKIPPED_REASONS=()
BILLING_EXPORT_TYPE=""    # Track billing export type

# Try to create billing-scope export for non-CSP subscriptions
if [ -n "$NONCSP_SUBS" ]; then
  log_info "Attempting to create billing-scope export for MCA/EA subscriptions..."

  if [ -z "${BILLING_SCOPE:-}" ]; then
    log_info "Auto-discovering billing scope..."
    BA_ID=$(az rest --method GET \
      --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01" \
      --query "value[0].name" -o tsv 2>/dev/null || true)

    if [ -z "$BA_ID" ]; then
      log_warning "No billing accounts visible, will use per-subscription exports for non-CSP"
      FORCE_PER_SUB_EXPORTS=1
    else
      BILLING_SCOPE=$(az rest --method GET \
        --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BA_ID/billingProfiles?api-version=2024-04-01" \
        --query "value[0].id" -o tsv 2>/dev/null || true)

      if [ -z "$BILLING_SCOPE" ]; then
        log_warning "No billing profiles found, will use per-subscription exports for non-CSP"
        FORCE_PER_SUB_EXPORTS=1
      fi
    fi
  fi

  if [ -n "${BILLING_SCOPE:-}" ]; then
    log_info "Using billing scope: $BILLING_SCOPE"

    # Extract billing profile ID for folder path
    BP=$(echo "$BILLING_SCOPE" | awk -F'/billingProfiles/' '{print $2}' | cut -d'/' -f1)
    BILLING_SUBFOLDER="tailpipe/billing"
    [ -n "$BP" ] && BILLING_SUBFOLDER="tailpipe/billing/$BP"

    # Create payload template with placeholder for export type
    # Will try ActualCost first, then fallback to Usage
    BILLING_PAYLOAD_TEMPLATE=$(cat <<JSON
{
  "location": "$LOCATION",
  "properties": {
    "definition": {
      "type": "EXPORT_TYPE_PLACEHOLDER",
      "timeframe": "MonthToDate",
      "dataset": { "granularity": "Daily", "configuration": { "columns": [] } }
    },
    "format": "Csv",
    "compressionMode": "Gzip",
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "schedule": {
      "status": "Active",
      "recurrence": "Daily",
      "recurrencePeriod": { "from": "$START_DATE", "to": "2099-12-31" }
    },
    "deliveryInfo": {
      "destination": {
        "resourceId": "/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME",
        "container": "$STORAGE_CONTAINER",
        "rootFolderPath": "$BILLING_SUBFOLDER"
      }
    }
  }
}
JSON
)

    BILLING_EXPORT_URL="https://management.azure.com/$BILLING_SCOPE/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_BILLING?api-version=2025-03-01"

    log_info "Attempting to create billing-scope export (trying ActualCost first, fallback to Usage)..."
    LAST_EXPORT_ERROR=""
    BILLING_EXPORT_TYPE=$(create_export_with_type_fallback "$BILLING_EXPORT_URL" "$BILLING_PAYLOAD_TEMPLATE" "0")

    if [ -n "$BILLING_EXPORT_TYPE" ]; then
      log_success "Billing-scope export created: $EXPORT_NAME_BILLING (type: $BILLING_EXPORT_TYPE)"
    else
      log_warning "Failed to create billing-scope export, will use per-subscription exports"
      [ -n "$LAST_EXPORT_ERROR" ] && log_info "Error: ${LAST_EXPORT_ERROR:0:100}"
      FORCE_PER_SUB_EXPORTS=1
    fi
  fi
fi

# Create subscription-scope exports
PER_SUB_LIST="$CSP_SUBS"
if [ "$FORCE_PER_SUB_EXPORTS" = "1" ] && [ -n "$NONCSP_SUBS" ]; then
  PER_SUB_LIST="$PER_SUB_LIST $NONCSP_SUBS"
fi

if [ -n "$PER_SUB_LIST" ]; then
  log_info "Creating subscription-scope exports..."
  log_info "Will try ActualCost first for non-CSP subscriptions, fallback to Usage if not supported"

  for SUBID in $PER_SUB_LIST; do
    [ -z "$SUBID" ] && continue

    # Check if subscription should be skipped (lookup quota ID from temp file)
    QID=$(grep "^$SUBID|" "$SUB_QUOTA_FILE" 2>/dev/null | cut -d'|' -f2 || echo "")
    if [ -n "$QID" ]; then
      SKIP_REASON=$(should_skip_subscription "$SUBID" "$QID" 2>/dev/null || echo "")
      if [ -n "$SKIP_REASON" ]; then
        EXPORT_SKIPPED+=("$SUBID")
        EXPORT_SKIPPED_REASONS+=("$SKIP_REASON")
        log_info "Skipping subscription $SUBID: $SKIP_REASON"
        continue
      fi
    fi

    SUBID_SUFFIX=${SUBID: -6}
    EXPORT_NAME_SUB="$EXPORT_NAME_PREFIX-$SUBID_SUFFIX"
    SUB_SUBFOLDER="$EXPORT_FOLDER_PREFIX/subscriptions/$SUBID"

    # Determine if this is a CSP subscription
    IS_CSP="0"
    if is_csp_subscription "$SUBID"; then
      IS_CSP="1"
    fi

    # Create payload template with placeholder for export type
    SUB_PAYLOAD_TEMPLATE=$(cat <<JSON
{
  "location": "$LOCATION",
  "properties": {
    "definition": {
      "type": "EXPORT_TYPE_PLACEHOLDER",
      "timeframe": "MonthToDate",
      "dataset": { "granularity": "Daily", "configuration": { "columns": [] } }
    },
    "format": "Csv",
    "compressionMode": "Gzip",
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "schedule": {
      "status": "Active",
      "recurrence": "Daily",
      "recurrencePeriod": { "from": "$START_DATE", "to": "2099-12-31" }
    },
    "deliveryInfo": {
      "destination": {
        "resourceId": "/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME",
        "container": "$STORAGE_CONTAINER",
        "rootFolderPath": "$SUB_SUBFOLDER"
      }
    }
  }
}
JSON
)

    SUB_EXPORT_URL="https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_SUB?api-version=2025-03-01"

    LAST_EXPORT_ERROR=""
    EXPORT_TYPE=$(create_export_with_type_fallback "$SUB_EXPORT_URL" "$SUB_PAYLOAD_TEMPLATE" "$IS_CSP")

    if [ -n "$EXPORT_TYPE" ]; then
      EXPORT_SUCCESS+=("$SUBID")
      EXPORT_SUCCESS_TYPES+=("$EXPORT_TYPE")
      log_success "Export created: $EXPORT_NAME_SUB (subscription: $SUBID, type: $EXPORT_TYPE)"
    else
      EXPORT_FAILED+=("$SUBID")

      # Parse common error types from LAST_EXPORT_ERROR
      if echo "$LAST_EXPORT_ERROR" | grep -q "RBACAccessDenied"; then
        EXPORT_FAILED_REASONS+=("Insufficient permissions")
      elif echo "$LAST_EXPORT_ERROR" | grep -q "DisallowedProvider"; then
        EXPORT_FAILED_REASONS+=("Cost Management provider not permitted")
      elif echo "$LAST_EXPORT_ERROR" | grep -q "AuthorizationFailed"; then
        EXPORT_FAILED_REASONS+=("Authorization failed")
      else
        EXPORT_FAILED_REASONS+=("${LAST_EXPORT_ERROR:0:80}")
      fi

      log_warning "Failed to create export for subscription: $SUBID"
    fi
  done
fi

# Export creation summary
log_section "Export Creation Summary"

# Count export types
ACTUAL_COST_COUNT=0
USAGE_COUNT=0
for t in "${EXPORT_SUCCESS_TYPES[@]}"; do
  if [ "$t" = "ActualCost" ]; then
    ACTUAL_COST_COUNT=$((ACTUAL_COST_COUNT + 1))
  else
    USAGE_COUNT=$((USAGE_COUNT + 1))
  fi
done

# Add billing export to counts if it exists
if [ -n "$BILLING_EXPORT_TYPE" ]; then
  if [ "$BILLING_EXPORT_TYPE" = "ActualCost" ]; then
    ACTUAL_COST_COUNT=$((ACTUAL_COST_COUNT + 1))
  else
    USAGE_COUNT=$((USAGE_COUNT + 1))
  fi
fi

log_info "Successful exports: ${#EXPORT_SUCCESS[@]} subscription(s)$([ -n "$BILLING_EXPORT_TYPE" ] && echo " + 1 billing")"
log_info "  ActualCost exports: $ACTUAL_COST_COUNT"
log_info "  Usage exports: $USAGE_COUNT"

if [ -n "$BILLING_EXPORT_TYPE" ]; then
  log_success "  ✓ Billing scope ($BILLING_EXPORT_TYPE)"
fi

if [ "${#EXPORT_SUCCESS[@]}" -gt 0 ]; then
  for i in "${!EXPORT_SUCCESS[@]}"; do
    log_success "  ✓ ${EXPORT_SUCCESS[$i]} (${EXPORT_SUCCESS_TYPES[$i]})"
  done
fi

if [ "${#EXPORT_FAILED[@]}" -gt 0 ]; then
  log_warning "Failed exports: ${#EXPORT_FAILED[@]}"
  for i in "${!EXPORT_FAILED[@]}"; do
    log_error "  ✗ ${EXPORT_FAILED[$i]}: ${EXPORT_FAILED_REASONS[$i]}"
  done
fi

if [ "${#EXPORT_SKIPPED[@]}" -gt 0 ]; then
  log_info "Skipped subscriptions: ${#EXPORT_SKIPPED[@]}"
  for i in "${!EXPORT_SKIPPED[@]}"; do
    log_info "  ⊘ ${EXPORT_SKIPPED[$i]}: ${EXPORT_SKIPPED_REASONS[$i]}"
  done
fi

log_success "Phase 2 complete: Cost exports configured"

#==============================================================================
# PHASE 3: AUTOMATION (CSP ONLY)
#==============================================================================

if [ "$CSP_COUNT" -gt 0 ] && [ "${SKIP_AUTOMATION:-0}" = "0" ] && [ "${SKIP_POLICY:-0}" = "0" ]; then
  log_section "Phase 3: Automation for New Subscriptions"

  log_info "CSP subscriptions detected, setting up automation..."

  # Determine management group for policy deployment
  if [ -z "${MANAGEMENT_GROUP_ID:-}" ]; then
    MANAGEMENT_GROUP_ID=$(az account management-group list --query "[?properties.details.parent==null].name | [0]" -o tsv 2>/dev/null || echo "")
    if [ -z "$MANAGEMENT_GROUP_ID" ] || [ "$MANAGEMENT_GROUP_ID" = "null" ]; then
      log_warning "No management group found, will deploy policy at subscription scope"
      MANAGEMENT_GROUP_ID=""
    else
      log_info "Using root management group: $MANAGEMENT_GROUP_ID"
    fi
  fi

  # Deploy Azure Policy for auto-export
  log_info "Deploying Azure Policy for automatic export creation..."

  # Determine scope
  if [ -z "$MANAGEMENT_GROUP_ID" ]; then
    SCOPE_TYPE="subscription"
    SCOPE="/subscriptions/$HOST_SUBID"
    SCOPE_PARAM="--subscription $HOST_SUBID"
    log_info "Deploying policy at subscription scope"
  else
    SCOPE_TYPE="managementGroup"
    SCOPE="/providers/Microsoft.Management/managementGroups/$MANAGEMENT_GROUP_ID"
    SCOPE_PARAM="--management-group $MANAGEMENT_GROUP_ID"
    log_info "Deploying policy at management group scope"
  fi

  # Generate policy rule file at runtime (embedded to avoid external file dependency)
  TEMP_RULE_FILE=$(mktemp)
  cat > "$TEMP_RULE_FILE" <<'POLICY_RULE_EOF'
{
  "if": {
    "field": "type",
    "equals": "Microsoft.Resources/subscriptions"
  },
  "then": {
    "effect": "[parameters('effect')]",
    "details": {
      "type": "Microsoft.CostManagement/exports",
      "name": "[concat(parameters('exportNamePrefix'), '-', substring(subscription().subscriptionId, sub(length(subscription().subscriptionId), 6), 6))]",
      "deploymentScope": "subscription",
      "existenceScope": "subscription",
      "roleDefinitionIds": [
        "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
      ],
      "existenceCondition": {
        "allOf": [
          {
            "field": "Microsoft.CostManagement/exports/schedule.status",
            "equals": "Active"
          },
          {
            "field": "Microsoft.CostManagement/exports/deliveryInfo.destination.resourceId",
            "equals": "[parameters('storageAccountResourceId')]"
          }
        ]
      },
      "deployment": {
        "location": "[parameters('deploymentLocation')]",
        "properties": {
          "mode": "Incremental",
          "parameters": {
            "storageAccountResourceId": {
              "value": "[parameters('storageAccountResourceId')]"
            },
            "storageContainerName": {
              "value": "[parameters('storageContainerName')]"
            },
            "exportNamePrefix": {
              "value": "[parameters('exportNamePrefix')]"
            },
            "exportFolderPrefix": {
              "value": "[parameters('exportFolderPrefix')]"
            },
            "subscriptionId": {
              "value": "[subscription().subscriptionId]"
            }
          },
          "template": {
            "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "parameters": {
              "storageAccountResourceId": {
                "type": "string"
              },
              "storageContainerName": {
                "type": "string"
              },
              "exportNamePrefix": {
                "type": "string"
              },
              "exportFolderPrefix": {
                "type": "string"
              },
              "subscriptionId": {
                "type": "string"
              },
              "startDate": {
                "type": "string",
                "defaultValue": "[utcNow('yyyy-MM-dd')]"
              }
            },
            "variables": {
              "exportName": "[concat(parameters('exportNamePrefix'), '-', substring(parameters('subscriptionId'), sub(length(parameters('subscriptionId')), 6), 6))]",
              "rootFolderPath": "[concat(parameters('exportFolderPrefix'), '/subscriptions/', parameters('subscriptionId'))]",
              "endDate": "2099-12-31"
            },
            "resources": [
              {
                "type": "Microsoft.CostManagement/exports",
                "apiVersion": "2023-08-01",
                "name": "[variables('exportName')]",
                "properties": {
                  "schedule": {
                    "status": "Active",
                    "recurrence": "Daily",
                    "recurrencePeriod": {
                      "from": "[concat(parameters('startDate'), 'T00:00:00Z')]",
                      "to": "[concat(variables('endDate'), 'T00:00:00Z')]"
                    }
                  },
                  "format": "Csv",
                  "deliveryInfo": {
                    "destination": {
                      "resourceId": "[parameters('storageAccountResourceId')]",
                      "container": "[parameters('storageContainerName')]",
                      "rootFolderPath": "[variables('rootFolderPath')]",
                      "type": "AzureBlob"
                    }
                  },
                  "definition": {
                    "type": "ActualCost",
                    "timeframe": "MonthToDate",
                    "dataSet": {
                      "granularity": "Daily"
                    }
                  }
                }
              }
            ],
            "outputs": {
              "exportName": {
                "type": "string",
                "value": "[variables('exportName')]"
              }
            }
          }
        }
      }
    }
  }
}
POLICY_RULE_EOF

  # Policy parameters (inline JSON)
  PARAMS_JSON='{
    "storageAccountResourceId": {
      "type": "String",
      "metadata": {
        "displayName": "Storage Account Resource ID",
        "description": "The full resource ID of the storage account where exports will be written"
      }
    },
    "storageContainerName": {
      "type": "String",
      "metadata": {
        "displayName": "Storage Container Name",
        "description": "The blob container name for exports"
      },
      "defaultValue": "dataexport"
    },
    "exportNamePrefix": {
      "type": "String",
      "metadata": {
        "displayName": "Export Name Prefix",
        "description": "Prefix for the export name (will append subscription ID suffix)"
      },
      "defaultValue": "TailpipeDataExport"
    },
    "exportFolderPrefix": {
      "type": "String",
      "metadata": {
        "displayName": "Export Folder Prefix",
        "description": "Root folder path prefix in storage"
      },
      "defaultValue": "tailpipe"
    },
    "deploymentLocation": {
      "type": "String",
      "metadata": {
        "displayName": "Deployment Location",
        "description": "Azure region for the ARM deployment"
      },
      "defaultValue": "uksouth"
    },
    "effect": {
      "type": "String",
      "metadata": {
        "displayName": "Effect",
        "description": "Enable or disable the execution of the policy"
      },
      "allowedValues": [
        "DeployIfNotExists",
        "AuditIfNotExists",
        "Disabled"
      ],
      "defaultValue": "DeployIfNotExists"
    }
  }'

  execute az policy definition create \
    --name "$POLICY_NAME" \
    --display-name "Deploy Cost Management Export for Subscriptions" \
    --description "Automatically creates Cost Management exports for subscriptions" \
    --rules "$TEMP_RULE_FILE" \
    --params "$PARAMS_JSON" \
    --mode All \
    $SCOPE_PARAM >/dev/null || log_warning "Policy definition already exists or failed to create"

  rm -f "$TEMP_RULE_FILE"

  # Create policy assignment
  if [ -z "$MANAGEMENT_GROUP_ID" ]; then
    POLICY_ID="/subscriptions/$HOST_SUBID/providers/Microsoft.Authorization/policyDefinitions/$POLICY_NAME"
  else
    POLICY_ID="/providers/Microsoft.Management/managementGroups/$MANAGEMENT_GROUP_ID/providers/Microsoft.Authorization/policyDefinitions/$POLICY_NAME"
  fi

  ASSIGNMENT_ID=$(execute az policy assignment create \
    --name "$POLICY_ASSIGNMENT_NAME" \
    --display-name "Auto-deploy Cost Exports" \
    --policy "$POLICY_ID" \
    --scope "$SCOPE" \
    --location "$LOCATION" \
    --mi-system-assigned \
    --identity-scope "$SCOPE" \
    --role Contributor \
    --params "{
      \"storageAccountResourceId\": {\"value\": \"/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME\"},
      \"storageContainerName\": {\"value\": \"$STORAGE_CONTAINER\"},
      \"exportNamePrefix\": {\"value\": \"$EXPORT_NAME_PREFIX\"},
      \"exportFolderPrefix\": {\"value\": \"$EXPORT_FOLDER_PREFIX\"},
      \"deploymentLocation\": {\"value\": \"$LOCATION\"},
      \"effect\": {\"value\": \"DeployIfNotExists\"}
    }" \
    --query 'id' -o tsv 2>/dev/null || echo "")

  if [ -n "$ASSIGNMENT_ID" ]; then
    log_success "Policy assigned"

    # Grant permissions to policy managed identity
    if [ "$DRY_RUN" = "0" ]; then
      sleep 5  # Wait for identity to be created
      POLICY_PRINCIPAL_ID=$(az policy assignment show --name "$POLICY_ASSIGNMENT_NAME" --scope "$SCOPE" --query 'identity.principalId' -o tsv 2>/dev/null || echo "")

      if [ -n "$POLICY_PRINCIPAL_ID" ]; then
        log_info "Granting permissions to policy managed identity..."
        STORAGE_SUB_ID=$(echo "$STORAGE_SCOPE" | cut -d'/' -f3)

        create_role_assignment "$POLICY_PRINCIPAL_ID" "Reader" "/subscriptions/$STORAGE_SUB_ID" "Policy MI: Reader on storage subscription" || true
        create_role_assignment "$POLICY_PRINCIPAL_ID" "Storage Blob Data Contributor" "$STORAGE_SCOPE" "Policy MI: Storage Blob Data Contributor" || true
      fi
    fi

    # Create remediation task
    log_info "Creating remediation task for existing subscriptions..."
    REMEDIATION_NAME="remediate-cost-exports-$(date +%s)"

    if [ -z "$MANAGEMENT_GROUP_ID" ]; then
      execute az policy remediation create \
        --name "$REMEDIATION_NAME" \
        --policy-assignment "$ASSIGNMENT_ID" \
        --subscription "$HOST_SUBID" \
        --resource-discovery-mode ReEvaluateCompliance >/dev/null || log_warning "Failed to create remediation task"
    else
      execute az policy remediation create \
        --name "$REMEDIATION_NAME" \
        --policy-assignment "$ASSIGNMENT_ID" \
        --management-group "$MANAGEMENT_GROUP_ID" \
        --resource-discovery-mode ExistingNonCompliant >/dev/null || log_warning "Failed to create remediation task"
    fi

    log_success "Policy remediation task created"
  else
    log_warning "Policy assignment failed or already exists"
  fi

  # Setup Automation Account for provider registration
  log_info "Setting up Automation Account for provider registration..."

  # Create resource group
  execute az group create \
    --name "$AUTOMATION_RG" \
    --location "$LOCATION" \
    --only-show-errors $DEBUG_FLAG >/dev/null

  # Create automation account
  if ! az automation account show --name "$AUTOMATION_ACCOUNT" --resource-group "$AUTOMATION_RG" &>/dev/null; then
    log_info "Creating Automation Account..."
    execute az automation account create \
      --name "$AUTOMATION_ACCOUNT" \
      --resource-group "$AUTOMATION_RG" \
      --location "$LOCATION" \
      --sku Basic \
      --only-show-errors >/dev/null

    # Enable managed identity
    execute az resource update \
      --resource-group "$AUTOMATION_RG" \
      --name "$AUTOMATION_ACCOUNT" \
      --resource-type "Microsoft.Automation/automationAccounts" \
      --set identity.type="SystemAssigned" >/dev/null

    sleep 10
    log_success "Automation Account created"
  else
    log_info "Automation Account already exists"
  fi

  # Generate runbook content at runtime (embedded to avoid external file dependency)
  RUNBOOK_FILE=$(mktemp)
  cat > "$RUNBOOK_FILE" <<'RUNBOOK_EOF'
param()

$ErrorActionPreference = 'Stop'

# Connect with managed identity
Connect-AzAccount -Identity | Out-Null

# Get all subscriptions in the tenant
$subscriptions = Get-AzSubscription

$providersToRegister = @(
    'Microsoft.CostManagement',
    'Microsoft.PolicyInsights',
    'Microsoft.CostManagementExports'
)

foreach ($sub in $subscriptions) {
    Write-Output "Processing subscription: $($sub.Name) ($($sub.Id))"

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        foreach ($provider in $providersToRegister) {
            $providerStatus = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue

            if (-not $providerStatus) {
                Write-Output "  Provider $provider not found in subscription"
                continue
            }

            if ($providerStatus.RegistrationState -ne 'Registered') {
                Write-Output "  Registering provider: $provider (current state: $($providerStatus.RegistrationState))"
                Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null
            } else {
                Write-Output "  Provider $provider already registered"
            }
        }
    }
    catch {
        Write-Warning "  Failed to process subscription $($sub.Name): $_"
        continue
    }
}

Write-Output "Provider registration check complete"
RUNBOOK_EOF

  # Create and publish runbook
  execute az automation runbook create \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$AUTOMATION_RG" \
    --name "$RUNBOOK_NAME" \
    --type "PowerShell" \
    --location "$LOCATION" 2>/dev/null || log_info "Runbook already exists"

  execute az automation runbook replace-content \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$AUTOMATION_RG" \
    --name "$RUNBOOK_NAME" \
    --content @"$RUNBOOK_FILE" >/dev/null

  rm -f "$RUNBOOK_FILE"

  execute az automation runbook publish \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$AUTOMATION_RG" \
    --name "$RUNBOOK_NAME" >/dev/null

  log_success "Runbook published"

  # Create schedule
  if ! az automation schedule show \
       --automation-account-name "$AUTOMATION_ACCOUNT" \
       --resource-group "$AUTOMATION_RG" \
       --name "DailyProviderCheck" &>/dev/null; then

    # Calculate start time (10 minutes from now)
    if date --version >/dev/null 2>&1; then
      START_TIME=$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ')
    else
      START_TIME=$(date -u -v+10M '+%Y-%m-%dT%H:%M:%SZ')
    fi

    execute az automation schedule create \
      --automation-account-name "$AUTOMATION_ACCOUNT" \
      --resource-group "$AUTOMATION_RG" \
      --name "DailyProviderCheck" \
      --start-time "$START_TIME" \
      --frequency "Day" \
      --interval 1 >/dev/null

    log_success "Daily schedule created"
  fi

  # Grant permissions to automation managed identity
  if [ "$DRY_RUN" = "0" ]; then
    AUTO_PRINCIPAL_ID=$(az automation account show \
      --name "$AUTOMATION_ACCOUNT" \
      --resource-group "$AUTOMATION_RG" \
      --query "identity.principalId" -o tsv 2>/dev/null || echo "")

    if [ -n "$AUTO_PRINCIPAL_ID" ]; then
      log_info "Granting permissions to Automation Account managed identity..."
      create_role_assignment "$AUTO_PRINCIPAL_ID" "Reader" "/" "Automation MI: Reader at tenant root" || true
      create_role_assignment "$AUTO_PRINCIPAL_ID" "Contributor" "/" "Automation MI: Contributor at tenant root" || true
    fi
  fi

  log_success "Phase 3 complete: Automation configured"
else
  if [ "$CSP_COUNT" = "0" ]; then
    log_info "No CSP subscriptions detected, skipping automation setup"
  else
    log_info "Automation setup skipped (SKIP_AUTOMATION or SKIP_POLICY set)"
  fi
fi

#==============================================================================
# PHASE 4: VALIDATION
#==============================================================================

log_section "Phase 4: Validation"

if [ "$DRY_RUN" = "0" ]; then
  log_info "Validating deployment..."

  # Validate storage account
  if az storage account show \
       --name "$STORAGE_ACCOUNT_NAME" \
       --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_success "Storage account validated"
  else
    log_error "Storage account validation failed"
  fi

  # Validate service principal RBAC (with delay for propagation)
  log_info "Waiting for RBAC propagation (5 seconds)..."
  sleep 5

  if check_role_assignment "$SP_OBJECT_ID" "Storage Blob Data Reader" "$STORAGE_SCOPE"; then
    log_success "Storage RBAC validated"
  else
    log_warning "Storage RBAC validation failed (may take time to propagate)"
  fi

  # Count exports using tracked data
  TOTAL_EXPORTS=${#EXPORT_SUCCESS[@]}

  if [ -n "${BILLING_SCOPE:-}" ] && [ "$FORCE_PER_SUB_EXPORTS" = "0" ]; then
    TOTAL_EXPORTS=$((TOTAL_EXPORTS + 1))
  fi

  if [ "$TOTAL_EXPORTS" -gt 0 ]; then
    log_success "Successfully created $TOTAL_EXPORTS cost export(s)"
  else
    log_warning "No cost exports were created"
  fi
else
  log_info "Validation skipped (dry run mode)"
fi

#==============================================================================
# CONFIGURATION SUMMARY
#==============================================================================

log_section "Configuration Summary"

# Build monitoring configuration
if [ "$FALLBACK_PER_SUB" = "1" ]; then
  MON_MODE="perSubscription"
  MON_SUBS_JSON=""
  for sid in $SUB_IDS; do
    [ -z "$sid" ] && continue
    MON_SUBS_JSON="${MON_SUBS_JSON:+$MON_SUBS_JSON, }\"$sid\""
  done
  MON_SUBS_JSON="[$MON_SUBS_JSON]"
  MG_ID_JSON="null"
else
  MON_MODE="managementGroup"
  MON_SUBS_JSON="[]"
  MG_ID_JSON="\"$ROOT_MG\""
fi

# Build export paths with export types
SUB_PATHS_JSON=""
PER_SUB_EXPORTS_JSON=""
for i in "${!EXPORT_SUCCESS[@]}"; do
  sid="${EXPORT_SUCCESS[$i]}"
  export_type="${EXPORT_SUCCESS_TYPES[$i]:-Usage}"
  [ -z "$sid" ] && continue
  SUB_PATHS_JSON="${SUB_PATHS_JSON:+$SUB_PATHS_JSON, }\"$EXPORT_FOLDER_PREFIX/subscriptions/$sid\""
  suffix=${sid: -6}
  name="$EXPORT_NAME_PREFIX-$suffix"
  PER_SUB_EXPORTS_JSON="${PER_SUB_EXPORTS_JSON:+$PER_SUB_EXPORTS_JSON, }{ \"subscriptionId\": \"$sid\", \"name\": \"$name\", \"type\": \"$export_type\" }"
done
[ -n "$SUB_PATHS_JSON" ] && SUB_PATHS_JSON="[$SUB_PATHS_JSON]" || SUB_PATHS_JSON="[]"
[ -n "$PER_SUB_EXPORTS_JSON" ] && PER_SUB_EXPORTS_JSON="[$PER_SUB_EXPORTS_JSON]" || PER_SUB_EXPORTS_JSON="[]"

# Build billing export info
BILLING_PATH_JSON="null"
BILLING_EXPORT_JSON="null"
if [ -n "${BILLING_SCOPE:-}" ] && [ -n "$BILLING_EXPORT_TYPE" ]; then
  BILLING_PATH_JSON="\"${BILLING_SUBFOLDER:-tailpipe/billing}\""
  BILLING_EXPORT_JSON="{ \"name\": \"$EXPORT_NAME_BILLING\", \"scope\": \"$BILLING_SCOPE\", \"type\": \"$BILLING_EXPORT_TYPE\" }"
fi

ACCOUNT_RESOURCE_ID="/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
BLOB_ENDPOINT="https://$STORAGE_ACCOUNT_NAME.blob.core.windows.net"

# Ensure proper JSON null for empty values
TENANT_ID_JSON="null"
[ -n "$TARGET_TENANT" ] && TENANT_ID_JSON="\"$TARGET_TENANT\""

cat <<JSON_OUTPUT

{
  "tenantId": $TENANT_ID_JSON,
  "tailpipe": {
    "appId": "$ENTERPRISE_APP_ID",
    "servicePrincipalObjectId": "$SP_OBJECT_ID"
  },
  "monitoringAccess": {
    "mode": "$MON_MODE",
    "managementGroupId": $MG_ID_JSON,
    "subscriptions": $MON_SUBS_JSON
  },
  "storage": {
    "subscriptionId": "$HOST_SUBID",
    "resourceGroup": "$RESOURCE_GROUP",
    "accountName": "$STORAGE_ACCOUNT_NAME",
    "accountResourceId": "$ACCOUNT_RESOURCE_ID",
    "container": "$STORAGE_CONTAINER",
    "paths": {
      "billing": $BILLING_PATH_JSON,
      "subscriptions": $SUB_PATHS_JSON
    },
    "blobEndpoint": "$BLOB_ENDPOINT"
  },
  "costExports": {
    "billing": $BILLING_EXPORT_JSON,
    "perSubscription": $PER_SUB_EXPORTS_JSON
  },
  "automation": {
    "policyEnabled": $([ "$CSP_COUNT" -gt 0 ] && [ "${SKIP_POLICY:-0}" = "0" ] && echo "true" || echo "false"),
    "runbookEnabled": $([ "$CSP_COUNT" -gt 0 ] && [ "${SKIP_AUTOMATION:-0}" = "0" ] && echo "true" || echo "false")
  }
}
JSON_OUTPUT

log_section "Setup Complete!"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "This was a DRY RUN - no changes were made"
  log_info "Run without DRY_RUN=1 to perform actual deployment"
else
  log_success "Tailpipe has been successfully configured in your Azure tenant"
  log_info ""
  log_info "Next steps:"
  log_info "1. Save the JSON configuration above for Tailpipe onboarding"
  log_info "2. Cost exports will begin running daily"
  if [ "$CSP_COUNT" -gt 0 ]; then
    log_info "3. New subscriptions will automatically get exports via Azure Policy"
    log_info "4. Provider registration runs daily via Automation Account"
  fi
fi

log_info ""
log_info "For troubleshooting and management commands, see README.md"

# Cleanup temp files
rm -f "$SUB_QUOTA_FILE" 2>/dev/null || true
