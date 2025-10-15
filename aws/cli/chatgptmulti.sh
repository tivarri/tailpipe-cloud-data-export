#!/usr/bin/env bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Input file with AWS accounts
ACCOUNTS_FILE="aws_accounts.csv"

if [[ ! -f "$ACCOUNTS_FILE" ]]; then
    echo "Error: AWS accounts file '$ACCOUNTS_FILE' not found. Please create a CSV with columns: region,account_number,external_id."
    exit 1
fi

# Read the CSV file line by line, skipping the header
sed 1d "$ACCOUNTS_FILE" | while IFS="," read -r region aws_account_number external_id; do
    if [[ -z "$region" || -z "$aws_account_number" || -z "$external_id" ]]; then
        echo "Skipping invalid line in CSV: $region, $aws_account_number, $external_id"
        continue
    fi
    
    echo "Configuring AWS account: $aws_account_number in region: $region"
    
    # Generate JSON policy file for each account
    cat <<EOT > tailpipe-dataexport-s3-policy-$aws_account_number.json
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
                "arn:aws:s3:::tailpipe-dataexport-$aws_account_number/*"
            ]
        }
    ]
}
EOT

    # Create S3 bucket
    aws s3api create-bucket --bucket tailpipe-dataexport-$aws_account_number --region $region --create-bucket-configuration LocationConstraint=$region

    # Apply policy to the bucket
    aws s3api put-bucket-policy --bucket tailpipe-dataexport-$aws_account_number --policy file://tailpipe-dataexport-s3-policy-$aws_account_number.json

    echo "AWS account $aws_account_number configured successfully."

done

echo "All AWS accounts processed successfully."
