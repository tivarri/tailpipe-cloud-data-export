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
#   CHILD_ACCOUNTS  - Cleanup specific child accounts only (comma-separated IDs)
#                     If not set, cleans up ALL child accounts
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

# BCM Data Exports are ONLY available in us-east-1 regardless of where other
# resources are deployed. This is an AWS limitation, not a bug.
BCM_REGION="us-east-1"

# Options
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
KEEP_DATA="${KEEP_DATA:-0}"
KEEP_ROLE="${KEEP_ROLE:-0}"
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--debug"

# Child account selection (for Organizations cleanup)
# If not set, cleans up ALL child accounts
CHILD_ACCOUNTS="${CHILD_ACCOUNTS:-}"

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

# Count comma-separated items (handles empty strings correctly)
count_csv_items() {
  local input="$1"
  if [ -z "$input" ]; then
    echo 0
  else
    echo "$input" | awk -F',' '{print NF}'
  fi
}

# Normalize comma-separated list (remove empty entries, trim spaces, deduplicate)
normalize_csv() {
  local input="$1"
  # Split, trim, remove empty, deduplicate, rejoin
  # Use sed to remove empty lines instead of grep to avoid pipefail issues
  echo "$input" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//'
}

# Validate AWS account ID format (must be exactly 12 digits)
is_valid_account_id() {
  local id="$1"
  echo "$id" | grep -qE '^[0-9]{12}$'
}

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
# EXPORT HELPER FUNCTIONS
#==============================================================================

# Sanitize a string for safe use in JMESPath queries
# Note: hyphen must be at end to avoid being interpreted as a range
sanitize_for_jmespath() {
  local input="$1"
  echo "$input" | tr -cd '[:alnum:]_-'
}

