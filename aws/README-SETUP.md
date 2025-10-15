# Tailpipe AWS Setup Guide

Complete automation for setting up Tailpipe in AWS environments.

## Overview

This toolkit provides a unified solution for configuring AWS Cost and Usage Reports for the Tailpipe platform. It handles:

- **Management account verification** to ensure proper access
- **S3 bucket** provisioning for cost report data
- **Cost and Usage Report (CUR)** export configuration
- **IAM role** for Tailpipe data access with external ID protection
- **CloudFormation StackSets** for child account CloudWatch access (Organizations)

## Quick Start

### Prerequisites

1. **AWS CLI** version 2.x or later
   ```bash
   aws --version
   # If needed: brew install awscli
   ```

2. **jq** for JSON parsing
   ```bash
   jq --version
   # If needed: brew install jq
   ```

3. **Permissions** required:
   - **AdministratorAccess** or equivalent on management account
   - **Organizations access** (for multi-account setups)
   - **IAM permissions** to create roles and policies
   - **S3 permissions** to create and manage buckets
   - **CloudFormation permissions** (for child accounts)

4. **Login** to AWS:
   ```bash
   aws configure
   # OR use AWS SSO:
   aws sso login --profile your-profile
   ```

5. **External ID** from Tailpipe (provided during onboarding)

### Installation

#### Interactive Mode (Recommended for first-time setup)

```bash
chmod +x setup-tailpipe.sh
./setup-tailpipe.sh
```

You'll be prompted for:
- AWS region (e.g., `us-east-1`, `eu-west-1`)
- Tailpipe External ID
- Confirmation for child account configuration

#### Non-Interactive Mode (CI/CD or scripted deployments)

```bash
chmod +x setup-tailpipe.sh
REGION=us-east-1 EXTERNAL_ID=your-external-id ./setup-tailpipe.sh
```

#### Dry Run (Preview changes without executing)

```bash
DRY_RUN=1 ./setup-tailpipe.sh
```

This shows exactly what would be created without making any changes.

## Configuration Options

### Environment Variables

All configuration can be controlled via environment variables:

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `REGION` | AWS region for resources | _(prompt)_ | `us-east-1` |
| `EXTERNAL_ID` | Tailpipe external ID | _(prompt)_ | `abc123...` |
| `TAILPIPE_ROLE_ARN` | Tailpipe connector role ARN | Prod role | `arn:aws:iam::336268260260:role/TailpipeConnector-UAT` |
| `SKIP_CHILD_ACCOUNTS` | Skip child account setup | `0` | `1` |
| `DRY_RUN` | Preview without changes | `0` | `1` |
| `FORCE` | Skip confirmations | `0` | `1` |
| `DEBUG` | Verbose AWS CLI output | `0` | `1` |

### Examples

**Production deployment:**
```bash
REGION=us-east-1 \
EXTERNAL_ID=your-external-id \
./setup-tailpipe.sh
```

**Test with UAT environment:**
```bash
TAILPIPE_ROLE_ARN=arn:aws:iam::336268260260:role/TailpipeConnector-UAT \
REGION=us-east-1 \
EXTERNAL_ID=test-external-id \
DRY_RUN=1 \
./setup-tailpipe.sh
```

**Skip child account configuration:**
```bash
SKIP_CHILD_ACCOUNTS=1 \
REGION=us-east-1 \
EXTERNAL_ID=your-external-id \
./setup-tailpipe.sh
```

**Automated deployment:**
```bash
FORCE=1 \
REGION=us-east-1 \
EXTERNAL_ID=your-external-id \
./setup-tailpipe.sh
```

## What Gets Created

### For All Deployments

1. **S3 Bucket**
   - Name: `tailpipe-dataexport-{account-number}`
   - Region: Your chosen region
   - Bucket policy: Allows AWS Billing and BCM Data Exports services

2. **Cost and Usage Report Export**
   - Name: `tailpipe-dataexport`
   - Type: COST_AND_USAGE_REPORT with all fields
   - Granularity: Hourly
   - Format: CSV (GZIP compressed)
   - Destination: S3 bucket with prefix `dataexport/`
   - Refresh: Synchronous (updates throughout the day)

3. **IAM Role**
   - Name: `tailpipe-connector-role`
   - Trust policy: Tailpipe connector with External ID
   - Permissions:
     - `s3:ListBucket`, `s3:GetObject` on data export bucket
     - `cloudwatch:GetMetricStatistics` globally

### For AWS Organizations (Management Account)

