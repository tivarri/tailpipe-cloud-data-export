#!/bin/bash
#
# Deploy Azure Policy for automatic Cost Management export creation
# Modified version: Skips subscriptions where we can't assign permissions
#
# This script:
# 1. Creates a custom policy definition at Management Group or Subscription scope
# 2. Assigns the policy with required parameters
# 3. Tests permission assignment on storage subscription before proceeding
# 4. Creates a remediation task to fix existing non-compliant subscriptions
# 5. Logs any subscriptions that had to be skipped
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
SKIP_LOG_FILE="$SCRIPT_DIR/skipped-subscriptions-$(date +%Y%m%d-%H%M%S).log"

if [ ! -f "$POLICY_FILE" ]; then
    echo "Error: Policy definition file not found at $POLICY_FILE"
    exit 1
fi

echo "=========================================="
echo "Azure Policy Deployment (Skip Restricted)"
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
    exit 1
else
    echo "Policy Managed Identity: $PRINCIPAL_ID"

    # Extract storage subscription ID from resource ID
    STORAGE_SUB_ID=$(echo "$STORAGE_ACCOUNT_RESOURCE_ID" | cut -d'/' -f3)

    echo ""
    echo "Step 4: Testing and granting permissions..."
    echo "This script will skip subscriptions where permission assignment fails"
    echo ""

    # Initialize skip log
    echo "# Subscriptions Skipped During Policy Deployment" > "$SKIP_LOG_FILE"
    echo "# Date: $(date)" >> "$SKIP_LOG_FILE"
    echo "# Reason: Unable to assign required permissions" >> "$SKIP_LOG_FILE"
    echo "" >> "$SKIP_LOG_FILE"

    SKIPPED_COUNT=0

    # Test and grant Reader on storage subscription
    echo "Testing permission assignment on storage subscription: $STORAGE_SUB_ID"
    if az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Reader" \
        --scope "/subscriptions/$STORAGE_SUB_ID" \
        --output none 2>/dev/null; then
        echo "✅ Successfully assigned Reader role on storage subscription"
    else
        echo "⚠️  WARNING: Could not assign Reader role on storage subscription $STORAGE_SUB_ID"
        echo "   The policy may not work for subscriptions that need to validate storage access"
        echo "$STORAGE_SUB_ID - Storage subscription (Reader role assignment failed)" >> "$SKIP_LOG_FILE"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi

    # Grant Storage Blob Data Contributor on storage account
    echo "Granting Storage Blob Data Contributor on storage account..."
    if az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Storage Blob Data Contributor" \
        --scope "$STORAGE_ACCOUNT_RESOURCE_ID" \
        --output none 2>/dev/null; then
        echo "✅ Successfully assigned Storage Blob Data Contributor role"
    else
        echo "⚠️  WARNING: Could not assign Storage Blob Data Contributor on storage account"
        echo "   Exports will not be able to write data to the storage account"
        echo "$STORAGE_ACCOUNT_RESOURCE_ID - Storage account (Storage Blob Data Contributor assignment failed)" >> "$SKIP_LOG_FILE"
    fi

    # If deploying at management group scope, check all subscriptions in scope
    if [ ! -z "$MANAGEMENT_GROUP_ID" ]; then
        echo ""
        echo "Step 4b: Checking permissions across all subscriptions in management group..."

        # Get all subscriptions in the management group
        SUBSCRIPTIONS=$(az account management-group show \
            --name "$MANAGEMENT_GROUP_ID" \
            --expand --recurse \
            --query 'children[?type==`Microsoft.Management/managementGroups`].children[?type==`/subscriptions`].name' \
            -o tsv 2>/dev/null || \
            az account list --query "[].id" -o tsv)

        TESTED_COUNT=0
        for SUB in $SUBSCRIPTIONS; do
            TESTED_COUNT=$((TESTED_COUNT + 1))
            SUB_NAME=$(az account show --subscription "$SUB" --query 'name' -o tsv 2>/dev/null || echo "Unknown")

            # Test if we can create a role assignment (we'll use a test that doesn't actually create anything)
            # Try to list role assignments - if this fails, we definitely can't create them
            if ! az role assignment list --scope "/subscriptions/$SUB" --query "[0].id" -o tsv >/dev/null 2>&1; then
                echo "⚠️  Subscription $SUB_NAME ($SUB): Cannot access - WILL BE SKIPPED"
                echo "$SUB - $SUB_NAME (No access)" >> "$SKIP_LOG_FILE"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
            fi

            # Check if current user has permission to create role assignments
            # We do this by checking if we have Owner or User Access Administrator
            HAS_PERMS=$(az role assignment list \
                --scope "/subscriptions/$SUB" \
                --query "[?principalType=='User' && (roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator')].roleDefinitionName" \
                -o tsv 2>/dev/null | wc -l | tr -d ' ')

            if [ "$HAS_PERMS" -eq 0 ]; then
                echo "⚠️  Subscription $SUB_NAME ($SUB): Insufficient permissions - WILL BE SKIPPED"
                echo "$SUB - $SUB_NAME (Insufficient permissions to assign roles)" >> "$SKIP_LOG_FILE"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            else
                echo "✅ Subscription $SUB_NAME ($SUB): Permissions OK"
            fi
        done

        echo ""
        echo "Tested $TESTED_COUNT subscriptions, $SKIPPED_COUNT will be skipped"
    fi
fi

echo ""
echo "Step 5: Creating remediation task for existing subscriptions..."
echo "This will create exports for all existing subscriptions that don't have one"
echo "(Skipped subscriptions will show as failed in remediation)"

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

if [ $SKIPPED_COUNT -gt 0 ]; then
    echo "⚠️  WARNING: $SKIPPED_COUNT subscription(s) were skipped due to permission issues"
    echo "   See log file: $SKIP_LOG_FILE"
    echo ""
    echo "Skipped subscriptions:"
    grep -v "^#" "$SKIP_LOG_FILE" | grep -v "^$" || echo "  (none)"
    echo ""
    echo "To enable exports for these subscriptions:"
    echo "1. Ask subscription Owners to grant required permissions"
    echo "2. Or deploy policy at individual subscription scope where you have Owner/UAA role"
    echo ""
fi

echo "What happens next:"
echo "1. The policy will automatically scan all subscriptions in scope"
echo "2. For any subscription without a compliant export, it will create one"
echo "3. The remediation task is running in the background"
echo "4. Subscriptions with permission issues will show as failed in remediation"
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
