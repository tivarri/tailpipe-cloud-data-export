# Architecture Overview

Cross-platform architecture documentation for Tailpipe cloud cost data export automation.

## Philosophy

This repository follows a **unified automation approach** across AWS, Azure, and GCP while respecting each platform's native patterns and best practices. All implementations share common principles:

1. **Infrastructure as Code** - Declarative, repeatable deployments
2. **Least Privilege** - Minimal IAM permissions required
3. **Automation First** - One-command setup with validation
4. **Security by Default** - External IDs, keyless auth, audit trails
5. **Multi-Account Support** - Organizations, subscriptions, billing accounts

## Platform Comparison

### Deployment Models

| Aspect | AWS | Azure | GCP |
|--------|-----|-------|-----|
| **Primary Method** | Bash script | Azure Policy (recommended) | Bash script |
| **Alternative Methods** | CloudFormation | Automation Account, CLI scripts | - |
| **Multi-Account** | CloudFormation StackSets | Policy at Management Group | Multiple billing accounts |
| **Account Detection** | Automatic (mgmt vs standalone) | Manual selection | Manual selection |
| **Dry-Run Support** | ✅ Yes | ✅ Yes | ✅ Yes |

### Cost Export Architecture

#### AWS: BCM Data Exports

```
┌─────────────────────────────────────────────────────┐
│ Management Account                                   │
│                                                      │
│  ┌─────────────────┐      ┌────────────────────┐   │
│  │ BCM Data Export │─────▶│ S3 Bucket          │   │
│  │ (CUR)           │      │ tailpipe-dataexport│   │
│  │ - Hourly        │      │ - GZIP CSV         │   │
│  │ - All fields    │      │ - Prefix: dataexport/│ │
│  └─────────────────┘      └────────────────────┘   │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │ IAM Role: tailpipe-connector-role            │  │
│  │ - Trust: External ID                         │  │
│  │ - Permissions: s3:Get*, cloudwatch:Get*      │  │
│  └──────────────────────────────────────────────┘  │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │ CloudFormation StackSet (Organizations)      │  │
│  │ Deploys to all child accounts:               │  │
│  │   - IAM Role: tailpipe-child-connector       │  │
│  │   - CloudWatch metrics read access           │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Key Design Decisions:**
- BCM Data Exports (new API) instead of legacy CUR
- Hourly granularity for real-time insights
- Management account hosts all billing data
- Child accounts only provide CloudWatch metrics
- External ID prevents confused deputy attacks

#### Azure: Three-Tier Approach

**Approach 1: Azure Policy (Recommended)**

```
┌─────────────────────────────────────────────────────┐
│ Management Group                                     │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │ Policy Definition: deploy-cost-export        │  │
│  │ - Type: deployIfNotExists                    │  │
│  │ - Scope: All subscriptions                   │  │
│  └──────────────────────────────────────────────┘  │
│                           │                          │
│                           ▼                          │
│  ┌──────────────────────────────────────────────┐  │
│  │ Policy Assignment                            │  │
│  │ - Managed Identity (auto-created)            │  │
│  │ - Remediation Task (automatic)               │  │
│  └──────────────────────────────────────────────┘  │
└──────────────────┬───────────────────────────────────┘
                   │
         ┌─────────┴─────────┬─────────────┐
         ▼                   ▼             ▼
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│ Subscription 1 │  │ Subscription 2 │  │ Subscription N │
│                │  │                │  │                │
│ Cost Export    │  │ Cost Export    │  │ Cost Export    │
│      ▼         │  │      ▼         │  │      ▼         │
│ Storage Account│  │ Storage Account│  │ Storage Account│
└────────────────┘  └────────────────┘  └────────────────┘
```

**Approach 2: Automation Account**

```
┌─────────────────────────────────────────────────────┐
│ Central Subscription                                 │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │ Automation Account                           │  │
│  │                                              │  │
│  │  ┌────────────────────────────────────────┐ │  │
│  │  │ PowerShell Runbook                     │ │  │
│  │  │ - Runs daily                           │ │  │
│  │  │ - Queries all subscriptions            │ │  │
│  │  │ - Creates exports if missing           │ │  │
│  │  └────────────────────────────────────────┘ │  │
│  │                                              │  │
│  │  ┌────────────────────────────────────────┐ │  │
│  │  │ Managed Identity                       │ │  │
│  │  │ - Cost Management Contributor          │ │  │
│  │  │ - Storage Blob Data Contributor        │ │  │
│  │  └────────────────────────────────────────┘ │  │
│  │                                              │  │
│  │  ┌────────────────────────────────────────┐ │  │
│  │  │ State Storage (Blob)                   │ │  │
│  │  │ - known_subscriptions.json             │ │  │
│  │  └────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Approach 3: CLI Scripts**

