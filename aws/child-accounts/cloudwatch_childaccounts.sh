#!/usr/bin/env bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# First figure out the organisational structure, which is the parent account and which are the children accounts

# Find the AWS Organisational Root ID
root=$(aws organizations list-roots --query "Roots[].Id" --output text)

echo "Root ID $root"

# List all the child accounts, including the management accoutn
children=$(aws organizations list-children --child-type ACCOUNT --parent-id $root --query "Children[].Id" --output text)
children=${children%% }  # Trim trailing space

echo "Child Accounts including management account $children"

# Find the Master Account ID
master=$(aws organizations describe-organization | jq -r '.Organization.MasterAccountId')

echo "Master Account ID is $master"

#Remove the Master Account from the list of child accounts
children=$(echo "$children" | awk -v id="$master" '{for(i=1;i<=NF;i++) if($i!=id) printf "%s ", $i}')
children=${children%% }  # Trim trailing space

echo "Child Accounts with management account removed $children"

#Input user variables
echo "Enter Region (in the format eu-north-1):"
read -r region
# echo "Enter AWS Account Number:"
# read -r aws_account_number
echo "Enter Taipipe External ID (provided by Tailpipe):"
read -r external_id

# Now configure the master account

echo "Starting Master Account JSON file generation..."

#Create tailpipe-dataexport-s3-policy.json
echo "Generating Master Account tailpipe-dataexport-s3-policy.json"
cat <<EOT > tailpipe-dataexport-s3-policy.json
{
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
					"billingreports.amazonaws.com",
					"bcm-data-exports.amazonaws.com"
				]
            },
            "Action": [
                "s3:PutObject",
                "s3:GetBucketPolicy"
            ],
            "Resource": [
				"arn:aws:s3:::tailpipe-dataexport-${master}",
				"arn:aws:s3:::tailpipe-dataexport-${master}/*"
			],
            "Condition": {
                "StringLike": {
                    "aws:SourceAccount": "${master}",
                    "aws:SourceArn": [
						"arn:aws:cur:us-east-1:${master}:definition/*",
						"arn:aws:bcm-data-exports:us-east-1:${master}:export/*"
					]
                }
            }
        }
    ]
}
EOT
echo "✅ Master Account tailpipe-dataexport-s3-policy.json generated." \

