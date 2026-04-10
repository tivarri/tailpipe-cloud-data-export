# Tailpipe Cloud Data Export

Automated infrastructure setup for Tailpipe carbon emissions analytics across AWS, Azure, and Google Cloud Platform.

[![License](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-AWS%20%7C%20Azure%20%7C%20GCP-blue.svg)]()

## Overview

This repository contains automated scripts and infrastructure-as-code for setting up cost data exports from major cloud providers to the Tailpipe carbon emissions analytics platform. Each cloud provider implementation includes:

- ✅ **Automated setup scripts** - One-command deployment
- ✅ **Cleanup utilities** - Safe resource removal
- ✅ **Multi-account support** - Organizations and standalone accounts
- ✅ **Security best practices** - Least-privilege IAM, external ID protection
- ✅ **Comprehensive documentation** - Setup guides and troubleshooting

## Quick Start

Choose your cloud provider:

| Cloud Provider | Setup Command | Documentation |
|----------------|---------------|---------------|
| **AWS** | `cd aws && ./setup-tailpipe.sh` | [AWS Setup Guide](aws/README-SETUP.md) |
| **Azure** | `cd azure && ./setup-tailpipe.sh` | [Azure Setup Guide](azure/README-SETUP.md) |
| **GCP** | `cd gcp && ./setup-tailpipe.sh` | [GCP Setup Guide](gcp/README-SETUP.md) |

## What Gets Created

### AWS
- S3 bucket for Cost and Usage Reports (CUR)
- BCM Data Export with hourly granularity
- IAM role for Tailpipe connector (with External ID)
- CloudFormation StackSets for AWS Organizations (optional)

### Azure
- Storage account for cost export data
- Cost Management exports (monthly/daily)
- Service principal or managed identity
- Azure Policy for automatic deployment (recommended)
- Automation Account with PowerShell runbooks (alternative)

### GCP
- BigQuery dataset for billing data
- Cloud Storage bucket
- Service account with Workload Identity Federation
- Multi-billing account support

## Repository Structure

```
tailpipe-cloud-data-export/
├── README.md                    # This file
├── .gitignore                   # Excludes sensitive files
│
├── aws/                         # AWS automation
│   ├── README-SETUP.md          # Complete AWS guide
│   ├── setup-tailpipe.sh        # Main setup script
│   ├── cleanup-tailpipe.sh      # Cleanup script
│   ├── iam-policy-single-account.json
│   └── iam-policy-organization.json
│
├── azure/                       # Azure automation
│   ├── README-SETUP.md          # Complete Azure guide
│   ├── setup-tailpipe.sh        # Unified setup script
│   ├── cleanup-tailpipe.sh      # Cleanup script
│   ├── custom-role-tailpipe-setup.json
│   └── custom-role-tailpipe-setup-csp.json
│
├── gcp/                         # GCP automation
│   ├── README-SETUP.md          # Complete GCP guide
│   ├── setup-tailpipe.sh        # Main setup script
│   └── cleanup-tailpipe.sh      # Cleanup script
│
└── docs/                        # Cross-cloud documentation
    ├── architecture.md          # Architecture overview
    ├── security.md              # Security best practices
    ├── troubleshooting.md       # Common issues
    └── operator-permissions.md  # Operator permission policies
```

## Features

### Common Features (All Platforms)

- 🚀 **One-command setup** - Interactive or fully automated
- 🔍 **Dry-run mode** - Preview changes without executing
- 🔐 **Security hardened** - Least-privilege IAM, external IDs, key rotation
- 📊 **Validation built-in** - Verifies all resources after creation
- 🧹 **Safe cleanup** - Remove all resources with confirmation
- 📝 **JSON output** - Configuration summary for Tailpipe onboarding
- 🎯 **Error handling** - Comprehensive error messages and solutions
- 📖 **Extensive docs** - Step-by-step guides and troubleshooting

### Platform-Specific Features

#### AWS
- Automatic account type detection (Management vs Standalone)
- CloudFormation StackSets for AWS Organizations
- Support for multiple AWS accounts
- BCM Data Export with hourly granularity

#### Azure
- Three implementation approaches:
  - **Azure Policy** (Recommended) - Automatic deployment
  - **Automation Account** - Scheduled PowerShell runbooks
  - **CLI Scripts** - Manual or ad-hoc deployment
- Management group and subscription-level deployment
- Automatic compliance tracking and remediation
- Cross-subscription export support

#### GCP
- Multi-billing account support
- Interactive billing account selector
- Workload Identity Federation (keyless authentication)
- BigQuery and Cloud Storage integration

## Prerequisites

### General
- Command-line access (bash shell)
- Administrative access to cloud accounts
- External ID from Tailpipe (provided during onboarding)

### AWS
- AWS CLI v2.x or later
- `jq` for JSON parsing
- AdministratorAccess or equivalent
- AWS Organizations access (for multi-account)

### Azure
- Azure CLI 2.30.0 or later
- Contributor role or higher
- Policy Assignment permissions (for Azure Policy approach)
- PowerShell 7+ (for Automation Account approach)