```
Manual execution from developer workstation or CI/CD
- deploy_tailpipe_dataexport.sh (single subscription)
- setup_tailpipe_multisub_export.sh (all subscriptions)
```

**Key Design Decisions:**
- Policy approach is declarative and self-healing
- Automation Account provides explicit control and logging
- CLI scripts for ad-hoc deployments and troubleshooting
- All approaches write to same storage structure for consistency

#### GCP: BigQuery-Centric

```
┌─────────────────────────────────────────────────────┐
│ Export Project (tailpipe-dataexport)                 │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │ BigQuery Dataset: billing_export             │  │
│  │                                              │  │
│  │  Tables (one per billing account):           │  │
│  │  - gcp_billing_export_v1_XXXXXX_XXXXXX_XXX  │  │
│  │  - gcp_billing_export_resource_v1_...       │  │
│  └──────────────────────────────────────────────┘  │
│                       ▲                              │
│                       │                              │
│  ┌────────────────────┴─────────────────────────┐  │
│  │ Cloud Storage Bucket                         │  │
│  │ tailpipe-billing-export-{project-id}         │  │
│  └──────────────────────────────────────────────┘  │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │ Service Account                              │  │
│  │ tailpipe-connector@...iam.gserviceaccount.com│  │
│  │ - Workload Identity Federation              │  │
│  │ - BigQuery Data Viewer                       │  │
│  │ - Storage Object Viewer                      │  │
│  └──────────────────────────────────────────────┘  │
└──────────────────┬───────────────────────────────────┘
                   │
                   │ Manual Console Step:
                   │ Enable billing export for each
                   │ billing account → BigQuery dataset
                   │
         ┌─────────┴─────────┬─────────────┐
         ▼                   ▼             ▼
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│ Billing Acct 1 │  │ Billing Acct 2 │  │ Billing Acct N │
│ 123456-789ABC  │  │ 234567-890BCD  │  │ ...            │
└────────────────┘  └────────────────┘  └────────────────┘
```

**Key Design Decisions:**
- Single project for all billing accounts (cost optimization)
- BigQuery native export (no custom ETL needed)
- Workload Identity Federation (keyless, more secure)
- Manual console step unavoidable (no gcloud API for billing export)
- Multi-billing account support in single dataset

## Data Flow Patterns

### AWS Data Flow

```
1. AWS generates billing data hourly
2. BCM Data Exports writes to S3 (GZIP CSV)
3. Tailpipe assumes IAM role (with External ID)
4. Reads S3 objects and CloudWatch metrics
5. Child account metrics via role chaining
```

### Azure Data Flow

```
1. Azure Cost Management generates daily exports
2. Written to Storage Account (CSV)
3. Tailpipe uses Service Principal or Managed Identity
4. Reads blob storage and queries Cost Management API
5. Multi-subscription via RBAC on management group
```

### GCP Data Flow

```
1. GCP Billing writes to BigQuery (streaming)
2. Also written to Cloud Storage (backup)
3. Tailpipe uses Workload Identity Federation
4. Queries BigQuery directly (SQL)
5. Multi-billing account via single dataset
```

