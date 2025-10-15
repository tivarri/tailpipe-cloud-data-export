#!/bin/bash

# Variables
RG_NAME="tailpipe-automation-rg"
AUTOMATION_ACCOUNT="tailpipeAutomation"
STORAGE_ACCOUNT="tailpipedataexport934b4f"
STORAGE_CONTAINER="dataexport"
BLOB_NAME="known_subscriptions.json"

echo "Checking Automation Account identity..."
PRINCIPAL_ID=$(az automation account show \
  --name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --query "identity.principalId" -o tsv 2>/dev/null)

if [ -n "$PRINCIPAL_ID" ]; then
  echo "Removing role assignments for principalId: $PRINCIPAL_ID"

  # Remove from tenant root scope
  az role assignment delete --assignee "$PRINCIPAL_ID" --role "Cost Management Contributor" --scope / 2>/dev/null
  az role assignment delete --assignee "$PRINCIPAL_ID" --role "Storage Blob Data Contributor" --scope / 2>/dev/null

  # Remove from storage account scope
  STORAGE_SCOPE=$(az storage account show --name "$STORAGE_ACCOUNT" --query "id" -o tsv 2>/dev/null)
  if [ -n "$STORAGE_SCOPE" ]; then
    az role assignment delete --assignee "$PRINCIPAL_ID" --role "Storage Blob Data Contributor" --scope "$STORAGE_SCOPE" 2>/dev/null
  fi
else
  echo "⚠️ Could not determine Automation Account identity. Skipping RBAC cleanup."
fi

echo "Deleting Automation resource group: $RG_NAME..."
az group delete --name "$RG_NAME" --yes --no-wait

echo "Removing known_subscriptions blob (if present)..."
az storage blob delete \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$STORAGE_CONTAINER" \
  --name "$BLOB_NAME" \
  --auth-mode login 2>/dev/null || echo "⚠️ Failed to delete blob or blob not found."

echo "✅ Teardown script complete."
