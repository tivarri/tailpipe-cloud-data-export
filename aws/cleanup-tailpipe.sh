#!/usr/bin/env bash
#
# Tailpipe AWS Cleanup Script
#
# This script removes all Tailpipe resources from your AWS account:
# - Cost and Usage Report exports
# - S3 bucket and data
# - IAM roles and policies
# - CloudFormation StackSets (child account configuration)
#
# Usage:
#   ./cleanup-tailpipe.sh                          # Interactive mode with confirmations
#   FORCE=1 ./cleanup-tailpipe.sh                  # Skip confirmations
#   DRY_RUN=1 ./cleanup-tailpipe.sh                # Preview without deleting
#   KEEP_DATA=1 ./cleanup-tailpipe.sh              # Keep S3 bucket and data
#   KEEP_ROLE=1 ./cleanup-tailpipe.sh              # Keep IAM role
#
# Environment Variables:
#   DRY_RUN         - Set to 1 to preview deletions without executing
#   FORCE           - Set to 1 to skip all confirmations
#   KEEP_DATA       - Set to 1 to preserve S3 bucket and data
#   KEEP_ROLE       - Set to 1 to preserve IAM role
#   DEBUG           - Set to 1 for verbose output
#

set -Eeuo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================

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
ROLE_NAME="tailpipe-connector-role"
CHILD_ROLE_NAME="tailpipe-child-connector"
STACKSET_NAME="Tailpipe-CloudWatch-Child-StackSet"

# Options
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
KEEP_DATA="${KEEP_DATA:-0}"
KEEP_ROLE="${KEEP_ROLE:-0}"
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--debug"

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

check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found"
    exit 1
  fi
}

check_jq() {
  if ! command -v jq &> /dev/null; then
    log_error "jq not found. Please install: brew install jq"
    exit 1
  fi
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

log_section "Tailpipe AWS Cleanup"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No resources will be deleted"
fi

if [ "$KEEP_DATA" = "1" ]; then
  log_warning "KEEP_DATA set - S3 bucket and data will be preserved"
fi

if [ "$KEEP_ROLE" = "1" ]; then
  log_warning "KEEP_ROLE set - IAM role will be preserved"
fi

# Check prerequisites
check_aws_cli
check_jq

# Get AWS account info
ACCOUNT_NUMBER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

if [ -z "$ACCOUNT_NUMBER" ]; then
  log_error "Failed to get AWS account number. Are you logged in?"
  exit 1
fi

log_info "AWS account: $ACCOUNT_NUMBER"

# Check if management account
IS_MANAGEMENT_ACCOUNT=0
MANAGEMENT_ACCOUNT=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null || echo "")

if [ -n "$MANAGEMENT_ACCOUNT" ] && [ "$ACCOUNT_NUMBER" = "$MANAGEMENT_ACCOUNT" ]; then
  IS_MANAGEMENT_ACCOUNT=1
  log_info "Detected management account"

  ROOT_ID=$(aws organizations list-roots --query "Roots[].Id" --output text 2>/dev/null || echo "")
  if [ -n "$ROOT_ID" ]; then
    log_info "Organization Root ID: $ROOT_ID"
  fi

  # Count child accounts
  ACCOUNTS_JSON=$(aws organizations list-accounts 2>/dev/null || echo '{"Accounts":[]}')
  CHILD_COUNT=$(echo "$ACCOUNTS_JSON" | jq "[.Accounts[] | select(.Id != \"$ACCOUNT_NUMBER\")] | length")
  log_info "Found $CHILD_COUNT child account(s)"
fi

# Determine S3 bucket name
S3_BUCKET="${S3_BUCKET_PREFIX}-${ACCOUNT_NUMBER}"

#==============================================================================
# CONFIRMATION
#==============================================================================

if [ "$FORCE" != "1" ]; then
  log_section "Resources to be Deleted"

  echo "The following resources will be removed:"
  echo ""
  echo "  📊 Cost and Usage Report:"
  echo "     - Export: $EXPORT_NAME"
  echo ""

  if [ "$KEEP_DATA" != "1" ]; then
    echo "  🪣 S3 Bucket:"
    echo "     - Bucket: $S3_BUCKET"
    echo "     - ALL COST DATA WILL BE DELETED"
    echo ""
  fi

  if [ "$KEEP_ROLE" != "1" ]; then
    echo "  🔑 IAM Role:"
    echo "     - Role: $ROLE_NAME"
    echo "     - Policies: tailpipe-access-policy"
    echo ""
  fi

  if [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "$CHILD_COUNT" -gt 0 ]; then
    echo "  📚 CloudFormation StackSets:"
    echo "     - StackSet: $STACKSET_NAME"
    echo "     - Child account roles: $CHILD_ROLE_NAME"
    echo "     - Affects $CHILD_COUNT child account(s)"
    echo ""
  fi

  if ! confirm "Do you want to proceed with cleanup?"; then
    log_warning "Cleanup cancelled by user"
    exit 0
  fi
