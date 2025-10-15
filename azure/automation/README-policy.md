# Azure Policy for Automatic Cost Management Export Creation

This directory contains an Azure Policy that automatically creates Cost Management exports for all subscriptions in scope.

## Files

- **[policy-auto-export.json](policy-auto-export.json)** - The policy definition (JSON)
- **[deploy-policy.sh](deploy-policy.sh)** - Deployment script
- **README-policy.md** - This file

## How It Works

1. **Policy Definition**: Uses `deployIfNotExists` effect to check if each subscription has a Cost Management export
2. **Automatic Remediation**: When a subscription doesn't have an export (or it's non-compliant), the policy automatically deploys one
3. **Managed Identity**: The policy assignment creates a managed identity that's granted Contributor role to deploy resources
4. **Cross-Subscription Support**: Handles exports that write to storage accounts in different subscriptions

## Advantages Over Runbook Approach

- ✅ No permission propagation issues (Azure Policy handles timing)
- ✅ Built-in compliance tracking and reporting
- ✅ Automatic remediation for new subscriptions
- ✅ No custom code maintenance
- ✅ Audit trail of all policy actions
- ✅ Can deploy at Management Group level to cover all current and future subscriptions

## Prerequisites

Before deploying, ensure you have:

1. **Azure CLI** installed and authenticated:
   ```bash
   az login
   ```

2. **Permissions** to create policy definitions and assignments at your chosen scope:
   - For Management Group: `Resource Policy Contributor` at MG level
   - For Subscription: `Resource Policy Contributor` at subscription level

3. **Storage Account** already created with:
   - Resource ID ready (e.g., `/subscriptions/{id}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{name}`)
   - Container created (e.g., `dataexport`)

## Deployment

### Option 1: Deploy at Management Group Level (Recommended)

Covers all subscriptions in the management group, including future ones:

```bash
# Edit deploy-policy.sh and set:
# - MANAGEMENT_GROUP_ID="your-mg-id"
# - STORAGE_ACCOUNT_RESOURCE_ID="/subscriptions/..."
# - Other configuration values

chmod +x deploy-policy.sh
./deploy-policy.sh
```

### Option 2: Deploy at Subscription Level

Covers only a single subscription:

```bash
# Edit deploy-policy.sh and set:
# - MANAGEMENT_GROUP_ID=""  (leave empty)
# - SUBSCRIPTION_ID="your-sub-id"
# - STORAGE_ACCOUNT_RESOURCE_ID="/subscriptions/..."
# - Other configuration values

chmod +x deploy-policy.sh
./deploy-policy.sh
```

### Manual Deployment Steps

If you prefer to deploy manually:

#### 1. Create Policy Definition

```bash
az policy definition create \
  --name deploy-cost-export \
  --display-name "Deploy Cost Management Export for Subscriptions" \
  --rules policy-auto-export.json \
  --mode All \
  --management-group YOUR_MG_ID
```

#### 2. Assign Policy

```bash
az policy assignment create \
  --name deploy-cost-export-assignment \
  --policy deploy-cost-export \
  --management-group YOUR_MG_ID \
  --location uksouth \
  --assign-identity \
  --identity-scope /providers/Microsoft.Management/managementGroups/YOUR_MG_ID \
  --role Contributor \
  --params '{
    "storageAccountResourceId": {"value": "/subscriptions/SUB_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/STORAGE"},
    "storageContainerName": {"value": "dataexport"},
    "exportNamePrefix": {"value": "TailpipeDataExport"},
    "exportFolderPrefix": {"value": "tailpipe"},
    "effect": {"value": "DeployIfNotExists"}
  }'
```

#### 3. Grant Storage Permissions

The policy's managed identity needs:
- **Reader** on the storage subscription (to validate storage account exists)
- **Storage Blob Data Contributor** on the storage account (for exports to write data)

```bash
# Get the policy's managed identity principal ID
PRINCIPAL_ID=$(az policy assignment show \
  --name deploy-cost-export-assignment \
  --management-group YOUR_MG_ID \
  --query 'identity.principalId' -o tsv)

# Grant Reader on storage subscription
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Reader" \
  --scope "/subscriptions/STORAGE_SUB_ID"

# Grant Storage Blob Data Contributor on storage account
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/STORAGE_SUB_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/STORAGE"
```

