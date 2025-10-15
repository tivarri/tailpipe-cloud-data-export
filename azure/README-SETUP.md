# Tailpipe Azure Setup Guide

Complete automation for setting up Tailpipe cost analytics in Azure environments.

## Overview

This toolkit provides a unified solution for configuring Azure Cost Management exports for the Tailpipe platform. It handles:

- **Service Principal setup** for Tailpipe data access
- **Storage account** provisioning for cost export data
- **Cost Management exports** at billing or subscription scope
- **Azure Policy** for automatic export creation on new subscriptions (CSP only)
- **Automation Account** for provider registration (CSP only)
- **RBAC configuration** for monitoring and storage access

## Quick Start

### Prerequisites

1. **Azure CLI** version 2.50.0 or later
   ```bash
   az version
   # If needed: brew update && brew upgrade azure-cli
   ```

2. **Permissions** required:
   - **Global Administrator** or **Application Administrator** (to create service principals)
   - **Owner** or **Contributor** at Management Group or Subscription level
   - **Billing Profile Contributor** (for billing-scope exports, MCA/EA only)

3. **Login** to Azure:
   ```bash
   az login
   ```

### Installation

#### Interactive Mode (Recommended for first-time setup)

```bash
chmod +x setup-tailpipe.sh
./setup-tailpipe.sh
```

You'll be prompted for:
- Azure region (e.g., `uksouth`, `westeurope`)
- Confirmation before creating resources

#### Non-Interactive Mode (CI/CD or scripted deployments)

```bash
chmod +x setup-tailpipe.sh
LOCATION=uksouth ./setup-tailpipe.sh
```

#### Dry Run (Preview changes without executing)

```bash
DRY_RUN=1 ./setup-tailpipe.sh
```

This shows exactly what would be created without making any changes.

## Configuration Options

### Environment Variables

All configuration can be controlled via environment variables:

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `LOCATION` | Azure region for resources | _(prompt)_ | `uksouth` |
| `ENTERPRISE_APP_ID` | Tailpipe application ID | UAT App ID | `071b0391-48e8-483c-b652-a8a6cd43a018` |
| `MANAGEMENT_GROUP_ID` | Target management group | Auto-detected | `contoso-root` |
| `BILLING_SCOPE` | Billing profile resource ID | Auto-detected | `/providers/Microsoft.Billing/...` |
| `STORAGE_SUBID` | Subscription for storage | Auto-detected | `9ea664c2-812d-...` |
| `TENANT_ID` | Target tenant ID | Current tenant | `00000000-0000-...` |
| `DRY_RUN` | Preview without changes | `0` | `1` |
| `SKIP_AUTOMATION` | Skip Automation Account | `0` | `1` |
| `SKIP_POLICY` | Skip Azure Policy | `0` | `1` |
| `DEBUG` | Verbose Azure CLI output | `0` | `1` |

### Examples

**Production deployment:**
```bash
ENTERPRISE_APP_ID=f5f07900-0484-4506-a34d-ec781138342a \
LOCATION=uksouth \
./setup-tailpipe.sh
```

**Test with specific management group:**
```bash
MANAGEMENT_GROUP_ID=my-test-mg \
LOCATION=westeurope \
DRY_RUN=1 \
./setup-tailpipe.sh
```

**Skip automation for simple setups:**
```bash
SKIP_AUTOMATION=1 \
SKIP_POLICY=1 \
LOCATION=uksouth \
./setup-tailpipe.sh
```

## What Gets Created

### For All Deployments

1. **Service Principal**
   - Name: Tailpipe Enterprise Application
   - App ID: `071b0391-48e8-483c-b652-a8a6cd43a018` (UAT) or `f5f07900-0484-4506-a34d-ec781138342a` (Prod)
   - Roles:
     - `Storage Blob Data Reader` on storage account
     - `Monitoring Reader` at Management Group or per-subscription

2. **Resource Group**
   - Name: `tailpipe-dataexport`
   - Location: Your chosen region

3. **Storage Account**
   - Name: `tailpipedataexport{6-char-suffix}` (suffix from subscription ID)
   - Type: Standard LRS, StorageV2
   - Container: `dataexport`