fi

#==============================================================================
# DELETE COST EXPORT
#==============================================================================

log_section "Deleting Cost and Usage Report"

log_info "Deleting cost export: $EXPORT_NAME"

EXPORT_ARN="arn:aws:bcm-data-exports:us-east-1:${ACCOUNT_NUMBER}:export/${EXPORT_NAME}"

if [ "$DRY_RUN" = "0" ]; then
  if aws bcm-data-exports get-export --export-arn "$EXPORT_ARN" 2>/dev/null | grep -q "ExportArn"; then
    execute aws bcm-data-exports delete-export --export-arn "$EXPORT_ARN" && \
      log_success "Cost export deleted" || \
      log_warning "Failed to delete cost export"
  else
    log_info "Cost export not found or already deleted"
  fi
else
  log_info "[DRY RUN] Would delete cost export: $EXPORT_NAME"
fi

#==============================================================================
# DELETE S3 BUCKET
#==============================================================================

if [ "$KEEP_DATA" != "1" ]; then
  log_section "Deleting S3 Bucket and Data"

  if [ "$FORCE" != "1" ] && [ "$DRY_RUN" = "0" ]; then
    log_warning "This will DELETE ALL COST DATA in the S3 bucket"
    if ! confirm "Are you sure you want to delete the S3 bucket and all data?"; then
      log_warning "S3 bucket deletion skipped"
      KEEP_DATA=1
    fi
  fi

  if [ "$KEEP_DATA" != "1" ]; then
    log_info "Deleting S3 bucket: $S3_BUCKET"

    if [ "$DRY_RUN" = "0" ]; then
      if aws s3 ls "s3://$S3_BUCKET" 2>/dev/null; then
        # Remove all objects first
        log_info "Removing all objects from bucket..."
        execute aws s3 rm "s3://$S3_BUCKET" --recursive || {
          log_warning "Failed to remove all objects, bucket may not be empty"
        }

        # Delete bucket
        execute aws s3 rb "s3://$S3_BUCKET" --force && \
          log_success "S3 bucket deleted" || \
          log_warning "Failed to delete S3 bucket"
      else
        log_info "S3 bucket not found or already deleted"
      fi
    else
      log_info "[DRY RUN] Would delete S3 bucket: $S3_BUCKET"
    fi
  fi
else
  log_info "Skipping S3 bucket deletion (KEEP_DATA=1)"
fi

#==============================================================================
# DELETE IAM ROLE
#==============================================================================

if [ "$KEEP_ROLE" != "1" ]; then
  log_section "Deleting IAM Role"

  if [ "$FORCE" != "1" ] && [ "$DRY_RUN" = "0" ]; then
    log_warning "The Tailpipe IAM role is used to read cost data"
    log_warning "Deleting it will break the Tailpipe integration"
    if ! confirm "Do you want to delete the IAM role?"; then
      log_warning "IAM role deletion skipped"
      KEEP_ROLE=1
    fi
  fi

  if [ "$KEEP_ROLE" != "1" ]; then
    log_info "Deleting IAM role: $ROLE_NAME"

    if [ "$DRY_RUN" = "0" ]; then
      if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null | grep -q "RoleName"; then
        # Delete inline policies first
        log_info "Removing inline policies..."
        POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null || echo "")

        for policy in $POLICIES; do
          [ -z "$policy" ] && continue
          execute aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy" && \
            log_info "Deleted policy: $policy" || \
            log_warning "Failed to delete policy: $policy"
        done

        # Delete attached managed policies
        ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")

        for policy_arn in $ATTACHED; do
          [ -z "$policy_arn" ] && continue
          execute aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" && \
            log_info "Detached policy: $policy_arn" || \
            log_warning "Failed to detach policy: $policy_arn"
        done

        # Delete role
        execute aws iam delete-role --role-name "$ROLE_NAME" && \
          log_success "IAM role deleted" || \
          log_warning "Failed to delete IAM role"
      else
        log_info "IAM role not found or already deleted"
      fi
    else
      log_info "[DRY RUN] Would delete IAM role: $ROLE_NAME"
    fi
  fi
