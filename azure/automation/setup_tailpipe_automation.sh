#!/bin/bash

# This script is cross-platform (Linux, macOS) but must be adapted manually for PowerShell on Windows

# Variables
RG_NAME="tailpipe-automation-rg"
LOCATION="uksouth"
AUTOMATION_ACCOUNT="tailpipeAutomation"
RUNBOOK_NAME="TailpipeExportSetup"
RUNBOOK_FILE="TailpipeExportSetup.ps1"
SCHEDULE_NAME="DailyExportCheck"
STORAGE_ACCOUNT="tailpipedataexport934b4f"
STORAGE_CONTAINER="dataexport"
BLOB_NAME="known_subscriptions.json"

# Cross-platform date for --start-time (+10 minutes UTC)
get_utc_start_time() {
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ'
  else
    # BSD date (macOS)
    date -u -v+10M '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# Create Resource Group
az group create --name "$RG_NAME" --location "$LOCATION"

# Create Automation Account without identity
az automation account create \
  --name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION"

# Enable system-assigned managed identity
az resource update \
  --resource-group "$RG_NAME" \
  --name "$AUTOMATION_ACCOUNT" \
  --resource-type "Microsoft.Automation/automationAccounts" \
  --set identity.type="SystemAssigned"

# Wait for the automation account resource to be fully available
sleep 10

if ! az automation account show --name "$AUTOMATION_ACCOUNT" --resource-group "$RG_NAME" &>/dev/null; then
  echo "Automation account creation failed or is not ready. Exiting."
  exit 1
fi

#
# Create PowerShell Runbook
az automation runbook create \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$RUNBOOK_NAME" \
  --type "PowerShell" \
  --location "$LOCATION"

#
# Upload PowerShell Runbook script
az automation runbook replace-content \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$RUNBOOK_NAME" \
  --content @"$RUNBOOK_FILE"

#
# Publish PowerShell Runbook
az automation runbook publish \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$RUNBOOK_NAME"

# Create a daily schedule
az automation schedule create \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$SCHEDULE_NAME" \
  --start-time "$(get_utc_start_time)" \
  --frequency "Day" \
  --interval 1

# Link schedule to runbook
# Removed az automation runbook create-schedule-link block as schedule is created above

# Get Automation Account identity
PRINCIPAL_ID=$(az automation account show \
  --name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --query "identity.principalId" -o tsv)

# Assign roles at tenant root scope
if [ -n "$PRINCIPAL_ID" ]; then
  az role assignment create --assignee "$PRINCIPAL_ID" --role "Cost Management Contributor" --scope /
  az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Blob Data Contributor" --scope /

  # Assign Storage Blob Data Contributor at the Storage Account level
  STORAGE_SCOPE=$(az storage account show \
    --name "$STORAGE_ACCOUNT" \
    --query "id" -o tsv)

  if [ -n "$STORAGE_SCOPE" ]; then
    az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role "Storage Blob Data Contributor" \
      --scope "$STORAGE_SCOPE"
  else
    echo "⚠️ Failed to determine Storage Account scope for RBAC assignment."
  fi
else
  echo "⚠️ Failed to retrieve Automation Account identity. RBAC assignment was skipped. Check if the Automation Account was created properly and try again."
fi

# Create placeholder known_subscriptions blob in storage
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$STORAGE_CONTAINER" \
  --name "$BLOB_NAME" \
  --file <(echo '[]') \
  --auth-mode login || echo "⚠️ Failed to upload placeholder blob. You may need 'Storage Blob Data Contributor' role."

echo "✅ Setup script completed (on $(uname))"
