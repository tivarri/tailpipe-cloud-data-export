#!/bin/bash
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO (exit $?): see above. If you saw: The content for this response was already consumed, update Azure CLI (brew update && brew upgrade azure-cli) and re-run with DEBUG=1."' ERR

# Set deployment variables

# Show Azure CLI version and enable optional debug
AZ_VER=$(az version --query "azure-cli" -o tsv 2>/dev/null || echo "unknown")
echo "Using Azure CLI version: $AZ_VER"
DEBUG_FLAG=${DEBUG:+--debug}

# Ensure required resource providers are registered
ensure_provider() {
  local ns="$1"
  local state
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [ "$state" != "Registered" ]; then
    echo "Registering provider: $ns (current state: $state)"
    az provider register --namespace "$ns" --accept-terms --wait >/dev/null
  fi
  echo "$ns -> $(az provider show --namespace "$ns" --query registrationState -o tsv)"
}
ensure_provider "Microsoft.Resources"
ensure_provider "Microsoft.Storage"
ensure_provider "Microsoft.CostManagement"
ensure_provider "Microsoft.CostManagementExports"
ensure_provider "Microsoft.Insights"

#
# Prompt for Azure region (allow env override via LOCATION)
if [ -n "${LOCATION:-}" ]; then
  echo "Using LOCATION from environment: $LOCATION"
else
  read -rp "Enter Azure region (e.g., uksouth, westeurope): " LOCATION
fi
# Normalise and validate region against available locations
LOCATION=$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')
if [ -z "$LOCATION" ]; then
  echo "❌ No location provided. You can run: az account list-locations -o table"; exit 1
fi
if ! az account list-locations --query "[?name=='$LOCATION'] | length(@)" -o tsv | grep -q '^1$'; then
  echo "❌ Invalid location: '$LOCATION'";
  echo "Run 'az account list-locations -o table' to see valid regions, then re-run."; exit 1
fi
echo "Target location: $LOCATION"
TEMPLATE_FILE="tailpipeDataExport.rg.json"
RESOURCE_GROUP="tailpipe-dataexport"
# Tailpipe UAT
ENTERPRISE_APP_ID="071b0391-48e8-483c-b652-a8a6cd43a018"
# Tailpipe Prod
# ENTERPRISE_APP_ID="f5f07900-0484-4506-a34d-ec781138342a"

# Step 0: Generate the ARM template inline
echo "Generating ARM template: $TEMPLATE_FILE"
cat <<EOF > $TEMPLATE_FILE
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "type": "string",
      "metadata": { "description": "Azure region for the deployment" }
    }
  },
  "variables": {
    "subIdSuffix": "[substring(subscription().subscriptionId, sub(length(subscription().subscriptionId), 6), 6)]",
    "storageAccountName": "[toLower(concat('tailpipedataexport', variables('subIdSuffix')))]"
  },
  "resources": [
    {
      "type": "Microsoft.Storage/storageAccounts",
      "apiVersion": "2023-01-01",
      "name": "[variables('storageAccountName')]",
      "location": "[parameters('location')]",
      "sku": { "name": "Standard_LRS" },
      "kind": "StorageV2",
      "properties": { "accessTier": "Hot" }
    },
    {
      "type": "Microsoft.Storage/storageAccounts/blobServices",
      "apiVersion": "2023-01-01",
      "name": "[format('{0}/default', variables('storageAccountName'))]",
      "dependsOn": [
        "[resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))]"
      ],
      "properties": {}
    },
    {
      "type": "Microsoft.Storage/storageAccounts/blobServices/containers",
      "apiVersion": "2023-01-01",
      "name": "[format('{0}/default/dataexport', variables('storageAccountName'))]",
      "dependsOn": [
        "[resourceId('Microsoft.Storage/storageAccounts/blobServices', variables('storageAccountName'), 'default')]"
      ],
      "properties": {}
    }
  ],
  "outputs": {
    "storageAccountName": { "type": "string", "value": "[variables('storageAccountName')]" }
  }
}
EOF

echo "Ensuring enterprise application (service principal) exists (tenant-wide)..."
# Try to resolve via direct show first
SP_OBJECT_ID=$(az ad sp show --id "$ENTERPRISE_APP_ID" --query id -o tsv 2>/dev/null || true)
# If not found, try filtered list (some tenants restrict direct show by appId transiently)
if [ -z "$SP_OBJECT_ID" ]; then
  SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$ENTERPRISE_APP_ID'" --query "[0].id" -o tsv 2>/dev/null || true)
fi

