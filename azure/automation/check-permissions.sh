#!/bin/bash
#
# Check which subscriptions the current user has Owner or User Access Administrator on
#

echo "Checking permissions across all subscriptions..."
echo ""

az account list --query "[].{id:id, name:name}" -o json > /tmp/subs.json

jq -r '.[] | "\(.id)|\(.name)"' /tmp/subs.json | while IFS='|' read -r sub_id sub_name; do
  roles=$(az role assignment list \
    --subscription "$sub_id" \
    --assignee galleryadmin@visitgunnersbury.org \
    --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator'].roleDefinitionName" \
    -o tsv 2>/dev/null)

  if [ ! -z "$roles" ]; then
    echo "✅ $sub_name ($sub_id): $roles"
  else
    echo "❌ $sub_name ($sub_id): No Owner/UAA permissions"
  fi
done

rm -f /tmp/subs.json
