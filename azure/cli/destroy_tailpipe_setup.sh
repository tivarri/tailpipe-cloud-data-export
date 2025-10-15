#!/usr/bin/env bash
set -euo pipefail

########################################
# Tailpipe Destroy / Cleanup Script
# Removes exports, RBAC, and RG created by the Tailpipe setup script.
########################################

# ===== Config (env or flags) =====
ENTERPRISE_APP_ID="${ENTERPRISE_APP_ID:-071b0391-48e8-483c-b652-a8a6cd43a018}"  # TailpipeConnector App (client) ID
RESOURCE_GROUP="${RESOURCE_GROUP:-tailpipe-dataexport}"                          # RG that hosts the storage
STORAGE_SUBID="${STORAGE_SUBID:-}"                                               # Host sub for storage (optional; will auto-pick)
BILLING_SCOPE="${BILLING_SCOPE:-}"                                               # Optional override for MCA/EA billing scope
TARGET_TENANT="${TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || echo "")}"
DELETE_SP="${DELETE_SP:-0}"                                                       # 1 to delete the SP; 0 to keep
DEBUG_FLAG="${DEBUG:+--debug}"

# Flags parsing (simple)
while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --tenant|-t) TARGET_TENANT="$2"; shift 2 ;;
    --subs) SUBS="$2"; shift 2 ;;
    --storage-subid) STORAGE_SUBID="$2"; shift 2 ;;
    --resource-group|--rg) RESOURCE_GROUP="$2"; shift 2 ;;
    --app-id) ENTERPRISE_APP_ID="$2"; shift 2 ;;
    --billing-scope) BILLING_SCOPE="$2"; shift 2 ;;
    --delete-sp) DELETE_SP=1; shift ;;
    --keep-sp) DELETE_SP=0; shift ;;
    --debug) DEBUG=1; DEBUG_FLAG="--debug"; shift ;;
    *) echo "Unknown flag: $1"; exit 2 ;;
  esac
done

echo "Using Azure CLI version: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo unknown)"
[ -n "$TARGET_TENANT" ] && echo "Targeting tenant: $TARGET_TENANT"

# ===== Helper: pick first non-empty token from a list =====
first_token() {
  for tok in $1; do echo -n "$tok"; return 0; done
  return 1
}

# ===== Discover subscriptions in tenant =====
echo "Enumerating subscriptions..."
if [ -n "${SUBS:-}" ]; then
  SUB_IDS="$SUBS"
else
  MAP=$(az account list --all --refresh --query "[?state!='Disabled'].{id:id,tenantId:tenantId}" -o tsv)
  if [ -n "$TARGET_TENANT" ]; then
    SUB_IDS=$(echo "$MAP" | awk -v t="$TARGET_TENANT" '$2==t {print $1}')
  else
    SUB_IDS=$(echo "$MAP" | awk '{print $1}')
  fi
fi

echo "Discovered subscriptions:"; echo "$SUB_IDS" | sed 's/^/  - /'
if [ -z "${SUB_IDS:-}" ]; then
  echo "❌ No accessible subscriptions found for current login (after tenant filter)."
  echo "   Try: az account clear; az login${TARGET_TENANT:+ --tenant $TARGET_TENANT}"
  exit 1
fi

# ===== Resolve Tailpipe SP (service principal) =====
echo "Resolving Tailpipe service principal..."
SP_OBJECT_ID="$(az ad sp show --id "$ENTERPRISE_APP_ID" --query id -o tsv 2>/dev/null || true)"
if [ -z "$SP_OBJECT_ID" ]; then
  SP_OBJECT_ID="$(az ad sp list --filter "appId eq '$ENTERPRISE_APP_ID'" --query "[0].id" -o tsv 2>/dev/null || true)"
fi
if [ -n "$SP_OBJECT_ID" ]; then
  echo "Tailpipe SP objectId: $SP_OBJECT_ID"
else
  echo "ℹ️ Tailpipe SP not found in this tenant. Skipping RBAC removals tied to SP."
fi

# ===== Choose host subscription for storage (if not provided) =====
if [ -n "$STORAGE_SUBID" ]; then
  HOST_SUBID="$STORAGE_SUBID"
else
  HOST_SUBID="$(first_token "$SUB_IDS" || true)"
fi
if [ -z "${HOST_SUBID:-}" ]; then
  echo "❌ Could not determine a host subscription. Aborting."
  exit 1
fi
echo "Using host subscription for storage: $HOST_SUBID"

