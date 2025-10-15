#!/usr/bin/env bash
#
# Tailpipe GCP Cleanup Script
#
# This script removes all Tailpipe resources from your GCP environment:
# - Service account and keys
# - BigQuery dataset and billing export
# - GCS bucket and data
# - IAM permissions
# - Workload Identity pools (optional)
# - Project (optional)
#
# Usage:
#   ./cleanup-tailpipe.sh                          # Interactive mode with confirmations
#   FORCE=1 ./cleanup-tailpipe.sh                  # Skip confirmations
#   DRY_RUN=1 ./cleanup-tailpipe.sh                # Preview without deleting
#   KEEP_DATA=1 ./cleanup-tailpipe.sh              # Keep bucket and dataset
#   KEEP_PROJECT=1 ./cleanup-tailpipe.sh           # Keep project
#
# Environment Variables:
#   PROJECT_ID      - GCP project ID (auto-detected if not set)
#   DRY_RUN         - Set to 1 to preview deletions without executing
#   FORCE           - Set to 1 to skip all confirmations
#   KEEP_DATA       - Set to 1 to preserve bucket and dataset
#   KEEP_PROJECT    - Set to 1 to preserve project
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
BUCKET_PREFIX="tailpipe-billing-export"
DATASET_NAME="billing_export"
SERVICE_ACCOUNT_NAME="tailpipe-connector"
WORKLOAD_POOL_ID="tailpipe-pool"
WORKLOAD_PROVIDER_ID="tailpipe-provider"

# Options
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
KEEP_DATA="${KEEP_DATA:-0}"
KEEP_PROJECT="${KEEP_PROJECT:-0}"
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--verbosity=debug"

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

check_gcloud() {
  if ! command -v gcloud &> /dev/null; then
    log_error "gcloud CLI not found"
    exit 1
  fi
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

log_section "Tailpipe GCP Cleanup"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No resources will be deleted"
fi

if [ "$KEEP_DATA" = "1" ]; then
  log_warning "KEEP_DATA set - Bucket and dataset will be preserved"
fi

if [ "$KEEP_PROJECT" = "1" ]; then
  log_warning "KEEP_PROJECT set - Project will be preserved"
fi

# Check prerequisites
check_gcloud

# Get project ID
if [ -n "${PROJECT_ID:-}" ]; then
  log_info "Using PROJECT_ID from environment: $PROJECT_ID"
else
  # Try to get from gcloud config
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")

  if [ -z "$PROJECT_ID" ]; then
    echo "Enter GCP Project ID to clean up:"
    read -r PROJECT_ID
  fi
fi

if [ -z "$PROJECT_ID" ]; then
  log_error "No project ID provided"
  exit 1
fi

log_info "Target project: $PROJECT_ID"

# Check if project exists
if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
  log_error "Project not found: $PROJECT_ID"
  exit 1
fi

# Get project details
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || echo "")
BUCKET_NAME="${BUCKET_PREFIX}-${PROJECT_ID}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Try to detect organization
ORGANIZATION_ID=$(gcloud projects describe "$PROJECT_ID" --format="value(parent.id)" 2>/dev/null || echo "")
if [ -n "$ORGANIZATION_ID" ] && [ "$ORGANIZATION_ID" != "null" ]; then
  log_info "Project is part of organization: $ORGANIZATION_ID"
fi

#==============================================================================
# CONFIRMATION
#==============================================================================

if [ "$FORCE" != "1" ]; then
  log_section "Resources to be Deleted"

  echo "The following resources will be removed:"
  echo ""
  echo "  👤 Service Account:"
  echo "     - Email: $SERVICE_ACCOUNT_EMAIL"
  echo "     - All associated keys"
  echo ""

  if [ "$KEEP_DATA" != "1" ]; then
    echo "  📊 BigQuery Dataset:"
    echo "     - Dataset: $DATASET_NAME"
    echo "     - ALL BILLING DATA WILL BE DELETED"
    echo ""
    echo "  🪣 GCS Bucket:"
    echo "     - Bucket: $BUCKET_NAME"
    echo "     - ALL DATA WILL BE DELETED"
    echo ""
  fi

  echo "  🔐 IAM Permissions:"
  echo "     - Project-level roles"
  if [ -n "$ORGANIZATION_ID" ]; then
    echo "     - Organization-level roles"
  fi
  echo ""

  echo "  🔑 Workload Identity (if configured):"
  echo "     - Pool: $WORKLOAD_POOL_ID"
  echo "     - Provider: $WORKLOAD_PROVIDER_ID"
  echo ""

  if [ "$KEEP_PROJECT" != "1" ]; then
    echo "  📦 Project (OPTIONAL):"
    echo "     - Project ID: $PROJECT_ID"
    echo "     - Project Number: $PROJECT_NUMBER"
    echo "     - THIS WILL DELETE THE ENTIRE PROJECT"
    echo ""
  fi

  if ! confirm "Do you want to proceed with cleanup?"; then
    log_warning "Cleanup cancelled by user"
    exit 0
  fi