## Authentication & Authorization

### AWS: IAM Roles with External ID

**Pattern:**
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
        "sts:ExternalId": "customer-specific-external-id"
      }
    }
  }]
}
```

**Why External ID?**
- Prevents confused deputy problem
- Customer-specific secret
- Required for all role assumptions

### Azure: Managed Identity or Service Principal

**Managed Identity (Recommended):**
```
Azure Policy Assignment
  └─ System-Assigned Managed Identity
       └─ RBAC Roles:
            - Reader (subscription)
            - Storage Blob Data Contributor (storage account)
            - Cost Management Contributor (optional)
```

**Service Principal (Alternative):**
```
Azure AD Application
  └─ Service Principal
       └─ Client Secret or Certificate
            └─ RBAC assignments same as above
```

### GCP: Workload Identity Federation (Keyless)

**Pattern:**
```
Workload Identity Pool
  └─ Workload Identity Provider (OIDC)
       └─ Service Account
            └─ IAM Roles:
                 - BigQuery Data Viewer
                 - Storage Object Viewer
                 - Billing Account Viewer
```

**Why Workload Identity?**
- No service account keys to manage
- Automatic key rotation
- Federates with external identity providers
- More secure than long-lived keys

## Storage Patterns

### Path Structures

**AWS:**
```
s3://tailpipe-dataexport-{account-id}/
  └─ dataexport/
       └─ {export-name}/
            └─ {date-range}/
                 └─ {manifest-files}
                 └─ {data-files}.csv.gz
```

**Azure:**
```
https://{storage-account}.blob.core.windows.net/
  └─ dataexport/
       └─ {prefix}/
            └─ subscriptions/
                 └─ {subscription-id}/
                      └─ {date-range}/
                           └─ {data-files}.csv
```

**GCP:**
```
BigQuery: {project-id}:billing_export
  └─ gcp_billing_export_v1_{billing-id}
  └─ gcp_billing_export_resource_v1_{billing-id}

Cloud Storage: gs://tailpipe-billing-export-{project-id}/
  └─ {billing-account-id}/
       └─ {date}/
            └─ {data-files}