echo "Generating Master Account tailpipe-dataexport-report-definition.json"
cat <<EOT > tailpipe-dataexport-report-definition.json
{
  "DataQuery": {
    "QueryStatement":"SELECT bill_bill_type, bill_billing_entity, bill_billing_period_end_date, bill_billing_period_start_date, bill_invoice_id, bill_invoicing_entity, bill_payer_account_id, bill_payer_account_name, cost_category, discount, discount_bundled_discount, discount_total_discount, identity_line_item_id, identity_time_interval, line_item_availability_zone, line_item_blended_cost, line_item_blended_rate, line_item_currency_code, line_item_legal_entity, line_item_line_item_description, line_item_line_item_type, line_item_net_unblended_cost, line_item_net_unblended_rate, line_item_normalization_factor, line_item_normalized_usage_amount, line_item_operation, line_item_product_code, line_item_resource_id, line_item_tax_type, line_item_unblended_cost, line_item_unblended_rate, line_item_usage_account_id, line_item_usage_account_name, line_item_usage_amount, line_item_usage_end_date, line_item_usage_start_date, line_item_usage_type, pricing_currency, pricing_lease_contract_length, pricing_offering_class, pricing_public_on_demand_cost, pricing_public_on_demand_rate, pricing_purchase_option, pricing_rate_code, pricing_rate_id, pricing_term, pricing_unit, product, product_comment, product_fee_code, product_fee_description, product_from_location, product_from_location_type, product_from_region_code, product_instance_family, product_instance_type, product_instancesku, product_location, product_location_type, product_operation, product_pricing_unit, product_product_family, product_region_code, product_servicecode, product_sku, product_to_location, product_to_location_type, product_to_region_code, product_usagetype, reservation_amortized_upfront_cost_for_usage, reservation_amortized_upfront_fee_for_billing_period, reservation_availability_zone, reservation_effective_cost, reservation_end_time, reservation_modification_status, reservation_net_amortized_upfront_cost_for_usage, reservation_net_amortized_upfront_fee_for_billing_period, reservation_net_effective_cost, reservation_net_recurring_fee_for_usage, reservation_net_unused_amortized_upfront_fee_for_billing_period, reservation_net_unused_recurring_fee, reservation_net_upfront_value, reservation_normalized_units_per_reservation, reservation_number_of_reservations, reservation_recurring_fee_for_usage, reservation_reservation_a_r_n, reservation_start_time, reservation_subscription_id, reservation_total_reserved_normalized_units, reservation_total_reserved_units, reservation_units_per_reservation, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_normalized_unit_quantity, reservation_unused_quantity, reservation_unused_recurring_fee, reservation_upfront_value, resource_tags, savings_plan_amortized_upfront_commitment_for_billing_period, savings_plan_end_time, savings_plan_instance_type_family, savings_plan_net_amortized_upfront_commitment_for_billing_period, savings_plan_net_recurring_commitment_for_billing_period, savings_plan_net_savings_plan_effective_cost, savings_plan_offering_type, savings_plan_payment_option, savings_plan_purchase_term, savings_plan_recurring_commitment_for_billing_period, savings_plan_region, savings_plan_savings_plan_a_r_n, savings_plan_savings_plan_effective_cost, savings_plan_savings_plan_rate, savings_plan_start_time, savings_plan_total_commitment_to_date, savings_plan_used_commitment FROM COST_AND_USAGE_REPORT","TableConfigurations":{"COST_AND_USAGE_REPORT":{"INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY":"FALSE","INCLUDE_RESOURCES":"TRUE","INCLUDE_SPLIT_COST_ALLOCATION_DATA":"FALSE","TIME_GRANULARITY":"HOURLY"}}
  },
  "Description": "Tailpipe DataExport",
  "DestinationConfigurations": {
    "S3Destination": {
      "S3Bucket": "tailpipe-dataexport-${master}",
      "S3OutputConfigurations": {
        "Compression": "GZIP",
        "Format": "TEXT_OR_CSV",
        "OutputType": "CUSTOM",
        "Overwrite": "OVERWRITE_REPORT"
      },
      "S3Prefix": "dataexport",
      "S3Region": "${region}"
    }
  },
  "Name": "tailpipe-dataexport",
  "RefreshCadence": {
    "Frequency": "SYNCHRONOUS"
  }
}
EOT
echo "✅ Master Account tailpipe-dataexport-report-definition.json generated" \

echo "Generating Master Account tailpipe-connector-role-policy-document.json"
cat <<EOT > tailpipe-connector-role-policy-document.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::336268260260:role/TailpipeConnector-Prod"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "${external_id}"
                }
            }
        }
    ]
}
EOT
echo "✅ Master Account tailpipe-connector-role-policy-document.json generated" \

echo "Generating Master Account tailpipe_dataexport_and_cloudwatch_policy.json"
cat <<EOT > tailpipe_dataexport_and_cloudwatch_policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Statement1",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject"
            ],
            "Resource": [
                "arn:aws:s3:::tailpipe-dataexport-${master}",
                "arn:aws:s3:::tailpipe-dataexport-${master}/*"
            ]
        },
        {
            "Sid": "Statement2",
            "Effect": "Allow",
            "Action": [
                "cloudwatch:GetMetricStatistics"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
EOT
echo "✅ Master Account tailpipe_dataexport_and_cloudwatch_policy.json generated" \
	
echo "Master Account JSON file generation completed"

echo "Starting AWS Master Account configuration..."

echo "Creating Master Account S3 bucket..."
aws s3 mb s3://tailpipe-dataexport-${master} --region ${region} || {
	echo "❌ Failed to create S3 bucket. Please check your AWS credentials and permissions.";
	exit 1;
}
echo "✅ Master Account S3 bucket created successfully"

echo "Adding policy to Master Account S3 bucket tailpipe-dataexport..."
aws s3api put-bucket-policy --bucket tailpipe-dataexport-${master} --policy file://tailpipe-dataexport-s3-policy.json || {
	echo "❌ Failed to apply S3 bucket policy. Please check your AWS credentials and permissions. Rolling back changes...";
	exit 1;
	}
