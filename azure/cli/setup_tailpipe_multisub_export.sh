#!/bin/bash

# Tailpipe Multi-Subscription Cost Export Setup

# CONFIGURATION
LOCATION="uksouth"
TEMPLATE_FILE="tailpipeDataExport.sub.json"
RESOURCE_GROUP="tailpipe-dataexport"
ENTERPRISE_APP_ID="071b0391-48e8-483c-b652-a8a6cd43a018"
EXPORT_NAME="TailpipeExport"
CONTAINER_NAME="dataexport"

TODAY_DATE=$(date -u +"%Y-%m-%dT00:00:00Z")
END_DATE="2099-12-31T00:00:00Z"

# Get central subscription details
CENTRAL_SUB=$(az account show --query id -o tsv)
CENTRAL_SUB_SUFFIX=${CENTRAL_SUB: -6}
STORAGE_ACCOUNT_NAME="tailpipedataexport$CENTRAL_SUB_SUFFIX"
STORAGE_ACCOUNT_ID="/subscriptions/$CENTRAL_SUB/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

echo "🔧 Using central subscription: $CENTRAL_SUB"
echo "📦 Storage account will be: $STORAGE_ACCOUNT_NAME"

# Step 1: Generate ARM template
echo "📝 Generating ARM template: $TEMPLATE_FILE"
cat <<EOF > "$TEMPLATE_FILE"
# {
#   "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
#   "contentVersion": "1.0.0.0",
#   "parameters": {
#     "location": {
#       "type": "string"
#     }
#   },
#   "variables": {
#     "resourceGroupName": "$RESOURCE_GROUP"
#   },
#   "resources": [
#     {
#       "type": "Microsoft.Resources/resourceGroups",
#       "apiVersion": "2021-04-01",
#       "name": "[variables('resourceGroupName')]",
#       "location": "[parameters('location')]"
#     },
#     {
#       "type": "Microsoft.Storage/storageAccounts",
#       "apiVersion": "2023-01-01",
#       "name": "$STORAGE_ACCOUNT_NAME",
#       "location": "[parameters('location')]",
#       "sku": {
#         "name": "Standard_LRS"
#       },
#       "kind": "StorageV2",
#       "properties": {
#         "accessTier": "Hot"
#       }
#     },
#     {
#       "type": "Microsoft.Storage/storageAccounts/blobServices/containers",
#       "apiVersion": "2023-01-01",
#       "name": "[format('{0}/default/{1}', '$STORAGE_ACCOUNT_NAME', '$CONTAINER_NAME')]",
#       "dependsOn": [
#         "[resourceId('Microsoft.Storage/storageAccounts', '$STORAGE_ACCOUNT_NAME')]"
#       ],
#       "properties": {}
#     }
#   ]
# }
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "type": "string",
      "metadata": {
        "description": "Azure region for the deployment"
      }
    }
  },
  "variables": {
    "resourceGroupName": "tailpipe-dataexport"
  },
  "resources": [
    {
      "type": "Microsoft.Resources/resourceGroups",
      "apiVersion": "2021-04-01",
      "name": "[variables('resourceGroupName')]",
      "location": "[parameters('location')]"
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": "nestedRgDeployment",
      "resourceGroup": "[variables('resourceGroupName')]",
      "dependsOn": [
        "[resourceId('Microsoft.Resources/resourceGroups', variables('resourceGroupName'))]"
      ],
      "properties": {
        "mode": "Incremental",
        "expressionEvaluationOptions": {
          "scope": "inner"
        },
        "parameters": {
          "location": {
            "value": "[parameters('location')]"
          }
        },
        "template": {
          "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
          "contentVersion": "1.0.0.0",
          "parameters": {
            "location": {
              "type": "string"
            }
          },
          "variables": {
            "subIdSuffix": "[substring(subscription().subscriptionId, sub(length(subscription().subscriptionId), 6), 6)]",
            "storageAccountName": "[toLower(concat('tailpipedataexport', variables('subIdSuffix')))]"
          },
          "resources": [
            {
              "type": "Microsoft.Storage/storageAccounts",
              "apiVersion": "2023-01-01",
              "name": "[variables('storageAccountName')]",
              "location": "[parameters('location')]",
              "sku": {
                "name": "Standard_LRS"
              },
              "kind": "StorageV2",
              "properties": {
                "accessTier": "Hot"
              }
            },
            {
              "type": "Microsoft.Storage/storageAccounts/blobServices/containers",
              "apiVersion": "2023-01-01",
              "name": "[format('{0}/default/dataexport', variables('storageAccountName'))]",
              "dependsOn": [
                "[resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))]"
              ],
              "properties": {}
            }
          ],
          "outputs": {
            "storageAccountName": {
              "type": "string",
              "value": "[variables('storageAccountName')]"
            }
          }
        }
      }
    }
  ],
  "outputs": {
    "resourceGroupName": {
      "type": "string",
      "value": "[variables('resourceGroupName')]"
    }
  }
}
EOF

# Step 2: Deploy template to central subscription
echo "🚀 Deploying central storage resources..."
az deployment sub create \
  --location "$LOCATION" \
  --template-file "$TEMPLATE_FILE" \
  --parameters location="$LOCATION"

echo "🔐 Assigning role to enterprise app in central subscription..."
az account set --subscription "$CENTRAL_SUB"
az role assignment create \
  --assignee "$ENTERPRISE_APP_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ACCOUNT_ID" \
  --only-show-errors

# Step 3: Loop through subscriptions
echo "🔄 Enumerating all subscriptions..."
az account list --query "[?state=='Enabled'].id" -o tsv | while read SUB_ID; do
  if [[ "$SUB_ID" == "$CENTRAL_SUB" ]]; then
    echo "↩️  Skipping central subscription ($CENTRAL_SUB)"
    continue
  fi
  echo "➡️  Processing subscription: $SUB_ID"
  az account set --subscription "$SUB_ID" 2>/dev/null || {
    echo "⚠️ Skipping inaccessible subscription: $SUB_ID"
    continue
  }

  echo "📤 Creating cost export for subscription: $SUB_ID"
  az costmanagement export create \
    --name "$EXPORT_NAME" \
    --type Usage \
    --timeframe MonthToDate \
    --storage-container "$CONTAINER_NAME" \
    --storage-directory "sub-$SUB_ID" \
    --storage-account-id "$STORAGE_ACCOUNT_ID" \
    --recurrence Daily \
    --recurrence-period from=$TODAY_DATE to=$END_DATE \
    --time-period from=$TODAY_DATE to=$TODAY_DATE \
    --scope "/subscriptions/$SUB_ID" \
    --only-show-errors
done

# Step 4: Clean up
echo "🧹 Cleaning up template..."
rm -f "$TEMPLATE_FILE"

echo "✅ All subscriptions configured successfully."