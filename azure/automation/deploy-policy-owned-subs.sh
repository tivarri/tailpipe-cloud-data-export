#!/bin/bash
#
# Deploy Azure Policy for automatic Cost Management export creation
# On subscriptions where current user has Owner permissions
#
# This script:
# 1. Identifies subscriptions where you have Owner/UAA permissions
# 2. Deploys policy definition at each subscription scope
# 3. Assigns the policy with required parameters
# 4. Creates remediation tasks for each subscription
#

set -e

# Configuration - UPDATE THESE VALUES
STORAGE_ACCOUNT_RESOURCE_ID="/subscriptions/9ea664c2-812d-4d18-a036-c58be0934b4f/resourceGroups/tailpipe-dataexport/providers/Microsoft.Storage/storageAccounts/tailpipedataexport934b4f"
STORAGE_CONTAINER="dataexport"
EXPORT_NAME_PREFIX="TailpipeDataExport"
EXPORT_FOLDER_PREFIX="tailpipe"
POLICY_NAME="deploy-cost-export"
ASSIGNMENT_NAME="deploy-cost-export-a"

# Derived values
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
POLICY_FILE="$SCRIPT_DIR/policy-auto-export.json"
DEPLOYMENT_LOG="$SCRIPT_DIR/deployment-log-$(date +%Y%m%d-%H%M%S).log"

if [ ! -f "$POLICY_FILE" ]; then
    echo "Error: Policy definition file not found at $POLICY_FILE"
    exit 1
fi

echo "=========================================="
echo "Azure Policy Deployment (Owned Subscriptions)"
echo "=========================================="
echo "Policy: Auto-create Cost Management Exports"
echo "Storage: $STORAGE_ACCOUNT_RESOURCE_ID"
echo "Container: $STORAGE_CONTAINER"
echo ""
echo "Deployment log: $DEPLOYMENT_LOG"
echo ""

# Initialize log
echo "# Azure Policy Deployment Log" > "$DEPLOYMENT_LOG"
echo "# Date: $(date)" >> "$DEPLOYMENT_LOG"
echo "# User: $(az account show --query 'user.name' -o tsv)" >> "$DEPLOYMENT_LOG"
echo "" >> "$DEPLOYMENT_LOG"

# Extract storage subscription ID
STORAGE_SUB_ID=$(echo "$STORAGE_ACCOUNT_RESOURCE_ID" | cut -d'/' -f3)

# Find subscriptions where user has Owner or User Access Administrator
echo "Step 1: Identifying subscriptions with Owner/UAA permissions..."
echo ""

OWNED_SUBS=()
az account list --query "[].{id:id, name:name}" -o json > /tmp/subs.json