echo "✅ Master Account S3 bucket policy added successfully"

echo "Creating the Master Account billing data export..."
aws bcm-data-exports create-export --export file://tailpipe-dataexport-report-definition.json || {
	echo "❌ Failed to create billing data export. Please check your AWS credentials and permissions. Rolling back changes...";
	exit 1;
}
echo "✅ Master Account Billing data export created successfully"

echo "Creating a new Master Account role: tailpipe-connector-role for Tailpipe's third party data access..."
aws iam create-role --role-name tailpipe-connector-role --assume-role-policy-document file://tailpipe-connector-role-policy-document.json > /dev/null ||{
	echo "❌ Failed to create the tailpipe-connector-role. Please check your AWS credentials and permissions. Rolling back changes...";
	exit 1;
}
echo "✅ New Master Account role created successfully"

echo "Applying a permissions policy to the Master Account tailpipe-connector-role to allow Tailpipe to access the billling data export..."
aws iam put-role-policy --role-name tailpipe-connector-role --policy-name tailpipe_dataexport_and_cloudwatch_policy --policy-document file://tailpipe_dataexport_and_cloudwatch_policy.json || {
	echo "❌ Failed to apply permissions policy to the tailpipe-connector-role. Please check your AWS credentials and permissions.";
	exit 1;
}
echo "Master Account Permissions policy applied successfully"

echo "✅ AWS Master Account Configuration Finished Successfully."

# Check if there are no child accounts. If there aren't, exit

if [ -z "$children" ]; then
  echo "No child accounts have bee found. Exiting setup."
  exit 1
fi

for child in $children; do
	echo "Processing child account: $child"

	echo "Starting Child Account $child JSON file generation..."

	echo "Generating Child Account $child tailpipe-child-connector-policy-document.json"
	cat <<EOT > tailpipe-child-connector-policy-document.json
	{
		"Version": "2012-10-17", 
		"Statement": [
			{
				"Effect": "Allow",
				"Principal": {
					"AWS": "arn:aws:iam::336268260260:role/TailpipeConnector-Prod"
				},
				"Action": "sts:AssumeRole",
				"Condition": {
					"StringEquals": {
						"sts:ExternalId": "${external_id}"
					}
				}
			}
		]
	}
	EOT
	echo "✅ Child Account $child tailpipe-child-connector-policy-document.json generated" \

	echo "Generating Child Account $child tailpipe_child_connector_policy.json"
	cat <<EOT > tailpipe_child_connector_policy.json
	{
		"Version": "2012-10-17",
		"Statement": [
			{
				"Sid": "Statement2",
				"Effect": "Allow",
				"Action": [
					"cloudwatch:GetMetricStatistics"
				],
				"Resource": [
					"*"
				]
			}
		]
	}
	EOT
	echo "✅ Child Account $child tailpipe_child_connector_policy.json generated" \
		
	echo "Child Account $child JSON file generation completed"

	echo "Starting AWS Child Account $child configuration..."

	echo "Creating a new Child Account $child role: tailpipe-child-connector-role for Tailpipe's third party data access..."
	aws iam create-role --role-name tailpipe-child-connector-role --assume-role-policy-document file://tailpipe-child-connector-policy-document.json > /dev/null ||{
		echo "❌ Failed to create the tailpipe-child-connector-role. Please check your AWS credentials and permissions. Rolling back changes...";
		exit 1;
	}
	echo "✅ New Child Account $child role created successfully"

	echo "Applying a permissions policy to the Child Account $child tailpipe-child-connector-role..."
	aws iam put-role-policy --role-name tailpipe-child-connector-role --policy-name tailpipe_child_connector_policy --policy-document file://tailpipe_child_connector_policy.json || {
		echo "❌ Failed to apply permissions policy to the tailpipe-child-connector-role. Please check your AWS credentials and permissions.";
		exit 1;
	}
	echo "Child Account $child Permissions policy applied successfully"

	echo "Removing JSON files"
	rm tailpipe-child-connector-policy-document.json
	rm tailpipe_child_connector_policy.json
	echo "✅ JSON files removed"

	echo "✅ Child Account $child AWS Configuration Finished Successfully."
	
done