#!/usr/bin/env bash
#
# Tailpipe AWS Setup - Unified Installation Script
#
# This script sets up everything needed for Tailpipe cost analytics:
# 1. Verify management account access
# 2. Create S3 bucket for cost and usage reports
# 3. Create AWS Cost and Usage Report (CUR) data export
# 4. Create IAM role for Tailpipe access
# 5. Configure child accounts via CloudFormation StackSets (if applicable)
#
# Usage:
#   ./setup-tailpipe.sh                    # Interactive mode
#   DRY_RUN=1 ./setup-tailpipe.sh          # Preview changes without executing
#   REGION=us-east-1 EXTERNAL_ID=xxx ./setup-tailpipe.sh   # Non-interactive
#
# Environment Variables:
#   REGION              - AWS region (e.g., us-east-1, eu-west-1)
#   EXTERNAL_ID         - Tailpipe external ID (provided by Tailpipe)
#   TAILPIPE_ROLE_ARN   - Tailpipe connector role ARN (default: prod)
#   SKIP_CHILD_ACCOUNTS - Set to 1 to skip child account configuration
#   DRY_RUN             - Set to 1 to preview without making changes
#   FORCE               - Set to 1 to skip confirmations
#   DEBUG               - Set to 1 for verbose AWS CLI output
#

set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO (exit $?): see above"' ERR

#==============================================================================
# CONFIGURATION
#==============================================================================

# Script version
VERSION="1.0.0"

# Color output
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Resource names
S3_BUCKET_PREFIX="tailpipe-dataexport"
EXPORT_NAME="tailpipe-dataexport"
EXPORT_PREFIX="dataexport"
ROLE_NAME="tailpipe-connector-role"
CHILD_ROLE_NAME="tailpipe-child-connector"
STACKSET_NAME="Tailpipe-CloudWatch-Child-StackSet"

# Tailpipe connector role ARNs
TAILPIPE_PROD_ROLE_ARN="arn:aws:iam::336268260260:role/TailpipeConnector-Prod"
TAILPIPE_UAT_ROLE_ARN="arn:aws:iam::336268260260:role/TailpipeConnector-UAT"

# Default to production unless overridden
TAILPIPE_ROLE_ARN="${TAILPIPE_ROLE_ARN:-$TAILPIPE_PROD_ROLE_ARN}"

# Options
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
SKIP_CHILD_ACCOUNTS="${SKIP_CHILD_ACCOUNTS:-0}"
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--debug"

# Temp files tracking
TEMP_FILES=()

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

log_info() {
  echo -e "${BLUE}ℹ${NC}  $*"
}

log_success() {
  echo -e "${GREEN}✅${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}⚠️${NC}  $*"
}

log_error() {
  echo -e "${RED}❌${NC} $*"
}

log_section() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}$*${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

execute() {
  if [ "$DRY_RUN" = "1" ]; then
    echo -e "${YELLOW}[DRY RUN]${NC} $*"
    return 0
  else
    "$@"
  fi
}

confirm() {
  if [ "$FORCE" = "1" ]; then
    return 0
  fi

  local prompt="$1"
  read -rp "$prompt [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

create_temp_file() {
  local filename="$1"
  local filepath="/tmp/$filename"
  TEMP_FILES+=("$filepath")
  echo "$filepath"
}

cleanup_temp_files() {
  for file in "${TEMP_FILES[@]}"; do
    [ -f "$file" ] && rm -f "$file"
  done
}

trap cleanup_temp_files EXIT

#==============================================================================
# VALIDATION FUNCTIONS
#==============================================================================

check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Please install: https://aws.amazon.com/cli/"
    exit 1
  fi

  local aws_version
  aws_version=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2)
  log_info "AWS CLI version: $aws_version"
}

check_jq() {
  if ! command -v jq &> /dev/null; then
    log_error "jq not found. Please install: brew install jq"
    exit 1
  fi
}