4. **Cost Management Exports**
   - **MCA/EA subscriptions**: Billing-scope export (if available)
     - Name: `TailpipeAllSubs`
     - Path: `tailpipe/billing/{billing-profile-id}/`
   - **CSP/Partner subscriptions**: Per-subscription exports
     - Name: `TailpipeDataExport-{6-char-suffix}`
     - Path: `tailpipe/subscriptions/{subscription-id}/`

### For CSP Deployments (Automatic)

5. **Azure Policy**
   - Definition: `deploy-cost-export`
   - Assignment: `deploy-cost-export-a`
   - Scope: Management Group or Subscription
   - Effect: DeployIfNotExists
   - Purpose: Auto-create exports on new subscriptions

6. **Automation Account**
   - Resource Group: `tailpipe-automation`
   - Account: `tailpipeAutomation`
   - Runbook: `RegisterResourceProviders`
   - Schedule: Daily at 00:00 UTC
   - Purpose: Register required providers on new subscriptions

## Subscription Type Detection

The script automatically detects subscription types:

- **CSP/Partner** (quotaId contains `CSP`, `AZURE_PLAN`, or `MICROSOFT_AZURE_PLAN`)
  - Gets per-subscription exports
  - Triggers policy and automation setup

- **MCA/EA** (all other quotaIds)
  - Attempts billing-scope export first
  - Falls back to per-subscription if billing not available

## Output

After successful deployment, you'll receive a JSON configuration summary:

```json
{
  "tenantId": "00000000-0000-0000-0000-000000000000",
  "tailpipe": {
    "appId": "071b0391-48e8-483c-b652-a8a6cd43a018",
    "servicePrincipalObjectId": "..."
  },
  "monitoringAccess": {
    "mode": "managementGroup",
    "managementGroupId": "root-mg",
    "subscriptions": []
  },
  "storage": {
    "subscriptionId": "...",
    "resourceGroup": "tailpipe-dataexport",
    "accountName": "tailpipedataexport934b4f",
    "accountResourceId": "/subscriptions/.../tailpipedataexport934b4f",
    "container": "dataexport",
    "paths": {
      "billing": "tailpipe/billing/BP123",
      "subscriptions": ["tailpipe/subscriptions/sub-id-1", ...]
    },
    "blobEndpoint": "https://tailpipedataexport934b4f.blob.core.windows.net"
  },
  "costExports": {
    "billing": {
      "name": "TailpipeAllSubs",
      "scope": "/providers/Microsoft.Billing/..."
    },
    "perSubscription": [
      {"subscriptionId": "...", "name": "TailpipeDataExport-934b4f"}
    ]
  },
  "automation": {
    "policyEnabled": true,
    "runbookEnabled": true
  }
}
```

**Save this output** - it contains all the information needed for Tailpipe onboarding.

## Validation

The setup script automatically validates:

- ✅ Storage account creation
- ✅ Service principal RBAC assignments
- ✅ Cost export counts

### Manual Validation

**Check exports:**
```bash
# List all cost exports in a subscription
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub-id}/providers/Microsoft.CostManagement/exports?api-version=2023-08-01" \
  --query "value[].{name:name, status:properties.schedule.status}"
```

**Check policy compliance (CSP only):**
```bash
# View compliance state
az policy state list \
  --policy-assignment deploy-cost-export-a \
  --management-group {mg-id} \
  --query "[].{subscription:resourceId, state:complianceState}" -o table
```

**Check automation runbook (CSP only):**
```bash
# Start runbook manually
az automation runbook start \
  --automation-account-name tailpipeAutomation \
  --resource-group tailpipe-automation \
  --name RegisterResourceProviders

# Check job status
az automation job list \
  --automation-account-name tailpipeAutomation \
  --resource-group tailpipe-automation \
  --query "[0].{Status:status, StartTime:startTime}" -o table
```

## Troubleshooting

### Common Issues

#### 1. Service Principal Creation Fails

**Error:** `Service principal has not appeared in directory yet`

**Solution:**
```bash
# Wait 1-2 minutes for Azure AD replication
# Then re-run the script
./setup-tailpipe.sh
```

#### 2. Billing Scope Not Found

**Message:** `No billing accounts visible; automatically falling back to per-subscription exports`

**Cause:** No MCA/EA billing profile access, or CSP subscription type

**Impact:** Per-subscription exports will be created instead (this is normal for CSP)

