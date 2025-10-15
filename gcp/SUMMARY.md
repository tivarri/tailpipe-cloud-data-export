# GCP Setup for Tailpipe - Summary

## What Was Created

A complete GCP setup toolkit matching the quality and standards of the Azure and AWS implementations.

### Files Created

1. **setup-tailpipe.sh** - Main setup script (v1.2.0)
2. **cleanup-tailpipe.sh** - Complete cleanup tool (v1.0.0)
3. **README-SETUP.md** - Comprehensive documentation (v1.2.0)

### Recent Updates

**v1.2.0 (January 2025):**
- 🎉 **Multi-billing account support** - Major new feature
  - Select multiple billing accounts in a single setup run
  - Interactive selection: comma-separated numbers (1,2,3) or "all" for all OPEN accounts
  - All accounts export to the same BigQuery dataset
  - Each account creates uniquely named tables
  - Enhanced JSON output with per-account table mapping
- 📊 Table name mapping displayed during configuration
- 🔄 Fully backward compatible with single billing account setup

**v1.1.0 (January 2025):**
- ✨ Billing account selector with OPEN/CLOSED status table
- ✨ Region selector with recommended low-cost options
- ✨ Line editing support (backspace, arrow keys) for all prompts
- 🔧 Fixed billing enabled check (case sensitivity: True vs true)
- 🔧 Fixed project lifecycle state detection (DELETE_REQUESTED)
- 🔧 Added timeout handling for hanging gcloud commands (10s timeout)
- 🐛 Fixed grep failures with proper null handling
- 🎨 Improved error messages with actionable solutions
- 📝 Clarified manual billing export requirement (no gcloud command exists)
- ✅ Better validation and status checks throughout

### How GCP Differs from AWS/Azure

| Aspect | GCP | AWS | Azure |
|--------|-----|-----|-------|
| **Cost Data Export** | BigQuery dataset | S3 + CUR | Storage + Cost Exports |
| **Export Type** | BigQuery tables | CSV files | CSV files |
| **Authentication** | Service Account + Key | IAM Role + External ID | Service Principal + Secret |
| **Keyless Auth** | Workload Identity | AssumeRole | Managed Identity |
| **Monitoring** | Cloud Monitoring API | CloudWatch | Azure Monitor |
| **Organization** | Organization + Folders | AWS Organizations | Management Groups |
| **Cost Tracking** | Labels + Projects | Tags + Accounts | Tags + Subscriptions |

## Multi-Billing Account Support (v1.2.0)

### Overview

GCP organizations often have multiple billing accounts for different departments, projects, or environments. The setup script now supports configuring **multiple billing accounts** in a single run, with all billing data consolidated into one BigQuery dataset.

### How It Works

**Single Project, Multiple Billing Accounts:**
```
Organization
├── Billing Account 1 (Production)
│   ├── Project A
│   ├── Project B
│   └── → BigQuery Export → tailpipe-dataexport:billing_export
│
├── Billing Account 2 (Development)
│   ├── Project C
│   └── → BigQuery Export → tailpipe-dataexport:billing_export
│
└── Billing Account 3 (Sandbox)
    ├── Project D
    └── → BigQuery Export → tailpipe-dataexport:billing_export
```

**Data Consolidation:**
- All billing accounts export to **the same BigQuery dataset**
- Each billing account creates **unique tables** with the pattern:
  - `gcp_billing_export_v1_{billing_account_id}`
  - `gcp_billing_export_resource_v1_{billing_account_id}`
- One service account accesses all billing data
- No duplication of infrastructure

### Selection Options

**Interactive Mode:**
```bash
./setup-tailpipe.sh

# Prompts show:
# Select billing account(s):
#   - Enter a number (e.g., 2)
#   - Enter multiple numbers separated by commas (e.g., 1,2,3)
#   - Enter 'all' to configure all OPEN billing accounts
#   - Press Enter to manually enter ID(s)
```

**Non-Interactive Mode:**
```bash
# Single account (backward compatible)
BILLING_ACCOUNT="123456-789ABC-DEF012" ./setup-tailpipe.sh

# Multiple accounts (comma-separated)
BILLING_ACCOUNT="123456-789ABC-DEF012,234567-890BCD-EFG123,345678-901CDE-FGH234" ./setup-tailpipe.sh
```

### Use Cases

1. **Multi-Department Organizations:**
   - Finance department has separate billing account
   - Engineering department has separate billing account
   - Consolidate all costs into one Tailpipe dashboard

2. **Multi-Environment Setups:**
   - Production billing account
   - Staging billing account
   - Development billing account
   - Track costs across all environments

3. **Acquired Companies:**
   - Parent company billing account
   - Subsidiary A billing account
   - Subsidiary B billing account
   - Unified cost visibility

4. **Project-Based Billing:**
   - Each major project has dedicated billing account
   - Central finance team needs consolidated view
   - Tailpipe accesses all project costs

### Configuration Flow

**Setup creates:**
1. One GCP project (`tailpipe-dataexport`)
2. One BigQuery dataset (`billing_export`)
3. One GCS bucket (for backup/storage)
4. One service account (with access to all data)

