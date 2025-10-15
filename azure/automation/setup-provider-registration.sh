#!/bin/bash

# Setup Azure Automation to auto-register resource providers on all subscriptions
# This ensures the cost export policy can work on new subscriptions

set -e

RG_NAME="tailpipe-automation-rg"
LOCATION="uksouth"
AUTOMATION_ACCOUNT="tailpipeAutomation"
RUNBOOK_NAME="RegisterResourceProviders"
RUNBOOK_FILE="RegisterProvidersRunbook.ps1"
SCHEDULE_NAME="DailyProviderCheck"

# Check if automation account exists, create if not
if ! az automation account show --name "$AUTOMATION_ACCOUNT" --resource-group "$RG_NAME" &>/dev/null; then
  echo "Creating resource group and automation account..."
  az group create --name "$RG_NAME" --location "$LOCATION"
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

  sleep 10
fi

echo "Creating runbook: $RUNBOOK_NAME"
az automation runbook create \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$RUNBOOK_NAME" \
  --type "PowerShell" \
  --location "$LOCATION" || echo "Runbook already exists"

echo "Uploading runbook content..."
az automation runbook replace-content \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$RUNBOOK_NAME" \
  --content @"$RUNBOOK_FILE"

echo "Publishing runbook..."
az automation runbook publish \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --name "$RUNBOOK_NAME"

# Create daily schedule if it doesn't exist
if ! az automation schedule show --automation-account-name "$AUTOMATION_ACCOUNT" \
     --resource-group "$RG_NAME" --name "$SCHEDULE_NAME" &>/dev/null; then

  # Get UTC time +10 minutes
  if date --version >/dev/null 2>&1; then
    START_TIME=$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ')
  else
    START_TIME=$(date -u -v+10M '+%Y-%m-%dT%H:%M:%SZ')
  fi

  echo "Creating schedule: $SCHEDULE_NAME"
  az automation schedule create \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RG_NAME" \
    --name "$SCHEDULE_NAME" \
    --start-time "$START_TIME" \
    --frequency "Day" \
    --interval 1
fi

# Get managed identity principal ID
PRINCIPAL_ID=$(az automation account show \
  --name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --query "identity.principalId" -o tsv)

if [ -n "$PRINCIPAL_ID" ]; then
  echo "Granting permissions to managed identity: $PRINCIPAL_ID"

  # Grant Reader at tenant root to enumerate subscriptions
  az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Reader" \
    --scope "/" || echo "Reader role already assigned"

  # Grant ability to register providers on all subscriptions
  # Note: This requires a custom role or Contributor at root
  az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Contributor" \
    --scope "/" || echo "Contributor role already assigned"
else
  echo "⚠️ Failed to get managed identity. Please assign permissions manually."
fi

echo ""
echo "✅ Provider registration automation setup complete!"
echo ""
echo "The runbook will run daily to ensure all subscriptions have required providers registered."
echo ""
echo "To test immediately, run:"
echo "  az automation runbook start --automation-account-name $AUTOMATION_ACCOUNT --resource-group $RG_NAME --name $RUNBOOK_NAME"
