#!/usr/bin/env bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

#Input user variables
echo "Enter Region (in the format eu-north-1):"
read -r region
echo "Enter AWS Account Number:"
read -r aws_account_number
echo "Enter Taipipe External ID (provided by Tailpipe):"
read -r external_id

echo "Starting JSON file generation..."

#Create tailpipe-dataexport-s3-policy.json
echo "Generating tailpipe-dataexport-s3-policy.json"
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
				"arn:aws:s3:::tailpipe-dataexport-${aws_account_number}",
				"arn:aws:s3:::tailpipe-dataexport-${aws_account_number}/*"
			],
            "Condition": {
                "StringLike": {
                    "aws:SourceAccount": "${aws_account_number}",
                    "aws:SourceArn": [
						"arn:aws:cur:us-east-1:${aws_account_number}:definition/*",
						"arn:aws:bcm-data-exports:us-east-1:${aws_account_number}:export/*"
					]
                }
            }
        }
    ]
}
EOT
echo "✅ tailpipe-dataexport-s3-policy.json generated." \

echo "Generating tailpipe-dataexport-report-definition.json"
cat <<EOT > tailpipe-dataexport-report-definition.json
{
  "DataQuery": {
    "QueryStatement":"SELECT bill_bill_type, bill_billing_entity, bill_billing_period_end_date, bill_billing_period_start_date, bill_invoice_id, bill_invoicing_entity, bill_payer_account_id, bill_payer_account_name, cost_category, discount, discount_bundled_discount, discount_total_discount, identity_line_item_id, identity_time_interval, line_item_availability_zone, line_item_blended_cost, line_item_blended_rate, line_item_currency_code, line_item_legal_entity, line_item_line_item_description, line_item_line_item_type, line_item_net_unblended_cost, line_item_net_unblended_rate, line_item_normalization_factor, line_item_normalized_usage_amount, line_item_operation, line_item_product_code, line_item_resource_id, line_item_tax_type, line_item_unblended_cost, line_item_unblended_rate, line_item_usage_account_id, line_item_usage_account_name, line_item_usage_amount, line_item_usage_end_date, line_item_usage_start_date, line_item_usage_type, pricing_currency, pricing_lease_contract_length, pricing_offering_class, pricing_public_on_demand_cost, pricing_public_on_demand_rate, pricing_purchase_option, pricing_rate_code, pricing_rate_id, pricing_term, pricing_unit, product, product_comment, product_fee_code, product_fee_description, product_from_location, product_from_location_type, product_from_region_code, product_instance_family, product_instance_type, product_instancesku, product_location, product_location_type, product_operation, product_pricing_unit, product_product_family, product_region_code, product_servicecode, product_sku, product_to_location, product_to_location_type, product_to_region_code, product_usagetype, reservation_amortized_upfront_cost_for_usage, reservation_amortized_upfront_fee_for_billing_period, reservation_availability_zone, reservation_effective_cost, reservation_end_time, reservation_modification_status, reservation_net_amortized_upfront_cost_for_usage, reservation_net_amortized_upfront_fee_for_billing_period, reservation_net_effective_cost, reservation_net_recurring_fee_for_usage, reservation_net_unused_amortized_upfront_fee_for_billing_period, reservation_net_unused_recurring_fee, reservation_net_upfront_value, reservation_normalized_units_per_reservation, reservation_number_of_reservations, reservation_recurring_fee_for_usage, reservation_reservation_a_r_n, reservation_start_time, reservation_subscription_id, reservation_total_reserved_normalized_units, reservation_total_reserved_units, reservation_units_per_reservation, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_normalized_unit_quantity, reservation_unused_quantity, reservation_unused_recurring_fee, reservation_upfront_value, resource_tags, savings_plan_amortized_upfront_commitment_for_billing_period, savings_plan_end_time, savings_plan_instance_type_family, savings_plan_net_amortized_upfront_commitment_for_billing_period, savings_plan_net_recurring_commitment_for_billing_period, savings_plan_net_savings_plan_effective_cost, savings_plan_offering_type, savings_plan_payment_option, savings_plan_purchase_term, savings_plan_recurring_commitment_for_billing_period, savings_plan_region, savings_plan_savings_plan_a_r_n, savings_plan_savings_plan_effective_cost, savings_plan_savings_plan_rate, savings_plan_start_time, savings_plan_total_commitment_to_date, savings_plan_used_commitment FROM COST_AND_USAGE_REPORT","TableConfigurations":{"COST_AND_USAGE_REPORT":{"INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY":"FALSE","INCLUDE_RESOURCES":"TRUE","INCLUDE_SPLIT_COST_ALLOCATION_DATA":"FALSE","TIME_GRANULARITY":"HOURLY"}}
  },
  "Description": "Tailpipe DataExport",
  "DestinationConfigurations": {
    "S3Destination": {
      "S3Bucket": "tailpipe-dataexport-${aws_account_number}",
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
echo "✅ tailpipe-dataexport-report-definition.json generated" \

echo "Generating tailpipe-connector-role-policy-document.json"
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
echo "✅ tailpipe-connector-role-policy-document.json generated" \

echo "Generating tailpipe_dataexport_and_cloudwatch_policy.json"
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
                "arn:aws:s3:::tailpipe-dataexport-${aws_account_number}",
                "arn:aws:s3:::tailpipe-dataexport-${aws_account_number}/*"
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
echo "✅ tailpipe_dataexport_and_cloudwatch_policy.json generated" \
	
echo "JSON file generation completed"

echo "Starting AWS configuration..."

echo "Creating S3 bucket..."
aws s3 mb s3://tailpipe-dataexport-${aws_account_number} --region ${region} || {
	echo "❌ Failed to create S3 bucket. Please check your AWS credentials and permissions.";
	exit 1;
}
echo "✅ S3 bucket created successfully"

echo "Adding policy to S3 bucket tailpipe-dataexport..."
aws s3api put-bucket-policy --bucket tailpipe-dataexport-${aws_account_number} --policy file://tailpipe-dataexport-s3-policy.json || {
	echo "❌ Failed to apply S3 bucket policy. Please check your AWS credentials and permissions. Rolling back changes...";
	exit 1;
	}
echo "✅ S3 bucket policy added successfully"

echo "Creating the billing data export..."
aws bcm-data-exports create-export --export file://tailpipe-dataexport-report-definition.json || {
	echo "❌ Failed to create billing data export. Please check your AWS credentials and permissions. Rolling back changes...";
	exit 1;
}
echo "✅ Billing data export created successfully"

echo "Creating a new role: tailpipe-connector-role for Tailpipe's third party data access..."
aws iam create-role --role-name tailpipe-connector-role --assume-role-policy-document file://tailpipe-connector-role-policy-document.json > /dev/null ||{
	echo "❌ Failed to create the tailpipe-connector-role. Please check your AWS credentials and permissions. Rolling back changes...";
	exit 1;
}
echo "✅ New role created successfully"

echo "Applying a permissions policy to the tailpipe-connector-role to allow Tailpipe to access the billling data export..."
aws iam put-role-policy --role-name tailpipe-connector-role --policy-name tailpipe_dataexport_and_cloudwatch_policy --policy-document file://tailpipe_dataexport_and_cloudwatch_policy.json || {
	echo "❌ Failed to apply permissions policy to the tailpipe-connector-role. Please check your AWS credentials and permissions.";
	exit 1;
}
echo "Permissions policy applied successfully"

echo "✅ AWS Configuration Finished Successfully."