verify_management_account() {
  local aws_account_number
  local management_account

  aws_account_number=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

  if [ -z "$aws_account_number" ]; then
    log_error "Failed to get AWS account number. Are you logged in?"
    exit 1
  fi

  log_info "Current AWS account: $aws_account_number"

  # Try to get management account
  management_account=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null || echo "")

  if [ -z "$management_account" ]; then
    log_warning "Unable to query AWS Organizations. This might be a standalone account."
    if [ "$FORCE" != "1" ]; then
      if ! confirm "Continue without organization validation?"; then
        exit 1
      fi
    fi
    IS_MANAGEMENT_ACCOUNT=0
    ACCOUNT_NUMBER="$aws_account_number"
    return 0
  fi

  if [ "$aws_account_number" = "$management_account" ]; then
    log_success "Verified this is the MANAGEMENT account"
    IS_MANAGEMENT_ACCOUNT=1
    ACCOUNT_NUMBER="$aws_account_number"
  else
    log_error "This is a CHILD account ($aws_account_number)"
    log_error "Please re-authenticate with the MANAGEMENT account credentials ($management_account)"
    exit 1
  fi
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

log_section "Tailpipe AWS Setup v$VERSION"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No changes will be made"
fi

# Check prerequisites
check_aws_cli
check_jq

# Get configuration
if [ -n "${REGION:-}" ]; then
  log_info "Using REGION from environment: $REGION"
else
  echo "Enter the region where you'd like everything to be set up (e.g., us-east-1, eu-west-1):"
  read -r REGION
fi

if [ -z "$REGION" ]; then
  log_error "No region provided"
  exit 1
fi

if [ -n "${EXTERNAL_ID:-}" ]; then
  log_info "Using EXTERNAL_ID from environment"
else
  echo "Enter Tailpipe External ID (provided by Tailpipe):"
  read -r EXTERNAL_ID
fi

if [ -z "$EXTERNAL_ID" ]; then
  log_error "No external ID provided"
  exit 1
fi

log_info "Target region: $REGION"
log_info "Using Tailpipe role: $TAILPIPE_ROLE_ARN"

#==============================================================================
# PHASE 1: ACCOUNT VERIFICATION & PERMISSIONS CHECK
#==============================================================================

log_section "Phase 1: Account Verification & Permissions Check"

verify_management_account

# Check required permissions before proceeding
log_info "Checking IAM permissions..."

MISSING_PERMISSIONS=()

# Check S3 permissions
if ! aws s3api list-buckets --query "Buckets[0].Name" --output text &>/dev/null; then
  MISSING_PERMISSIONS+=("s3:ListAllMyBuckets / s3:CreateBucket")
fi

# Check bcm-data-exports permissions (the one that failed for you)
if ! aws bcm-data-exports list-exports --max-results 1 &>/dev/null 2>&1; then
  MISSING_PERMISSIONS+=("bcm-data-exports:ListExports / bcm-data-exports:CreateExport")
fi

# Check IAM permissions
if ! aws iam list-roles --max-items 1 &>/dev/null; then
  MISSING_PERMISSIONS+=("iam:ListRoles / iam:CreateRole")
fi

# Check IAM policy permissions
if ! aws iam list-policies --scope Local --max-items 1 &>/dev/null; then
  MISSING_PERMISSIONS+=("iam:ListPolicies / iam:PutRolePolicy")
fi