**Manual configuration per billing account:**
1. Go to Console → Billing → Billing Export
2. Point each billing account to the **same dataset**
3. Each account automatically creates its own tables

**Result:**
- Dataset contains tables from all billing accounts
- Service account can query all tables
- Tailpipe sees consolidated multi-account costs

### JSON Output Example

```json
{
  "billingAccountId": [
    "123456-789ABC-DEF012",
    "234567-890BCD-EFG123",
    "345678-901CDE-FGH234"
  ],
  "billingExport": {
    "type": "BigQuery",
    "dataset": "tailpipe-dataexport:billing_export",
    "accountCount": 3,
    "tables": {
      "123456-789ABC-DEF012": {
        "standard": "gcp_billing_export_v1_123456_789ABC_DEF012",
        "detailed": "gcp_billing_export_resource_v1_123456_789ABC_DEF012"
      },
      "234567-890BCD-EFG123": {
        "standard": "gcp_billing_export_v1_234567_890BCD_EFG123",
        "detailed": "gcp_billing_export_resource_v1_234567_890BCD_EFG123"
      },
      "345678-901CDE-FGH234": {
        "standard": "gcp_billing_export_v1_345678_901CDE_FGH234",
        "detailed": "gcp_billing_export_resource_v1_345678_901CDE_FGH234"
      }
    }
  }
}
```

### Benefits

✅ **Cost Savings:**
- No duplicate infrastructure for each billing account
- Single service account, single project

✅ **Simplified Management:**
- One setup process for all billing accounts
- Centralized billing data access

✅ **Easy Onboarding:**
- Add new billing accounts to existing setup
- No need to recreate infrastructure

✅ **Backward Compatible:**
- Single billing account setup still works
- JSON output adapts automatically

## GCP Architecture

### Resources Created

```
GCP Organization (optional)
└── Billing Account: 123456-789ABC-DEF012
    └── BigQuery Export
        ↓
Project: tailpipe-dataexport
├── BigQuery Dataset: billing_export
│   ├── gcp_billing_export_v1_{billing_account}
│   └── gcp_billing_export_resource_v1_{billing_account}
│
├── GCS Bucket: tailpipe-billing-export-{project}
│   └── Lifecycle: Auto-delete after 90 days
│
├── Service Account: tailpipe-connector
│   ├── Key: tailpipe-gcp-key-{project}.json
│   ├── Roles (Project):
│   │   ├── bigquery.dataViewer
│   │   ├── bigquery.jobUser
│   │   ├── storage.objectViewer
│   │   ├── monitoring.viewer
│   │   └── compute.viewer
│   └── Roles (Organization):
│       ├── billing.viewer
│       └── monitoring.viewer
│
└── Workload Identity Pool: tailpipe-pool (optional)
    └── OIDC Provider → Service Account
```

### Data Access

**Cost Data (BigQuery):**
- Daily exports from billing account
- Standard usage table (aggregated)
- Detailed usage table (resource-level)
- Queryable via BigQuery API

**Monitoring Data (Cloud Monitoring):**
- Compute Engine metrics (CPU, disk, network)
- GKE container metrics
- Cloud Functions metrics
- Custom metrics

**Authentication:**
- **Option 1**: Service Account Key (JSON file)
  - Traditional approach
  - Simple setup
  - Requires key management

- **Option 2**: Workload Identity Federation (recommended)
  - Keyless authentication
  - OIDC-based
  - More secure
  - No key rotation needed

## Key Features

### Setup Script (setup-tailpipe.sh)

✅ **All Standard Features:**
- Dry-run mode
- Interactive & non-interactive modes
- Colored output
- Phase-based execution
- Post-deployment validation
- JSON configuration output
- Debug mode
- Force mode

✅ **GCP-Specific Features:**
- Auto-detects organization
- Interactive billing account selector (OPEN/CLOSED status)
- **Multi-billing account support** (single or multiple accounts)
  - Select multiple accounts: comma-separated (1,2,3) or "all"
  - All accounts export to same BigQuery dataset
  - Per-account table name mapping
- Interactive region selector (recommended regions)
- Creates or uses existing project
- Detects project lifecycle state (pending deletion)
- Enables required APIs automatically
- Provides manual billing export instructions (no gcloud command available)
- Sets up Workload Identity (optional)
- Grants minimal required permissions
- Creates service account key
- Validates all resources
- Timeout handling for hanging commands
- Line editing support for all prompts

### Cleanup Script (cleanup-tailpipe.sh)

✅ **Safe Deletion:**
- Dry-run preview
- Multi-level confirmations
- Selective cleanup (KEEP_DATA, KEEP_PROJECT)
- Removes all IAM permissions
- Deletes Workload Identity pools
- Cleans up service account keys
- Optional project deletion

### Documentation (README-SETUP.md)

✅ **Comprehensive Guide:**
- Quick start instructions
- All configuration options
- Troubleshooting guide
- Architecture diagrams
- Security considerations
- Advanced usage patterns
- Comparison with AWS/Azure

## Usage Examples

### Setup

**Interactive:**
```bash
./setup-tailpipe.sh
```

