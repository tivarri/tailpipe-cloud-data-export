# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains Azure infrastructure automation for setting up Cost Management exports across multiple subscriptions. The primary goal is to automatically export Azure cost data to centralized storage accounts for the Tailpipe cost analytics platform.

## Architecture

### Three Implementation Approaches

The repository provides three distinct methods to achieve the same goal, each with different trade-offs:

1. **Azure Policy (Recommended)** - `Automation/` directory
   - Uses Azure Policy `deployIfNotExists` to automatically create cost exports
   - Handles new subscriptions automatically
   - Built-in compliance tracking and remediation
   - No custom code maintenance required

2. **Automation Account with PowerShell Runbook** - `Automation/` directory
   - Scheduled PowerShell runbook that runs daily
   - Uses managed identity or service principal authentication
   - Maintains state file (`known_subscriptions.json`) in blob storage
   - Handles permission propagation timing issues explicitly

3. **CLI Scripts (Manual/Ad-hoc)** - `CLI/` directory
   - Bash scripts for one-time or manual deployment
   - Useful for initial setup or troubleshooting
   - Can target single or multiple subscriptions

### Core Components

**Storage Architecture:**
- Central storage account naming: `tailpipedataexport{6-char-suffix}` (suffix from subscription ID)
- Container: `dataexport`
- Path structure: `{prefix}/subscriptions/{subscription-id}/`
- Default prefix: `tailpipe`

**Cost Export Configuration:**
- Export name pattern: `{prefix}-{last-6-chars-of-sub-id}`
- Type: ActualCost / Usage
- Timeframe: MonthToDate
- Granularity: Daily
- Format: CSV
- Recurrence: Daily (from start date to 2099-12-31)

**Enterprise App ID (Tailpipe):**
- UAT: `071b0391-48e8-483c-b652-a8a6cd43a018`
- Prod: `f5f07900-0484-4506-a34d-ec781138342a`

## Common Commands

### Azure Policy Approach (Primary Method)

**Deploy policy at Management Group level:**
```bash
cd Automation/
# Edit deploy-policy.sh to configure:
# - MANAGEMENT_GROUP_ID
# - STORAGE_ACCOUNT_RESOURCE_ID
# - STORAGE_CONTAINER, EXPORT_NAME_PREFIX, EXPORT_FOLDER_PREFIX
chmod +x deploy-policy.sh
./deploy-policy.sh
```

**Check compliance status:**
```bash
az policy state list \
  --policy-assignment deploy-cost-export-assignment \
  --management-group <MG_ID> \
  --query "[].{subscription:resourceId, state:complianceState}" -o table
```

**Trigger manual remediation:**
```bash
az policy remediation create \
  --name manual-remediation-$(date +%s) \
  --policy-assignment deploy-cost-export-assignment \
  --management-group <MG_ID> \
  --resource-discovery-mode ReEvaluateCompliance
```

**Clean up policy deployment:**
```bash
az policy assignment delete --name deploy-cost-export-assignment --management-group <MG_ID>
az policy definition delete --name deploy-cost-export --management-group <MG_ID>
```

### Automation Account Approach (Legacy Method)

**Deploy automation account with runbook:**
```bash
cd Automation/
# Review and configure variables in setup_tailpipe_automation.sh
chmod +x setup_tailpipe_automation.sh
./setup_tailpipe_automation.sh
```

**Teardown automation resources:**
```bash
cd Automation/
chmod +x teardown_tailpipe_automation.sh
./teardown_tailpipe_automation.sh
```

### CLI Scripts (Manual Deployment)

**Deploy for single subscription (creates storage + export):**
```bash
cd CLI/
# Set LOCATION environment variable or will be prompted
export LOCATION=uksouth
chmod +x deploy_tailpipe_dataexport.sh
./deploy_tailpipe_dataexport.sh
```

**Deploy across all subscriptions (multi-sub setup):**
```bash
cd CLI/
chmod +x setup_tailpipe_multisub_export.sh
./setup_tailpipe_multisub_export.sh
```

**Destroy resources created by CLI deployment:**
```bash
cd CLI/
chmod +x destroy_tailpipe_setup.sh
./destroy_tailpipe_setup.sh
# See destroy_tailpipe_setup_readme.txt for details
```