#### 4. Create Remediation Task

To fix existing non-compliant subscriptions:

```bash
az policy remediation create \
  --name remediate-cost-exports \
  --policy-assignment deploy-cost-export-assignment \
  --management-group YOUR_MG_ID \
  --resource-discovery-mode ReEvaluateCompliance
```

## Monitoring

### Check Compliance State

```bash
# List all subscriptions and their compliance
az policy state list \
  --policy-assignment deploy-cost-export-assignment \
  --management-group YOUR_MG_ID \
  --query "[].{subscription:resourceId, state:complianceState}" -o table
```

### Check Remediation Progress

```bash
# View remediation task status
az policy remediation show \
  --name remediate-cost-exports \
  --management-group YOUR_MG_ID
```

### View Policy Events

```bash
# See policy evaluation events
az policy event list \
  --management-group YOUR_MG_ID \
  --from "2025-10-01" \
  --query "[?policyAssignmentName=='deploy-cost-export-assignment']" -o table
```

## Configuration Parameters

The policy accepts these parameters (configured during assignment):

| Parameter | Description | Default |
|-----------|-------------|---------|
| `storageAccountResourceId` | Full resource ID of storage account | (required) |
| `storageContainerName` | Blob container name | `dataexport` |
| `exportNamePrefix` | Prefix for export names | `TailpipeDataExport` |
| `exportFolderPrefix` | Root folder prefix in storage | `tailpipe` |
| `effect` | Policy effect | `DeployIfNotExists` |

### Export Naming

Exports are named: `{exportNamePrefix}-{last-6-chars-of-subscription-id}`

Example: `TailpipeDataExport-53d0e6`

### Storage Path

Data is written to: `{exportFolderPrefix}/subscriptions/{subscription-id}/`

Example: `tailpipe/subscriptions/eff915d9-c67f-404b-b6fa-7a83de53d0e6/`

## Troubleshooting

### Policy not deploying exports

1. **Check compliance state**:
   ```bash
   az policy state list --policy-assignment deploy-cost-export-assignment
   ```

2. **Check managed identity has required roles**:
   - Contributor on each subscription (granted automatically by policy)
   - Reader on storage subscription
   - Storage Blob Data Contributor on storage account

3. **Manually trigger remediation**:
   ```bash
   az policy remediation create \
     --name manual-remediation \
     --policy-assignment deploy-cost-export-assignment \
     --scope /subscriptions/SUBSCRIPTION_ID
   ```

### Cross-subscription exports failing

Ensure the policy's managed identity has:
- Contributor on BOTH the target subscription AND storage subscription
- Storage Blob Data Contributor on the storage account

### Policy evaluation not running

Policy evaluation happens:
- Every 24 hours automatically
- When a new subscription is added
- When you create a remediation task manually

To force evaluation, create a new remediation task.

## Cleanup

To remove the policy:

```bash
# Delete assignment
az policy assignment delete \
  --name deploy-cost-export-assignment \
  --management-group YOUR_MG_ID

# Delete definition
az policy definition delete \
  --name deploy-cost-export \
  --management-group YOUR_MG_ID
```

**Note**: This will NOT delete the exports that were already created. You'll need to delete those manually if desired.

## Migration from Runbook

If you're currently using the PowerShell runbook:

1. **Deploy the policy** (this README)
2. **Wait 24 hours** for policy to evaluate and remediate all subscriptions
3. **Verify** all subscriptions have exports via Azure Portal or CLI
4. **Disable the runbook** (but keep as backup)
5. **Optional**: Clean up state file (`known_subscriptions.json`) as it's no longer needed

The policy approach is more robust and doesn't require maintaining the state file.

## Support

For issues with:
- **Policy definition**: Check [policy-auto-export.json](policy-auto-export.json)
- **Deployment script**: Check [deploy-policy.sh](deploy-policy.sh)
- **Azure Policy**: See [Azure Policy documentation](https://docs.microsoft.com/azure/governance/policy/)
- **Cost Management Exports**: See [Cost Management documentation](https://docs.microsoft.com/azure/cost-management-billing/costs/tutorial-export-acm-data)