4. **CloudFormation StackSet**
   - Name: `Tailpipe-CloudWatch-Child-StackSet`
   - Deployment: Automatic to all child accounts
   - Creates in each child account:
     - IAM Role: `tailpipe-child-connector`
     - Permission: `cloudwatch:GetMetricStatistics`
     - Trust: Tailpipe connector with External ID

## Account Type Detection

The script automatically detects account types:

- **Management Account**: Full setup including child account configuration
- **Standalone Account**: Core setup only (S3, CUR, IAM role)

## Output

After successful deployment, you'll receive a JSON configuration summary:

```json
{
  "awsAccountNumber": "123456789012",
  "region": "us-east-1",
  "isManagementAccount": true,
  "organizationRootId": "r-abc123",
  "tailpipe": {
    "externalId": "your-external-id",
    "connectorRoleArn": "arn:aws:iam::336268260260:role/TailpipeConnector-Prod"
  },
  "costExport": {
    "name": "tailpipe-dataexport",
    "s3Bucket": "tailpipe-dataexport-123456789012",
    "s3Prefix": "dataexport",
    "exportArn": "arn:aws:bcm-data-exports:us-east-1:123456789012:export/tailpipe-dataexport"
  },
  "iamRole": {
    "name": "tailpipe-connector-role",
    "arn": "arn:aws:iam::123456789012:role/tailpipe-connector-role"
  },
  "childAccounts": {
    "configured": true,
    "count": 5,
    "childRoleName": "tailpipe-child-connector",
    "stackSetName": "Tailpipe-CloudWatch-Child-StackSet"
  }
}
```

**Save this output** - it contains all the information needed for Tailpipe onboarding.

## Validation

The setup script automatically validates:

- ✅ S3 bucket creation
- ✅ Cost export creation
- ✅ IAM role creation
- ✅ CloudFormation StackSet deployment (if applicable)

### Manual Validation

**Check S3 bucket:**
```bash
aws s3 ls s3://tailpipe-dataexport-{account-number}
```

**Check cost export:**
```bash
aws bcm-data-exports get-export \
  --export-arn "arn:aws:bcm-data-exports:us-east-1:{account-number}:export/tailpipe-dataexport"
```

**Check IAM role:**
```bash
aws iam get-role --role-name tailpipe-connector-role
```

**Check StackSet (Organizations):**
```bash
aws cloudformation describe-stack-set \
  --stack-set-name Tailpipe-CloudWatch-Child-StackSet \
  --region us-east-1
```

**Check stack instances:**
```bash
aws cloudformation list-stack-instances \
  --stack-set-name Tailpipe-CloudWatch-Child-StackSet \
  --region us-east-1
```

## Troubleshooting

### Common Issues

#### 1. "Failed to get AWS account number"

**Error:** `Failed to get AWS account number. Are you logged in?`

**Solution:**
```bash
# Check AWS credentials
aws sts get-caller-identity

# If not configured:
aws configure

# Or use SSO:
aws sso login --profile your-profile
```

#### 2. "This is a CHILD account"

**Error:** `This is a CHILD account. Please re-authenticate with the MANAGEMENT account`

**Cause:** You're logged into a member account, not the management/payer account

**Solution:**
- Switch to the management account credentials
- Or use `SKIP_CHILD_ACCOUNTS=1` if you only want single-account setup

#### 3. S3 Bucket Creation Fails

**Error:** `Failed to create S3 bucket`

**Common causes:**
- Bucket name already exists globally (choose different account)
- Insufficient S3 permissions
- Region restrictions

**Solution:**
```bash
# Check if bucket already exists
aws s3 ls s3://tailpipe-dataexport-{account-number}

# If it exists and is yours, the script will skip creation
# If it exists and isn't yours, you need a different account number
```

#### 4. Cost Export Creation Fails

**Error:** `Failed to create billing data export`

**Cause:** BCM Data Exports service may not be available in all regions

**Solution:**
- Ensure you're using `us-east-1` region for the export (it's created there by default)
- Check that AWS Billing is accessible in your account
- Verify S3 bucket exists and has correct policy

#### 5. CloudFormation StackSet Deployment Fails

**Error:** `Failed to create StackSet` or operation fails

**Common causes:**
- CloudFormation service-managed permissions not enabled
- Organizational unit ID incorrect
- Conflicting IAM roles in child accounts

**Solution:**
```bash
# Check CloudFormation access
aws cloudformation describe-organizations-access

# Enable if needed
aws cloudformation activate-organizations-access

# Check for existing roles in child accounts
aws iam get-role --role-name tailpipe-child-connector
```

#### 6. "jq not found"

**Error:** `jq not found. Please install: brew install jq`

**Solution:**
```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq  # Debian/Ubuntu
sudo yum install jq      # RHEL/CentOS
```

### Debug Mode