if [ ${#MISSING_PERMISSIONS[@]} -gt 0 ]; then
  log_error "Missing required IAM permissions:"
  echo ""
  for perm in "${MISSING_PERMISSIONS[@]}"; do
    log_error "  - $perm"
  done
  echo ""
  log_error "The IAM user/role running this script needs the following permissions:"
  log_error ""
  log_error "  - s3:CreateBucket, s3:PutBucketPolicy, s3:ListAllMyBuckets"
  log_error "  - bcm-data-exports:CreateExport, bcm-data-exports:ListExports, bcm-data-exports:GetExport"
  log_error "  - iam:CreateRole, iam:PutRolePolicy, iam:GetRole, iam:ListRoles, iam:ListPolicies"
  log_error ""
  log_error "You can attach the AWS managed policy 'AdministratorAccess' temporarily,"
  log_error "or create a custom policy with these specific permissions."
  log_error ""
  log_error "Current identity: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo 'unknown')"
  exit 1
fi

log_success "IAM permissions verified"

if [ "$IS_MANAGEMENT_ACCOUNT" = "1" ]; then
  ROOT_ID=$(aws organizations list-roots --query "Roots[].Id" --output text 2>/dev/null || echo "")
  if [ -n "$ROOT_ID" ]; then
    log_info "AWS Organization Root ID: $ROOT_ID"
  fi
fi

#==============================================================================
# PHASE 2: S3 BUCKET SETUP
#==============================================================================

log_section "Phase 2: S3 Bucket Setup"

S3_BUCKET="${S3_BUCKET_PREFIX}-${ACCOUNT_NUMBER}"
log_info "Creating S3 bucket: $S3_BUCKET"

# Create S3 bucket
if [ "$DRY_RUN" = "0" ]; then
  if aws s3 ls "s3://$S3_BUCKET" 2>/dev/null; then
    log_warning "S3 bucket already exists"
  else
    # Create bucket with appropriate location constraint
    if [ "$REGION" = "us-east-1" ]; then
      execute aws s3 mb "s3://$S3_BUCKET" --region "$REGION" || {
        log_error "Failed to create S3 bucket"
        exit 1
      }
    else
      execute aws s3api create-bucket \
        --bucket "$S3_BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" || {
        log_error "Failed to create S3 bucket"
        exit 1
      }
    fi
    log_success "S3 bucket created"
  fi
else
  log_info "[DRY RUN] Would create S3 bucket: $S3_BUCKET"
fi

# Create bucket policy
log_info "Creating S3 bucket policy..."

S3_POLICY_FILE=$(create_temp_file "tailpipe-s3-policy.json")
cat > "$S3_POLICY_FILE" <<EOF
{
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "billingreports.amazonaws.com",
                    "bcm-data-exports.amazonaws.com"
                ]
            },
            "Action": [
                "s3:PutObject",
                "s3:GetBucketPolicy"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET}",
                "arn:aws:s3:::${S3_BUCKET}/*"
            ],
            "Condition": {
                "StringLike": {
                    "aws:SourceAccount": "${ACCOUNT_NUMBER}",
                    "aws:SourceArn": [
                        "arn:aws:cur:us-east-1:${ACCOUNT_NUMBER}:definition/*",
                        "arn:aws:bcm-data-exports:us-east-1:${ACCOUNT_NUMBER}:export/*"
                    ]
                }
            }
        }
    ]
}
EOF

execute aws s3api put-bucket-policy \
  --bucket "$S3_BUCKET" \
  --policy "file://$S3_POLICY_FILE" || {
  log_error "Failed to apply S3 bucket policy"
  exit 1
}

log_success "S3 bucket policy applied"

#==============================================================================
# PHASE 3: COST AND USAGE REPORT
#==============================================================================

log_section "Phase 3: Cost and Usage Report Setup"

log_info "Creating billing data export..."