if [ -z "$SP_OBJECT_ID" ]; then
  echo "Enterprise app not found. Creating service principal for appId $ENTERPRISE_APP_ID..."
  # Capture the object id straight from the create response when possible
  SP_OBJECT_ID=$(az ad sp create --id "$ENTERPRISE_APP_ID" --query id -o tsv --only-show-errors $DEBUG_FLAG 2>/dev/null || true)

  # Smarter wait loop (exponential backoff) for Graph/dir replication
  ATTEMPTS=12
  SLEEP=2
  for i in $(seq 1 $ATTEMPTS); do
    if [ -n "$SP_OBJECT_ID" ]; then
      break
    fi
    # Try both resolvers each time
    SP_OBJECT_ID=$(az ad sp show --id "$ENTERPRISE_APP_ID" --query id -o tsv 2>/dev/null || true)
    if [ -z "$SP_OBJECT_ID" ]; then
      SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$ENTERPRISE_APP_ID'" --query "[0].id" -o tsv 2>/dev/null || true)
    fi
    if [ -n "$SP_OBJECT_ID" ]; then
      break
    fi
    echo "Waiting for service principal to appear... ($i/$ATTEMPTS)"; sleep $SLEEP; SLEEP=$(( SLEEP<30 ? SLEEP*2 : 30 ))
  done

  if [ -z "$SP_OBJECT_ID" ]; then
    echo "❌ Service principal has not appeared in directory yet. Ensure you're in the correct tenant and that directory read is permitted (Directory Reader/Global Reader). Try again in a minute."
    rm -f "$TEMPLATE_FILE" /tmp/costexport.json
    exit 1
  fi
  echo "Service principal created (objectId: $SP_OBJECT_ID)"
else
  echo "Enterprise application present (objectId: $SP_OBJECT_ID)"
fi

# Process ALL accessible subscriptions for this login (used for role assignments)
echo "Enumerating subscriptions in current login..."

TARGET_TENANT=${TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || echo "")}
[ -n "$TARGET_TENANT" ] && echo "Targeting tenant: $TARGET_TENANT" || echo "Targeting all tenants (no TENANT_ID and no default tenant detected)"

if [ -n "${SUBS:-}" ]; then
  echo "Using subscriptions provided via SUBS env var: $SUBS"
  SUB_IDS="$SUBS"
else
  MAP=$(az account list --all --refresh --query "[?state!='Disabled'].{id:id,tenantId:tenantId}" -o tsv)
  if [ -n "$TARGET_TENANT" ]; then
    SUB_IDS=$(echo "$MAP" | awk -v t="$TARGET_TENANT" '$2==t {print $1}')
  else
    SUB_IDS=$(echo "$MAP" | awk '{print $1}')
  fi
fi

echo "Discovered subscriptions:"
echo "$SUB_IDS" | sed 's/^/  - /'

if [ -z "$SUB_IDS" ]; then
  echo "❌ No accessible subscriptions found for current login (after tenant filter)."
  rm -f "$TEMPLATE_FILE" /tmp/costexport.json /tmp/costexport_mg.json 2>/dev/null || true
  exit 1
fi

# Classify subscriptions by quotaId (CSP/Partner vs MCA/EA)
CSP_SUBS=""
NONCSP_SUBS=""
for SID in $SUB_IDS; do
  QID=$(az rest --method GET \
    --url "https://management.azure.com/subscriptions/$SID?api-version=2020-01-01" \
    --query "subscriptionPolicies.quotaId" -o tsv 2>/dev/null || echo "")
  if echo "$QID" | grep -qiE "CSP|AZURE_PLAN|MICROSOFT_AZURE_PLAN"; then
    CSP_SUBS="$CSP_SUBS $SID"
  else
    NONCSP_SUBS="$NONCSP_SUBS $SID"
  fi
done

echo "CSP/Partner subscriptions:"; for s in $CSP_SUBS; do [ -n "$s" ] && echo "  - $s"; done
echo "MCA/EA subscriptions:"; for s in $NONCSP_SUBS; do [ -n "$s" ] && echo "  - $s"; done

# Choose a host subscription for the storage account (pick the FIRST non-empty subscription id only)
if [ -n "${STORAGE_SUBID:-}" ]; then
  HOST_SUBID="$STORAGE_SUBID"
elif [ -n "$NONCSP_SUBS" ]; then
  for tok in $NONCSP_SUBS; do HOST_SUBID="$tok"; break; done
else
  for tok in $SUB_IDS; do HOST_SUBID="$tok"; break; done
fi