Enable detailed logging:

```bash
DEBUG=1 ./setup-tailpipe.sh
```

This shows full AWS CLI command output for troubleshooting.

### Get Help

Check script logs for specific error messages. Common patterns:

- **AccessDenied**: Missing IAM permissions
- **NoSuchBucket**: Bucket doesn't exist
- **InvalidInput**: Parameter validation failed
- **ResourceAlreadyExists**: Resource exists (usually safe to ignore)

## Cleanup & Removal

To remove all Tailpipe resources:

```bash
chmod +x cleanup-tailpipe.sh
./cleanup-tailpipe.sh
```

### Cleanup Options

**Preview cleanup without deleting:**
```bash
DRY_RUN=1 ./cleanup-tailpipe.sh
```

**Keep IAM role (preserve integration):**
```bash
KEEP_ROLE=1 ./cleanup-tailpipe.sh
```

**Keep S3 bucket and data:**
```bash
KEEP_DATA=1 ./cleanup-tailpipe.sh
```

**Force cleanup without confirmations:**
```bash
FORCE=1 ./cleanup-tailpipe.sh
```

**Combined options:**
```bash
KEEP_ROLE=1 KEEP_DATA=1 FORCE=1 ./cleanup-tailpipe.sh
```

### What Gets Deleted

- ❌ Cost and Usage Report export
- ❌ S3 bucket and all cost data (unless `KEEP_DATA=1`)
- ❌ IAM role and policies (unless `KEEP_ROLE=1`)
- ❌ CloudFormation StackSets and child account roles

### Cleanup Validation

```bash
# Check for remaining S3 buckets
aws s3 ls | grep tailpipe

# Check for IAM roles
aws iam get-role --role-name tailpipe-connector-role 2>&1 | grep -q NoSuchEntity && echo "Role deleted" || echo "Role still exists"

# Check for cost exports
aws bcm-data-exports list-exports --query 'Exports[?contains(ExportName, `tailpipe`)].ExportName'
```

## Maintenance

### Monitor Export Status

```bash
# Check export details
aws bcm-data-exports get-export \
  --export-arn "arn:aws:bcm-data-exports:us-east-1:{account-number}:export/tailpipe-dataexport"

# List all exports
aws bcm-data-exports list-exports
```

### Update CloudFormation StackSet

If you need to update child account configuration:

```bash
# Update StackSet template
aws cloudformation update-stack-set \
  --stack-set-name Tailpipe-CloudWatch-Child-StackSet \
  --template-body file://updated-template.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Update stack instances
aws cloudformation update-stack-instances \
  --stack-set-name Tailpipe-CloudWatch-Child-StackSet \
  --deployment-targets OrganizationalUnitIds=r-xxxx \
  --regions us-east-1 \
  --region us-east-1
```

### Rotate External ID

If you need to update the External ID:

```bash
# Update trust policy with new External ID
NEW_EXTERNAL_ID="new-external-id"

aws iam update-assume-role-policy \
  --role-name tailpipe-connector-role \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"AWS\": \"arn:aws:iam::336268260260:role/TailpipeConnector-Prod\"},
      \"Action\": \"sts:AssumeRole\",
      \"Condition\": {\"StringEquals\": {\"sts:ExternalId\": \"$NEW_EXTERNAL_ID\"}}
    }]
  }"
```

### Check Data Export Activity

```bash
# List objects in export bucket
aws s3 ls s3://tailpipe-dataexport-{account-number}/dataexport/ --recursive

# Check recent exports
aws s3 ls s3://tailpipe-dataexport-{account-number}/dataexport/ \
  --recursive \
  --human-readable \
  --summarize
```

## Architecture

### Resource Topology

```
AWS Account (Management)
├── S3 Bucket
│   └── tailpipe-dataexport-{account-id}
│       └── dataexport/
│           └── COST_AND_USAGE_REPORT files
│
├── Cost and Usage Report Export
│   ├── Type: COST_AND_USAGE_REPORT
│   ├── Granularity: Hourly
│   └── Destination: S3 bucket
│
├── IAM Role: tailpipe-connector-role
│   ├── Trust: Tailpipe (with External ID)
│   └── Permissions:
│       ├── S3 read access
│       └── CloudWatch metrics
│
└── CloudFormation StackSet (if Organization)
    └── Deploys to all child accounts:
        └── IAM Role: tailpipe-child-connector
            ├── Trust: Tailpipe (with External ID)
            └── Permission: CloudWatch metrics
```

### Data Flow