## Directory Structure

```
.
├── Automation/          # Azure Policy and Automation Account resources
│   ├── policy-auto-export.json           # Policy definition
│   ├── deploy-policy.sh                  # Policy deployment script
│   ├── TailpipeExportSetup.ps1          # PowerShell runbook
│   ├── setup_tailpipe_automation.sh     # Automation account setup
│   ├── teardown_tailpipe_automation.sh  # Automation cleanup
│   └── README-policy.md                  # Detailed policy documentation
├── CLI/                 # Bash scripts for manual deployment
│   ├── deploy_tailpipe_dataexport.sh    # Single-sub deployment
│   ├── setup_tailpipe_multisub_export.sh # Multi-sub deployment
│   └── destroy_tailpipe_setup.sh         # Cleanup script
└── ARM/                 # ARM template files
    ├── tailpipeArmTemplateStorageExport.json  # Complete template
    └── tailpipeArmTemplateExportOnly.json     # Export-only template
```

## Key Considerations

### RBAC Requirements

**For Policy Approach:**
- Policy Assignment requires: `Contributor` at scope (auto-assigned)
- Policy Managed Identity needs:
  - `Reader` on storage subscription
  - `Storage Blob Data Contributor` on storage account

**For Automation Runbook:**
- Managed Identity requires:
  - `Cost Management Contributor` at tenant root (/)
  - `Storage Blob Data Contributor` at tenant root or storage account level

**For CLI Scripts:**
- User/SPN executing must have:
  - Subscription `Contributor` or equivalent
  - `Storage Blob Data Contributor` on target storage account

### Resource Provider Registration

Required providers (scripts auto-register):
- Microsoft.Resources
- Microsoft.Storage
- Microsoft.CostManagement
- Microsoft.CostManagementExports
- Microsoft.Insights

### Cross-Subscription Considerations

When exports write to storage accounts in different subscriptions:
- Ensure managed identity has access to BOTH subscriptions
- Storage subscription requires `Reader` access for validation
- Storage account requires `Storage Blob Data Contributor` for data writes

### Timing and Propagation

**Policy Approach:**
- Policy evaluation runs every 24 hours automatically
- Manual remediation tasks trigger immediate evaluation
- Permission propagation handled by Azure Policy framework

**Runbook Approach:**
- Includes explicit retry logic for permission propagation delays
- State file tracks known subscriptions to detect new ones
- Daily schedule with configurable start time

## Troubleshooting

### Policy not creating exports

1. Check compliance state: `az policy state list --policy-assignment <name>`
2. Verify managed identity role assignments
3. Create manual remediation task to force evaluation
4. Check Activity Log for policy deployment errors

### Automation runbook failures

1. Check runbook job output in Azure Portal
2. Verify managed identity has required roles at tenant root
3. Ensure `known_subscriptions.json` blob exists in storage
4. Check for Azure CLI extension installation (`costmanagement`)

### CLI script errors

1. Verify Azure CLI version: `az version`
2. Check resource provider registration: `az provider list --query "[?namespace=='Microsoft.CostManagement']"`
3. Validate RBAC permissions on target subscription
4. Review error on specific line (scripts use error trapping)

### Permission issues

For "The content for this response was already consumed" errors:
```bash
brew update && brew upgrade azure-cli
# Then re-run with DEBUG=1 for detailed output
DEBUG=1 ./deploy_tailpipe_dataexport.sh
```

## Development Notes

### Modifying ARM Templates

ARM templates use inline generation in bash scripts (heredoc). To modify:
1. Edit the script's template section directly
2. Or update standalone templates in `ARM/` directory
3. Validate with: `az deployment sub validate --location uksouth --template-file <file>`

### Updating Policy Definition

1. Edit `Automation/policy-auto-export.json`
2. Update policy definition: `az policy definition update --name deploy-cost-export --rules policy-auto-export.json`
3. Trigger new remediation to apply changes

### Testing Changes

For safe testing:
1. Use `--subscription` scope instead of `--management-group`
2. Set policy effect to `AuditIfNotExists` initially
3. Create test subscription to validate before production rollout
4. Review compliance reports before switching to `DeployIfNotExists`