**Action:** No action needed - this is expected behavior

#### 3. Policy Assignment Fails at Management Group

**Error:** `Failed to create policy assignment`

**Solution:**
```bash
# Deploy at subscription level instead
MANAGEMENT_GROUP_ID="" LOCATION=uksouth ./setup-tailpipe.sh
```

#### 4. "The content for this response was already consumed"

**Cause:** Outdated Azure CLI version

**Solution:**
```bash
# Update Azure CLI
brew update && brew upgrade azure-cli

# Re-run with debug
DEBUG=1 ./setup-tailpipe.sh
```

#### 5. Export Creation Fails with "Provider not registered"

**Cause:** Required resource providers not registered in subscription

**Solution:**
```bash
# Manually register providers
az provider register --namespace Microsoft.CostManagement --wait
az provider register --namespace Microsoft.CostManagementExports --wait

# Re-run setup
./setup-tailpipe.sh
```

### Debug Mode

Enable detailed logging:

```bash
DEBUG=1 ./setup-tailpipe.sh
```

This shows full Azure CLI command output for troubleshooting.

### Get Help

Check script logs for specific error messages. Common patterns:

- **403 Forbidden**: Missing RBAC permissions
- **404 Not Found**: Resource doesn't exist (may need to wait for propagation)
- **409 Conflict**: Resource already exists (usually safe to ignore)

## Cleanup & Removal

To remove all Tailpipe resources:

```bash
chmod +x cleanup-tailpipe.sh
./cleanup-tailpipe.sh
```

### Cleanup Options

**Preview cleanup without deleting:**
```bash
DRY_RUN=1 ./cleanup-tailpipe.sh
```

**Keep service principal (preserve integration):**
```bash
KEEP_SP=1 ./cleanup-tailpipe.sh
```

**Keep storage account and data:**
```bash
KEEP_STORAGE=1 ./cleanup-tailpipe.sh
```

**Force cleanup without confirmations:**
```bash
FORCE=1 ./cleanup-tailpipe.sh
```

**Combined options:**
```bash
KEEP_SP=1 KEEP_STORAGE=1 FORCE=1 ./cleanup-tailpipe.sh
```

### What Gets Deleted

- ❌ All Cost Management exports (billing and subscription scope)
- ❌ Azure Policy definitions and assignments
- ❌ Automation Account and runbooks
- ❌ Storage account and all cost data (unless `KEEP_STORAGE=1`)
- ❌ All RBAC role assignments
- ❌ Service principal (unless `KEEP_SP=1`)

### Cleanup Validation

```bash
# Check for remaining resources
az group list --query "[?starts_with(name, 'tailpipe')].{Name:name, State:properties.provisioningState}" -o table

# Check for remaining exports
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub-id}/providers/Microsoft.CostManagement/exports?api-version=2023-08-01" \
  --query "value[?starts_with(name, 'Tailpipe')].name"
```

## Maintenance

### Trigger Policy Remediation Manually

If new subscriptions aren't getting exports:

```bash
az policy remediation create \
  --name manual-remediation-$(date +%s) \
  --policy-assignment deploy-cost-export-a \
  --management-group {mg-id} \
  --resource-discovery-mode ReEvaluateCompliance
```

### Run Provider Registration Manually

```bash
az automation runbook start \
  --automation-account-name tailpipeAutomation \
  --resource-group tailpipe-automation \
  --name RegisterResourceProviders
```

### Update Policy Definition

```bash
cd Automation/
# Edit policy-auto-export.json

# Update the policy
az policy definition update \
  --name deploy-cost-export \
  --management-group {mg-id} \
  --rules policy-auto-export.json

# Trigger new remediation
az policy remediation create \
  --name update-remediation-$(date +%s) \
  --policy-assignment deploy-cost-export-a \
  --management-group {mg-id} \
  --resource-discovery-mode ReEvaluateCompliance
```

### Monitor Export Health

```bash
# Check export run history
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub-id}/providers/Microsoft.CostManagement/exports/{export-name}/runHistory?api-version=2023-08-01" \
  --query "value[].{Status:properties.status, ExecutionTime:properties.runSettings.startDate}"
```

## Architecture

### Resource Topology

