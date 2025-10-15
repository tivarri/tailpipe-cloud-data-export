# Troubleshooting Guide

Common issues and solutions across AWS, Azure, and GCP implementations.

## Table of Contents

- [General Issues](#general-issues)
- [AWS Issues](#aws-issues)
- [Azure Issues](#azure-issues)
- [GCP Issues](#gcp-issues)
- [Script Errors](#script-errors)
- [Permission Issues](#permission-issues)
- [Network & Connectivity](#network--connectivity)
- [Data Export Issues](#data-export-issues)
- [Getting Help](#getting-help)

## General Issues

### Command Line Tools Not Found

**Symptoms:**
```
bash: aws: command not found
bash: az: command not found
bash: gcloud: command not found
```

**Solutions:**

**AWS CLI:**
```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Verify
aws --version
```

**Azure CLI:**
```bash
# macOS
brew install azure-cli

# Linux
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Verify
az --version
```

**Google Cloud CLI:**
```bash
# macOS
brew install --cask google-cloud-sdk

# Linux
curl https://sdk.cloud.google.com | bash

# Verify
gcloud --version
```

### jq Not Found (AWS/Azure scripts)

**Symptoms:**
```
bash: jq: command not found
```

**Solution:**
```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq  # Debian/Ubuntu
sudo yum install jq      # RHEL/CentOS

# Verify
jq --version
```

### Script Permission Denied

**Symptoms:**
```
bash: ./setup-tailpipe.sh: Permission denied
```

**Solution:**
```bash
chmod +x setup-tailpipe.sh
./setup-tailpipe.sh
```

### OneDrive / Cloud Storage Sync Issues

**Symptoms:**
```
cp: fcopyfile failed: Operation timed out
rsync: failed to set times on ...: Operation timed out
```

**Cause:** Cloud storage sync interference

**Solutions:**
```bash
# Option 1: Pause OneDrive/iCloud sync temporarily
# Option 2: Copy to local disk first
cp -r "~/Library/CloudStorage/OneDrive-Tivarri/..." ~/tmp-local/
cd ~/tmp-local/

# Option 3: Use rsync with --ignore-times
rsync -av --ignore-times source/ dest/
```

## AWS Issues

### 1. Authentication Failures

**Symptoms:**
```
Failed to get AWS account number. Are you logged in?
An error occurred (UnrecognizedClientException) when calling the GetCallerIdentity operation
```

**Solutions:**

**Check credentials:**
```bash
aws sts get-caller-identity

# If using profiles
aws sts get-caller-identity --profile your-profile

# If using SSO
aws sso login --profile your-profile
```

**Configure credentials:**
```bash
# Interactive setup
aws configure

# Or use SSO
aws configure sso
```

**Environment variables:**
```bash
export AWS_PROFILE=your-profile
export AWS_REGION=us-east-1
```

### 2. Wrong Account Type

**Symptoms:**
```
This is a CHILD account. Please re-authenticate with the MANAGEMENT account.
```

**Cause:** Logged into member account instead of management/payer account

**Solutions:**

**Option 1: Switch to management account**
```bash
# Find management account ID
aws organizations describe-organization \
  --query 'Organization.MasterAccountId' \
  --output text

# Switch credentials
aws configure --profile management-account
export AWS_PROFILE=management-account
```

**Option 2: Skip child account setup**
```bash
SKIP_CHILD_ACCOUNTS=1 ./setup-tailpipe.sh
```

### 3. S3 Bucket Creation Fails

**Symptoms:**
```
Failed to create S3 bucket
BucketAlreadyExists: The requested bucket name is not available
```

**Solutions:**

**Check if bucket exists:**
```bash
aws s3 ls s3://tailpipe-dataexport-ACCOUNT_NUMBER

# If accessible, script should skip creation
# If not accessible, bucket is owned by someone else
```

**Use different region:**
```bash
REGION=us-west-2 ./setup-tailpipe.sh
```

### 4. BCM Data Export Fails

**Symptoms:**
```
Failed to create billing data export
ValidationException: Invalid region
```

**Cause:** BCM Data Exports may not be available in all regions

**Solutions:**

**Use us-east-1:**
```bash
# BCM Data Exports are created in us-east-1 by default
# Bucket can be in any region
REGION=us-east-1 ./setup-tailpipe.sh
```

**Verify billing access:**
```bash
aws bcm-data-exports list-exports

# If permission error, ensure IAM permissions include:
# - bcm-data-exports:*
```

### 5. CloudFormation StackSet Failures

**Symptoms:**
```
Failed to create StackSet
FAILED: INSUFFICIENT_CAPABILITIES
```

**Solutions:**

**Enable Organizations access:**
```bash
# Check if enabled
aws cloudformation describe-organizations-access

# Enable if needed
aws cloudformation activate-organizations-access
```

**Check for existing roles:**
```bash
# In child accounts
aws iam get-role --role-name tailpipe-child-connector

# If exists, delete and re-run
aws iam delete-role --role-name tailpipe-child-connector
```

## Azure Issues

### 1. Authentication Failures

**Symptoms:**
```
ERROR: No subscription found. Run 'az account set' to select a subscription.
ERROR: The command requires authentication. Please login with 'az login'.
```

**Solutions:**

**Login:**
```bash
# Interactive login
az login

# With device code (headless)
az login --use-device-code

# With service principal
az login --service-principal \
  --username APP_ID \
  --password PASSWORD \
  --tenant TENANT_ID

# Verify
az account show
```

**Select subscription:**
```bash
# List subscriptions
az account list --output table

# Set active subscription
az account set --subscription "Subscription Name or ID"
```

### 2. Resource Provider Not Registered

**Symptoms:**
```
Code: MissingSubscriptionRegistration
Message: The subscription is not registered to use namespace 'Microsoft.CostManagement'
```

**Solutions:**

**Register providers:**
```bash
az provider register --namespace Microsoft.CostManagement
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.CostManagementExports

# Check status
az provider show --namespace Microsoft.CostManagement \
  --query "registrationState"

# Wait for "Registered" (can take 5-10 minutes)
```

### 3. Policy Deployment Fails

**Symptoms:**
```
ERROR: Policy assignment failed
AuthorizationFailed: Does not have authorization to perform action
```

**Solutions:**

**Check permissions:**
```bash
# You need:
# - Contributor or Owner at Management Group level
# - Or Resource Policy Contributor + User Access Administrator

az role assignment list --assignee YOUR_USER_ID \
  --scope /providers/Microsoft.Management/managementGroups/MG_ID
```

**Grant required roles:**
```bash
az role assignment create \
  --assignee YOUR_USER_ID \
  --role "Resource Policy Contributor" \
  --scope /providers/Microsoft.Management/managementGroups/MG_ID

az role assignment create \
  --assignee YOUR_USER_ID \
  --role "User Access Administrator" \
  --scope /providers/Microsoft.Management/managementGroups/MG_ID
```

### 4. Policy Not Creating Exports

**Symptoms:**
```
Policy shows compliant but no exports created
```

**Solutions:**

**Check compliance:**
```bash
az policy state list \
  --policy-assignment deploy-cost-export-assignment \
  --management-group MG_ID \
  --query "[].{sub:resourceId, state:complianceState}" \
  --output table
```

**Trigger remediation:**
```bash
az policy remediation create \
  --name manual-fix-$(date +%s) \
  --policy-assignment deploy-cost-export-assignment \
  --management-group MG_ID \
  --resource-discovery-mode ReEvaluateCompliance
```

**Check managed identity permissions:**
```bash
# Get managed identity
MANAGED_IDENTITY_ID=$(az policy assignment show \
  --name deploy-cost-export-assignment \
  --scope /providers/Microsoft.Management/managementGroups/MG_ID \
  --query identity.principalId -o tsv)

# Check role assignments
az role assignment list \
  --assignee $MANAGED_IDENTITY_ID \
  --all \
  --output table
```

### 5. Storage Account Access Denied

**Symptoms:**
```
AuthorizationPermissionMismatch
This request is not authorized to perform this operation using this permission.
```

**Solutions:**

**Check RBAC:**
```bash
az role assignment list \
  --scope /subscriptions/SUB_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/STORAGE_ACCOUNT \
  --output table

# Grant Storage Blob Data Contributor
az role assignment create \
  --assignee IDENTITY_ID \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/SUB_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/STORAGE_ACCOUNT
```

**Wait for propagation:**
```bash
# RBAC changes can take up to 5 minutes
sleep 300
```

### 6. Automation Account Runbook Failures

**Symptoms:**
```
Runbook job failed
Exception: Cannot find subscription
```

**Solutions:**

**Check managed identity:**
```bash
# Ensure system-assigned managed identity is enabled
az automation account show \
  --name tailpipe-automation \
  --resource-group rg-tailpipe \
  --query identity
```

**Check role assignments:**
```bash
# Managed identity needs:
# - Cost Management Contributor (tenant root)
# - Storage Blob Data Contributor

# Get managed identity principal ID
PRINCIPAL_ID=$(az automation account show \
  --name tailpipe-automation \
  --resource-group rg-tailpipe \
  --query identity.principalId -o tsv)

# Grant at tenant root
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Cost Management Contributor" \
  --scope /
```

**Check runbook logs:**
```bash
# View job output
az automation job show \
  --automation-account-name tailpipe-automation \
  --resource-group rg-tailpipe \
  --name JOB_ID
```

## GCP Issues

### 1. Authentication Failures

**Symptoms:**
```
ERROR: (gcloud.auth.list) There are no credentialed accounts.
```

**Solutions:**

**Login:**
```bash
# Interactive login
gcloud auth login

# With service account key
gcloud auth activate-service-account \
  --key-file=/path/to/key.json

# Verify
gcloud auth list
```

**Set project:**
```bash
# List projects
gcloud projects list

# Set active project
gcloud config set project PROJECT_ID
```

### 2. Billing Account Issues

**Symptoms:**
```
ERROR: Billing account is CLOSED
ERROR: Cannot link billing account to project
```

**Solutions:**

**Check billing account status:**
```bash
gcloud beta billing accounts list

# Look for "OPEN" status
# If CLOSED, select different billing account
```

**Link billing account:**
```bash
gcloud beta billing projects link PROJECT_ID \
  --billing-account=BILLING_ACCOUNT_ID
```

**Permissions required:**
```bash
# You need "Billing Account Administrator" role
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/billing.admin"
```

### 3. API Not Enabled

**Symptoms:**
```
ERROR: (gcloud.services.enable) FAILED_PRECONDITION: Billing must be enabled
API [bigquery.googleapis.com] not enabled
```

**Solutions:**

**Enable APIs:**
```bash
gcloud services enable bigquery.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable cloudbilling.googleapis.com
gcloud services enable iam.googleapis.com

# Verify
gcloud services list --enabled
```

### 4. Project Creation Fails

**Symptoms:**
```
ERROR: Project pending deletion
ERROR: Project ID already exists
```

**Solutions:**

**Check project status:**
```bash
gcloud projects describe PROJECT_ID \
  --format="value(lifecycleState)"

# If DELETE_REQUESTED, wait 30 days or use different ID
```

**Use unique project ID:**
```bash
# Add random suffix
PROJECT_ID=tailpipe-dataexport-$(date +%s)
./setup-tailpipe.sh
```

### 5. BigQuery Dataset Creation Fails

**Symptoms:**
```
ERROR: (gcloud.alpha.bq.datasets.create) Dataset already exists
```

**Solutions:**

**Check existing dataset:**
```bash
bq ls PROJECT_ID:

# If exists, update instead of create
bq update PROJECT_ID:billing_export \
  --description="Tailpipe billing export"
```

### 6. Service Account Permission Errors

**Symptoms:**
```
ERROR: (gcloud.iam.service-accounts.create) PERMISSION_DENIED
User does not have permission to create service accounts
```

**Solutions:**

**Check IAM permissions:**
```bash
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:user:YOUR_EMAIL"

# Need "Service Account Admin" or "Editor" role
```

**Grant required role:**
```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="user:YOUR_EMAIL" \
  --role="roles/iam.serviceAccountAdmin"
```

### 7. Billing Export Not Appearing in BigQuery

**Symptoms:**
- Script completes successfully
- Manual billing export configured
- No data appearing in BigQuery after 24 hours

**Solutions:**

**Verify billing export configuration:**
```bash
# Check in Cloud Console:
# Billing > Billing export > BigQuery export

# Ensure:
# - Correct project selected
# - Correct dataset name (billing_export)
# - Both "Standard usage cost" and "Detailed usage cost" enabled
```

**Check dataset location:**
```bash
bq show --format=prettyjson PROJECT_ID:billing_export

# Dataset location must match billing export region
# Usually US or EU
```

**Check IAM permissions on dataset:**
```bash
bq show --format=prettyjson PROJECT_ID:billing_export

# Billing account must have BigQuery Data Editor role
```

## Script Errors

### Dry Run Mode Not Working

**Symptoms:**
```
DRY_RUN=1 ./setup-tailpipe.sh
# Script still creates resources
```

**Solutions:**

**Check script version:**
```bash
head -20 setup-tailpipe.sh | grep VERSION

# Ensure using latest version
# DRY_RUN support added in v1.0.0+
```

**Use correct syntax:**
```bash
# Correct
DRY_RUN=1 ./setup-tailpipe.sh

# Also works
export DRY_RUN=1
./setup-tailpipe.sh
```

### Interactive Prompts Not Working

**Symptoms:**
```
# Script hangs waiting for input
# Or backspace doesn't work
```

**Solutions:**

**Use bash (not sh):**
```bash
# Correct
bash setup-tailpipe.sh

# Or
chmod +x setup-tailpipe.sh
./setup-tailpipe.sh

# Incorrect
sh setup-tailpipe.sh  # May not support read -e
```

**Use non-interactive mode:**
```bash
# Pass all parameters
REGION=us-east-1 EXTERNAL_ID=abc123 ./setup-tailpipe.sh
```

### Timeout Errors in GCP

**Symptoms:**
```
Timeout waiting for command to complete (10 seconds)
```

**Solutions:**

**Update gcloud components:**
```bash
gcloud components update

# If permission denied
sudo gcloud components update
```

**Increase timeout (not recommended):**
```bash
# Edit script and change timeout value
# Line: timeout 10s gcloud ...
# Change to: timeout 30s gcloud ...
```

## Permission Issues

### General Permission Debugging

**AWS:**
```bash
# Decode authorization errors
aws sts decode-authorization-message \
  --encoded-message "ENCODED_MESSAGE"

# Check effective permissions
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::ACCOUNT:role/ROLE \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::bucket/*
```

**Azure:**
```bash
# Check effective permissions
az role assignment list --all --assignee YOUR_ID

# Check specific resource
az role assignment list \
  --scope /subscriptions/SUB_ID/resourceGroups/RG
```

**GCP:**
```bash
# Check IAM policy
gcloud projects get-iam-policy PROJECT_ID

# Test permissions
gcloud iam service-accounts test-iam-permissions \
  tailpipe-connector@PROJECT.iam.gserviceaccount.com \
  --permissions=bigquery.datasets.get
```

## Network & Connectivity

### Timeout Connecting to Cloud APIs

**Symptoms:**
```
ConnectionError: Connection timed out
```

**Solutions:**

**Check internet connectivity:**
```bash
ping 8.8.8.8
curl -I https://aws.amazon.com
```

**Check proxy settings:**
```bash
# AWS
export HTTP_PROXY=http://proxy:port
export HTTPS_PROXY=http://proxy:port

# Azure
export HTTP_PROXY=http://proxy:port
export HTTPS_PROXY=http://proxy:port

# GCP (uses same variables)
```

**Check firewall rules:**
```bash
# Ensure outbound HTTPS (443) is allowed
# To AWS API endpoints: *.amazonaws.com
# To Azure API endpoints: *.azure.com
# To GCP API endpoints: *.googleapis.com
```

## Data Export Issues

### No Data Appearing After Setup

**AWS:**
```bash
# CUR generation can take 24 hours
# Check export status
aws bcm-data-exports get-export \
  --export-arn "arn:aws:bcm-data-exports:REGION:ACCOUNT:export/tailpipe-dataexport"

# Check S3 bucket
aws s3 ls s3://tailpipe-dataexport-ACCOUNT/dataexport/ --recursive
```

**Azure:**
```bash
# Cost exports run on schedule (usually daily)
# Check export status
az costmanagement export show \
  --name tailpipe-SUBSCRIPTION_SUFFIX \
  --scope /subscriptions/SUBSCRIPTION_ID

# Check storage account
az storage blob list \
  --account-name tailpipedataexportXXXX \
  --container-name dataexport \
  --output table
```

**GCP:**
```bash
# BigQuery export is near real-time
# Check for tables
bq ls PROJECT_ID:billing_export

# Query for recent data
bq query --use_legacy_sql=false \
  'SELECT MAX(export_time) FROM `PROJECT_ID.billing_export.gcp_billing_export_v1_*`'
```

## Getting Help

### Enable Debug Mode

**AWS:**
```bash
DEBUG=1 ./setup-tailpipe.sh 2>&1 | tee setup-debug.log
```

**Azure:**
```bash
DEBUG=1 ./setup-tailpipe.sh 2>&1 | tee setup-debug.log

# Or Azure CLI debug
az <command> --debug
```

**GCP:**
```bash
DEBUG=1 ./setup-tailpipe.sh 2>&1 | tee setup-debug.log

# Or gcloud verbosity
gcloud <command> --verbosity=debug
```

### Collect Diagnostic Information

**Before contacting support, gather:**

```bash
# Script version
head -20 setup-tailpipe.sh | grep VERSION

# Cloud CLI versions
aws --version
az --version
gcloud --version

# OS information
uname -a
sw_vers  # macOS
lsb_release -a  # Linux

# Error logs (from debug mode)
cat setup-debug.log

# Configuration output (if script partially completed)
# Redact sensitive information (External IDs, account numbers)
```

### Contact Support

**Tailpipe Support:**
- Email: support@tailpipe.io
- Subject: [Platform] Issue Description
- Include: Diagnostic information above

**Community Resources:**
- GitHub Issues: https://github.com/tivarri/tailpipe-cloud-data-export/issues
- Documentation: Platform-specific README files

### Known Issues

**AWS:**
- BCM Data Exports not available in all regions (use us-east-1)
- CloudFormation StackSets require Organizations access pre-enabled

**Azure:**
- Policy remediation can take up to 24 hours
- RBAC permission propagation: 5-10 minutes
- Cost Management API rate limits: 10 calls/minute

**GCP:**
- No gcloud command for billing export (manual Console step)
- Billing export data delay: up to 24 hours
- Project deletion prevents reuse for 30 days

---

**Document Version:** 1.0.0
**Last Updated:** October 2025
**Maintained By:** Tivarri Support Team
