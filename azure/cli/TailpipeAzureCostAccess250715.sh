#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# === INPUT USER VARIABLES ===
echo "Enter Resource Group:"
read -r RESOURCE_GROUP
echo "Enter Storage Account Name:"
read -r STORAGE_ACCOUNT_NAME
echo "Enter Storage Containter Name:"
read -r CONTAINER_NAME
echo "Tailpipe App Name"
read -r TAILPIPE_APP_NAME

# # === USER INPUT ===
# RESOURCE_GROUP="my-resource-group"
# STORAGE_ACCOUNT_NAME="mystorageaccount"
# CONTAINER_NAME="cost-exports"
# TAILPIPE_APP_NAME="tailpipe-access-sp"

# === Derived values ===
SCOPE="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME/blobServices/default/containers/$CONTAINER_NAME"

echo "🔍 Checking if the service principal '$TAILPIPE_APP_NAME' already exists..."
SP_APP_ID=$(az ad sp list --display-name "$TAILPIPE_APP_NAME" --query "[0].appId" -o tsv)

if [ -z "$SP_APP_ID" ]; then
  echo "🆕 Creating a new service principal for Tailpipe..."
  SP_OUTPUT=$(az ad sp create-for-rbac --name "$TAILPIPE_APP_NAME" --role "Storage Blob Data Reader" --scopes "$SCOPE" --sdk-auth)
else
  echo "✅ Service principal already exists. Assigning role..."
  SP_OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query "id" -o tsv)
  az role assignment create --assignee "$SP_OBJECT_ID" --role "Storage Blob Data Reader" --scope "$SCOPE"
  SP_OUTPUT=$(az ad sp credential reset --name "$SP_APP_ID" --sdk-auth)
fi

echo "🔐 Tailpipe can use the following credentials to authenticate:"
echo "$SP_OUTPUT" | jq .

echo -e "\n📌 NOTE: These credentials should be provided to Tailpipe securely and stored in a secure location."