if [ -z "${HOST_SUBID:-}" ]; then
  echo "❌ Could not determine host subscription (empty). This can happen if your login has expired tokens or no subs in the target tenant."
  echo "   Try: az account clear; az login${TARGET_TENANT:+ --tenant $TARGET_TENANT}"
  rm -f "$TEMPLATE_FILE"
  exit 1
fi

echo "Using host subscription for storage: $HOST_SUBID"

az account set --subscription "$HOST_SUBID"

# Register providers in the host subscription
ensure_provider "Microsoft.Resources"
ensure_provider "Microsoft.Storage"
ensure_provider "Microsoft.CostManagement"
ensure_provider "Microsoft.CostManagementExports"
ensure_provider "Microsoft.Insights"

# Ensure resource group in the host subscription
echo "Ensuring resource group exists in $HOST_SUBID..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --only-show-errors $DEBUG_FLAG >/dev/null || { echo "❌ RG create failed in $HOST_SUBID"; rm -f "$TEMPLATE_FILE"; exit 1; }

# Deploy storage + container in the host subscription
echo "Deploying storage account + container in $HOST_SUBID..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name tailpipeDataExportRgDeployment \
  --template-file "$TEMPLATE_FILE" \
  --parameters location="$LOCATION" \
  --only-show-errors \
  $DEBUG_FLAG || { echo "❌ RG-scope deployment failed in $HOST_SUBID"; rm -f "$TEMPLATE_FILE"; exit 1; }

# Derive storage account name deterministically from host subscription
HOST_SUFFIX=${HOST_SUBID: -6}
STORAGE_ACCOUNT_NAME="tailpipedataexport$HOST_SUFFIX"

echo "Storage account for export: $STORAGE_ACCOUNT_NAME (subscription: $HOST_SUBID)"

# Create a single Billing-scope export for NON-CSP (MCA/EA) subscriptions, if any
START_DATE="2025-07-01"
EXPORT_NAME_MG="TailpipeAllSubs"