while IFS= read -r line; do
  SUB_ID=$(echo "$line" | jq -r '.id')
  SUB_NAME=$(echo "$line" | jq -r '.name')

  roles=$(az role assignment list \
    --subscription "$SUB_ID" \
    --assignee galleryadmin@visitgunnersbury.org \
    --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator'].roleDefinitionName" \
    -o tsv 2>/dev/null)

  if [ ! -z "$roles" ]; then
    echo "✅ Found: $SUB_NAME ($SUB_ID)"
    OWNED_SUBS+=("$SUB_ID|$SUB_NAME")
  fi
done < <(jq -c '.[]' /tmp/subs.json)

rm -f /tmp/subs.json

if [ ${#OWNED_SUBS[@]} -eq 0 ]; then
  echo "❌ No subscriptions found with Owner or User Access Administrator permissions"
  echo "Cannot deploy policy without proper permissions"
  exit 1
fi

echo ""
echo "Found ${#OWNED_SUBS[@]} subscription(s) where you have Owner/UAA permissions"
echo ""

# Extract policyRule once for reuse
TEMP_RULE_FILE=$(mktemp)
if jq -e '.properties.policyRule' "$POLICY_FILE" > /dev/null 2>&1; then
  jq '.properties.policyRule' "$POLICY_FILE" > "$TEMP_RULE_FILE"
  PARAMS_JSON=$(jq '.properties.parameters' "$POLICY_FILE")
else
  cp "$POLICY_FILE" "$TEMP_RULE_FILE"
  PARAMS_JSON=$(jq '.parameters' "$POLICY_FILE" 2>/dev/null || echo '{}')
fi

SUCCESS_COUNT=0
FAILED_COUNT=0

# Deploy to each subscription
for sub_info in "${OWNED_SUBS[@]}"; do
  SUB_ID=$(echo "$sub_info" | cut -d'|' -f1)
  SUB_NAME=$(echo "$sub_info" | cut -d'|' -f2)

  echo "=========================================="
  echo "Deploying to: $SUB_NAME ($SUB_ID)"
  echo "=========================================="
  echo ""

  echo "## Subscription: $SUB_NAME ($SUB_ID)" >> "$DEPLOYMENT_LOG"
  echo "Started: $(date)" >> "$DEPLOYMENT_LOG"
  echo "" >> "$DEPLOYMENT_LOG"

  # Set active subscription
  az account set --subscription "$SUB_ID"

  # Step 1: Create policy definition
  echo "  Creating policy definition..."
  if az policy definition create \
    --name "$POLICY_NAME" \
    --display-name "Deploy Cost Management Export for Subscriptions" \
    --description "Automatically creates Cost Management exports for subscriptions" \
    --rules "$TEMP_RULE_FILE" \
    --params "$PARAMS_JSON" \
    --mode All \
    --subscription "$SUB_ID" \
    >> "$DEPLOYMENT_LOG" 2>&1; then
    echo "  ✅ Policy definition created"
    echo "Status: Policy definition created successfully" >> "$DEPLOYMENT_LOG"
  else
    echo "  ⚠️  Policy definition may already exist (continuing)"
    echo "Status: Policy definition already exists or creation failed" >> "$DEPLOYMENT_LOG"
  fi

  # Step 2: Assign policy
  echo "  Assigning policy..."

  POLICY_ID="/subscriptions/$SUB_ID/providers/Microsoft.Authorization/policyDefinitions/$POLICY_NAME"
  SCOPE="/subscriptions/$SUB_ID"

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
    --query 'id' -o tsv 2>> "$DEPLOYMENT_LOG")

  if [ -z "$ASSIGNMENT_ID" ]; then
    echo "  ❌ Failed to assign policy"
    echo "Status: FAILED - Policy assignment failed" >> "$DEPLOYMENT_LOG"
    echo "" >> "$DEPLOYMENT_LOG"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  echo "  ✅ Policy assigned: $ASSIGNMENT_ID"
  echo "Assignment ID: $ASSIGNMENT_ID" >> "$DEPLOYMENT_LOG"

  # Step 3: Get managed identity
  echo "  Extracting managed identity..."
  PRINCIPAL_ID=$(az policy assignment show --name "$ASSIGNMENT_NAME" --scope "$SCOPE" --query 'identity.principalId' -o tsv)

  if [ -z "$PRINCIPAL_ID" ]; then
    echo "  ⚠️  Could not extract principal ID"
    echo "Status: WARNING - Could not extract managed identity" >> "$DEPLOYMENT_LOG"
    echo "" >> "$DEPLOYMENT_LOG"
    continue
  fi

  echo "  Managed Identity: $PRINCIPAL_ID"
  echo "Managed Identity: $PRINCIPAL_ID" >> "$DEPLOYMENT_LOG"

  # Step 4: Grant permissions
  echo "  Granting permissions..."

  # Grant Reader on storage subscription
  if [ "$SUB_ID" != "$STORAGE_SUB_ID" ]; then
    echo "    - Reader on storage subscription..."
    if az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role "Reader" \
      --scope "/subscriptions/$STORAGE_SUB_ID" \
      --output none 2>/dev/null; then
      echo "    ✅ Reader role assigned"
      echo "Permission: Reader on storage subscription - SUCCESS" >> "$DEPLOYMENT_LOG"
    else
      echo "    ⚠️  Could not assign Reader (may already exist or insufficient permissions)"
      echo "Permission: Reader on storage subscription - FAILED" >> "$DEPLOYMENT_LOG"
    fi
  fi

  # Grant Storage Blob Data Contributor on storage account
  echo "    - Storage Blob Data Contributor on storage account..."
  if az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "$STORAGE_ACCOUNT_RESOURCE_ID" \
    --output none 2>/dev/null; then
    echo "    ✅ Storage Blob Data Contributor assigned"
    echo "Permission: Storage Blob Data Contributor - SUCCESS" >> "$DEPLOYMENT_LOG"
  else
    echo "    ⚠️  Could not assign Storage Blob Data Contributor (may already exist or insufficient permissions)"
    echo "Permission: Storage Blob Data Contributor - FAILED" >> "$DEPLOYMENT_LOG"
  fi

  # Step 5: Create remediation task
  echo "  Creating remediation task..."
  REMEDIATION_NAME="remediate-cost-exports-$(date +%s)"

  if az policy remediation create \
    --name "$REMEDIATION_NAME" \
    --policy-assignment "$ASSIGNMENT_ID" \
    --subscription "$SUB_ID" \
    --resource-discovery-mode ReEvaluateCompliance \
    >> "$DEPLOYMENT_LOG" 2>&1; then
    echo "  ✅ Remediation task created: $REMEDIATION_NAME"
    echo "Remediation: $REMEDIATION_NAME - CREATED" >> "$DEPLOYMENT_LOG"
  else
    echo "  ⚠️  Failed to create remediation task"
    echo "Remediation: FAILED" >> "$DEPLOYMENT_LOG"
  fi

  echo "Status: COMPLETED SUCCESSFULLY" >> "$DEPLOYMENT_LOG"
  echo "Completed: $(date)" >> "$DEPLOYMENT_LOG"
  echo "" >> "$DEPLOYMENT_LOG"
  echo ""

  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done

rm -f "$TEMP_RULE_FILE"

echo "=========================================="
echo "✅ Deployment Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Successfully deployed: $SUCCESS_COUNT subscription(s)"
echo "  Failed: $FAILED_COUNT subscription(s)"
echo ""
echo "Detailed log: $DEPLOYMENT_LOG"
echo ""
echo "Next steps:"
echo "1. Check compliance status for each subscription:"
echo "   az policy state list --policy-assignment \"$ASSIGNMENT_NAME\" --subscription <SUB_ID>"
echo ""
echo "2. Monitor remediation tasks in Azure Portal:"
echo "   Policy > Remediation"
echo ""
echo "3. Verify exports are created:"
echo "   az costmanagement export list --scope /subscriptions/<SUB_ID>"
echo ""
