# Security Best Practices

Comprehensive security guidance for Tailpipe cloud cost data export implementations.

## Table of Contents

- [Overview](#overview)
- [Authentication & Authorization](#authentication--authorization)
- [Secret Management](#secret-management)
- [Network Security](#network-security)
- [Data Protection](#data-protection)
- [Audit & Compliance](#audit--compliance)
- [Incident Response](#incident-response)
- [Security Checklist](#security-checklist)

## Overview

All Tailpipe integrations follow security best practices:

- ✅ **Least Privilege Access** - Minimal permissions required
- ✅ **No Write Access** - Read-only access to cost data
- ✅ **Audit Trails** - All operations logged
- ✅ **Encrypted Transit** - HTTPS/TLS for all communications
- ✅ **Encrypted at Rest** - Default encryption for all storage
- ✅ **Secret Rotation** - Support for credential rotation
- ✅ **Principle of Defense in Depth** - Multiple security layers

## Authentication & Authorization

### AWS

#### External ID Pattern

**Purpose:** Prevents confused deputy attack

**Implementation:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::336268260260:role/TailpipeConnector-Prod"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "CUSTOMER_SPECIFIC_SECRET"
      }
    }
  }]
}
```

**Security Properties:**
- External ID acts as a shared secret
- Prevents Tailpipe from accessing wrong customer accounts
- Unique per customer (never reused)
- Rotatable without infrastructure changes

#### IAM Role Permissions (Least Privilege)

**Management Account Role:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::tailpipe-dataexport-*",
        "arn:aws:s3:::tailpipe-dataexport-*/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "cloudwatch:GetMetricStatistics",
      "Resource": "*"
    }
  ]
}
```

**What's NOT allowed:**
- ❌ `s3:PutObject` - Cannot write data
- ❌ `s3:DeleteObject` - Cannot delete data
- ❌ `iam:*` - Cannot modify IAM
- ❌ `ec2:*` - Cannot control compute
- ❌ Wildcard permissions

**Child Account Role:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "cloudwatch:GetMetricStatistics",
    "Resource": "*"
  }]
}
```

#### Session Policies

Consider adding session policies for additional constraints:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": "arn:aws:s3:::tailpipe-dataexport-*/*",
    "Condition": {
      "IpAddress": {
        "aws:SourceIp": [
          "52.1.2.3/32",
          "54.5.6.7/32"
        ]
      }
    }
  }]
}
```

### Azure

#### Managed Identity (Recommended)

**Why Managed Identity?**
- No credentials to manage
- Automatic rotation by Azure
- Tied to resource lifecycle
- Azure AD integration

**RBAC Assignments:**
```bash
# Reader role on subscription (minimal read access)
az role assignment create \
  --assignee <managed-identity-principal-id> \
  --role "Reader" \
  --scope "/subscriptions/{subscription-id}"

# Storage Blob Data Contributor (data access only)
az role assignment create \
  --assignee <managed-identity-principal-id> \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{name}"
```

**What's NOT granted:**
- ❌ `Contributor` - Too broad, allows resource modification
- ❌ `Owner` - Allows RBAC changes
- ❌ `Storage Blob Data Owner` - Allows ACL changes

#### Service Principal (Alternative)

**If Managed Identity not available:**
```bash
# Create service principal
az ad sp create-for-rbac \
  --name "tailpipe-connector" \
  --role "Reader" \
  --scopes "/subscriptions/{subscription-id}"

# Use certificate instead of client secret (more secure)
az ad sp create-for-rbac \
  --name "tailpipe-connector" \
  --create-cert \
  --cert @/path/to/cert.pem
```

**Secret Rotation:**
```bash
# Rotate client secret annually
az ad sp credential reset \
  --id <app-id> \
  --years 1
```

#### Conditional Access Policies

For enterprise deployments:

```
Azure AD Conditional Access
├─ Require MFA for service principal operations
├─ Restrict access to specific IP ranges
├─ Require compliant device (for interactive auth)
└─ Session timeout policies
```

### GCP

#### Workload Identity Federation (Keyless)

**Why Workload Identity Federation?**
- No service account keys
- Short-lived tokens (1 hour)
- Federates with external OIDC providers
- Automatic key rotation