if [ -n "$NONCSP_SUBS" ]; then
  echo "Creating export at Billing scope for MCA/EA..."
  # Auto-discover BILLING_SCOPE via REST if not provided
  if [ -z "${BILLING_SCOPE:-}" ]; then
    BA_ID=$(az rest --method GET \
      --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01" \
      --query "value[0].name" -o tsv 2>/dev/null || true)
    if [ -z "$BA_ID" ]; then
      echo "⚠️ No billing accounts visible; automatically falling back to per-subscription exports for NON-CSP. (Set BILLING_SCOPE to force billing-scope.)"
      FORCE_PER_SUB_EXPORTS=1
    else
      BILLING_SCOPE=$(az rest --method GET \
        --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BA_ID/billingProfiles?api-version=2024-04-01" \
        --query "value[0].id" -o tsv 2>/dev/null || true)
      if [ -z "$BILLING_SCOPE" ]; then
        echo "⚠️ No billing profiles visible under billing account: $BA_ID; falling back to per-subscription exports for NON-CSP."
        FORCE_PER_SUB_EXPORTS=1
      fi
    fi
  fi

  if [ -n "${BILLING_SCOPE:-}" ]; then
    # Build unique subfolder for billing export to avoid collisions
    BILLING_SUBFOLDER="tailpipe/billing"
    BP=$(echo "$BILLING_SCOPE" | awk -F'/billingProfiles/' '{print $2}' | cut -d'/' -f1)
    [ -n "$BP" ] && BILLING_SUBFOLDER="tailpipe/billing/$BP"

    # Generate billing export payload now that we know the destination subfolder
    cat > /tmp/costexport_mg.json <<JSON
{
  "location": "$LOCATION",
  "properties": {
    "definition": { "type": "Usage", "timeframe": "MonthToDate",
      "dataset": { "granularity": "Daily", "configuration": { "columns": [] } } },
    "format": "Csv",
    "compressionMode": "Gzip",
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "schedule": { "status": "Active", "recurrence": "Daily",
      "recurrencePeriod": { "from": "$START_DATE", "to": "2099-12-31" } },
    "deliveryInfo": { "destination": {
      "resourceId": "/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME",
      "container": "dataexport", "rootFolderPath": "$BILLING_SUBFOLDER" } }
  }
}
JSON

    echo "Using BILLING_SCOPE: $BILLING_SCOPE"
    az rest --method PUT \
      --url "https://management.azure.com/$BILLING_SCOPE/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_MG?api-version=2025-03-01" \
      --body @/tmp/costexport_mg.json \
      --only-show-errors $DEBUG_FLAG || { echo "❌ Failed to create export at billing scope $BILLING_SCOPE"; rm -f "$TEMPLATE_FILE" /tmp/costexport_mg.json; exit 1; }
    echo "✅ Billing-scope export created/updated: $EXPORT_NAME_MG at $BILLING_SCOPE"
  fi
fi

# Create subscription-scope exports for all CSP/Partner subscriptions (and optionally for NON-CSP if forced)
# Build the list to export at subscription scope
PER_SUB_LIST="$CSP_SUBS"
if [ -n "$NONCSP_SUBS" ] && [ "${FORCE_PER_SUB_EXPORTS:-0}" = "1" ]; then
  PER_SUB_LIST="$PER_SUB_LIST $NONCSP_SUBS"
fi

for SUBID in $PER_SUB_LIST; do
  [ -z "$SUBID" ] && continue
  echo "Ensuring subscription-scope export in $SUBID..."

  SUBID_SUFFIX=${SUBID: -6}
  EXPORT_NAME_SUB="TailpipeDataExport-$SUBID_SUFFIX"
  SUB_SUBFOLDER="tailpipe/subscriptions/$SUBID"

  cat > "/tmp/costexport_sub_${SUBID_SUFFIX}.json" <<JSON
{
  "location": "$LOCATION",
  "properties": {
    "definition": { "type": "Usage", "timeframe": "MonthToDate",
      "dataset": { "granularity": "Daily", "configuration": { "columns": [] } } },
    "format": "Csv",
    "compressionMode": "Gzip",
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "schedule": { "status": "Active", "recurrence": "Daily",
      "recurrencePeriod": { "from": "$START_DATE", "to": "2099-12-31" } },
    "deliveryInfo": { "destination": {
      "resourceId": "/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME",
      "container": "dataexport", "rootFolderPath": "$SUB_SUBFOLDER" } }
  }
}
JSON

  az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBID/providers/Microsoft.CostManagement/exports/$EXPORT_NAME_SUB?api-version=2025-03-01" \
    --body @"/tmp/costexport_sub_${SUBID_SUFFIX}.json" \
    --only-show-errors $DEBUG_FLAG || echo "❌ Failed to create/update export in $SUBID"
done

# Assign Storage Blob Data Reader on the host storage account to the TailpipeConnector SP
echo "Assigning 'Storage Blob Data Reader' role to enterprise app on host storage account..."
EXISTS=$(az role assignment list \
  --assignee-object-id "$SP_OBJECT_ID" \
  --role "Storage Blob Data Reader" \
  --scope "/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME" \
  --query "length(@)" -o tsv 2>/dev/null || echo 0)
if [ "${EXISTS:-0}" -eq 0 ]; then
  az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --role "Storage Blob Data Reader" \
    --scope "/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME" \
    --only-show-errors $DEBUG_FLAG || echo "❌ Storage RBAC failed on host subscription"
else
  echo "ℹ️ Storage Blob Data Reader already assigned on host storage."
fi

# Assign Monitoring Reader at Root Management Group scope (preferred), with fallback to per-subscription
echo "Assigning 'Monitoring Reader' at Root Management Group scope..."
ROOT_MG=$(az account management-group list --query "[?properties.details.parent==null].name | [0]" -o tsv 2>/dev/null || echo "")
if [ -z "$ROOT_MG" ] || [ "$ROOT_MG" = "null" ]; then
  echo "⚠️ Could not determine Root Management Group. Falling back to per-subscription assignments."
  FALLBACK_PER_SUB=1
else
  # Check if already assigned at MG scope
  MG_EXISTS=$(az role assignment list \
    --assignee-object-id "$SP_OBJECT_ID" \
    --role "Monitoring Reader" \
    --scope "/providers/Microsoft.Management/managementGroups/$ROOT_MG" \
    --query "length(@)" -o tsv 2>/dev/null || echo 0)
  if [ "${MG_EXISTS:-0}" -eq 0 ]; then
    if az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --role "Monitoring Reader" \
      --scope "/providers/Microsoft.Management/managementGroups/$ROOT_MG" \
      --only-show-errors $DEBUG_FLAG; then
      echo "✅ Monitoring Reader assigned at MG: $ROOT_MG"
      FALLBACK_PER_SUB=0
    else
      echo "⚠️ MG-scope assignment failed. Falling back to per-subscription assignments."
      FALLBACK_PER_SUB=1
    fi
  else
    echo "ℹ️ Monitoring Reader already assigned at MG: $ROOT_MG"
    FALLBACK_PER_SUB=0
  fi
fi

if [ "${FALLBACK_PER_SUB:-0}" = "1" ]; then
  echo "Assigning 'Monitoring Reader' across subscriptions (fallback)..."
  for SUBID in $SUB_IDS; do
    EXISTS=$(az role assignment list \
      --assignee-object-id "$SP_OBJECT_ID" \
      --role "Monitoring Reader" \
      --scope "/subscriptions/$SUBID" \
      --query "length(@)" -o tsv 2>/dev/null || echo 0)
    if [ "${EXISTS:-0}" -eq 0 ]; then
      az role assignment create \
        --assignee-object-id "$SP_OBJECT_ID" \
        --role "Monitoring Reader" \
        --scope "/subscriptions/$SUBID" \
        --only-show-errors $DEBUG_FLAG || echo "❌ Monitoring Reader RBAC failed in $SUBID"
    else
      echo "  ℹ️ Monitoring Reader already assigned at subscription: $SUBID"
    fi
  done
fi

#
# Step 3.5: Output Tailpipe configuration summary (identifiers only, no secrets)
TENANT_OUT=${TARGET_TENANT:-$(az account show --query tenantId -o tsv 2>/dev/null || echo "")}

# Monitoring mode and fields
if [ "${FALLBACK_PER_SUB:-0}" = "1" ]; then
  MON_MODE="perSubscription"
else
  MON_MODE="managementGroup"
fi

# Monitoring subscriptions array (only relevant for per-sub mode)
MON_SUBS_JSON=""
if [ "$MON_MODE" = "perSubscription" ]; then
  for sid in $SUB_IDS; do
    [ -z "$sid" ] && continue
    MON_SUBS_JSON="${MON_SUBS_JSON:+$MON_SUBS_JSON, }\"$sid\""
  done
fi
[ -n "$MON_SUBS_JSON" ] && MON_SUBS_JSON="[$MON_SUBS_JSON]" || MON_SUBS_JSON="[]"

# Subscription export paths and export-name list (based on the list we actually used for per-sub exports)
SUB_PATHS_JSON=""
PER_SUB_EXPORTS_JSON=""
for sid in $PER_SUB_LIST; do
  [ -z "$sid" ] && continue
  SUB_PATHS_JSON="${SUB_PATHS_JSON:+$SUB_PATHS_JSON, }\"tailpipe/subscriptions/$sid\""
  suffix=${sid: -6}; name="TailpipeDataExport-$suffix"
  PER_SUB_EXPORTS_JSON="${PER_SUB_EXPORTS_JSON:+$PER_SUB_EXPORTS_JSON, }{ \"subscriptionId\": \"$sid\", \"name\": \"$name\" }"
done
[ -n "$SUB_PATHS_JSON" ] && SUB_PATHS_JSON="[$SUB_PATHS_JSON]" || SUB_PATHS_JSON="[]"
[ -n "$PER_SUB_EXPORTS_JSON" ] && PER_SUB_EXPORTS_JSON="[$PER_SUB_EXPORTS_JSON]" || PER_SUB_EXPORTS_JSON="[]"

# Billing-scope fields (may be empty if not created / CSP-only)
BILLING_PATH_JSON=${BILLING_SUBFOLDER:+\"$BILLING_SUBFOLDER\"}
[ -z "$BILLING_PATH_JSON" ] && BILLING_PATH_JSON=null
if [ -n "${BILLING_SCOPE:-}" ]; then
  BILLING_EXPORT_JSON="{ \"name\": \"${EXPORT_NAME_MG:-TailpipeAllSubs}\", \"scope\": \"$BILLING_SCOPE\" }"
else
  BILLING_EXPORT_JSON="null"
fi

# MG id (null when not applicable)
MG_ID_JSON=${ROOT_MG:+\"$ROOT_MG\"}
[ -z "$MG_ID_JSON" ] && MG_ID_JSON=null

ACCOUNT_RESOURCE_ID="/subscriptions/$HOST_SUBID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
BLOB_ENDPOINT="https://$STORAGE_ACCOUNT_NAME.blob.core.windows.net"

echo "\n==== Tailpipe configuration summary (save this JSON) ===="
cat <<JSON_TAILPIPE
{
  "tenantId": "$TENANT_OUT",
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
    "container": "dataexport",
    "paths": {
      "billing": $BILLING_PATH_JSON,
      "subscriptions": $SUB_PATHS_JSON
    },
    "blobEndpoint": "$BLOB_ENDPOINT"
  },
  "costExports": {
    "billing": $BILLING_EXPORT_JSON,
    "perSubscription": $PER_SUB_EXPORTS_JSON
  }
}
JSON_TAILPIPE
echo "==== End summary ===="

# Step 4: Clean up
echo "Cleaning up generated files..."
rm -f "$TEMPLATE_FILE" /tmp/costexport.json /tmp/costexport_mg.json /tmp/costexport_sub_*.json