fi

#==============================================================================
# DELETE SERVICE ACCOUNT KEYS
#==============================================================================

log_section "Deleting Service Account Keys"

if [ "$DRY_RUN" = "0" ]; then
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    log_info "Deleting service account keys..."

    KEYS=$(gcloud iam service-accounts keys list \
      --iam-account="$SERVICE_ACCOUNT_EMAIL" \
      --project="$PROJECT_ID" \
      --format="value(name)" \
      --filter="keyType=USER_MANAGED" 2>/dev/null || echo "")

    KEY_COUNT=0
    for key in $KEYS; do
      [ -z "$key" ] && continue
      execute gcloud iam service-accounts keys delete "$key" \
        --iam-account="$SERVICE_ACCOUNT_EMAIL" \
        --project="$PROJECT_ID" \
        --quiet $DEBUG_FLAG && \
        KEY_COUNT=$((KEY_COUNT + 1))
    done

    if [ $KEY_COUNT -gt 0 ]; then
      log_success "Deleted $KEY_COUNT service account key(s)"
    else
      log_info "No user-managed keys found"
    fi

    # Delete local key file if it exists
    KEY_FILE="tailpipe-gcp-key-${PROJECT_ID}.json"
    if [ -f "$KEY_FILE" ]; then
      log_info "Deleting local key file: $KEY_FILE"
      rm -f "$KEY_FILE"
      log_success "Local key file deleted"
    fi
  else
    log_info "Service account not found"
  fi
else
  log_info "[DRY RUN] Would delete service account keys"
fi

#==============================================================================
# REMOVE IAM PERMISSIONS
#==============================================================================

log_section "Removing IAM Permissions"

if [ "$DRY_RUN" = "0" ]; then
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    # Remove project-level permissions
    log_info "Removing project-level permissions..."

    PROJECT_ROLES=(
      "roles/bigquery.dataViewer"
      "roles/bigquery.jobUser"
      "roles/storage.objectViewer"
      "roles/monitoring.viewer"
      "roles/compute.viewer"
    )

    for role in "${PROJECT_ROLES[@]}"; do
      execute gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
        --role="$role" \
        --no-user-output-enabled $DEBUG_FLAG 2>/dev/null || true
    done

    log_success "Project-level permissions removed"

    # Remove organization-level permissions (if applicable)
    if [ -n "$ORGANIZATION_ID" ]; then
      log_info "Removing organization-level permissions..."

      ORG_ROLES=(
        "roles/billing.viewer"
        "roles/monitoring.viewer"
      )

      for role in "${ORG_ROLES[@]}"; do
        execute gcloud organizations remove-iam-policy-binding "$ORGANIZATION_ID" \
          --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
          --role="$role" \
          --no-user-output-enabled $DEBUG_FLAG 2>/dev/null || true
      done

      log_success "Organization-level permissions removed"
    fi
  fi
else
  log_info "[DRY RUN] Would remove IAM permissions"
fi

#==============================================================================
# DELETE WORKLOAD IDENTITY
#==============================================================================

log_section "Deleting Workload Identity Configuration"

if [ "$DRY_RUN" = "0" ]; then
  # Delete workload identity provider
  if gcloud iam workload-identity-pools providers describe "$WORKLOAD_PROVIDER_ID" \
       --location="global" \
       --workload-identity-pool="$WORKLOAD_POOL_ID" \
       --project="$PROJECT_ID" &>/dev/null; then

    log_info "Deleting workload identity provider..."
    execute gcloud iam workload-identity-pools providers delete "$WORKLOAD_PROVIDER_ID" \
      --location="global" \
      --workload-identity-pool="$WORKLOAD_POOL_ID" \
      --project="$PROJECT_ID" \
      --quiet $DEBUG_FLAG && \
      log_success "Workload identity provider deleted" || \
      log_warning "Failed to delete workload identity provider"
  else
    log_info "Workload identity provider not found"
  fi

  # Delete workload identity pool
  if gcloud iam workload-identity-pools describe "$WORKLOAD_POOL_ID" \
       --location="global" \
       --project="$PROJECT_ID" &>/dev/null; then

    log_info "Deleting workload identity pool..."
    execute gcloud iam workload-identity-pools delete "$WORKLOAD_POOL_ID" \
      --location="global" \
      --project="$PROJECT_ID" \
      --quiet $DEBUG_FLAG && \
      log_success "Workload identity pool deleted" || \
      log_warning "Failed to delete workload identity pool"
  else
    log_info "Workload identity pool not found"
  fi
else
  log_info "[DRY RUN] Would delete workload identity configuration"
fi

#==============================================================================
# DELETE SERVICE ACCOUNT
#==============================================================================