**Implementation:**
```bash
# Create Workload Identity Pool
gcloud iam workload-identity-pools create tailpipe-pool \
  --location="global" \
  --description="Tailpipe connector pool"

# Create OIDC provider
gcloud iam workload-identity-pools providers create-oidc tailpipe-provider \
  --workload-identity-pool="tailpipe-pool" \
  --issuer-uri="https://accounts.google.com" \
  --location="global"

# Bind service account
gcloud iam service-accounts add-iam-policy-binding \
  tailpipe-connector@PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/tailpipe-pool/*"
```

#### Service Account Permissions (Least Privilege)

**BigQuery Access:**
```bash
# Dataset-level permissions (not project-level)
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:tailpipe-connector@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer" \
  --condition="resource.name.startsWith('projects/PROJECT_ID/datasets/billing_export')"
```

**Cloud Storage Access:**
```bash
# Bucket-level permissions only
gsutil iam ch \
  serviceAccount:tailpipe-connector@PROJECT_ID.iam.gserviceaccount.com:roles/storage.objectViewer \
  gs://tailpipe-billing-export-PROJECT_ID
```

**What's NOT granted:**
- ❌ `roles/editor` - Too broad
- ❌ `roles/bigquery.admin` - Allows schema changes
- ❌ `roles/storage.admin` - Allows deletions
- ❌ Project-level permissions

#### Service Account Key Management (If Required)

**If keys are necessary:**

```bash
# Create key with expiration
gcloud iam service-accounts keys create key.json \
  --iam-account=tailpipe-connector@PROJECT_ID.iam.gserviceaccount.com

# Rotate every 90 days
gcloud iam service-accounts keys list \
  --iam-account=tailpipe-connector@PROJECT_ID.iam.gserviceaccount.com

# Delete old keys
gcloud iam service-accounts keys delete KEY_ID \
  --iam-account=tailpipe-connector@PROJECT_ID.iam.gserviceaccount.com
```

**Store keys securely:**
- ✅ HashiCorp Vault
- ✅ GCP Secret Manager
- ✅ Kubernetes Secrets (encrypted at rest)
- ❌ Version control (git)
- ❌ Unencrypted filesystems
- ❌ Email or chat

## Secret Management

### External IDs (AWS)

**Generation:**
```bash
# Use cryptographically secure random
openssl rand -hex 32
# Or
python3 -c "import secrets; print(secrets.token_hex(32))"
```

**Storage:**
- ✅ AWS Secrets Manager
- ✅ HashiCorp Vault
- ✅ Parameter Store (encrypted)
- ❌ Environment variables in CI/CD logs
- ❌ Hardcoded in scripts

**Rotation:**
```bash
# Update External ID in trust policy
aws iam update-assume-role-policy \
  --role-name tailpipe-connector-role \
  --policy-document file://new-trust-policy.json
```

### Client Secrets (Azure)

**Storage:**
- ✅ Azure Key Vault
- ✅ Managed Identity (no secrets)
- ❌ Application settings (plaintext)
- ❌ Environment variables

**Access Control:**
```bash
# Limit Key Vault access
az keyvault set-policy \
  --name tailpipe-kv \
  --object-id <managed-identity-id> \
  --secret-permissions get
```

### Service Account Keys (GCP)

**Avoid if possible:**
- Use Workload Identity Federation instead
- If required, rotate every 90 days
- Store in Secret Manager

**Storage:**
```bash
# Store in Secret Manager
gcloud secrets create tailpipe-sa-key \
  --data-file=key.json

# Grant access only to specific identities
gcloud secrets add-iam-policy-binding tailpipe-sa-key \
  --member="serviceAccount:app@PROJECT.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

## Network Security

### AWS

**VPC Endpoints (Optional):**
```bash
# S3 VPC Endpoint for private access
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-xxxxx \
  --service-name com.amazonaws.REGION.s3 \
  --route-table-ids rtb-xxxxx
```

**Bucket Policies (Defense in Depth):**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "RequireSSL",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::tailpipe-dataexport-*",
      "arn:aws:s3:::tailpipe-dataexport-*/*"
    ],
    "Condition": {
      "Bool": {"aws:SecureTransport": "false"}
    }
  }]
}
```

### Azure

