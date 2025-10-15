#!/bin/bash
#
# Deploy Azure Policy for automatic Cost Management export creation
#
# This script:
# 1. Creates a custom policy definition at Management Group or Subscription scope
# 2. Assigns the policy with required parameters
# 3. Creates a remediation task to fix existing non-compliant subscriptions
#

set -e

# Configuration - UPDATE THESE VALUES
MANAGEMENT_GROUP_ID="9cb873e4-0b7f-4c64-bbb8-e3339723c637"  # Leave empty to deploy at subscription scope, or set to your MG ID (e.g., "contoso-root")
SUBSCRIPTION_ID="9ea664c2-812d-4d18-a036-c58be0934b4f"  # Your storage subscription (used if MG is empty)
STORAGE_ACCOUNT_RESOURCE_ID="/subscriptions/9ea664c2-812d-4d18-a036-c58be0934b4f/resourceGroups/tailpipe-dataexport/providers/Microsoft.Storage/storageAccounts/tailpipedataexport934b4f"
STORAGE_CONTAINER="dataexport"
EXPORT_NAME_PREFIX="TailpipeDataExport"
EXPORT_FOLDER_PREFIX="tailpipe"
POLICY_NAME="deploy-cost-export"
ASSIGNMENT_NAME="deploy-cost-export-a"

# Derived values
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
POLICY_FILE="$SCRIPT_DIR/policy-auto-export.json"

if [ ! -f "$POLICY_FILE" ]; then
    echo "Error: Policy definition file not found at $POLICY_FILE"
    exit 1
fi

echo "=========================================="
echo "Azure Policy Deployment"
echo "=========================================="
echo "Policy: Auto-create Cost Management Exports"
echo "Storage: $STORAGE_ACCOUNT_RESOURCE_ID"
echo "Container: $STORAGE_CONTAINER"
echo ""

# Determine scope
if [ -z "$MANAGEMENT_GROUP_ID" ]; then
    SCOPE_TYPE="subscription"
    SCOPE="/subscriptions/$SUBSCRIPTION_ID"
    SCOPE_PARAM="--subscription $SUBSCRIPTION_ID"
    echo "Deploying at SUBSCRIPTION scope: $SUBSCRIPTION_ID"
else
    SCOPE_TYPE="managementGroup"
    SCOPE="/providers/Microsoft.Management/managementGroups/$MANAGEMENT_GROUP_ID"
    SCOPE_PARAM="--management-group $MANAGEMENT_GROUP_ID"
    echo "Deploying at MANAGEMENT GROUP scope: $MANAGEMENT_GROUP_ID"
fi

echo ""
echo "Step 1: Creating policy definition..."

# Extract just the policyRule from the JSON (remove properties wrapper if present)
TEMP_RULE_FILE=$(mktemp)
if jq -e '.properties.policyRule' "$POLICY_FILE" > /dev/null 2>&1; then
  echo "Extracting policyRule from properties wrapper..."
  jq '.properties.policyRule' "$POLICY_FILE" > "$TEMP_RULE_FILE"
  PARAMS_JSON=$(jq '.properties.parameters' "$POLICY_FILE")
else
  echo "Using policy file as-is..."
  cp "$POLICY_FILE" "$TEMP_RULE_FILE"
  PARAMS_JSON=$(jq '.parameters' "$POLICY_FILE" 2>/dev/null || echo '{}')
fi

az policy definition create \
  --name "$POLICY_NAME" \
  --display-name "Deploy Cost Management Export for Subscriptions" \
  --description "Automatically creates Cost Management exports for subscriptions" \
  --rules "$TEMP_RULE_FILE" \
  --params "$PARAMS_JSON" \
  --mode All \
  $SCOPE_PARAM

rm -f "$TEMP_RULE_FILE"

echo ""
echo "Step 2: Assigning policy..."

# Get the full policy definition ID
if [ -z "$MANAGEMENT_GROUP_ID" ]; then
  POLICY_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/policyDefinitions/$POLICY_NAME"
else
  POLICY_ID="/providers/Microsoft.Management/managementGroups/$MANAGEMENT_GROUP_ID/providers/Microsoft.Authorization/policyDefinitions/$POLICY_NAME"
fi

echo "Using policy definition ID: $POLICY_ID"