log_section "Deleting Service Account"

if [ "$DRY_RUN" = "0" ]; then
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    log_info "Deleting service account: $SERVICE_ACCOUNT_EMAIL"
    execute gcloud iam service-accounts delete "$SERVICE_ACCOUNT_EMAIL" \
      --project="$PROJECT_ID" \
      --quiet $DEBUG_FLAG && \
      log_success "Service account deleted" || \
      log_warning "Failed to delete service account"
  else
    log_info "Service account not found"
  fi
else
  log_info "[DRY RUN] Would delete service account: $SERVICE_ACCOUNT_EMAIL"
fi

#==============================================================================
# DELETE DATA RESOURCES
#==============================================================================

if [ "$KEEP_DATA" != "1" ]; then
  log_section "Deleting Data Resources"

  if [ "$FORCE" != "1" ] && [ "$DRY_RUN" = "0" ]; then
    log_warning "This will DELETE ALL BILLING DATA in BigQuery and GCS"
    if ! confirm "Are you sure you want to delete all data?"; then
      log_warning "Data deletion skipped"
      KEEP_DATA=1
    fi
  fi

  if [ "$KEEP_DATA" != "1" ]; then
    # Delete BigQuery dataset
    log_info "Deleting BigQuery dataset: $DATASET_NAME"

    if [ "$DRY_RUN" = "0" ]; then
      if bq ls -d --project_id="$PROJECT_ID" 2>/dev/null | grep -q "$DATASET_NAME"; then
        execute bq rm -r -f -d --project_id="$PROJECT_ID" "$DATASET_NAME" && \
          log_success "BigQuery dataset deleted" || \
          log_warning "Failed to delete BigQuery dataset"
      else
        log_info "BigQuery dataset not found"
      fi
    else
      log_info "[DRY RUN] Would delete BigQuery dataset: $DATASET_NAME"
    fi

    # Delete GCS bucket
    log_info "Deleting GCS bucket: $BUCKET_NAME"

    if [ "$DRY_RUN" = "0" ]; then
      if gsutil ls -b "gs://$BUCKET_NAME" &>/dev/null; then
        # Remove all objects first
        log_info "Removing all objects from bucket..."
        execute gsutil -m rm -r "gs://$BUCKET_NAME/**" 2>/dev/null || true

        # Delete bucket
        execute gsutil rb "gs://$BUCKET_NAME" && \
          log_success "GCS bucket deleted" || \
          log_warning "Failed to delete GCS bucket"
      else
        log_info "GCS bucket not found"
      fi
    else
      log_info "[DRY RUN] Would delete GCS bucket: $BUCKET_NAME"
    fi
  fi
else
  log_info "Skipping data deletion (KEEP_DATA=1)"
fi

#==============================================================================
# DISABLE BILLING EXPORT
#==============================================================================

log_section "Billing Export Configuration"

log_warning "Billing export configuration must be removed manually"
log_info "Visit: https://console.cloud.google.com/billing"
log_info "Navigate to 'Billing Export' and disable BigQuery export for this project"

#==============================================================================
# DELETE PROJECT (OPTIONAL)
#==============================================================================

if [ "$KEEP_PROJECT" != "1" ]; then
  log_section "Deleting Project (Optional)"

  if [ "$FORCE" != "1" ] && [ "$DRY_RUN" = "0" ]; then
    log_warning "This will DELETE THE ENTIRE PROJECT: $PROJECT_ID"
    log_warning "All resources in the project will be permanently deleted"
    if ! confirm "Are you absolutely sure you want to delete the project?"; then
      log_warning "Project deletion skipped"
      KEEP_PROJECT=1
    fi
  fi

  if [ "$KEEP_PROJECT" != "1" ]; then
    log_info "Deleting project: $PROJECT_ID"

    if [ "$DRY_RUN" = "0" ]; then
      execute gcloud projects delete "$PROJECT_ID" --quiet $DEBUG_FLAG && \
        log_success "Project deletion initiated" || \
        log_warning "Failed to delete project"

      log_warning "Project deletion may take several minutes to complete"
    else
      log_info "[DRY RUN] Would delete project: $PROJECT_ID"
    fi
  fi
else
  log_info "Skipping project deletion (KEEP_PROJECT=1)"
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
  log_info "  ✓ Service account and keys"
  log_info "  ✓ IAM permissions"
  log_info "  ✓ Workload Identity configuration"
  [ "$KEEP_DATA" != "1" ] && log_info "  ✓ BigQuery dataset and GCS bucket"
  [ "$KEEP_PROJECT" != "1" ] && log_info "  ✓ Project (deletion in progress)"
  echo ""
  log_warning "Manual action required:"
  log_warning "Disable billing export at: https://console.cloud.google.com/billing"
fi

log_info ""
log_info "Cleanup script finished"