**Private Endpoints:**
```bash
# Storage account private endpoint
az network private-endpoint create \
  --name tailpipe-storage-pe \
  --resource-group rg-tailpipe \
  --vnet-name vnet-tailpipe \
  --subnet subnet-private \
  --private-connection-resource-id "/subscriptions/.../Microsoft.Storage/storageAccounts/tailpipedataexport..." \
  --group-id blob \
  --connection-name tailpipe-pe-connection
```

**Firewall Rules:**
```bash
# Restrict storage account access
az storage account update \
  --name tailpipedataexport... \
  --default-action Deny

az storage account network-rule add \
  --account-name tailpipedataexport... \
  --ip-address 52.1.2.3
```

### GCP

**VPC Service Controls:**
```bash
# Create perimeter for billing export project
gcloud access-context-manager perimeters create tailpipe-perimeter \
  --title="Tailpipe Billing Export" \
  --resources="projects/PROJECT_NUMBER" \
  --restricted-services="bigquery.googleapis.com,storage.googleapis.com"
```

**Firewall Rules:**
```bash
# Restrict BigQuery access by IP
# (Applied via VPC Service Controls)
```

## Data Protection

### Encryption at Rest

**AWS:**
- S3 buckets: SSE-S3 (default) or SSE-KMS
```bash
aws s3api put-bucket-encryption \
  --bucket tailpipe-dataexport-ACCOUNT \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:..."
      }
    }]
  }'
```

**Azure:**
- Storage accounts: Microsoft-managed keys (default) or customer-managed keys
```bash
az storage account update \
  --name tailpipedataexport... \
  --encryption-key-source Microsoft.Keyvault \
  --encryption-key-vault https://tailpipe-kv.vault.azure.net/ \
  --encryption-key-name tailpipe-key
```

**GCP:**
- BigQuery: Google-managed encryption (default) or CMEK
- Cloud Storage: Same options
```bash
gsutil encryption set \
  -k projects/PROJECT/locations/LOCATION/keyRings/RING/cryptoKeys/KEY \
  gs://tailpipe-billing-export-PROJECT
```

### Encryption in Transit

**All platforms enforce TLS 1.2+ by default:**
- AWS: S3 API requires TLS
- Azure: Storage and Cost Management APIs require TLS
- GCP: BigQuery and Cloud Storage APIs require TLS

**Verify in scripts:**
```bash
# AWS
--no-verify-ssl flag is NEVER used

# Azure
# TLS enforced by SDK

# GCP
# TLS enforced by SDK
```

### Data Retention

**Compliance Requirements:**
```bash
# AWS S3 Lifecycle
aws s3api put-bucket-lifecycle-configuration \
  --bucket tailpipe-dataexport-ACCOUNT \
  --lifecycle-configuration '{
    "Rules": [{
      "Id": "DeleteOldReports",
      "Status": "Enabled",
      "Expiration": {"Days": 2555},
      "Filter": {"Prefix": "dataexport/"}
    }]
  }'

# Azure Storage Lifecycle
az storage account management-policy create \
  --account-name tailpipedataexport... \
  --policy '{
    "rules": [{
      "name": "deleteOldExports",
      "type": "Lifecycle",
      "definition": {
        "actions": {"baseBlob": {"delete": {"daysAfterModificationGreaterThan": 2555}}},
        "filters": {"blobTypes": ["blockBlob"], "prefixMatch": ["dataexport/"]}
      }
    }]
  }'

# GCP BigQuery Table Expiration
bq update --expiration 220924800 \
  PROJECT:billing_export.gcp_billing_export_v1_XXXXX
```

## Audit & Compliance

### Logging

**AWS CloudTrail:**
```bash
# Ensure CloudTrail is enabled
aws cloudtrail describe-trails

# Monitor for specific events
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --max-results 50
```

**Azure Activity Log:**
```bash
# Query for role assumptions
az monitor activity-log list \
  --query "[?operationName.value=='Microsoft.Authorization/roleAssignments/write']"

# Storage access logs
az storage logging update \
  --services b \
  --log rwd \
  --retention 90 \
  --account-name tailpipedataexport...
```

**GCP Cloud Audit Logs:**
```bash
# Query BigQuery access
gcloud logging read "resource.type=bigquery_dataset AND protoPayload.methodName=google.cloud.bigquery.v2.JobService.InsertJob" \
  --limit 50 \
  --format json

# Enable Data Access audit logs
gcloud projects set-iam-policy PROJECT_ID policy.yaml
```