ASSIGNMENT_ID=$(az policy assignment create \
  --name "$ASSIGNMENT_NAME" \
  --display-name "Auto-deploy Cost Exports" \
  --policy "$POLICY_ID" \
  --scope "$SCOPE" \
  --location uksouth \
  --mi-system-assigned \
  --identity-scope "$SCOPE" \
  --role Contributor \
  --params "{
    \"storageAccountResourceId\": {\"value\": \"$STORAGE_ACCOUNT_RESOURCE_ID\"},
    \"storageContainerName\": {\"value\": \"$STORAGE_CONTAINER\"},
    \"exportNamePrefix\": {\"value\": \"$EXPORT_NAME_PREFIX\"},
    \"exportFolderPrefix\": {\"value\": \"$EXPORT_FOLDER_PREFIX\"},
    \"effect\": {\"value\": \"DeployIfNotExists\"}
  }" \
  --query 'id' -o tsv)

echo "Policy assigned with ID: $ASSIGNMENT_ID"

echo ""
echo "Step 3: Extracting managed identity from policy assignment..."
PRINCIPAL_ID=$(az policy assignment show --name "$ASSIGNMENT_NAME" --scope "$SCOPE" --query 'identity.principalId' -o tsv)

if [ -z "$PRINCIPAL_ID" ]; then
    echo "Warning: Could not extract principal ID from policy assignment"
    echo "You may need to manually grant permissions to the policy's managed identity"
else
    echo "Policy Managed Identity: $PRINCIPAL_ID"

    # Extract storage subscription ID from resource ID
    STORAGE_SUB_ID=$(echo "$STORAGE_ACCOUNT_RESOURCE_ID" | cut -d'/' -f3)

    echo ""
    echo "Step 4: Granting policy managed identity access to storage subscription..."
    echo "This allows the policy to validate access to the storage account during deployment"

    # Grant Reader on storage subscription (needed to validate storage account exists)
    az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role "Reader" \
      --scope "/subscriptions/$STORAGE_SUB_ID" \
      --output none || echo "Warning: Could not assign Reader role (may already exist)"

    # Grant Storage Blob Data Contributor on storage account (needed for export to write data)
    az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role "Storage Blob Data Contributor" \
      --scope "$STORAGE_ACCOUNT_RESOURCE_ID" \
      --output none || echo "Warning: Could not assign Storage Blob Data Contributor role (may already exist)"
fi

echo ""
echo "Step 5: Creating remediation task for existing subscriptions..."
echo "This will create exports for all existing subscriptions that don't have one"

REMEDIATION_NAME="remediate-cost-exports-$(date +%s)"
if [ -z "$MANAGEMENT_GROUP_ID" ]; then
  az policy remediation create \
    --name "$REMEDIATION_NAME" \
    --policy-assignment "$ASSIGNMENT_ID" \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-discovery-mode ReEvaluateCompliance
else
  # Management group remediations must use ExistingNonCompliant mode
  az policy remediation create \
    --name "$REMEDIATION_NAME" \
    --policy-assignment "$ASSIGNMENT_ID" \
    --management-group "$MANAGEMENT_GROUP_ID" \
    --resource-discovery-mode ExistingNonCompliant
fi

echo ""
echo "=========================================="
echo "✅ Policy deployment complete!"
echo "=========================================="
echo ""
echo "What happens next:"
echo "1. The policy will automatically scan all subscriptions in scope"
echo "2. For any subscription without a compliant export, it will create one"
echo "3. The remediation task is running in the background"
echo ""
echo "To check remediation status:"
if [ -z "$MANAGEMENT_GROUP_ID" ]; then
  echo "  az policy remediation show --name $REMEDIATION_NAME --subscription \"$SUBSCRIPTION_ID\""
else
  echo "  az policy remediation show --name $REMEDIATION_NAME --management-group \"$MANAGEMENT_GROUP_ID\""
fi
echo ""
echo "To check compliance:"
if [ -z "$MANAGEMENT_GROUP_ID" ]; then
  echo "  az policy state list --policy-assignment \"$ASSIGNMENT_NAME\" --subscription \"$SUBSCRIPTION_ID\""
else
  echo "  az policy state list --policy-assignment \"$ASSIGNMENT_NAME\" --management-group \"$MANAGEMENT_GROUP_ID\""
fi
echo ""
echo "To manually trigger remediation for a specific subscription:"
echo "  az policy remediation create \\"
echo "    --name remediate-subscription-SUBID \\"
echo "    --policy-assignment \"$ASSIGNMENT_ID\" \\"
echo "    --scope /subscriptions/SUBSCRIPTION_ID"
echo ""
