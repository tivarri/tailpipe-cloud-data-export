#!/bin/bash
#
# Tailpipe Azure Setup - Unified Installation Script
#
# This script sets up everything needed for Tailpipe cost analytics:
# 1. Service Principal for Tailpipe Enterprise Application
# 2. Resource group and storage account for cost exports
# 3. Cost Management exports (billing-scope or subscription-scope)
# 4. Azure Policy for automatic export creation on new subscriptions (CSP only)
# 5. Automation Account for provider registration (CSP only)
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
VERSION="1.1.0"

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
  local sleep=2

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

    log_info "Waiting for service principal to appear... ($i/$attempts)"
    sleep $sleep
    sleep=$(( sleep < 30 ? sleep * 2 : 30 ))
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

#==============================================================================
# MAIN SCRIPT
#==============================================================================

log_section "Tailpipe Azure Setup v$VERSION"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No changes will be made"
fi

# Show Azure CLI version
AZ_VER=$(az version --query "\"azure-cli\"" -o tsv 2>/dev/null || echo "unknown")
log_info "Azure CLI version: $AZ_VER"

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

# Assign RBAC - Storage Blob Data Reader
STORAGE_SCOPE="/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
create_role_assignment "$SP_OBJECT_ID" "Storage Blob Data Reader" "$STORAGE_SCOPE" "Storage Blob Data Reader on storage account"

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
  for SUBID in $SUB_IDS; do
    create_role_assignment "$SP_OBJECT_ID" "Monitoring Reader" "/subscriptions/$SUBID" "Monitoring Reader on subscription $SUBID" || true
  done
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
EXPORT_FAILED=()
EXPORT_FAILED_REASONS=()
EXPORT_SKIPPED=()
EXPORT_SKIPPED_REASONS=()

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

    BILLING_EXPORT_PAYLOAD=$(mktemp)
    cat > "$BILLING_EXPORT_PAYLOAD" <<JSON
{
  "location": "$LOCATION",
  "properties": {
    "definition": {
      "type": "Usage",
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

    execute az rest --method PUT \
      --url "https://management.azure.com/$BILLING_SCOPE/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_BILLING?api-version=2025-03-01" \
      --body @"$BILLING_EXPORT_PAYLOAD" \
      --only-show-errors $DEBUG_FLAG || {
        log_warning "Failed to create billing-scope export, will use per-subscription exports"
        FORCE_PER_SUB_EXPORTS=1
      }

    rm -f "$BILLING_EXPORT_PAYLOAD"

    if [ "$FORCE_PER_SUB_EXPORTS" = "0" ]; then
      log_success "Billing-scope export created: $EXPORT_NAME_BILLING"
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

    SUB_EXPORT_PAYLOAD=$(mktemp)
    cat > "$SUB_EXPORT_PAYLOAD" <<JSON
{
  "location": "$LOCATION",
  "properties": {
    "definition": {
      "type": "Usage",
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

    ERROR_OUTPUT=$(mktemp)
    if execute az rest --method PUT \
      --url "https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_SUB?api-version=2025-03-01" \
      --body @"$SUB_EXPORT_PAYLOAD" \
      --only-show-errors 2>"$ERROR_OUTPUT"; then
      EXPORT_SUCCESS+=("$SUBID")
      log_success "Export created: $EXPORT_NAME_SUB (subscription: $SUBID)"
    else
      ERROR_MSG=$(cat "$ERROR_OUTPUT" | head -1)
      EXPORT_FAILED+=("$SUBID")

      # Parse common error types
      if echo "$ERROR_MSG" | grep -q "RBACAccessDenied"; then
        EXPORT_FAILED_REASONS+=("Insufficient permissions")
      elif echo "$ERROR_MSG" | grep -q "DisallowedProvider"; then
        EXPORT_FAILED_REASONS+=("Cost Management provider not permitted")
      elif echo "$ERROR_MSG" | grep -q "AuthorizationFailed"; then
        EXPORT_FAILED_REASONS+=("Authorization failed")
      else
        EXPORT_FAILED_REASONS+=("${ERROR_MSG:0:80}")
      fi

      log_warning "Failed to create export for subscription: $SUBID"
    fi

    rm -f "$SUB_EXPORT_PAYLOAD" "$ERROR_OUTPUT"
  done
fi

# Export creation summary
log_section "Export Creation Summary"
log_info "Successful exports: ${#EXPORT_SUCCESS[@]}"
if [ "${#EXPORT_SUCCESS[@]}" -gt 0 ]; then
  for sid in "${EXPORT_SUCCESS[@]}"; do
    log_success "  ✓ $sid"
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

  POLICY_FILE="$(dirname "$0")/Automation/policy-auto-export.json"
  if [ ! -f "$POLICY_FILE" ]; then
    log_warning "Policy definition file not found, skipping policy deployment"
  else
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

    # Create policy definition
    TEMP_RULE_FILE=$(mktemp)
    if jq -e '.properties.policyRule' "$POLICY_FILE" > /dev/null 2>&1; then
      jq '.properties.policyRule' "$POLICY_FILE" > "$TEMP_RULE_FILE"
      PARAMS_JSON=$(jq '.properties.parameters' "$POLICY_FILE")
    else
      cp "$POLICY_FILE" "$TEMP_RULE_FILE"
      PARAMS_JSON=$(jq '.parameters' "$POLICY_FILE" 2>/dev/null || echo '{}')
    fi

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
  fi

  # Setup Automation Account for provider registration
  log_info "Setting up Automation Account for provider registration..."

  RUNBOOK_FILE="$(dirname "$0")/Automation/RegisterProvidersRunbook.ps1"
  if [ ! -f "$RUNBOOK_FILE" ]; then
    log_warning "Runbook file not found, skipping Automation Account setup"
  else
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

# Build export paths
SUB_PATHS_JSON=""
PER_SUB_EXPORTS_JSON=""
for sid in $PER_SUB_LIST; do
  [ -z "$sid" ] && continue
  SUB_PATHS_JSON="${SUB_PATHS_JSON:+$SUB_PATHS_JSON, }\"$EXPORT_FOLDER_PREFIX/subscriptions/$sid\""
  suffix=${sid: -6}
  name="$EXPORT_NAME_PREFIX-$suffix"
  PER_SUB_EXPORTS_JSON="${PER_SUB_EXPORTS_JSON:+$PER_SUB_EXPORTS_JSON, }{ \"subscriptionId\": \"$sid\", \"name\": \"$name\" }"
done
[ -n "$SUB_PATHS_JSON" ] && SUB_PATHS_JSON="[$SUB_PATHS_JSON]" || SUB_PATHS_JSON="[]"
[ -n "$PER_SUB_EXPORTS_JSON" ] && PER_SUB_EXPORTS_JSON="[$PER_SUB_EXPORTS_JSON]" || PER_SUB_EXPORTS_JSON="[]"

# Build billing export info
BILLING_PATH_JSON="null"
BILLING_EXPORT_JSON="null"
if [ -n "${BILLING_SCOPE:-}" ] && [ "$FORCE_PER_SUB_EXPORTS" = "0" ]; then
  BILLING_PATH_JSON="\"${BILLING_SUBFOLDER:-tailpipe/billing}\""
  BILLING_EXPORT_JSON="{ \"name\": \"$EXPORT_NAME_BILLING\", \"scope\": \"$BILLING_SCOPE\" }"
fi

ACCOUNT_RESOURCE_ID="/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
BLOB_ENDPOINT="https://$STORAGE_ACCOUNT_NAME.blob.core.windows.net"

cat <<JSON_OUTPUT

{
  "tenantId": "$TARGET_TENANT",
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
