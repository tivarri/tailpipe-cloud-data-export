#!/usr/bin/env bash

# Script to automate the configuration of Child Accounts for Tailpipe using CloudFormation

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Allow the user to pick the region the Stack Set is created in
echo "Enter the region where you would like the AWS Stack Set creating (use format us-east-1):"
read -r region

# Find the AWS Organisational Root ID
root=$(aws organizations list-roots --query "Roots[].Id" --output text)
echo "Starting Tailpipe Cloudformation Configuration for Organization with Root ID $root child accounts"

# Create the CloudFormation configuration file 
echo "Generating TailpipeChildAccountCloudFormation.yml config file"
cat <<EOT > TailpipeChildAccountCloudFormation.yml
AWSTemplateFormatVersion: '2010-09-09'
Description: Creates a cross-account IAM role for Tailpipe to access CloudWatch metrics data.

Resources:
  TailpipeCloudWatchRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: tailpipe-child-connector
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: "arn:aws:iam::336268260260:role/TailpipeConnector-Prod"
            Action: "sts:AssumeRole"
      Policies:
        - PolicyName: tailpipe_child_connector_policy
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - "cloudwatch:GetMetricStatistics"
                Resource: "*"
EOT
echo "✅ TailpipeChildAccountCloudFormation250710.yml generated"

echo "Starting CloudFormation setup..."

# Checking if CloudFormation has access to configure all the accounts in the Organization
cloudFormationStatus=$(aws cloudformation describe-organizations-access --query Status --output text)

# Setting CloudFormation access to child accounts

if [ "$cloudFormationStatus" = "DISABLED" ]; then
  echo "🔒 Organizations access is DISABLED. Enabling..."
  aws cloudformation activate-organizations-access || {
    echo "❌ Failed to enable CloudFormation access across the organisation. Please check your AWS credentials and permissions.";
    exit 1;
  }
  echo "✅ Organizations access has been enabled."
else
  echo "🔓 Organizations access is already ENABLED."
fi


# Create the StackSet

aws cloudformation create-stack-set --stack-set-name Tailpipe-CloudWatch-Child-StackSet --template-body file://TailpipeChildAccountCloudFormation.yml --permission-model SERVICE_MANAGED --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false --capabilities CAPABILITY_NAMED_IAM --region $region || {
    echo "❌ Failed to create the StackSet. Please look in the CloudFormation Console to see what errors there are.";
    exit 1;
}

# Create and deplay the stack instances to execute the configuration. 

operation_id=$(aws cloudformation create-stack-instances --stack-set-name Tailpipe-CloudWatch-Child-StackSet --deployment-targets OrganizationalUnitIds=$root --regions us-east-1 --operation-preferences RegionConcurrencyType=PARALLEL,FailureToleranceCount=0,MaxConcurrentPercentage=100,ConcurrencyMode=SOFT_FAILURE_TOLERANCE --region $region --query 'OperationId' --output text) || {
    echo "❌ Failed to create and deploy the stack instances. Please look in the CloudFormation Console to see what errors there are.";
    exit 1;
}

# # Wait until all config is complete
echo "⌛ Waiting for StackSet operation $operation_id to complete..."

while true; do
    status=$(aws cloudformation describe-stack-set-operation \
        --stack-set-name Tailpipe-CloudWatch-Child-StackSet \
        --operation-id "$operation_id" \
        --region "$region" \
        --query 'StackSetOperation.Status' \
        --output text)

    echo " - Operation status: $status"

    if [[ "$status" == "SUCCEEDED" ]]; then
        break
    elif [[ "$status" == "FAILED" || "$status" == "STOPPED" ]]; then
        echo "❌ StackSet operation failed with status: $status"
        exit 1
    fi

    sleep 15
done

echo "✅ CloudFormation setup complete. Cleaning up..."

if [ "$cloudFormationStatus" = "DISABLED" ]; then
  echo "🔒 Disabling Organizations access..."
  aws cloudformation deactivate-organizations-access || {
    echo "❌ Failed to disable CloudFormation access across the organisation. Please check your AWS credentials and permissions.";
    exit 1;
  }
  echo "✅ Organizations access has been disabled."
fi

# Removing yaml file

rm TailpipeChildAccountCloudFormation.yml

echo "🎉 Cloudformation Configuration for Organization with Root ID $root child accounts is now complete!"