# ===== Derive storage account name (same convention as setup) =====
SUBID_SUFFIX="${HOST_SUBID: -6}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-tailpipedataexport$SUBID_SUFFIX}"
ACCOUNT_RESOURCE_ID="/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

# ===== Remove Monitoring Reader at MG scope (preferred), then per-sub fallback =====
if [ -n "$SP_OBJECT_ID" ]; then
  echo "Removing 'Monitoring Reader' at Root Management Group (if present)..."
  ROOT_MG="$(az account management-group list --query "[?properties.details.parent==null].name | [0]" -o tsv 2>/dev/null || echo "")"
  if [ -n "$ROOT_MG" ] && [ "$ROOT_MG" != "null" ]; then
    az role assignment delete \
      --assignee-object-id "$SP_OBJECT_ID" \
      --role "Monitoring Reader" \
      --scope "/providers/Microsoft.Management/managementGroups/$ROOT_MG" \
      --only-show-errors $DEBUG_FLAG || true
  else
    echo "  (Root MG not visible; skipping MG-scope removal)"
  fi

  echo "Removing 'Monitoring Reader' at subscription scope (all subs)..."
  for SUBID in $SUB_IDS; do
    az role assignment delete \
      --assignee-object-id "$SP_OBJECT_ID" \
      --role "Monitoring Reader" \
      --scope "/subscriptions/$SUBID" \
      --only-show-errors $DEBUG_FLAG || true
  done
fi

# ===== Remove Storage Blob Data Reader on host storage account =====
if [ -n "$SP_OBJECT_ID" ]; then
  echo "Removing 'Storage Blob Data Reader' on $STORAGE_ACCOUNT_NAME..."
  az role assignment delete \
    --assignee-object-id "$SP_OBJECT_ID" \
    --role "Storage Blob Data Reader" \
    --scope "$ACCOUNT_RESOURCE_ID" \
    --only-show-errors $DEBUG_FLAG || true
fi

# ===== Delete per-subscription exports (CSP and/or fallback MCA) =====
echo "Deleting per-subscription exports (if present)..."
for SUBID in $SUB_IDS; do
  suf="${SUBID: -6}"
  # New naming
  az rest --method DELETE \
    --url "https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports/TailpipeDataExport-$suf?api-version=2025-03-01" \
    --only-show-errors $DEBUG_FLAG || true
  # Legacy generic name (in case older runs used it)
  az rest --method DELETE \
    --url "https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports/TailpipeDataExport?api-version=2025-03-01" \
    --only-show-errors $DEBUG_FLAG || true
done

# ===== Delete billing-scope export (MCA/EA) =====
echo "Deleting billing-scope export if present..."
if [ -z "$BILLING_SCOPE" ]; then
  # Try REST discovery (no extension)
  BA_ID="$(az rest --method GET \
    --url 'https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01' \
    --query 'value[0].name' -o tsv 2>/dev/null || true)"
  if [ -n "$BA_ID" ]; then
    BILLING_SCOPE="$(az rest --method GET \
      --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BA_ID/billingProfiles?api-version=2024-04-01" \
      --query 'value[0].id' -o tsv 2>/dev/null || true)"
  fi
fi
if [ -n "$BILLING_SCOPE" ]; then
  az rest --method DELETE \
    --url "https://management.azure.com/$BILLING_SCOPE/providers/Microsoft.CostManagement/exports/TailpipeAllSubs?api-version=2025-03-01" \
    --only-show-errors $DEBUG_FLAG || true
else
  echo "  (No billing scope visible; skipping billing export removal)"
fi

# ===== Delete the resource group (storage account and container) =====
echo "Deleting resource group: $RESOURCE_GROUP in $HOST_SUBID ..."
az account set --subscription "$HOST_SUBID"
az group delete --name "$RESOURCE_GROUP" --yes --only-show-errors $DEBUG_FLAG || true

# ===== Optionally delete the service principal from this tenant =====
if [ "$DELETE_SP" = "1" ]; then
  if [ -n "$SP_OBJECT_ID" ]; then
    echo "Deleting Tailpipe service principal from tenant..."
    # Either by objectId or appId works; use appId for clarity.
    az ad sp delete --id "$ENTERPRISE_APP_ID" --only-show-errors $DEBUG_FLAG || true
  else
    echo "  (SP not found in tenant; nothing to delete)"
  fi
else
  echo "Keeping Tailpipe service principal (set DELETE_SP=1 or --delete-sp to remove)."
fi

echo "✅ Tailpipe cleanup complete."