EXPORT_DEF_FILE=$(create_temp_file "tailpipe-export-definition.json")
cat > "$EXPORT_DEF_FILE" <<EOF
{
  "DataQuery": {
    "QueryStatement":"SELECT bill_bill_type, bill_billing_entity, bill_billing_period_end_date, bill_billing_period_start_date, bill_invoice_id, bill_invoicing_entity, bill_payer_account_id, bill_payer_account_name, cost_category, discount, discount_bundled_discount, discount_total_discount, identity_line_item_id, identity_time_interval, line_item_availability_zone, line_item_blended_cost, line_item_blended_rate, line_item_currency_code, line_item_legal_entity, line_item_line_item_description, line_item_line_item_type, line_item_net_unblended_cost, line_item_net_unblended_rate, line_item_normalization_factor, line_item_normalized_usage_amount, line_item_operation, line_item_product_code, line_item_resource_id, line_item_tax_type, line_item_unblended_cost, line_item_unblended_rate, line_item_usage_account_id, line_item_usage_account_name, line_item_usage_amount, line_item_usage_end_date, line_item_usage_start_date, line_item_usage_type, pricing_currency, pricing_lease_contract_length, pricing_offering_class, pricing_public_on_demand_cost, pricing_public_on_demand_rate, pricing_purchase_option, pricing_rate_code, pricing_rate_id, pricing_term, pricing_unit, product, product_comment, product_fee_code, product_fee_description, product_from_location, product_from_location_type, product_from_region_code, product_instance_family, product_instance_type, product_instancesku, product_location, product_location_type, product_operation, product_pricing_unit, product_product_family, product_region_code, product_servicecode, product_sku, product_to_location, product_to_location_type, product_to_region_code, product_usagetype, reservation_amortized_upfront_cost_for_usage, reservation_amortized_upfront_fee_for_billing_period, reservation_availability_zone, reservation_effective_cost, reservation_end_time, reservation_modification_status, reservation_net_amortized_upfront_cost_for_usage, reservation_net_amortized_upfront_fee_for_billing_period, reservation_net_effective_cost, reservation_net_recurring_fee_for_usage, reservation_net_unused_amortized_upfront_fee_for_billing_period, reservation_net_unused_recurring_fee, reservation_net_upfront_value, reservation_normalized_units_per_reservation, reservation_number_of_reservations, reservation_recurring_fee_for_usage, reservation_reservation_a_r_n, reservation_start_time, reservation_subscription_id, reservation_total_reserved_normalized_units, reservation_total_reserved_units, reservation_units_per_reservation, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_normalized_unit_quantity, reservation_unused_quantity, reservation_unused_recurring_fee, reservation_upfront_value, resource_tags, savings_plan_amortized_upfront_commitment_for_billing_period, savings_plan_end_time, savings_plan_instance_type_family, savings_plan_net_amortized_upfront_commitment_for_billing_period, savings_plan_net_recurring_commitment_for_billing_period, savings_plan_net_savings_plan_effective_cost, savings_plan_offering_type, savings_plan_payment_option, savings_plan_purchase_term, savings_plan_recurring_commitment_for_billing_period, savings_plan_region, savings_plan_savings_plan_a_r_n, savings_plan_savings_plan_effective_cost, savings_plan_savings_plan_rate, savings_plan_start_time, savings_plan_total_commitment_to_date, savings_plan_used_commitment FROM COST_AND_USAGE_REPORT",
    "TableConfigurations":{
      "COST_AND_USAGE_REPORT":{
        "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY":"FALSE",
        "INCLUDE_RESOURCES":"TRUE",
        "INCLUDE_SPLIT_COST_ALLOCATION_DATA":"FALSE",
        "TIME_GRANULARITY":"HOURLY"
      }
    }
  },
  "Description": "Tailpipe DataExport",
  "DestinationConfigurations": {
    "S3Destination": {
      "S3Bucket": "${S3_BUCKET}",
      "S3OutputConfigurations": {
        "Compression": "GZIP",
        "Format": "TEXT_OR_CSV",
        "OutputType": "CUSTOM",
        "Overwrite": "OVERWRITE_REPORT"
      },
      "S3Prefix": "${EXPORT_PREFIX}",
      "S3Region": "${REGION}"
    }
  },
  "Name": "${EXPORT_NAME}",
  "RefreshCadence": {
    "Frequency": "SYNCHRONOUS"
  }
}
EOF

if [ "$DRY_RUN" = "0" ]; then
  # Check if export already exists
  if aws bcm-data-exports get-export --export-arn "arn:aws:bcm-data-exports:us-east-1:${ACCOUNT_NUMBER}:export/${EXPORT_NAME}" 2>/dev/null | grep -q "ExportArn"; then
    log_warning "Cost export already exists"
  else
    execute aws bcm-data-exports create-export --export "file://$EXPORT_DEF_FILE" || {
      log_error "Failed to create billing data export"
      exit 1
    }
    log_success "Billing data export created"
  fi