# List all Tailpipe exports (handles pagination, returns full ARNs)
list_tailpipe_exports() {
  local account="$1"
  local prefix="$2"
  local safe_account safe_prefix

  safe_account=$(sanitize_for_jmespath "$account")
  safe_prefix=$(sanitize_for_jmespath "$prefix")

  aws bcm-data-exports list-exports \
    --no-paginate \
    --query "Exports[?starts_with(ExportArn, 'arn:aws:bcm-data-exports:${BCM_REGION}:${safe_account}:export/${safe_prefix}')].ExportArn" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

# Track cleanup failures for summary
CLEANUP_FAILURES=0

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

# Discover actual export ARNs before showing confirmation
EXPORT_ARNS=$(list_tailpipe_exports "$ACCOUNT_NUMBER" "$EXPORT_NAME")
EXPORT_COUNT=$(echo "$EXPORT_ARNS" | grep -c . || echo "0")

if [ "$FORCE" != "1" ]; then
  log_section "Resources to be Deleted"

  echo "The following resources will be removed:"
  echo ""
  echo "  📊 Cost and Usage Report:"
  if [ -n "$EXPORT_ARNS" ]; then
    echo "$EXPORT_ARNS" | while read -r arn; do
      echo "     - $arn"
    done
  else
    echo "     - (no exports found matching: $EXPORT_NAME*)"
  fi
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
    if [ -n "$CHILD_ACCOUNTS" ]; then
      NORMALIZED_CLEANUP_ACCOUNTS=$(normalize_csv "$CHILD_ACCOUNTS")
      CLEANUP_ACCT_COUNT=$(count_csv_items "$NORMALIZED_CLEANUP_ACCOUNTS")
      echo "     - Affects $CLEANUP_ACCT_COUNT specific account(s): $NORMALIZED_CLEANUP_ACCOUNTS"
      echo "     - StackSet will be retained"
    else
      echo "     - Affects ALL $CHILD_COUNT child account(s)"
      echo "     - StackSet will be DELETED"
    fi
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

log_info "Looking for exports matching: $EXPORT_NAME*"

# Re-fetch in case confirmation was skipped
if [ -z "${EXPORT_ARNS:-}" ]; then
  EXPORT_ARNS=$(list_tailpipe_exports "$ACCOUNT_NUMBER" "$EXPORT_NAME")
fi

if [ "$DRY_RUN" = "0" ]; then
  if [ -n "$EXPORT_ARNS" ]; then
    # Delete ALL matching exports (handles duplicates from failed runs)
    # Use process substitution to avoid subshell variable scope issues
    DELETED_COUNT=0
    FAILED_COUNT=0

    while read -r EXPORT_ARN; do
      [ -z "$EXPORT_ARN" ] && continue
      log_info "Deleting export: $EXPORT_ARN"
      if aws bcm-data-exports delete-export --export-arn "$EXPORT_ARN" 2>/dev/null; then
        log_success "Deleted: $EXPORT_ARN"
        DELETED_COUNT=$((DELETED_COUNT + 1))
      else
        log_error "Failed to delete: $EXPORT_ARN"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
      fi
    done <<< "$EXPORT_ARNS"

    if [ "$FAILED_COUNT" -gt 0 ]; then
      log_warning "Some exports failed to delete - manual cleanup may be required"
    fi
  else
    log_info "No cost exports found matching '$EXPORT_NAME*'"
  fi
else
  if [ -n "$EXPORT_ARNS" ]; then
    log_info "[DRY RUN] Would delete the following exports:"
    echo "$EXPORT_ARNS" | while read -r arn; do
      log_info "  - $arn"
    done
  else
    log_info "[DRY RUN] No exports found matching: $EXPORT_NAME*"
  fi
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

  # Determine if we're cleaning up all accounts or specific ones
  CLEANUP_ALL_ACCOUNTS=1
  ACCOUNTS_TO_CLEANUP=""
  CLEANUP_ACCOUNT_COUNT=0

  if [ -n "$CHILD_ACCOUNTS" ]; then
    CLEANUP_ALL_ACCOUNTS=0
    # Normalize the account list (remove spaces, empty entries, duplicates)
    ACCOUNTS_TO_CLEANUP=$(normalize_csv "$CHILD_ACCOUNTS")

    if [ -z "$ACCOUNTS_TO_CLEANUP" ]; then
      log_error "CHILD_ACCOUNTS is set but contains no valid entries"
      exit 1
    fi

    # Validate account ID formats
    INVALID_FORMAT=""
    VALIDATED_ACCOUNTS=""
    for acct_id in $(echo "$ACCOUNTS_TO_CLEANUP" | tr ',' ' '); do
      if ! is_valid_account_id "$acct_id"; then
        INVALID_FORMAT="$INVALID_FORMAT $acct_id"
      else
        if [ -n "$VALIDATED_ACCOUNTS" ]; then
          VALIDATED_ACCOUNTS="$VALIDATED_ACCOUNTS,$acct_id"
        else
          VALIDATED_ACCOUNTS="$acct_id"
        fi
      fi
    done

    if [ -n "$INVALID_FORMAT" ]; then
      log_error "Invalid account ID format (must be 12 digits):$INVALID_FORMAT"
      exit 1
    fi

    ACCOUNTS_TO_CLEANUP="$VALIDATED_ACCOUNTS"
    CLEANUP_ACCOUNT_COUNT=$(count_csv_items "$ACCOUNTS_TO_CLEANUP")
    log_info "Cleaning up $CLEANUP_ACCOUNT_COUNT specific account(s)"
    log_warning "Note: Account IDs are validated for format only, not checked against existing stack instances"
  else
    log_info "Cleaning up ALL $CHILD_COUNT child accounts"
  fi

  # Check all regions where stacks might exist
  REGIONS_TO_CHECK=("us-east-1" "eu-west-1" "ap-southeast-1")

  for REGION in "${REGIONS_TO_CHECK[@]}"; do
    log_info "Checking region: $REGION"

    if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" --region "$REGION" 2>/dev/null | grep -q "StackSetName"; then
      log_info "Found StackSet in region: $REGION"

      # Delete stack instances
      log_info "Deleting stack instances..."

      if [ "$DRY_RUN" = "0" ]; then
        # Get list of stack instances
        INSTANCES=$(aws cloudformation list-stack-instances \
          --stack-set-name "$STACKSET_NAME" \
          --region "$REGION" \
          --query 'Summaries[].Account' \
          --output text 2>/dev/null || echo "")

        if [ -n "$INSTANCES" ]; then
          if [ "$CLEANUP_ALL_ACCOUNTS" = "1" ]; then
            # Delete all stack instances using OU targeting
            OPERATION_ID=$(execute aws cloudformation delete-stack-instances \
              --stack-set-name "$STACKSET_NAME" \
              --deployment-targets OrganizationalUnitIds="$ROOT_ID" \
              --regions us-east-1 \
              --no-retain-stacks \
              --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100 \
              --region "$REGION" \
              --query 'OperationId' \
              --output text 2>/dev/null || echo "")
          else
            # Delete only specific account instances
            # Build JSON array of account IDs
            ACCOUNTS_JSON_ARRAY=$(echo "$ACCOUNTS_TO_CLEANUP" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
            log_info "Deleting stack instances from accounts: $ACCOUNTS_TO_CLEANUP"
            OPERATION_ID=$(execute aws cloudformation delete-stack-instances \
              --stack-set-name "$STACKSET_NAME" \
              --deployment-targets "OrganizationalUnitIds=$ROOT_ID,AccountFilterType=INTERSECTION,Accounts=[$ACCOUNTS_JSON_ARRAY]" \
              --regions us-east-1 \
              --no-retain-stacks \
              --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100 \
              --region "$REGION" \
              --query 'OperationId' \
              --output text 2>/dev/null || echo "")
          fi

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
              log_warning "Stack instance deletion timed out after ~10 minutes"
              log_warning "Operation may still complete - check AWS CloudFormation console for status"
            fi
          fi
        else
          log_info "No stack instances found"
        fi

        # Only delete StackSet itself if cleaning up ALL accounts
        if [ "$CLEANUP_ALL_ACCOUNTS" = "1" ]; then
          # Verify no instances remain before deleting StackSet
          REMAINING=$(aws cloudformation list-stack-instances \
            --stack-set-name "$STACKSET_NAME" \
            --region "$REGION" \
            --query 'Summaries[].Account' \
            --output text 2>/dev/null || echo "")

          if [ -z "$REMAINING" ]; then
            log_info "Deleting StackSet..."
            execute aws cloudformation delete-stack-set \
              --stack-set-name "$STACKSET_NAME" \
              --region "$REGION" && \
              log_success "StackSet deleted" || \
              log_warning "Failed to delete StackSet"
          else
            log_warning "Cannot delete StackSet - some stack instances still exist"
            log_info "Remaining accounts: $REMAINING"
          fi
        else
          log_info "StackSet retained (only cleaning up specific accounts)"
        fi
      else
        if [ "$CLEANUP_ALL_ACCOUNTS" = "1" ]; then
          log_info "[DRY RUN] Would delete StackSet: $STACKSET_NAME"
        else
          log_info "[DRY RUN] Would delete stack instances from: $ACCOUNTS_TO_CLEANUP"
          log_info "[DRY RUN] StackSet would be retained"
        fi
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
  if [ "$CLEANUP_FAILURES" -gt 0 ]; then
    log_warning "Tailpipe cleanup completed with $CLEANUP_FAILURES failure(s)"
    log_warning "Some resources may require manual cleanup"
    echo ""
    log_info "Resources processed:"
  else
    log_success "Tailpipe cleanup complete!"
    echo ""
    log_info "Resources deleted:"
  fi
  log_info "  ✓ Cost and Usage Report export(s)"
  [ "$KEEP_DATA" != "1" ] && log_info "  ✓ S3 bucket and data"
  [ "$KEEP_ROLE" != "1" ] && log_info "  ✓ IAM role and policies"
  [ "$IS_MANAGEMENT_ACCOUNT" = "1" ] && [ "$CHILD_COUNT" -gt 0 ] && log_info "  ✓ CloudFormation StackSets"
fi

log_info ""
log_info "Cleanup script finished"

# Exit with error code if there were failures
[ "$CLEANUP_FAILURES" -gt 0 ] && exit 1 || exit 0