```

## Scaling Considerations

### AWS

**Single Account:**
- S3 bucket in one region
- CUR export up to 10GB/month typical
- CloudWatch metrics per-instance

**Organizations (100+ accounts):**
- Management account holds all billing data
- StackSets deploy in parallel to child accounts
- S3 scales automatically
- Consider S3 Intelligent-Tiering for cost optimization

### Azure

**Single Subscription:**
- Storage account in one region
- Cost export ~100MB/month typical

**Enterprise (1000+ subscriptions):**
- **Policy Approach:** Scales automatically, policy engine handles parallelism
- **Automation Approach:** Rate limiting in runbook, processes 10 subs/minute
- Consider multiple storage accounts by region or business unit

### GCP

**Single Billing Account:**
- BigQuery dataset in one region
- ~1GB/month typical for standard export
- Detailed export can be 10x larger

**Multiple Billing Accounts:**
- All accounts export to same dataset
- Tables named by billing account ID
- BigQuery auto-scales
- Consider partitioned tables for large datasets (>100GB)

## Error Handling & Resilience

### AWS

**Setup Script:**
- Validates credentials before starting
- Checks for existing resources (idempotent)
- Atomic operations where possible
- Rollback on critical failures

**Runtime:**
- S3 eventual consistency (rare)
- Retry logic in Tailpipe ingestion
- CloudTrail audit log for debugging

### Azure

**Policy Approach:**
- Auto-remediation on non-compliance
- Retry logic built into Azure Policy engine
- Compliance scans every 24 hours
- Manual remediation tasks for immediate fix

**Automation Approach:**
- Explicit retry logic in PowerShell runbook
- Handles permission propagation delays (30s timeout)
- State file tracks known subscriptions
- Job history in Automation Account (30 days)

### GCP

**Setup Script:**
- Timeout handling for hanging commands (10s)
- Validates billing account status (OPEN vs CLOSED)
- Detects project lifecycle state (PENDING_DELETION)
- API enablement with retries

**Runtime:**
- BigQuery streaming inserts (at-least-once delivery)
- Tailpipe de-duplicates based on row IDs
- Cloud Audit Logs for debugging

## Cost Optimization

### AWS
- S3 Lifecycle policies (archive old CUR data to Glacier)
- CloudWatch metrics retention (reduce from default 15 months)
- Use us-east-1 region for lowest BCM Data Export costs

### Azure
- Use LRS (Locally Redundant Storage) instead of GRS
- Archive old exports with Cool/Archive tier
- Deploy storage accounts in low-cost regions (uksouth, westeurope)
- Policy-based automation eliminates Automation Account costs

### GCP
- Use standard storage class (not Nearline/Coldline)
- BigQuery partitioned tables reduce query costs
- Single project approach minimizes overhead
- us-central1 region typically lowest cost

## Monitoring & Observability

### AWS
- CloudTrail logs all API calls
- S3 bucket metrics (object count, size)
- BCM Data Export status API
- CloudWatch alarms on role assumptions

### Azure
- Activity Log for all operations
- Azure Monitor for policy compliance
- Storage account metrics (ingress, egress)
- Automation Account job history
- Application Insights (optional)

### GCP
- Cloud Audit Logs for all API calls
- BigQuery audit logs (queries, data access)
- Cloud Monitoring for service account usage
- Log-based metrics for billing export delays

## Future Enhancements

### Potential Improvements

1. **Terraform Modules** - IaC alternative to bash scripts
2. **Multi-Region** - Replicate exports to multiple regions
3. **Delta Exports** - Only new/changed data (reduce transfer costs)
4. **Real-time Streaming** - Event-driven ingestion vs daily batch
5. **Cost Anomaly Detection** - Alert on unusual patterns
6. **Tag Validation** - Enforce tagging standards

### Platform-Specific

**AWS:**
- EventBridge integration for real-time CUR updates
- S3 Batch Operations for bulk export management
- Support for AWS GovCloud

**Azure:**
- Resource Graph integration for asset tracking
- Support for Azure Stack
- Integration with Azure Cost Management Connectors

**GCP:**
- Cloud Functions for real-time processing
- Data Studio dashboards (templated)
- Support for Google Workspace billing

## Comparison with Alternatives

### AWS CloudHealth / CloudCheckr
- **Our approach:** Direct CUR access, no intermediary
- **Alternative:** SaaS platform with their own data copy

### Azure Cost Management + Exports
- **Our approach:** Automated policy-based deployment
- **Native:** Manual setup per subscription, no automation

### GCP Cloud Billing
- **Our approach:** Centralized BigQuery dataset
- **Native:** Per-project exports, no consolidation

## References

### AWS Documentation
- [BCM Data Exports](https://docs.aws.amazon.com/cur/latest/userguide/dataexports.html)
- [Cost and Usage Reports](https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html)
- [IAM Roles External ID](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html)
- [CloudFormation StackSets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/what-is-cfnstacksets.html)

### Azure Documentation
- [Azure Policy](https://docs.microsoft.com/azure/governance/policy/overview)
- [Cost Management Exports](https://docs.microsoft.com/azure/cost-management-billing/costs/tutorial-export-acm-data)
- [Automation Account](https://docs.microsoft.com/azure/automation/overview)
- [Managed Identities](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)

### GCP Documentation
- [Cloud Billing Export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [BigQuery](https://cloud.google.com/bigquery/docs)
- [Service Accounts](https://cloud.google.com/iam/docs/service-accounts)

---

**Document Version:** 1.0.0
**Last Updated:** October 2025
**Maintained By:** Tivarri Platform Team
