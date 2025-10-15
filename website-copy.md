# Tailpipe Cloud Integration Setup

Website copy for tailpipe.ai

---

## Main Landing Page

### Cloud Data Integration

**Connect Your Cloud Accounts in Minutes**

Tailpipe seamlessly integrates with AWS, Azure, and Google Cloud Platform to provide accurate carbon emissions analytics. Our automated setup scripts handle all the technical complexity, creating secure, read-only access to your cloud cost data.

**Why Our Approach?**

- ✅ **Automated Setup** - One command deploys all required infrastructure
- ✅ **Security First** - Read-only access with least-privilege permissions
- ✅ **Open Source Scripts** - Full transparency, review every line of code
- ✅ **No Agents Required** - Native cloud integrations, no software to install
- ✅ **Multi-Account Support** - Works with AWS Organizations, Azure Management Groups, and GCP billing accounts

**Get Started:** Choose your cloud provider below to begin setup.

| Cloud Provider | Status | Action |
|----------------|--------|--------|
| **AWS** | 🟢 Production Ready | [Get Started Now →](#aws-setup) |
| **Azure** | 🟡 Beta Program | [Request Access →](mailto:sales@tailpipe.ai?subject=Azure%20Beta%20Access%20Request) |
| **GCP** | 🟡 Beta Program | [Request Access →](mailto:sales@tailpipe.ai?subject=GCP%20Beta%20Access%20Request) |

---

## AWS Setup Page

---
✅ **Production Ready** - Fully supported with 99.9% SLA
---

### AWS Integration Setup

**Automated Infrastructure Deployment for AWS**

Connect your AWS account to Tailpipe using our fully automated setup script. The script creates secure, read-only access to your AWS Cost and Usage Reports and CloudWatch metrics.

#### What Gets Created

Our setup script automatically provisions:

1. **S3 Bucket** - Stores your AWS Cost and Usage Report data
2. **Cost and Usage Report Export** - Hourly billing data with all cost allocation tags
3. **IAM Role** - Least-privilege, read-only access with External ID protection
4. **CloudFormation StackSets** (AWS Organizations only) - Deploys CloudWatch access to child accounts

#### Security & Privacy

- **Read-Only Access** - Cannot modify any AWS resources
- **External ID Protection** - Prevents unauthorized access (confused deputy attack prevention)
- **No Long-Term Credentials** - Uses IAM role assumption
- **Audit Trail** - All access logged in CloudTrail
- **You Stay in Control** - Remove access anytime with our cleanup script

#### Prerequisites

Before you begin, ensure you have:

- AWS CLI installed and configured ([Installation Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- `jq` command-line tool ([Installation Guide](https://stedolan.github.io/jq/download/))
- AWS account with Administrator access
- Your Tailpipe External ID (provided during onboarding)

#### Quick Start

**1. Download the Setup Script**

```bash
# Clone the repository (requires GitHub access)
git clone https://github.com/tivarri/tailpipe-cloud-data-export.git
cd tailpipe-cloud-data-export/aws
```

**2. Run the Setup Script**

```bash
# Interactive mode (recommended for first-time setup)
./setup-tailpipe.sh

# Or automated mode (for CI/CD)
REGION=us-east-1 EXTERNAL_ID=your-external-id ./setup-tailpipe.sh

# Preview changes first (dry-run)
DRY_RUN=1 ./setup-tailpipe.sh
```

**3. Share Configuration with Tailpipe**

The script outputs a JSON configuration containing your IAM role ARN and S3 bucket details. Share this with your Tailpipe account manager.

#### What Happens Next?

- AWS begins generating Cost and Usage Reports (first report within 24 hours)
- Tailpipe connects using the IAM role you created
- Your carbon emissions data appears in Tailpipe within 24-48 hours

#### Estimated Time

- **Management Account (without Organizations):** 5-10 minutes
- **Management Account (with AWS Organizations):** 10-15 minutes
- **Standalone Account:** 5 minutes

#### Resources

- **[Complete Setup Guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/aws/README-SETUP.md)** - Detailed documentation with troubleshooting
- **[Setup Script](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/aws/setup-tailpipe.sh)** - Main automation script
- **[Cleanup Script](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/aws/cleanup-tailpipe.sh)** - Remove all resources

#### Need Help?

Contact our support team at [support@tailpipe.ai](mailto:support@tailpipe.ai) or consult our [troubleshooting guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/troubleshooting.md#aws-issues).

---

## Azure Setup Page

---
🔬 **Beta Program - Request Access**

Azure integration is currently in beta testing. We're working with select customers to refine the experience before general availability.

**What Beta Means:**
- ✅ Fully functional scripts and automation
- ✅ Technical support available
- ⚠️ Configuration may change based on feedback
- ⚠️ Uses UAT environment during beta period

**To Request Access:** Contact [sales@tailpipe.ai](mailto:sales@tailpipe.ai) or your Tailpipe account manager.

*Estimated General Availability: Q4 2025*

---

### Azure Integration Setup

**Automated Infrastructure Deployment for Azure**

Connect your Azure subscriptions to Tailpipe using our automated setup scripts. Choose from three deployment methods based on your organization's needs.

#### Deployment Methods

**Azure Policy (Recommended)**

Best for organizations with multiple subscriptions. Automatically deploys cost exports to all subscriptions within a management group.

- ✅ Automatic deployment to new subscriptions
- ✅ Built-in compliance tracking
- ✅ Self-healing (auto-remediation)
- ✅ No custom code maintenance

**Automation Account with PowerShell Runbook**

Scheduled automation that creates cost exports across subscriptions. Provides explicit control and detailed logging.

- ✅ Daily scheduled execution
- ✅ Detailed job history
- ✅ Handles permission propagation delays
- ✅ State tracking for new subscriptions

**CLI Scripts (Manual)**

One-time or ad-hoc deployment for single subscriptions or testing.

- ✅ Quick setup for single subscription
- ✅ Useful for troubleshooting
- ✅ No persistent infrastructure

#### What Gets Created

Our setup scripts automatically provision:

1. **Storage Account** - Stores your Azure cost export data
2. **Cost Management Exports** - Daily cost and usage data
3. **Azure Policy** (Policy method) - Automatic deployment and compliance
4. **Automation Account** (Runbook method) - Scheduled execution engine
5. **Managed Identity** - Secure, keyless authentication

#### Security & Privacy

- **Read-Only Access** - Cannot modify any Azure resources
- **Managed Identity** - No credentials to manage or rotate
- **Least Privilege** - Minimal permissions required
- **Audit Trail** - All access logged in Activity Log
- **You Stay in Control** - Remove access anytime with our cleanup script

#### Prerequisites

Before you begin, ensure you have:

- Azure CLI installed and configured ([Installation Guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli))
- Azure subscription with Contributor access
- Policy Assignment permissions (for Azure Policy approach)
- PowerShell 7+ (for Automation Account approach)

#### Quick Start

**Azure Policy Approach (Recommended)**

```bash
# Clone the repository
git clone https://github.com/tivarri/tailpipe-cloud-data-export.git
cd tailpipe-cloud-data-export/azure/automation

# Configure variables in deploy-policy.sh:
# - MANAGEMENT_GROUP_ID
# - STORAGE_ACCOUNT_RESOURCE_ID
# - EXPORT_NAME_PREFIX

# Deploy policy
./deploy-policy.sh
```

**Automation Account Approach**

```bash
cd tailpipe-cloud-data-export/azure/automation

# Review and configure variables in setup_tailpipe_automation.sh
./setup_tailpipe_automation.sh
```

**CLI Scripts (Single Subscription)**

```bash
cd tailpipe-cloud-data-export/azure/cli

# Set region
export LOCATION=uksouth

# Deploy
./deploy_tailpipe_dataexport.sh
```

#### What Happens Next?

- Azure begins generating cost exports (first export within 24 hours)
- Tailpipe connects using the managed identity or service principal
- Your carbon emissions data appears in Tailpipe within 24-48 hours

#### Estimated Time

- **Azure Policy Deployment:** 15-20 minutes (plus 24 hours for automatic compliance)
- **Automation Account Setup:** 20-30 minutes
- **CLI Single Subscription:** 5-10 minutes

#### Resources

- **[Complete Setup Guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/azure/README-SETUP.md)** - Detailed documentation
- **[Azure Policy Guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/azure/automation/README-policy.md)** - Policy implementation details
- **[Development Guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/azure/CLAUDE.md)** - Advanced configuration
- **[Setup Script](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/azure/setup-tailpipe.sh)** - Unified automation script
- **[Cleanup Script](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/azure/cleanup-tailpipe.sh)** - Remove all resources

#### Need Help?

Contact our support team at [support@tailpipe.ai](mailto:support@tailpipe.ai) or consult our [troubleshooting guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/troubleshooting.md#azure-issues).

---

## GCP Setup Page

---
🔬 **Beta Program - Request Access**

GCP integration is currently in beta testing. We're working with select customers to refine the experience before general availability.

**What Beta Means:**
- ✅ Multi-billing account support
- ✅ Technical support available
- ⚠️ Configuration may change based on feedback
- ⚠️ Uses UAT environment during beta period

**To Request Access:** Contact [sales@tailpipe.ai](mailto:sales@tailpipe.ai) or your Tailpipe account manager.

*Estimated General Availability: Q1 2026*

---

### Google Cloud Platform Integration Setup

**Automated Infrastructure Deployment for GCP**

Connect your GCP billing accounts to Tailpipe using our automated setup script. Supports multiple billing accounts exporting to a single BigQuery dataset.

#### What Gets Created

Our setup script automatically provisions:

1. **GCP Project** - Dedicated project for billing exports
2. **BigQuery Dataset** - Stores billing data from all your billing accounts
3. **Cloud Storage Bucket** - Backup storage for billing data
4. **Service Account** - Secure access with Workload Identity Federation (keyless)
5. **IAM Permissions** - Least-privilege access to billing data

**Note:** Due to GCP API limitations, you'll need to manually configure the billing export in the Cloud Console (we provide step-by-step instructions).

#### Security & Privacy

- **Read-Only Access** - Cannot modify any GCP resources
- **Workload Identity Federation** - No service account keys required
- **Keyless Authentication** - Short-lived tokens (1 hour), auto-rotated
- **Least Privilege** - Minimal permissions required
- **Audit Trail** - All access logged in Cloud Audit Logs
- **You Stay in Control** - Remove access anytime with our cleanup script

#### Multi-Billing Account Support

A single project can consolidate billing data from multiple billing accounts. This simplifies management and reduces costs.

- Each billing account creates uniquely named tables in the same dataset
- Interactive selector during setup
- Support for organizations with multiple billing structures

#### Prerequisites

Before you begin, ensure you have:

- gcloud CLI installed and configured ([Installation Guide](https://cloud.google.com/sdk/docs/install))
- GCP account with Billing Account Administrator role
- Project Creator role (or existing project)

#### Quick Start

**1. Download the Setup Script**

```bash
# Clone the repository
git clone https://github.com/tivarri/tailpipe-cloud-data-export.git
cd tailpipe-cloud-data-export/gcp
```

**2. Run the Setup Script**

```bash
# Interactive mode (recommended)
./setup-tailpipe.sh

# Or automated mode
PROJECT_ID=tailpipe-export \
BILLING_ACCOUNT=123456-789ABC-DEF012 \
REGION=us-central1 \
./setup-tailpipe.sh

# Preview changes first (dry-run)
DRY_RUN=1 ./setup-tailpipe.sh
```

**3. Configure Billing Export (Manual Step)**

The script provides detailed instructions for configuring the billing export in the Google Cloud Console. This takes 2-3 minutes and is a one-time setup per billing account.

**4. Share Configuration with Tailpipe**

The script outputs a JSON configuration containing your service account details and BigQuery dataset information. Share this with your Tailpipe account manager.

#### What Happens Next?

- GCP begins streaming billing data to BigQuery (near real-time)
- Tailpipe connects using Workload Identity Federation
- Your carbon emissions data appears in Tailpipe within 24 hours

#### Estimated Time

- **Single Billing Account:** 10-15 minutes (including manual billing export step)
- **Multiple Billing Accounts:** 15-25 minutes

#### Resources

- **[Complete Setup Guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/gcp/README-SETUP.md)** - Detailed documentation with troubleshooting
- **[Architecture Overview](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/gcp/SUMMARY.md)** - GCP architecture and features
- **[Setup Script](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/gcp/setup-tailpipe.sh)** - Main automation script
- **[Cleanup Script](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/gcp/cleanup-tailpipe.sh)** - Remove all resources

#### Need Help?

Contact our support team at [support@tailpipe.ai](mailto:support@tailpipe.ai) or consult our [troubleshooting guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/troubleshooting.md#gcp-issues).

---

## Comparison Page

### Cloud Integration Comparison

**Choose the Right Setup Method for Your Organization**

| Feature | AWS | Azure | GCP |
|---------|-----|-------|-----|
| **Status** | 🟢 Production | 🟡 Beta | 🟡 Beta |
| **Availability** | All customers | Request access | Request access |
| **Environment** | Production | UAT | UAT |
| **Support SLA** | 99.9% | Best effort | Best effort |
| **Setup Time** | 5-15 min | 5-30 min | 10-25 min |
| **Manual Steps** | None | None | 1 (billing export) |
| **Multi-Account** | ✅ Organizations | ✅ Management Groups | ✅ Multiple Billing |
| **Authentication** | IAM Role + External ID | Managed Identity | Workload Identity (keyless) |
| **Data Granularity** | Hourly | Daily | Near real-time |
| **Storage** | S3 | Blob Storage | BigQuery + Cloud Storage |
| **Automatic Updates** | ✅ Yes | ✅ Yes (with Policy) | ✅ Yes |

---

## FAQ Page

### Frequently Asked Questions

#### General Questions

**Q: Do I need to install any software?**

A: You only need the cloud provider's CLI tool (AWS CLI, Azure CLI, or gcloud) and our setup scripts. No agents or continuous software installations required.

**Q: Can Tailpipe modify my cloud infrastructure?**

A: No. All integrations use read-only permissions. Tailpipe can only read cost and billing data, never modify infrastructure.

**Q: How long until I see data in Tailpipe?**

A: Typically 24-48 hours. Cloud providers need time to generate the first cost export. Once data starts flowing, it updates daily (Azure), hourly (AWS), or near real-time (GCP).

**Q: Can I remove the integration later?**

A: Yes. Each cloud provider includes a cleanup script that safely removes all resources created during setup. The process takes 2-5 minutes.

**Q: Is the setup reversible?**

A: Completely reversible. Our cleanup scripts remove all infrastructure we created. Your existing cloud resources are never modified.

**Q: What if I have multiple AWS accounts / Azure subscriptions / GCP billing accounts?**

A: Our scripts fully support multi-account scenarios. AWS uses Organizations, Azure uses Management Groups or multiple subscriptions, and GCP supports multiple billing accounts in a single project.

#### Security Questions

**Q: What permissions does Tailpipe require?**

A: Tailpipe requires read-only access to:
- **AWS:** S3 bucket (Cost and Usage Reports) and CloudWatch metrics
- **Azure:** Storage account (cost exports) and optionally Cost Management API
- **GCP:** BigQuery dataset (billing export) and Cloud Storage bucket

**Q: How is my data protected?**

A:
- All data transfer uses encrypted connections (TLS 1.2+)
- Data at rest is encrypted using cloud provider default encryption
- Access is logged and auditable
- Tailpipe uses least-privilege permissions

**Q: Do you store my cloud credentials?**

A: No. We never store cloud credentials. Integrations use:
- **AWS:** IAM role assumption with External ID
- **Azure:** Managed Identity (keyless)
- **GCP:** Workload Identity Federation (keyless)

**Q: What about compliance (SOC 2, GDPR, HIPAA)?**

A: Our setup scripts create audit-compliant integrations. See our [Security Documentation](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/security.md) for detailed compliance information.

#### Technical Questions

**Q: Can I customize the setup?**

A: Yes. All scripts support environment variables for customization. You can also modify the scripts directly - they're open source.

**Q: What if the script fails?**

A: Enable debug mode (`DEBUG=1 ./setup-tailpipe.sh`) and consult our [troubleshooting guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/troubleshooting.md). Our support team is also available.

**Q: Do you support AWS GovCloud, Azure Government, or GCP Assured Workloads?**

A: Contact our support team for government cloud requirements. Special configuration may be needed.

**Q: Can I use Terraform/CloudFormation/ARM templates instead of scripts?**

A: Currently, we provide bash scripts for maximum compatibility. Terraform modules are on our roadmap. Contact us if you need IaC templates.

**Q: How do I update my integration?**

A: Pull the latest scripts from our GitHub repository and re-run the setup script. The script is idempotent and safely updates existing resources.

---

## Support Page

### Integration Support

**Need Help with Your Cloud Integration?**

Our team is here to assist with any questions or issues during setup.

#### Before Contacting Support

1. **Review the documentation** for your cloud provider (links above)
2. **Check the troubleshooting guide** at [docs/troubleshooting.md](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/troubleshooting.md)
3. **Enable debug mode** and review the output:
   ```bash
   DEBUG=1 ./setup-tailpipe.sh 2>&1 | tee setup-debug.log
   ```

#### Contact Methods

**Email Support**
- General inquiries: [support@tailpipe.ai](mailto:support@tailpipe.ai)
- Security issues: [security@tailpipe.ai](mailto:security@tailpipe.ai)

**Response Times**
- Business hours (Mon-Fri, 9am-5pm GMT): Within 4 hours
- After hours: Within 24 hours
- Critical issues: Immediate escalation

#### What to Include

When contacting support, please provide:

- Cloud provider (AWS/Azure/GCP)
- Script version (shown at start of script output)
- Error messages (exact text)
- Debug log (if available)
- Your Tailpipe account email

**Redact sensitive information** before sharing:
- Account numbers
- Subscription IDs
- External IDs
- Service account keys

#### Additional Resources

- **[Architecture Guide](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/architecture.md)** - How it all works
- **[Security Best Practices](https://github.com/tivarri/tailpipe-cloud-data-export/blob/main/docs/security.md)** - Security guidance
- **[GitHub Repository](https://github.com/tivarri/tailpipe-cloud-data-export)** - All scripts and documentation

---

## Footer CTA (All Pages)

**Ready to Get Started?**

Connect your cloud accounts to Tailpipe and start tracking carbon emissions today.

[Get Started with AWS](#) | [Get Started with Azure](#) | [Get Started with GCP](#)

**Questions?** Contact our team at [support@tailpipe.ai](mailto:support@tailpipe.ai)

---

## Notes for Web Implementation

### Key Messaging Points

1. **Transparency** - Emphasize open-source scripts, full code review capability
2. **Security** - Highlight read-only access, keyless authentication where possible
3. **Simplicity** - One command setup, automated infrastructure
4. **Control** - Easy removal, no lock-in, you stay in control
5. **Support** - Available to help, comprehensive documentation

### Recommended Page Structure

```
/integrations/
├── index.html (main landing with comparison)
├── aws.html (AWS setup page)
├── azure.html (Azure setup page)
├── gcp.html (GCP setup page)
├── comparison.html (side-by-side comparison)
├── faq.html (FAQ)
└── support.html (support resources)
```

### Call-to-Action Strategy

- Primary CTA: "Get Started" (leads to cloud provider selection)
- Secondary CTA: "View Documentation" (links to GitHub)
- Tertiary CTA: "Contact Support" (support email or form)

### SEO Considerations

**Target Keywords:**
- "AWS carbon emissions tracking"
- "Azure cost export automation"
- "GCP billing export setup"
- "Cloud carbon footprint integration"
- "Multi-cloud emissions analytics"

**Meta Descriptions:**
- AWS: "Automate AWS cost data export for carbon emissions analytics. Secure, one-command setup with read-only access."
- Azure: "Deploy Azure cost exports automatically with Policy, Automation Account, or CLI. Secure carbon emissions tracking."
- GCP: "Connect GCP billing accounts to BigQuery for carbon emissions analytics. Keyless authentication with Workload Identity."

### Visual Elements to Consider

- Screenshots of completed setups
- Architecture diagrams (from docs/architecture.md)
- Progress indicators (3-step setup process)
- Code snippets with copy buttons
- Trust badges (security certifications if available)
- Customer testimonials (if available)

---

**Document Version:** 1.0.0
**Last Updated:** October 2025
**For:** tailpipe.ai website
