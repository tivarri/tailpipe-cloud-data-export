# Operator Permissions

Permissions required to **run** the Tailpipe setup and cleanup scripts (`setup-tailpipe.sh`, `cleanup-tailpipe.sh`).

These are distinct from the permissions Tailpipe receives after setup. For connector permissions (what Tailpipe can access in your account), see [security.md](security.md).

## AWS

### Choose Your Policy

| Your Setup | Policy File |
|------------|-------------|
| Single AWS account | `aws/iam-policy-single-account.json` |
| AWS Organizations (multi-account) | `aws/iam-policy-organization.json` |

The organization policy includes everything in the single-account policy plus AWS Organizations read access and CloudFormation StackSet management for deploying CloudWatch roles to child accounts.

### Apply the Policy

```bash
# Create the IAM policy (choose one)
aws iam create-policy \
  --policy-name TailpipeSetupOperator \
  --policy-document file://aws/iam-policy-single-account.json

# OR for Organizations
aws iam create-policy \
  --policy-name TailpipeSetupOperator \
  --policy-document file://aws/iam-policy-organization.json

# Attach to a user
aws iam attach-user-policy \
  --user-name <USER> \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/TailpipeSetupOperator

# OR attach to a group
aws iam attach-group-policy \
  --group-name <GROUP> \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/TailpipeSetupOperator
```

### What the Policy Allows

- **Pre-flight checks**: Read-only discovery (`sts:GetCallerIdentity`, `iam:ListRoles`, `iam:ListPolicies`, `s3:ListAllMyBuckets`, `s3:GetBucketLocation`)
- **S3 bucket**: Create, configure, and delete the `tailpipe-dataexport-<account>` bucket
- **Cost exports**: Create and manage BCM Data Exports
- **IAM role**: Create and manage the `tailpipe-connector-role` (scoped to this role name only)
- **Organizations** (org policy only): Read organization structure
- **CloudFormation StackSets** (org policy only): Deploy CloudWatch roles to child accounts via the `Tailpipe-CloudWatch-Child-StackSet`

**Note on CloudFormation service-linked roles** (org policy only): If your account has never used CloudFormation StackSets with AWS Organizations, `ActivateOrganizationsAccess` may need to create service-linked roles. If this fails, add `iam:CreateServiceLinkedRole` (conditioned on `iam:AWSServiceName = cloudformation.amazonaws.com`) or ask an admin to activate organizations access first.

### Security Considerations

**`iam:PutRolePolicy`**: This permission allows writing any inline policy to the `tailpipe-connector-role`. While scoped to that specific role name, the operator could theoretically attach a broader policy than intended. Mitigations:

- Review the connector role's trust policy and inline policies after setup completes
- Consider applying an [IAM permissions boundary](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html) to the connector role to cap its effective permissions
- Only grant the setup operator policy to users who would normally have IAM administrative access

## Azure

### Choose Your Role

| Your Setup | Role Definition File |
|------------|---------------------|
| Standard (direct customers) | `azure/custom-role-tailpipe-setup.json` |
| CSP (Cloud Solution Provider) | `azure/custom-role-tailpipe-setup-csp.json` |

The CSP role includes everything in the standard role plus Azure Policy, Policy Insights, and Automation Account management.

### Apply the Role

**Step 1: Edit the assignable scopes**

Open the JSON file and replace `{subscription-id}` with your actual subscription ID:

```json
"AssignableScopes": [
  "/subscriptions/00000000-0000-0000-0000-000000000000"
]
```

**Step 2: Create the custom role**

```bash
# Choose one
az role definition create --role-definition @azure/custom-role-tailpipe-setup.json

# OR for CSP
az role definition create --role-definition @azure/custom-role-tailpipe-setup-csp.json
```

**Step 3: Assign the role**

```bash
az role assignment create \
  --assignee <USER_OR_GROUP_OBJECT_ID> \
  --role "Tailpipe Setup Operator" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"

# For CSP, use the CSP role name instead:
# --role "Tailpipe Setup Operator (CSP)"
```

### Additional Manual Steps

The custom role covers most operations, but the following categories of permissions must be granted separately:

#### 1. Billing-Scope Permissions (Required)

The setup script discovers billing accounts/profiles and creates Cost Management exports at the billing scope. These operations require permissions that exist above the subscription hierarchy and cannot be granted via subscription-scoped custom roles.

**Required permissions:**

