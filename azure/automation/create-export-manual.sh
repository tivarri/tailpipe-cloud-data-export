#!/bin/bash
# Manually create cost export for a subscription
# Usage: ./create-export-manual.sh <subscription-id>

set -e

SUBSCRIPTION_ID="${1:-}"
if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "Usage: $0 <subscription-id>"
  exit 1
fi

STORAGE_ACCOUNT_RESOURCE_ID="/subscriptions/9ea664c2-812d-4d18-a036-c58be0934b4f/resourceGroups/tailpipe-dataexport/providers/Microsoft.Storage/storageAccounts/tailpipedataexport934b4f"
STORAGE_CONTAINER="dataexport"
EXPORT_NAME_PREFIX="TailpipeDataExport"
EXPORT_FOLDER_PREFIX="tailpipe"

echo "Creating cost export for subscription: $SUBSCRIPTION_ID"

# Create inline template
cat > /tmp/create-export-temp.json <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "startDate": {
      "type": "string",
      "defaultValue": "[utcNow('yyyy-MM-dd')]"
    }
  },
  "variables": {
    "exportName": "[concat('$EXPORT_NAME_PREFIX', '-', substring('$SUBSCRIPTION_ID', sub(length('$SUBSCRIPTION_ID'), 6), 6))]",
    "rootFolderPath": "[concat('$EXPORT_FOLDER_PREFIX', '/subscriptions/', '$SUBSCRIPTION_ID')]"
  },
  "resources": [
    {
      "type": "Microsoft.CostManagement/exports",
      "apiVersion": "2023-08-01",
      "name": "[variables('exportName')]",
      "properties": {
        "schedule": {
          "status": "Active",
          "recurrence": "Daily",
          "recurrencePeriod": {
            "from": "[concat(parameters('startDate'), 'T00:00:00Z')]",
            "to": "2099-12-31T00:00:00Z"
          }
        },
        "format": "Csv",
        "deliveryInfo": {
          "destination": {
            "resourceId": "$STORAGE_ACCOUNT_RESOURCE_ID",
            "container": "$STORAGE_CONTAINER",
            "rootFolderPath": "[variables('rootFolderPath')]",
            "type": "AzureBlob"
          }
        },
        "definition": {
          "type": "ActualCost",
          "timeframe": "MonthToDate",
          "dataSet": {
            "granularity": "Daily"
          }
        }
      }
    }
  ],
  "outputs": {
    "exportName": {
      "type": "string",
      "value": "[variables('exportName')]"
    }
  }
}
EOF

az deployment sub create \
  --location uksouth \
  --template-file /tmp/create-export-temp.json \
  --subscription "$SUBSCRIPTION_ID" \
  --query '{exportName:properties.outputs.exportName.value, state:properties.provisioningState}' \
  -o table

rm -f /tmp/create-export-temp.json

echo "✅ Export created successfully"