**Preview:**
```bash
DRY_RUN=1 ./setup-tailpipe.sh
```

**Automated:**
```bash
PROJECT_ID=tailpipe-export \
BILLING_ACCOUNT=123456-789ABC-DEF012 \
REGION=us-central1 \
FORCE=1 \
./setup-tailpipe.sh
```

### Cleanup

**Interactive:**
```bash
./cleanup-tailpipe.sh
```

**Keep data:**
```bash
KEEP_DATA=1 ./cleanup-tailpipe.sh
```

**Keep project:**
```bash
KEEP_PROJECT=1 ./cleanup-tailpipe.sh
```

## Important Notes

### Billing Export Configuration

⚠️ **Manual step required:**

Google Cloud does not provide a command-line tool (`gcloud`) for configuring BigQuery billing exports. This must be done manually through the Console (one-time setup, ~2 minutes).

**Why manual?** The `gcloud billing accounts update` command does not exist. After extensive testing, we confirmed that billing export configuration can only be done via:
- Google Cloud Console UI (recommended)
- Terraform (for infrastructure-as-code)
- Internal/undocumented APIs (not reliable)

**Setup steps:**

1. Go to: https://console.cloud.google.com/billing/{billing-account-id}
2. Click "Billing Export" → "BigQuery Export"
3. Click "EDIT SETTINGS"
4. Configure:
   - Project: `tailpipe-dataexport` (or your project)
   - Dataset: `billing_export`
5. Enable **all three export types**:
   - ✓ Standard usage cost (daily cost data)
   - ✓ Detailed usage cost (resource-level data)
   - ✓ Pricing data (SKU pricing information)
6. Click "Save"

The script automatically creates and configures everything else (project, dataset, bucket, service account, IAM, Workload Identity).

### Service Account Key Security

🔐 **Keep the key file secure:**

The service account key file (`tailpipe-gcp-key-{project}.json`) provides full access to:
- All billing data in BigQuery
- All objects in GCS bucket
- All monitoring metrics

**Best practices:**
- Store key securely (encrypted vault, secrets manager)
- Rotate keys regularly
- Consider using Workload Identity instead (no keys)
- Never commit keys to version control

### Data Latency

📊 **Billing data timing:**
- First export appears: 24-48 hours after setup
- Updates: Daily (may take up to 48 hours)
- Historical data: Included from billing account creation date

### Costs

💰 **GCP costs for Tailpipe setup:**
- BigQuery: Free tier (1 TB queries/month), then ~$5/TB
- GCS bucket: ~$0.02/GB/month (Standard storage)
- Project: No cost
- Service account: No cost
- Data transfer: Usually negligible
- Monitoring API calls: Free tier (1M requests/month)

**Typical monthly cost: $5-20** (depends on data volume)

## Cross-Platform Summary

You now have unified, professional setup toolkits for all three major cloud providers:

| Feature | Azure | AWS | GCP |
|---------|-------|-----|-----|
| ✅ Dry-run mode | Yes | Yes | Yes |
| ✅ Non-interactive | Yes | Yes | Yes |
| ✅ Colored output | Yes | Yes | Yes |
| ✅ Validation | Yes | Yes | Yes |
| ✅ Cleanup script | Yes | Yes | Yes |
| ✅ JSON output | Yes | Yes | Yes |
| ✅ Documentation | Yes | Yes | Yes |
| ✅ CI/CD ready | Yes | Yes | Yes |
| ✅ Debug mode | Yes | Yes | Yes |
| ✅ Version tracking | Yes | Yes | Yes |

All three toolkits follow the same patterns and provide consistent customer experience!

## Next Steps

1. **Test the setup** (dry-run mode):
   ```bash
   DRY_RUN=1 ./setup-tailpipe.sh
   ```

2. **Review the output** to understand what will be created

3. **Run actual setup**:
   ```bash
   PROJECT_ID=tailpipe-test \
   BILLING_ACCOUNT=your-billing-account \
   ./setup-tailpipe.sh
   ```

4. **Configure billing export manually** (if needed)

5. **Save the JSON output** and service account key

6. **Provide to Tailpipe** for onboarding

7. **Clean up test resources**:
   ```bash
   PROJECT_ID=tailpipe-test \
   FORCE=1 \
   ./cleanup-tailpipe.sh
   ```

## Support

For issues or questions:
- Check README-SETUP.md troubleshooting section
- Enable debug mode: `DEBUG=1 ./setup-tailpipe.sh`
- Review GCP documentation links in README
- Contact Tailpipe support with configuration JSON

## Version History

- **Setup script: v1.2.0** (January 2025)
  - Added multi-billing account support (select multiple or "all" OPEN accounts)
  - Enhanced JSON output with per-account table mapping
  - Backward compatible with single billing account setup

- **Setup script: v1.1.0** (January 2025)
  - Added interactive billing account and region selectors
  - Fixed billing enabled check and project lifecycle detection
  - Added timeout handling and line editing support
  - Clarified manual billing export requirement

- **Cleanup script: v1.0.0** (January 2025)
  - Initial release

- **Created:** January 2025
- **Last Updated:** January 2025
