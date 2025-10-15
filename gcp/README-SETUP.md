# Tailpipe GCP Setup

Automated toolkit for configuring Google Cloud Platform billing export for Tailpipe.

**Version:** 1.2.0 | **Status:** Production Ready

## Quick Start

```bash
# Interactive setup with prompts
./setup-tailpipe.sh

# Automated setup
PROJECT_ID=tailpipe-export \
BILLING_ACCOUNT=123456-789ABC-DEF012 \
REGION=us-central1 \
./setup-tailpipe.sh

# Preview without changes
DRY_RUN=1 ./setup-tailpipe.sh
```

## What It Does

✅ **Automated:**
- Creates GCP project with billing linked
- Creates BigQuery dataset for billing data
- Creates GCS bucket for storage
- Creates service account with least-privilege IAM
- Configures Workload Identity Federation (keyless auth)
- Validates all resources

⚠️ **Manual Step (2 minutes):**
- Configure billing export in Console (gcloud command doesn't exist)

## Interactive Features

- 📋 **Billing account selector** - Numbered table showing OPEN/CLOSED status
- 🔢 **Multi-billing account support** - Select multiple accounts or "all" OPEN accounts
- 🌍 **Region selector** - Recommended low-cost regions
- ⌨️ **Line editing** - Backspace and arrow keys work in all prompts
- 🛡️ **Smart validation** - Detects closed accounts, pending deletion, etc.
- 💡 **Helpful errors** - Actionable solutions for common issues

## Documentation

- **[README-SETUP.md](README-SETUP.md)** - Complete setup guide
- **[SUMMARY.md](SUMMARY.md)** - Architecture and features overview

## Files

| File | Description | Version |
|------|-------------|---------|
| `setup-tailpipe.sh` | Main setup script | v1.2.0 |
| `cleanup-tailpipe.sh` | Resource cleanup tool | v1.0.0 |
| `README-SETUP.md` | Full documentation | v1.2.0 |
| `SUMMARY.md` | Overview & architecture | v1.2.0 |

## Prerequisites

- **gcloud CLI** installed and authenticated
- **Billing Account Administrator** role (for manual billing export step)
- **Project Creator** role (or existing project)

```bash
# Check gcloud
gcloud version

# Authenticate
gcloud auth login
```

## Common Commands

```bash
# Setup with custom region
REGION=europe-west1 ./setup-tailpipe.sh

# Setup with multiple billing accounts (comma-separated)
BILLING_ACCOUNT="123456-789ABC-DEF012,234567-890BCD-EFG123" ./setup-tailpipe.sh

# Interactive setup - select "all" to configure all OPEN billing accounts
./setup-tailpipe.sh

# Preview cleanup
DRY_RUN=1 ./cleanup-tailpipe.sh

# Cleanup keeping data
KEEP_DATA=1 ./cleanup-tailpipe.sh

# Enable debug mode
DEBUG=1 ./setup-tailpipe.sh
```

## Output

The script provides a JSON configuration with all resource details:

**Single billing account:**
```json
{
  "platform": "gcp",
  "billingAccountId": "123456-789ABC-DEF012",
  "project": {
    "id": "tailpipe-dataexport",
    "number": "987654321098",
    "region": "us-central1"
  },
  "storage": {
    "bucket": "tailpipe-billing-export-tailpipe-dataexport",
    "dataset": "billing_export"
  },
  "serviceAccount": {
    "email": "tailpipe-connector@tailpipe-dataexport.iam.gserviceaccount.com",
    "keyFile": "tailpipe-gcp-key-tailpipe-dataexport.json"
  },
  "billingExport": {
    "type": "BigQuery",
    "dataset": "tailpipe-dataexport:billing_export",
    "accountCount": 1,
    "tables": {
      "123456-789ABC-DEF012": {
        "standard": "gcp_billing_export_v1_123456_789ABC_DEF012",
        "detailed": "gcp_billing_export_resource_v1_123456_789ABC_DEF012"
      }
    }
  }
}
```

**Multiple billing accounts:**
```json
{
  "platform": "gcp",
  "billingAccountId": ["123456-789ABC-DEF012", "234567-890BCD-EFG123"],
  "billingExport": {
    "type": "BigQuery",
    "dataset": "tailpipe-dataexport:billing_export",
    "accountCount": 2,
    "tables": {
      "123456-789ABC-DEF012": {
        "standard": "gcp_billing_export_v1_123456_789ABC_DEF012",
        "detailed": "gcp_billing_export_resource_v1_123456_789ABC_DEF012"
      },
      "234567-890BCD-EFG123": {
        "standard": "gcp_billing_export_v1_234567_890BCD_EFG123",
        "detailed": "gcp_billing_export_resource_v1_234567_890BCD_EFG123"
      }
    }
  }
}
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Script hangs** | Timeout handling included (10s), or try `gcloud components update` |
| **Billing account closed** | Select OPEN billing account from interactive menu |
| **Project pending deletion** | Use different project ID or wait 30 days |
| **Permission denied** | Ensure Billing Account Administrator role |
| **API not enabled** | Script auto-enables required APIs |

See [README-SETUP.md](README-SETUP.md) for detailed troubleshooting.

## Changelog

### v1.2.0 (October 2025)

**New Features:**
- 🎉 **Multi-billing account support** - Configure multiple billing accounts in a single run
  - Select multiple accounts interactively (comma-separated numbers: 1,2,3)
  - Select all OPEN accounts with "all" option
  - All accounts export to the same BigQuery dataset
  - Each account creates uniquely named tables
- Enhanced JSON output with per-account table mapping

**Improvements:**
- Backward compatible with single billing account setup
- Clear instructions for configuring each billing account
- Table name mapping displayed during setup

### v1.1.0 (October 2025)

**New Features:**
- Interactive billing account selector with status indicators
- Interactive region selector with recommendations
- Line editing support (backspace, arrows) for all inputs

**Bug Fixes:**
- Fixed billing enabled check (case sensitivity)
- Fixed project lifecycle state detection
- Added timeout handling for hanging commands
- Fixed grep failures in error handling

**Documentation:**
- Clarified manual billing export requirement
- Added actionable error messages
- Improved troubleshooting guide

### v1.0.0 (October 2025)
- Initial release

## Support

- 📖 Full docs: [README-SETUP.md](README-SETUP.md)
- 🏗️ Architecture: [SUMMARY.md](SUMMARY.md)
- 🐛 Debug mode: `DEBUG=1 ./setup-tailpipe.sh`
- 📧 Tailpipe support: Include JSON output from script

## License

Copyright © 2025 Tivarri Limited. All rights reserved.