- `Microsoft.Billing/billingAccounts/read` — discover billing accounts
- `Microsoft.Billing/billingAccounts/billingProfiles/read` — discover billing profiles
- `Microsoft.CostManagement/exports/write` and `exports/delete` — at the billing scope

**To grant:**

1. Go to **Azure Portal** > **Cost Management + Billing**
2. Select your billing account or billing profile
3. Go to **Access control (IAM)** > **Add role assignment**
4. Assign **Cost Management Contributor** to the operator user/group
5. The scope should be the billing account or billing profile where exports will be created

If billing permissions are not granted, the setup script will fall back to creating per-subscription exports instead of billing-scope exports.

#### 2. Microsoft Graph Permissions (Required)

Service principal creation and management requires Azure AD / Microsoft Graph permissions that cannot be included in custom RBAC roles.

**Required permissions:**

- `Application.Read.All` — read service principal / app registration details
- `Application.ReadWrite.All` — create and delete service principals

**To grant:**

A **Global Administrator** must grant admin consent for these permissions. This is typically done via:

1. **Azure Portal** > **Azure Active Directory** > **App registrations**
2. Or via the [Microsoft Graph permissions consent flow](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent)

#### 3. Management-Group Scope (If Applicable)

If the setup script assigns the Monitoring Reader role at a management group scope (rather than per-subscription), the custom role must also be assigned at that management group scope. Subscription-scoped role assignments cannot grant permissions above the subscription level.

```bash
az role assignment create \
  --assignee <USER_OR_GROUP_OBJECT_ID> \
  --role "Tailpipe Setup Operator" \
  --scope "/providers/Microsoft.Management/managementGroups/<MG_ID>"

# For CSP, use the CSP role name instead:
# --role "Tailpipe Setup Operator (CSP)"
```

This also requires updating `AssignableScopes` in the role definition to include the management group.

#### 4. Tenant-Root Scope for Automation (CSP Only)

The CSP setup script assigns `Reader` and `Contributor` roles to the Automation Account's managed identity at the tenant root scope (`/`). This requires the operator to have `Microsoft.Authorization/roleAssignments/write` at the tenant root, which cannot be provided by a subscription-scoped custom role.

The operator must have **User Access Administrator** (or equivalent) at the tenant root management group to perform this step. See [Elevate access to manage all Azure subscriptions and management groups](https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin).

### What the Role Allows

- **Resource groups**: Create, read, and delete `tailpipe-dataexport` (and `tailpipe-automation` for CSP)
- **ARM deployments**: Create template deployments
- **Resource providers**: Register `Microsoft.Storage`, `Microsoft.CostManagement`, `Microsoft.CostManagementExports`, `Microsoft.Insights`
- **Storage accounts**: Create and delete the Tailpipe data export storage account
- **Cost exports**: Create and manage subscription-scoped Cost Management exports
- **RBAC**: Create and manage role assignments (for Tailpipe service principal access)
- **Management groups**: Read management group hierarchy
- **Azure Policy** (CSP only): Create and manage policy definitions and assignments
- **Automation** (CSP only): Create and manage automation accounts, runbooks, and schedules

### Security Considerations

**`roleAssignments/write`**: This permission allows creating role assignments for any built-in or custom role. Azure does not support restricting which roles can be assigned via custom role definitions. Mitigations:

- Only grant the Tailpipe Setup Operator role to users who would normally have elevated access (e.g., Subscription Contributors or User Access Administrators)
- Review role assignments after setup completes using `az role assignment list`
- Consider using [Azure Privileged Identity Management (PIM)](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/) for just-in-time access

## Organization-Level Restrictions

These policies grant the permissions the scripts need, but they do not override higher-level restrictions in your environment:

- **AWS Service Control Policies (SCPs)**: If your organization has SCPs that restrict bucket creation, IAM role creation, or specific regions, those restrictions apply even with this policy attached. Work with your organization administrator to allowlist the required actions.
- **Azure Policy**: If your tenant has Azure Policies that restrict resource creation (e.g., allowed regions, required tags, allowed resource types), those policies take precedence. The setup script may fail if Tailpipe resources violate these restrictions.

## Keeping Policies Up to Date

These policy files correspond to the current version of the setup and cleanup scripts. If the scripts are updated with new cloud API calls, the policies may need to be updated too. Check this repository for updates when upgrading to a newer version of the scripts.

Last updated: 2026-03-27