1. **Daily**: AWS generates Cost and Usage Report data
2. **Export delivery**: Compressed CSV files written to S3 bucket
3. **Tailpipe ingestion**: Assumes IAM role using External ID
4. **Data read**: Reads CUR files from S3 and CloudWatch metrics
5. **Child accounts**: CloudWatch metrics accessed via child account roles

### Security Model

- **External ID**: Prevents confused deputy problem
- **Least privilege**: Roles have minimal required permissions
- **Read-only access**: Tailpipe cannot modify your infrastructure
- **Audit trail**: All access logged in CloudTrail

## Advanced Usage

### Multi-Account Deployment

For organizations with multiple standalone accounts (not an Organization):

```bash
# Deploy to each account
for ACCOUNT_PROFILE in prod-account staging-account dev-account; do
  echo "Deploying to $ACCOUNT_PROFILE..."
  AWS_PROFILE=$ACCOUNT_PROFILE \
  EXTERNAL_ID=your-external-id \
  REGION=us-east-1 \
  ./setup-tailpipe.sh
done
```

### Custom S3 Bucket Location

The bucket is always created in the specified region, but you can verify:

```bash
aws s3api get-bucket-location \
  --bucket tailpipe-dataexport-{account-number}
```

### CI/CD Integration

```yaml
# GitHub Actions / AWS CodePipeline example
- name: Setup Tailpipe
  env:
    REGION: us-east-1
    EXTERNAL_ID: ${{ secrets.TAILPIPE_EXTERNAL_ID }}
    FORCE: 1
  run: |
    ./setup-tailpipe.sh > tailpipe-config.json

- name: Upload Configuration
  uses: actions/upload-artifact@v3
  with:
    name: tailpipe-config
    path: tailpipe-config.json
```

### Using with AWS Organizations

The script automatically detects Organizations and configures:
- Management account: Full CUR export
- All child accounts: CloudWatch metrics access

To manually add a new OU after initial setup:

```bash
NEW_OU_ID="ou-xxxx-yyyyyyyy"

aws cloudformation create-stack-instances \
  --stack-set-name Tailpipe-CloudWatch-Child-StackSet \
  --deployment-targets OrganizationalUnitIds=$NEW_OU_ID \
  --regions us-east-1 \
  --region us-east-1
```

## Security Considerations

### Least Privilege

The setup follows least-privilege principles:

- **Management account role**: Read-only access to S3 and CloudWatch
- **Child account roles**: CloudWatch metrics only
- **External ID**: Required for all role assumptions

### Secrets Management

- **External ID**: Treat as a secret, provided by Tailpipe securely
- **No long-term credentials**: Uses IAM role assumption
- **Audit logging**: All actions logged in CloudTrail

### Compliance

- **Data residency**: Choose region according to your compliance requirements
- **Access logging**: Enable S3 bucket logging if needed
- **Encryption**: S3 server-side encryption enabled by default

### Audit Trail

All operations are logged in AWS CloudTrail:

```bash
# View setup activities
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=your-username \
  --start-time 2025-01-01 \
  --query 'Events[?contains(EventName, `tailpipe`) || contains(EventName, `CreateRole`) || contains(EventName, `CreateBucket`)]'
```

## Support

### Script Version

Check version:
```bash
head -20 setup-tailpipe.sh | grep VERSION
```

Current version: **1.0.0**

### Logs

All AWS CLI operations can be logged:

```bash
DEBUG=1 ./setup-tailpipe.sh 2>&1 | tee setup-tailpipe.log
```

### Resources

- [AWS Cost and Usage Reports](https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html)
- [BCM Data Exports](https://docs.aws.amazon.com/cur/latest/userguide/dataexports.html)
- [AWS Organizations](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_introduction.html)
- [CloudFormation StackSets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/what-is-cfnstacksets.html)
- [IAM Roles and External IDs](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html)

## Comparison with Original Script

### Improvements

| Feature | Original | New Version |
|---------|----------|-------------|
| Dry-run mode | ❌ | ✅ |
| Non-interactive | ❌ | ✅ |
| Colored output | ⚠️ Partial | ✅ Full |
| Validation | ❌ | ✅ |
| Cleanup script | ❌ | ✅ |
| Config output | ❌ | ✅ JSON |
| Error handling | ⚠️ Basic | ✅ Comprehensive |
| Documentation | ⚠️ Minimal | ✅ Complete |
| CI/CD ready | ❌ | ✅ |
| Version tracking | ❌ | ✅ |

### Migration

If you used the original script, the new version is compatible:

```bash
# Cleanup old resources (if needed)
./cleanup-tailpipe.sh

# Deploy with new script
./setup-tailpipe.sh
```

Or run the new script - it will detect existing resources and skip creation.

## License

Copyright © 2025 Tivarri Limited. All rights reserved.
