#!/bin/bash
#
# Check status of cost exports and policy compliance
#

echo "=========================================="
echo "Cost Export Status Check"
echo "=========================================="
echo ""

SUBS=(
  "98d3a03a-dfc2-4f26-91e7-3347ec3d1444|Microsoft Azure Sponsorship"
  "baafe319-8571-491d-8a97-cbd4dcb0333e|Microsoft Azure Sponsorship"
  "dc570414-2b89-43e9-a590-b50b215c7e40|Azure subscription 1"
)

for sub_info in "${SUBS[@]}"; do
  SUB_ID=$(echo "$sub_info" | cut -d'|' -f1)
  SUB_NAME=$(echo "$sub_info" | cut -d'|' -f2)

  echo "Subscription: $SUB_NAME ($SUB_ID)"
  echo "-------------------------------------------"

  # Check for exports
  echo "  Cost Exports:"
  EXPORTS=$(az costmanagement export list --scope "/subscriptions/$SUB_ID" --query "[].name" -o tsv 2>/dev/null)
  if [ -z "$EXPORTS" ]; then
    echo "    ❌ No exports found"
  else
    echo "$EXPORTS" | while read export_name; do
      echo "    ✅ $export_name"
    done
  fi

  # Check policy compliance
  echo "  Policy Compliance:"
  COMPLIANCE=$(az policy state list \
    --policy-assignment "deploy-cost-export-a" \
    --subscription "$SUB_ID" \
    --query "[].complianceState" -o tsv 2>/dev/null | head -1)

  if [ -z "$COMPLIANCE" ]; then
    echo "    ⏳ Not yet evaluated"
  elif [ "$COMPLIANCE" == "Compliant" ]; then
    echo "    ✅ Compliant"
  elif [ "$COMPLIANCE" == "NonCompliant" ]; then
    echo "    ⚠️  NonCompliant (export should be created soon)"
  else
    echo "    ❓ $COMPLIANCE"
  fi

  echo ""
done

echo "=========================================="
echo "Remediation Task Status"
echo "=========================================="
echo ""

# Check the one remediation that was successfully created
echo "Checking remediation for baafe319-8571-491d-8a97-cbd4dcb0333e..."
REMEDIATION=$(az policy remediation show \
  --name "remediate-cost-exports-1760007656" \
  --subscription "baafe319-8571-491d-8a97-cbd4dcb0333e" \
  --query "{status:provisioningState, successful:deploymentStatus.successfulDeployments, failed:deploymentStatus.failedDeployments, total:deploymentStatus.totalDeployments}" \
  -o json 2>/dev/null)

if [ ! -z "$REMEDIATION" ]; then
  echo "$REMEDIATION" | jq -r '"  Status: \(.status)\n  Successful: \(.successful)\n  Failed: \(.failed)\n  Total: \(.total)"'
else
  echo "  ⚠️  Remediation task not found or not accessible"
fi

echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
echo ""
echo "If exports are not created after 2-4 hours:"
echo "1. Check if Reader permissions need to be granted on storage subscription"
echo "2. Manually trigger remediation with:"
echo "   az policy remediation create --name manual-fix-\$(date +%s) \\"
echo "     --policy-assignment deploy-cost-export-a \\"
echo "     --subscription <SUB_ID> \\"
echo "     --resource-discovery-mode ReEvaluateCompliance"
echo ""
