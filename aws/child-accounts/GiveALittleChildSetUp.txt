#!/usr/bin/env bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

external_id=6a880dc0-f9a5-4090-abd1-a2921d7c7232

echo "Starting JSON file generation..."

echo "Generating tailpipe-child-connector-policy-document.json"
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
echo "✅ tailpipe-child-connector-policy-document.json generated" \

echo "Generating tailpipe_child_connector_policy.json"
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
echo "✅ tailpipe_child_connector_policy.json generated" \
    
echo "JSON file generation completed"

echo "Starting AWS configuration..."

echo "Creating a new role: tailpipe-child-connector-role for Tailpipe's third party data access..."
aws iam create-role --role-name tailpipe-child-connector-role --assume-role-policy-document file://tailpipe-child-connector-policy-document.json > /dev/null ||{
    echo "❌ Failed to create the tailpipe-child-connector-role. Please check your AWS credentials and permissions. Rolling back changes...";
    exit 1;
}
echo "✅ New role created successfully"

echo "Applying a permissions policy to the tailpipe-child-connector-role..."
aws iam put-role-policy --role-name tailpipe-child-connector-role --policy-name tailpipe_child_connector_policy --policy-document file://tailpipe_child_connector_policy.json || {
    echo "❌ Failed to apply permissions policy to the tailpipe-child-connector-role. Please check your AWS credentials and permissions.";
    exit 1;
}
echo "Permissions policy applied successfully"

echo "Removing JSON files"
rm tailpipe-child-connector-policy-document.json
rm tailpipe_child_connector_policy.json
echo "✅ JSON files removed"

echo "✅ AWS Configuration Finished Successfully."