### Compliance Frameworks

**SOC 2:**
- ✅ Audit logs enabled
- ✅ Encryption at rest and in transit
- ✅ Access control policies
- ✅ Change management (git history)

**GDPR:**
- ✅ Data minimization (only billing data)
- ✅ Right to erasure (deletion scripts)
- ✅ Data processing agreement with Tailpipe
- ✅ Audit trail of data access

**HIPAA (if applicable):**
- ✅ Encryption (AES-256)
- ✅ Access controls
- ✅ Audit logs (retention 7 years)
- ✅ BAA with Tailpipe required

**PCI-DSS:**
- N/A - No cardholder data in billing exports

## Incident Response

### Suspected Unauthorized Access

**AWS:**
```bash
# 1. Revoke sessions
aws iam delete-role-policy \
  --role-name tailpipe-connector-role \
  --policy-name TailpipeAccess

# 2. Rotate External ID
# Update trust policy with new External ID

# 3. Review CloudTrail logs
aws cloudtrail lookup-events \
  --start-time 2025-10-01T00:00:00Z \
  --lookup-attributes AttributeKey=Username,AttributeValue=tailpipe-connector-role
```

**Azure:**
```bash
# 1. Disable service principal
az ad sp update --id <app-id> --set accountEnabled=false

# 2. Revoke tokens
az ad app credential reset --id <app-id>

# 3. Review activity logs
az monitor activity-log list --start-time 2025-10-01
```

**GCP:**
```bash
# 1. Disable service account
gcloud iam service-accounts disable \
  tailpipe-connector@PROJECT.iam.gserviceaccount.com

# 2. Revoke keys
gcloud iam service-accounts keys list \
  --iam-account=tailpipe-connector@PROJECT.iam.gserviceaccount.com
gcloud iam service-accounts keys delete KEY_ID \
  --iam-account=tailpipe-connector@PROJECT.iam.gserviceaccount.com

# 3. Review audit logs
gcloud logging read "protoPayload.authenticationInfo.principalEmail=tailpipe-connector@PROJECT.iam.gserviceaccount.com"
```

### Data Breach Response

1. **Contain:** Revoke access immediately (see above)
2. **Assess:** Review audit logs to determine scope
3. **Notify:** Inform Tailpipe support and security team
4. **Remediate:** Rotate all credentials, review IAM policies
5. **Document:** Record timeline and actions taken

### Contact Information

**Tailpipe Security Team:**
- Email: security@tailpipe.io
- PGP Key: [Link to public key]

**Escalation:**
- Severity 1 (Critical): security@tailpipe.io + phone
- Severity 2 (High): security@tailpipe.io
- Severity 3 (Medium): support@tailpipe.io

## Security Checklist

### Pre-Deployment

- [ ] External ID / secret generated with cryptographically secure random
- [ ] External ID / secret stored in secure secret manager
- [ ] IAM roles reviewed for least privilege
- [ ] No wildcard permissions granted
- [ ] Service account keys avoided (use Workload Identity / Managed Identity)
- [ ] Network restrictions configured (if required)
- [ ] Encryption at rest enabled
- [ ] Audit logging enabled

### Post-Deployment

- [ ] Test access with actual credentials
- [ ] Verify audit logs are capturing events
- [ ] Document all resource IDs and ARNs
- [ ] Share configuration JSON with Tailpipe (securely)
- [ ] Schedule secret rotation (90 days)
- [ ] Configure alerts for unauthorized access attempts
- [ ] Review IAM policies quarterly

### Ongoing Operations

- [ ] Monitor audit logs weekly
- [ ] Rotate secrets every 90 days
- [ ] Review IAM permissions quarterly
- [ ] Update scripts to latest versions
- [ ] Test disaster recovery procedures
- [ ] Conduct security reviews annually

## Security Contacts

**Report a Vulnerability:**
- Email: security@tailpipe.io
- Subject: [SECURITY] Tailpipe Cloud Data Export
- Include: Platform, version, detailed description

**Bug Bounty Program:**
- Not currently available
- Responsible disclosure encouraged

---

**Document Version:** 1.0.0
**Last Updated:** October 2025
**Maintained By:** Tivarri Security Team