else
  log_info "Skipping IAM role deletion (KEEP_ROLE=1)"
fi

#==============================================================================
# DELETE CLOUDFORMATION STACKSETS
#==============================================================================

if [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "$CHILD_COUNT" -gt 0 ]; then
  log_section "Deleting CloudFormation StackSets"

  # Check all regions where stacks might exist
  REGIONS_TO_CHECK=("us-east-1" "eu-west-1" "ap-southeast-1")

  for REGION in "${REGIONS_TO_CHECK[@]}"; do
    log_info "Checking region: $REGION"

    if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" --region "$REGION" 2>/dev/null | grep -q "StackSetName"; then
      log_info "Found StackSet in region: $REGION"

      # Delete all stack instances first
      log_info "Deleting stack instances..."

      if [ "$DRY_RUN" = "0" ]; then
        # Get list of stack instances
        INSTANCES=$(aws cloudformation list-stack-instances \
          --stack-set-name "$STACKSET_NAME" \
          --region "$REGION" \
          --query 'Summaries[].Account' \
          --output text 2>/dev/null || echo "")

        if [ -n "$INSTANCES" ]; then
          OPERATION_ID=$(execute aws cloudformation delete-stack-instances \
            --stack-set-name "$STACKSET_NAME" \
            --deployment-targets OrganizationalUnitIds="$ROOT_ID" \
            --regions us-east-1 \
            --no-retain-stacks \
            --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100 \
            --region "$REGION" \
            --query 'OperationId' \
            --output text 2>/dev/null || echo "")

          if [ -n "$OPERATION_ID" ]; then
            log_info "Waiting for stack instance deletion (Operation ID: $OPERATION_ID)..."

            WAIT_COUNT=0
            MAX_WAIT=40  # 10 minutes max

            while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
              STATUS=$(aws cloudformation describe-stack-set-operation \
                --stack-set-name "$STACKSET_NAME" \
                --operation-id "$OPERATION_ID" \
                --region "$REGION" \
                --query 'StackSetOperation.Status' \
                --output text 2>/dev/null || echo "UNKNOWN")

              if [ "$STATUS" = "SUCCEEDED" ]; then
                log_success "Stack instances deleted"
                break
              elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "STOPPED" ]; then
                log_warning "Stack instance deletion failed: $STATUS"
                break
              fi

              sleep 15
              WAIT_COUNT=$((WAIT_COUNT + 1))
            done

            if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
              log_warning "Stack instance deletion timed out"
            fi
          fi
        else
          log_info "No stack instances found"
        fi

        # Delete StackSet
        log_info "Deleting StackSet..."
        execute aws cloudformation delete-stack-set \
          --stack-set-name "$STACKSET_NAME" \
          --region "$REGION" && \
          log_success "StackSet deleted" || \
          log_warning "Failed to delete StackSet"
      else
        log_info "[DRY RUN] Would delete StackSet: $STACKSET_NAME"
      fi

      break  # Found it, no need to check other regions
    fi
  done

  if [ "$DRY_RUN" = "0" ]; then
    log_info "StackSet cleanup complete"
  fi
else
  if [ "$IS_MANAGEMENT_ACCOUNT" = "0" ]; then
    log_info "Not a management account, skipping StackSet cleanup"
  else
    log_info "No child accounts, skipping StackSet cleanup"
  fi
fi

#==============================================================================
# SUMMARY
#==============================================================================

log_section "Cleanup Summary"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN COMPLETE - No resources were deleted"
  log_info "Run without DRY_RUN=1 to perform actual cleanup"
else
  log_success "Tailpipe cleanup complete!"
  echo ""
  log_info "Resources deleted:"
  log_info "  ✓ Cost and Usage Report export"
  [ "$KEEP_DATA" != "1" ] && log_info "  ✓ S3 bucket and data"
  [ "$KEEP_ROLE" != "1" ] && log_info "  ✓ IAM role and policies"
  [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "$CHILD_COUNT" -gt 0 ] && log_info "  ✓ CloudFormation StackSets"
fi

log_info ""
log_info "Cleanup script finished"
