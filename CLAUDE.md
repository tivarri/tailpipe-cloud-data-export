# tailpipe-cloud-data-export - Multi-Cloud Cost Data Export Setup

Shell scripts (Bash)

Automated setup scripts for configuring cost data exports from AWS, Azure, and GCP into Tailpipe. These are one-time or periodic setup utilities, not a running service.

## Usage

Each cloud provider has dedicated setup and cleanup scripts. Review scripts before executing — they modify cloud account configurations.

### AWS

- Cost and Usage Reports (CUR) setup
- BCM Data Export configuration
- S3 bucket creation for cost data
- CloudFormation StackSets for multi-account

### Azure

- Storage account setup
- Cost Management export configuration
- Service principal creation
- Azure Policy for governance

### GCP

- BigQuery dataset creation
- Cloud Storage for billing export
- Service account setup
- Workload Identity Federation

## Prerequisites

- AWS CLI v2 (`aws`)
- Google Cloud CLI (`gcloud`)
- Azure CLI (`az`)
- Appropriate admin permissions in each cloud account

## Safety

- Scripts modify cloud account billing and export configurations
- Review each script before executing
- Some operations create resources that incur costs (S3 buckets, BigQuery datasets)
- Cleanup scripts are provided to reverse changes
- All scripts are designed to be idempotent where possible

## Coding Conventions

- Bash scripts with `set -euo pipefail`
- Clear documentation in script headers
- Consistent argument parsing patterns