else
  log_info "[DRY RUN] Would create cost export: $EXPORT_NAME"
fi

#==============================================================================
# PHASE 4: IAM ROLE FOR TAILPIPE ACCESS
#==============================================================================

log_section "Phase 4: IAM Role Setup"

log_info "Creating IAM role for Tailpipe access: $ROLE_NAME"

# Create assume role policy document
ASSUME_ROLE_FILE=$(create_temp_file "tailpipe-assume-role.json")
cat > "$ASSUME_ROLE_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "${TAILPIPE_ROLE_ARN}"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "${EXTERNAL_ID}"
                }
            }
        }
    ]
}
EOF

# Create role
if [ "$DRY_RUN" = "0" ]; then
  if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null | grep -q "RoleName"; then
    log_warning "IAM role already exists"
  else
    execute aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$ASSUME_ROLE_FILE" \
      --description "Tailpipe connector role for cost data access" > /dev/null || {
      log_error "Failed to create IAM role"
      exit 1
    }
    log_success "IAM role created"
  fi
else
  log_info "[DRY RUN] Would create IAM role: $ROLE_NAME"
fi

# Create role policy
log_info "Applying permissions policy to IAM role..."

ROLE_POLICY_FILE=$(create_temp_file "tailpipe-role-policy.json")
cat > "$ROLE_POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3Access",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET}",
                "arn:aws:s3:::${S3_BUCKET}/*"
            ]
        },
        {
            "Sid": "CloudWatchAccess",
            "Effect": "Allow",
            "Action": [
                "cloudwatch:GetMetricStatistics"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
EOF

execute aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "tailpipe-access-policy" \
  --policy-document "file://$ROLE_POLICY_FILE" || {
  log_error "Failed to apply permissions policy"
  exit 1
}

log_success "Permissions policy applied"

# Get role ARN
ROLE_ARN="arn:aws:iam::${ACCOUNT_NUMBER}:role/${ROLE_NAME}"
log_info "Role ARN: $ROLE_ARN"

#==============================================================================
# PHASE 5: CHILD ACCOUNT CONFIGURATION (OPTIONAL)
#==============================================================================

if [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "$SKIP_CHILD_ACCOUNTS" = "0" ]; then
  log_section "Phase 5: Child Account Configuration"

  # Get list of accounts
  ACCOUNTS_JSON=$(aws organizations list-accounts 2>/dev/null || echo '{"Accounts":[]}')
  CHILD_COUNT=$(echo "$ACCOUNTS_JSON" | jq "[.Accounts[] | select(.Id != \"$ACCOUNT_NUMBER\")] | length")

  if [ "$CHILD_COUNT" -gt 0 ]; then
    log_info "Found $CHILD_COUNT child account(s) in the organization"

    if [ "$FORCE" != "1" ] && [ "$DRY_RUN" = "0" ]; then
      if ! confirm "Configure CloudWatch access for child accounts?"; then
        log_warning "Skipping child account configuration"
      else
        CONFIGURE_CHILDREN=1
      fi
    else
      CONFIGURE_CHILDREN=1
    fi

    if [ "${CONFIGURE_CHILDREN:-0}" = "1" ]; then
      # Create CloudFormation template
      CFN_TEMPLATE_FILE=$(create_temp_file "TailpipeChildAccountCloudFormation.yml")
      cat > "$CFN_TEMPLATE_FILE" <<EOF
Resources:
  TailpipeCloudWatchRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: ${CHILD_ROLE_NAME}
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: "${TAILPIPE_ROLE_ARN}"
            Action: "sts:AssumeRole"
            Condition:
              StringEquals:
                sts:ExternalId: "${EXTERNAL_ID}"
      Policies:
        - PolicyName: tailpipe_child_connector_policy
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - "cloudwatch:GetMetricStatistics"
                Resource: "*"
EOF

      log_info "CloudFormation template created"

      # Check CloudFormation access
      CFN_STATUS=$(aws cloudformation describe-organizations-access --query Status --output text 2>/dev/null || echo "UNKNOWN")

      if [ "$CFN_STATUS" = "DISABLED" ]; then
        log_info "Enabling CloudFormation Organizations access..."
        execute aws cloudformation activate-organizations-access || {
          log_error "Failed to enable CloudFormation access"
          exit 1
        }
        log_success "Organizations access enabled"
        RESTORE_CFN_STATUS=1
      elif [ "$CFN_STATUS" = "ENABLED" ]; then
        log_info "CloudFormation Organizations access already enabled"
        RESTORE_CFN_STATUS=0
      else
        log_warning "Cannot determine CloudFormation access status, proceeding anyway"
        RESTORE_CFN_STATUS=0
      fi

      # Check if StackSet already exists
      if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" --region "$REGION" 2>/dev/null | grep -q "StackSetName"; then
        log_warning "StackSet already exists, updating..."
        execute aws cloudformation update-stack-set \
          --stack-set-name "$STACKSET_NAME" \
          --template-body "file://$CFN_TEMPLATE_FILE" \
          --capabilities CAPABILITY_NAMED_IAM \
          --region "$REGION" > /dev/null || {
          log_warning "Failed to update StackSet, continuing anyway"
        }
      else
        # Create StackSet
        log_info "Creating StackSet..."
        execute aws cloudformation create-stack-set \
          --stack-set-name "$STACKSET_NAME" \
          --template-body "file://$CFN_TEMPLATE_FILE" \
          --permission-model SERVICE_MANAGED \
          --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
          --capabilities CAPABILITY_NAMED_IAM \
          --region "$REGION" || {
          log_error "Failed to create StackSet"
          exit 1
        }
        log_success "StackSet created"
      fi

      # Deploy stack instances
      log_info "Deploying stack instances to child accounts..."

      OPERATION_ID=$(execute aws cloudformation create-stack-instances \
        --stack-set-name "$STACKSET_NAME" \
        --deployment-targets OrganizationalUnitIds="$ROOT_ID" \
        --regions us-east-1 \
        --operation-preferences RegionConcurrencyType=PARALLEL,FailureToleranceCount=0,MaxConcurrentPercentage=100,ConcurrencyMode=SOFT_FAILURE_TOLERANCE \
        --region "$REGION" \
        --query 'OperationId' \
        --output text 2>/dev/null || echo "")

      if [ -n "$OPERATION_ID" ] && [ "$DRY_RUN" = "0" ]; then
        log_info "Waiting for StackSet operation to complete (Operation ID: $OPERATION_ID)..."

        WAIT_COUNT=0
        MAX_WAIT=60  # 15 minutes max

        while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
          STATUS=$(aws cloudformation describe-stack-set-operation \
            --stack-set-name "$STACKSET_NAME" \
            --operation-id "$OPERATION_ID" \
            --region "$REGION" \
            --query 'StackSetOperation.Status' \
            --output text 2>/dev/null || echo "UNKNOWN")

          log_info "Operation status: $STATUS"

          if [ "$STATUS" = "SUCCEEDED" ]; then
            log_success "StackSet deployment completed successfully"
            break
          elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "STOPPED" ]; then
            log_error "StackSet operation failed with status: $STATUS"
            log_error "Check CloudFormation console for details"
            exit 1
          fi

          sleep 15
          WAIT_COUNT=$((WAIT_COUNT + 1))
        done

        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
          log_warning "StackSet operation timed out, but may still complete"
          log_warning "Check CloudFormation console for status"
        fi
      elif [ "$DRY_RUN" = "1" ]; then
        log_info "[DRY RUN] Would deploy stack instances to organizational units"
      fi

      # Restore CloudFormation access state
      if [ "${RESTORE_CFN_STATUS:-0}" = "1" ] && [ "$DRY_RUN" = "0" ]; then
        log_info "Disabling CloudFormation Organizations access..."
        aws cloudformation deactivate-organizations-access || {
          log_warning "Failed to disable CloudFormation access"
        }
      fi

      log_success "Child account configuration complete"
    fi
  else
    log_info "No child accounts found in organization"
  fi
else
  if [ "$IS_MANAGEMENT_ACCOUNT" = "0" ]; then
    log_info "Not a management account, skipping child account configuration"
  else
    log_info "Skipping child account configuration (SKIP_CHILD_ACCOUNTS=1)"
  fi
fi

#==============================================================================
# PHASE 6: VALIDATION
#==============================================================================

log_section "Phase 6: Validation"

if [ "$DRY_RUN" = "0" ]; then
  log_info "Validating deployment..."

  # Validate S3 bucket
  if aws s3 ls "s3://$S3_BUCKET" &>/dev/null; then
    log_success "S3 bucket validated"
  else
    log_error "S3 bucket validation failed"
  fi

  # Validate cost export
  if aws bcm-data-exports get-export --export-arn "arn:aws:bcm-data-exports:us-east-1:${ACCOUNT_NUMBER}:export/${EXPORT_NAME}" 2>/dev/null | grep -q "ExportArn"; then
    log_success "Cost export validated"
  else
    log_warning "Cost export validation failed"
  fi

  # Validate IAM role
  if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null | grep -q "RoleName"; then
    log_success "IAM role validated"
  else
    log_error "IAM role validation failed"
  fi

  # Validate child account StackSet (if applicable)
  if [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "$SKIP_CHILD_ACCOUNTS" = "0" ] && [ "$CHILD_COUNT" -gt 0 ]; then
    if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" --region "$REGION" 2>/dev/null | grep -q "StackSetName"; then
      log_success "StackSet validated"
    else
      log_warning "StackSet validation failed"
    fi
  fi
else
  log_info "Validation skipped (dry run mode)"
fi

#==============================================================================
# CONFIGURATION SUMMARY
#==============================================================================

log_section "Configuration Summary"

cat <<JSON_OUTPUT

{
  "awsAccountNumber": "${ACCOUNT_NUMBER}",
  "region": "${REGION}",
  "isManagementAccount": ${IS_MANAGEMENT_ACCOUNT},
  "organizationRootId": "${ROOT_ID:-null}",
  "tailpipe": {
    "externalId": "${EXTERNAL_ID}",
    "connectorRoleArn": "${TAILPIPE_ROLE_ARN}"
  },
  "costExport": {
    "name": "${EXPORT_NAME}",
    "s3Bucket": "${S3_BUCKET}",
    "s3Prefix": "${EXPORT_PREFIX}",
    "exportArn": "arn:aws:bcm-data-exports:us-east-1:${ACCOUNT_NUMBER}:export/${EXPORT_NAME}"
  },
  "iamRole": {
    "name": "${ROLE_NAME}",
    "arn": "${ROLE_ARN}"
  },
  "childAccounts": {
    "configured": $([ "${CONFIGURE_CHILDREN:-0}" = "1" ] && echo "true" || echo "false"),
    "count": ${CHILD_COUNT:-0},
    "childRoleName": "${CHILD_ROLE_NAME}",
    "stackSetName": "${STACKSET_NAME}"
  }
}
JSON_OUTPUT

log_section "Setup Complete!"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "This was a DRY RUN - no changes were made"
  log_info "Run without DRY_RUN=1 to perform actual deployment"
else
  log_success "Tailpipe has been successfully configured in your AWS account"
  log_info ""
  log_info "Next steps:"
  log_info "1. Save the JSON configuration above for Tailpipe onboarding"
  log_info "2. Cost exports will begin generating within 24 hours"
  if [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "${CONFIGURE_CHILDREN:-0}" = "1" ]; then
    log_info "3. Child accounts can now be monitored via CloudWatch"
  fi
fi

log_info ""
log_info "For troubleshooting and management commands, see README.md"