### GCP
- gcloud CLI
- Billing Account Administrator role
- Project Creator role or existing project

## Installation

### Quick Setup (Interactive Mode)

```bash
# AWS
cd aws
./setup-tailpipe.sh

# Azure
cd azure
./setup-tailpipe.sh

# GCP
cd gcp
./setup-tailpipe.sh
```

### Automated Setup (CI/CD)

```bash
# AWS
REGION=us-east-1 EXTERNAL_ID=your-external-id aws/setup-tailpipe.sh

# Azure
LOCATION=uksouth MANAGEMENT_GROUP_ID=mg-prod azure/setup-tailpipe.sh

# GCP
PROJECT_ID=tailpipe-export BILLING_ACCOUNT=123456-789ABC-DEF012 gcp/setup-tailpipe.sh
```

### Dry Run (Preview Only)

```bash
# Preview changes without executing
DRY_RUN=1 aws/setup-tailpipe.sh
DRY_RUN=1 azure/setup-tailpipe.sh
DRY_RUN=1 gcp/setup-tailpipe.sh
```

## Configuration

All scripts support environment variable configuration for non-interactive deployment. See individual platform documentation for details:

- [AWS Environment Variables](aws/README-SETUP.md#environment-variables)
- [Azure Environment Variables](azure/README-SETUP.md)
- [GCP Environment Variables](gcp/README-SETUP.md#common-commands)

## Security

### Authentication
- **AWS**: IAM role assumption with External ID
- **Azure**: Managed identity or service principal
- **GCP**: Service account with Workload Identity Federation (keyless)

### Least Privilege
All implementations follow least-privilege principles:
- Read-only access to cost/billing data
- No write access to infrastructure
- Scoped permissions (no wildcards)

### Audit Trail
- AWS: CloudTrail logging
- Azure: Activity Log and Azure Monitor
- GCP: Cloud Audit Logs

### Secrets Management
- External IDs treated as secrets
- No long-term credentials stored
- Service account keys excluded from git (via .gitignore)

## Cleanup & Removal

Remove all Tailpipe resources:

```bash
# AWS
cd aws && ./cleanup-tailpipe.sh

# Azure
cd azure && ./cleanup-tailpipe.sh

# GCP
cd gcp && ./cleanup-tailpipe.sh
```

All cleanup scripts support dry-run mode and selective deletion:

```bash
# Preview cleanup
DRY_RUN=1 ./cleanup-tailpipe.sh

# Keep IAM resources
KEEP_ROLE=1 ./cleanup-tailpipe.sh

# Keep data
KEEP_DATA=1 ./cleanup-tailpipe.sh
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| **Permission denied** | Verify IAM/RBAC roles and permissions |
| **API not enabled** | Scripts auto-enable most APIs; manual enable may be required |
| **Resource already exists** | Scripts detect and skip existing resources |
| **Timeout errors** | Check network connectivity and cloud provider status |

See platform-specific troubleshooting guides:
- [AWS Troubleshooting](aws/README-SETUP.md#troubleshooting)
- [Azure Troubleshooting](azure/README-SETUP.md)
- [GCP Troubleshooting](gcp/README-SETUP.md#troubleshooting)

### Debug Mode

Enable verbose logging:

```bash
DEBUG=1 ./setup-tailpipe.sh
```

## Documentation

### Platform-Specific Guides
- **[AWS Setup Guide](aws/README-SETUP.md)** - Complete AWS implementation guide
- **[Azure Setup Guide](azure/README-SETUP.md)** - Azure CLI and unified script guide
- **[GCP Setup Guide](gcp/README-SETUP.md)** - Complete GCP implementation guide

### Cross-Platform Documentation
- [Architecture Overview](docs/architecture.md) - Cross-cloud architecture patterns
- [Security Best Practices](docs/security.md) - Security considerations
- [Troubleshooting Guide](docs/troubleshooting.md) - Common issues across platforms

## Contributing

This repository is maintained by Tivarri Limited for Tailpipe platform integrations.

For issues or feature requests:
1. Check platform-specific troubleshooting guides
2. Enable debug mode: `DEBUG=1 ./setup-tailpipe.sh`
3. Contact Tailpipe support with:
   - Platform (AWS/Azure/GCP)
   - Script version (shown in script output)
   - Error messages and logs
   - JSON configuration output (if available)

## Version History

### AWS
- **v1.0.0** - Initial release with Organizations support

### Azure
- **v2.0.0** - Unified setup script with three implementation approaches
- **v1.0.0** - Initial CLI scripts and policy definitions

### GCP
- **v1.2.0** - Multi-billing account support
- **v1.1.0** - Interactive selectors and line editing
- **v1.0.0** - Initial release

## License

Copyright © 2025 Tivarri Limited. All rights reserved.

This software is proprietary and confidential. Unauthorized copying, distribution, or use is strictly prohibited.

## Support

For Tailpipe platform support:
- 📧 Email: support@tailpipe.ai
- 📖 Methodology: https://tailpipe.ai/methodology
- 🌐 Website: https://tailpipe.ai