```
Azure Tenant
├── Service Principal (Tailpipe)
│   ├── Storage Blob Data Reader (on storage account)
│   └── Monitoring Reader (at MG or per-sub)
│
├── Management Group (optional)
│   └── Azure Policy Assignment
│       └── Managed Identity
│           ├── Reader (on storage subscription)
│           └── Storage Blob Data Contributor (on storage account)
│
├── Subscription (host)
│   ├── Resource Group: tailpipe-dataexport
│   │   └── Storage Account: tailpipedataexport{suffix}
│   │       └── Container: dataexport
│   │           ├── tailpipe/billing/{profile}/ (MCA/EA)
│   │           └── tailpipe/subscriptions/{sub-id}/ (CSP)
│   │
│   └── Resource Group: tailpipe-automation (CSP only)
│       └── Automation Account: tailpipeAutomation
│           ├── Runbook: RegisterResourceProviders
│           └── Schedule: Daily at 00:00 UTC
│
└── Each Subscription
    └── Cost Management Export
        ├── Type: Usage (ActualCost)
        ├── Schedule: Daily, MonthToDate
        └── Destination: Central storage account
```

### Data Flow

1. **Daily at ~00:00 UTC**: Azure Cost Management generates export files
2. **Export delivery**: CSV files written to storage account (compressed)
3. **Tailpipe ingestion**: Service principal reads blob data via Monitoring Reader + Storage Blob Data Reader
4. **New subscription handling** (CSP only):
   - Policy evaluates every 24h or on remediation trigger
   - Automation runbook registers providers daily
   - Export auto-created within 24-48h

## Advanced Usage

### Multi-Tenant Deployment

For organizations with multiple Azure tenants:

```bash
# Deploy to each tenant
for TENANT in tenant1-id tenant2-id tenant3-id; do
  az login --tenant $TENANT
  TENANT_ID=$TENANT LOCATION=uksouth ./setup-tailpipe.sh
done
```

### Custom Storage Location

Use a specific subscription for storage:

```bash
STORAGE_SUBID=your-sub-id LOCATION=uksouth ./setup-tailpipe.sh
```

### Partial Deployment

Deploy only core infrastructure without automation:

```bash
SKIP_AUTOMATION=1 SKIP_POLICY=1 ./setup-tailpipe.sh
```

### CI/CD Integration

```yaml
# Azure DevOps / GitHub Actions example
- name: Setup Tailpipe
  env:
    LOCATION: uksouth
    ENTERPRISE_APP_ID: ${{ secrets.TAILPIPE_APP_ID }}
    FORCE: 1
  run: |
    az login --service-principal -u $SP_ID -p $SP_SECRET --tenant $TENANT_ID
    ./setup-tailpipe.sh > tailpipe-config.json

- name: Upload Configuration
  uses: actions/upload-artifact@v3
  with:
    name: tailpipe-config
    path: tailpipe-config.json
```

## Security Considerations

### Least Privilege

The setup follows least-privilege principles:

- **Service Principal**: Read-only access to blob storage and monitoring data
- **Policy Managed Identity**: Contributor only on subscriptions where exports are created
- **Automation Managed Identity**: Contributor at root for provider registration only

### Secrets Management

No secrets are generated or stored by this toolkit:

- Service principal authentication is managed by Tailpipe
- Managed identities use Azure AD authentication
- No keys or passwords are created

### Audit Trail

All operations are logged in Azure Activity Log:

```bash
# View setup activities
az monitor activity-log list \
  --start-time 2025-01-01 \
  --query "[?contains(caller, 'setup-tailpipe')].{Time:eventTimestamp, Operation:operationName.localizedValue, Status:status.localizedValue}"
```

## Support

### Script Version

Check version:
```bash
head -20 setup-tailpipe.sh | grep VERSION
```

Current version: **1.0.0**

### Logs

All Azure CLI operations are logged to Azure Activity Log. Enable script debugging:

```bash
DEBUG=1 ./setup-tailpipe.sh 2>&1 | tee setup-tailpipe.log
```

### Resources

- [Azure Cost Management Exports Documentation](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-export-acm-data)
- [Azure Policy DeployIfNotExists](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects#deployifnotexists)
- [Azure Automation Runbooks](https://learn.microsoft.com/en-us/azure/automation/automation-runbook-types)

## License

Copyright © 2025 Tivarri Limited. All rights reserved.
