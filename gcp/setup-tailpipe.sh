#!/usr/bin/env bash
#
# Tailpipe GCP Setup - Unified Installation Script
#
# This script sets up everything needed for Tailpipe cost analytics in GCP:
# 1. Verify organization/billing account access
# 2. Create GCS bucket for BigQuery billing data export
# 3. Configure BigQuery billing export
# 4. Create service account for Tailpipe access
# 5. Grant monitoring and billing permissions
#
# Usage:
#   ./setup-tailpipe.sh                    # Interactive mode
#   DRY_RUN=1 ./setup-tailpipe.sh          # Preview changes without executing
#   PROJECT_ID=xxx BILLING_ACCOUNT=xxx ./setup-tailpipe.sh   # Non-interactive
#
# Environment Variables:
#   PROJECT_ID          - GCP project for resources (will be created if not exists)
#   BILLING_ACCOUNT     - Billing account ID (format: XXXXXX-XXXXXX-XXXXXX)
#   ORGANIZATION_ID     - Organization ID (auto-detected if not set)
#   REGION              - GCS region (default: us-central1)
#   TAILPIPE_DOMAIN     - Tailpipe service account domain (default: tailpipe.io)
#   DRY_RUN             - Set to 1 to preview without making changes
#   FORCE               - Set to 1 to skip confirmations
#   DEBUG               - Set to 1 for verbose gcloud output
#

set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO (exit $?): see above"' ERR

#==============================================================================
# CONFIGURATION
#==============================================================================

# Script version
VERSION="1.2.0"

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
DEFAULT_PROJECT_ID="tailpipe-dataexport"
BUCKET_PREFIX="tailpipe-billing-export"
DATASET_NAME="billing_export"
SERVICE_ACCOUNT_NAME="tailpipe-connector"
SERVICE_ACCOUNT_DISPLAY_NAME="Tailpipe Cost Analytics Connector"

# Tailpipe domains
TAILPIPE_PROD_DOMAIN="tailpipe.io"
TAILPIPE_UAT_DOMAIN="tailpipe-uat.io"

# Default to production unless overridden
TAILPIPE_DOMAIN="${TAILPIPE_DOMAIN:-$TAILPIPE_PROD_DOMAIN}"

# Options
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
DEBUG="${DEBUG:-0}"
DEBUG_FLAG=""
[ "$DEBUG" = "1" ] && DEBUG_FLAG="--verbosity=debug"

# Default region
DEFAULT_REGION="us-central1"
REGION="${REGION:-$DEFAULT_REGION}"

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
  read -rep "$prompt [y/N]: " response
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
    log_error "gcloud CLI not found. Please install: https://cloud.google.com/sdk/docs/install"
    exit 1
  fi

  local gcloud_version
  gcloud_version=$(gcloud version --format="value(version)" 2>/dev/null || echo "unknown")
  log_info "gcloud CLI version: $gcloud_version"
}

check_authenticated() {
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    log_error "Not authenticated with gcloud. Please run: gcloud auth login"
    exit 1
  fi

  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  log_info "Authenticated as: $ACTIVE_ACCOUNT"
}

enable_api() {
  local api="$1"
  local project="$2"

  if gcloud services list --enabled --project="$project" --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
    log_info "$api already enabled"
  else
    log_info "Enabling $api..."
    execute gcloud services enable "$api" --project="$project" $DEBUG_FLAG || {
      log_warning "Failed to enable $api"
      return 1
    }
    log_success "$api enabled"
  fi
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

log_section "Tailpipe GCP Setup v$VERSION"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "DRY RUN MODE - No changes will be made"
fi

# Check prerequisites
check_gcloud
check_authenticated

# Get configuration
if [ -n "${BILLING_ACCOUNT:-}" ]; then
  log_info "Using BILLING_ACCOUNT from environment: $BILLING_ACCOUNT"
else
  # Try to list available billing accounts
  log_info "Fetching available billing accounts..."
  BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName,open)" 2>/dev/null || echo "")

  if [ -z "$BILLING_ACCOUNTS" ]; then
    log_warning "No billing accounts found or no permission to list them"
    echo ""
    echo "Enter your GCP Billing Account ID (format: XXXXXX-XXXXXX-XXXXXX):"
    echo "Find it at: https://console.cloud.google.com/billing"
    read -re BILLING_ACCOUNT
  else
    echo ""
    echo "Available Billing Accounts:"
    echo "-----------------------------------------------------------"
    printf "%-4s %-22s %-30s %s\n" "No." "Billing Account ID" "Name" "Status"
    echo "-----------------------------------------------------------"

    # Build array of billing accounts
    BILLING_ARRAY=()
    BILLING_NAMES=()
    BILLING_STATUS=()
    INDEX=1

    while IFS=$'\t' read -r ba_id ba_name ba_open; do
      [ -z "$ba_id" ] && continue
      BILLING_ARRAY+=("$ba_id")
      BILLING_NAMES+=("$ba_name")
      BILLING_STATUS+=("$ba_open")

      STATUS_DISPLAY="CLOSED"
      [ "$ba_open" = "True" ] && STATUS_DISPLAY="OPEN"

      printf "%-4s %-22s %-30.30s %s\n" "$INDEX." "$ba_id" "$ba_name" "$STATUS_DISPLAY"
      INDEX=$((INDEX + 1))
    done <<< "$BILLING_ACCOUNTS"

    echo "-----------------------------------------------------------"
    echo ""
    log_warning "⚠️  Only select OPEN billing accounts (CLOSED accounts won't work)"
    echo ""

    if [ "${#BILLING_ARRAY[@]}" -eq 1 ]; then
      # Only one billing account, check if it's open
      BILLING_ACCOUNT="${BILLING_ARRAY[0]}"
      if [ "${BILLING_STATUS[0]}" = "True" ]; then
        log_info "Using only available billing account: $BILLING_ACCOUNT (${BILLING_NAMES[0]})"
      else
        log_warning "Only billing account available is CLOSED: $BILLING_ACCOUNT"
        log_warning "You need to reactivate it or add a payment method first"
        echo ""
        echo "Enter a different billing account ID, or press Ctrl+C to exit:"
        read -re BILLING_ACCOUNT
      fi
    else
      # Multiple accounts, prompt for selection
      echo "Select billing account(s):"
      echo "  - Enter a number (e.g., 2)"
      echo "  - Enter multiple numbers separated by commas (e.g., 1,2,3)"
      echo "  - Enter 'all' to configure all OPEN billing accounts"
      echo "  - Press Enter to manually enter ID(s)"
      echo ""
      read -rep "Selection: " CHOICE

      if [ "$CHOICE" = "all" ]; then
        # Select all OPEN billing accounts
        BILLING_ACCOUNTS=()
        for i in "${!BILLING_ARRAY[@]}"; do
          if [ "${BILLING_STATUS[$i]}" = "True" ]; then
            BILLING_ACCOUNTS+=("${BILLING_ARRAY[$i]}")
            log_info "Selected: ${BILLING_ARRAY[$i]} (${BILLING_NAMES[$i]})"
          fi
        done

        if [ ${#BILLING_ACCOUNTS[@]} -eq 0 ]; then
          log_error "No OPEN billing accounts found"
          exit 1
        fi

        log_success "Selected ${#BILLING_ACCOUNTS[@]} OPEN billing account(s)"

      elif [ -n "$CHOICE" ] && [[ "$CHOICE" =~ ^[0-9,]+$ ]]; then
        # Multiple selections (comma-separated numbers)
        IFS=',' read -ra SELECTIONS <<< "$CHOICE"
        BILLING_ACCOUNTS=()

        for selection in "${SELECTIONS[@]}"; do
          selection=$(echo "$selection" | tr -d ' ') # Remove spaces
          if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#BILLING_ARRAY[@]}" ]; then
            ARRAY_INDEX=$((selection - 1))
            BILLING_ACCOUNTS+=("${BILLING_ARRAY[$ARRAY_INDEX]}")

            if [ "${BILLING_STATUS[$ARRAY_INDEX]}" != "True" ]; then
              log_warning "⚠️  Selected billing account is CLOSED: ${BILLING_ARRAY[$ARRAY_INDEX]}"
            else
              log_info "Selected: ${BILLING_ARRAY[$ARRAY_INDEX]} (${BILLING_NAMES[$ARRAY_INDEX]})"
            fi
          else
            log_warning "Invalid selection: $selection (skipped)"
          fi
        done

        if [ ${#BILLING_ACCOUNTS[@]} -eq 0 ]; then
          log_error "No valid billing accounts selected"
          exit 1
        fi

        log_success "Selected ${#BILLING_ACCOUNTS[@]} billing account(s)"

      elif [ -z "$CHOICE" ]; then
        # Manual entry (can be comma-separated)
        echo "Enter billing account ID(s) manually (comma-separated for multiple):"
        read -re MANUAL_INPUT
        IFS=',' read -ra BILLING_ACCOUNTS <<< "$MANUAL_INPUT"

        # Trim whitespace
        for i in "${!BILLING_ACCOUNTS[@]}"; do
          BILLING_ACCOUNTS[$i]=$(echo "${BILLING_ACCOUNTS[$i]}" | xargs)
        done

      else
        log_error "Invalid input. Please enter a number, comma-separated numbers, 'all', or press Enter."
        exit 1
      fi
    fi
  fi
fi

# Handle single billing account (convert to array for consistent processing)
if [ -n "${BILLING_ACCOUNT:-}" ]; then
  BILLING_ACCOUNTS=("$BILLING_ACCOUNT")
fi

if [ ${#BILLING_ACCOUNTS[@]} -eq 0 ]; then
  log_error "No billing accounts provided"
  exit 1
fi

# Store primary billing account (first one) for backward compatibility
BILLING_ACCOUNT="${BILLING_ACCOUNTS[0]}"

if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
  log_info "Multi-billing account setup: ${#BILLING_ACCOUNTS[@]} accounts"
  log_info "All billing data will be exported to a single BigQuery dataset"
  log_info "Each account creates separate tables in the dataset"
else
  log_info "Single billing account setup"
fi

# Validate all billing account formats
for ba in "${BILLING_ACCOUNTS[@]}"; do
  if ! echo "$ba" | grep -qE '^[A-F0-9]{6}-[A-F0-9]{6}-[A-F0-9]{6}$'; then
    log_warning "Billing account format looks unusual: $ba (expected: XXXXXX-XXXXXX-XXXXXX)"
    if [ "$FORCE" != "1" ]; then
      if ! confirm "Continue anyway?"; then
        exit 1
      fi
    fi
  fi
done


# Get or create project
if [ -n "${PROJECT_ID:-}" ]; then
  log_info "Using PROJECT_ID from environment: $PROJECT_ID"
else
  echo "Enter GCP Project ID for Tailpipe resources (or press Enter for default: $DEFAULT_PROJECT_ID):"
  read -re PROJECT_ID
  PROJECT_ID="${PROJECT_ID:-$DEFAULT_PROJECT_ID}"
fi

# Get region
if [ -n "${REGION:-}" ] && [ "$REGION" != "$DEFAULT_REGION" ]; then
  log_info "Using REGION from environment: $REGION"
else
  echo ""
  echo "Select region for storage resources:"
  echo "  Recommended regions (low cost, high availability):"
  echo "    1. us-central1     (Iowa, USA)"
  echo "    2. us-east1        (South Carolina, USA)"
  echo "    3. europe-west1    (Belgium)"
  echo "    4. asia-southeast1 (Singapore)"
  echo ""
  echo "  Or enter a custom region (e.g., us-west1, europe-north1)"
  echo "  Full list: https://cloud.google.com/storage/docs/locations"
  echo ""
  read -rep "Enter region number or custom region [$DEFAULT_REGION]: " REGION_CHOICE

  case "$REGION_CHOICE" in
    1|"")
      REGION="us-central1"
      ;;
    2)
      REGION="us-east1"
      ;;
    3)
      REGION="europe-west1"
      ;;
    4)
      REGION="asia-southeast1"
      ;;
    *)
      REGION="$REGION_CHOICE"
      ;;
  esac
fi

log_info "Target project: $PROJECT_ID"
log_info "Target region: $REGION"
log_info "Billing account: $BILLING_ACCOUNT"

# Check billing account access
log_info "Checking billing account permissions..."

# Function to run command with timeout (works on macOS and Linux)
run_with_timeout() {
  local timeout_sec="$1"
  shift

  if command -v timeout &>/dev/null; then
    # GNU timeout (Linux, or brew install coreutils on macOS)
    timeout "$timeout_sec" "$@"
  elif command -v gtimeout &>/dev/null; then
    # GNU timeout from coreutils on macOS
    gtimeout "$timeout_sec" "$@"
  else
    # Fallback: use background process with kill
    ( "$@" ) &
    local pid=$!
    ( sleep "$timeout_sec"; kill -9 $pid 2>/dev/null ) &
    local killer=$!
    wait $pid 2>/dev/null
    local result=$?
    kill -9 $killer 2>/dev/null
    return $result
  fi
}

# Try to check billing account (with timeout to prevent hanging)
if run_with_timeout 10 gcloud beta billing accounts describe "$BILLING_ACCOUNT" --format="value(name)" &>/dev/null; then
  log_success "Can access billing account"

  # Check if user has billing admin role (with timeout)
  BILLING_MEMBERS=$(run_with_timeout 10 gcloud beta billing accounts get-iam-policy "$BILLING_ACCOUNT" \
       --flatten="bindings[].members" \
       --filter="bindings.role:roles/billing.admin" \
       --format="value(bindings.members)" 2>/dev/null || echo "")

  if echo "$BILLING_MEMBERS" | grep -q "$ACTIVE_ACCOUNT"; then
    log_success "You have Billing Account Administrator role"
    HAS_BILLING_ADMIN=1
  else
    log_warning "You don't have Billing Account Administrator role (roles/billing.admin)"
    log_warning "Billing export configuration will need to be done manually"
    log_info "To check your billing roles: https://console.cloud.google.com/billing/$BILLING_ACCOUNT?project=$PROJECT_ID"
    HAS_BILLING_ADMIN=0
  fi
else
  log_warning "Cannot verify billing account access (command timed out or failed)"
  log_warning "This might mean:"
  log_warning "  - The billing account ID is incorrect"
  log_warning "  - You don't have billing.accounts.get permission"
  log_warning "  - gcloud beta commands are not available"
  log_info "Continuing setup - billing export will need manual configuration"
  HAS_BILLING_ADMIN=0
fi

# Try to detect organization
if [ -z "${ORGANIZATION_ID:-}" ]; then
  log_info "Detecting organization..."
  ORGANIZATION_ID=$(gcloud organizations list --format="value(name)" 2>/dev/null | head -1 || echo "")

  if [ -n "$ORGANIZATION_ID" ]; then
    ORG_DISPLAY_NAME=$(gcloud organizations describe "$ORGANIZATION_ID" --format="value(displayName)" 2>/dev/null || echo "")
    log_info "Detected organization: $ORG_DISPLAY_NAME ($ORGANIZATION_ID)"
  else
    log_warning "No organization detected (standalone billing account)"
  fi
fi

#==============================================================================
# PHASE 1: PROJECT SETUP
#==============================================================================

log_section "Phase 1: Project Setup"

# Check if project exists
PROJECT_INFO=$(gcloud projects describe "$PROJECT_ID" --format="value(lifecycleState,name)" 2>/dev/null || echo "NOT_FOUND")

if [ "$PROJECT_INFO" = "NOT_FOUND" ]; then
  # Project doesn't exist, we can create it
  EXISTING_PROJECT=0
elif echo "$PROJECT_INFO" | grep -q "DELETE_REQUESTED"; then
  log_error "Project $PROJECT_ID is pending deletion (30-day retention period)"
  log_error "You cannot use this project ID until deletion completes"
  log_error ""
  log_error "Options:"
  log_error "1. Restore the project (if you want to keep it):"
  log_error "   gcloud projects undelete $PROJECT_ID"
  log_error ""
  log_error "2. Use a different project ID (RECOMMENDED):"
  log_error "   PROJECT_ID=tailpipe-dataexport-$(date +%Y%m%d) ./setup-tailpipe.sh"
  log_error ""
  log_error "3. Wait 30 days for complete deletion (not recommended)"
  exit 1
else
  log_warning "Project already exists: $PROJECT_ID"
  EXISTING_PROJECT=1

  # Check if project is active
  if ! echo "$PROJECT_INFO" | grep -q "ACTIVE"; then
    log_error "Project exists but is not in ACTIVE state: $(echo "$PROJECT_INFO" | awk '{print $1}')"
    exit 1
  fi

  # Check if we have permission to modify this project
  PROJECT_OWNER=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.role:roles/owner" \
    --format="value(bindings.members)" 2>/dev/null | grep "$ACTIVE_ACCOUNT" || echo "")

  if [ -z "$PROJECT_OWNER" ]; then
    log_error "Project exists but you don't have Owner role on it"
    log_error "This usually means the project was created by someone else"
    log_error ""
    log_error "Options:"
    log_error "1. Use a different project ID:"
    log_error "   PROJECT_ID=tailpipe-dataexport-2 ./setup-tailpipe.sh"
    log_error ""
    log_error "2. Get Owner role on the existing project from an admin"
    log_error ""
    log_error "3. If you're sure you want to delete it:"
    log_error "   gcloud projects delete $PROJECT_ID"
    log_error "   Then use a different project ID (deletion takes 30 days)"
    exit 1
  else
    log_success "You have Owner role on existing project"
  fi
fi

if [ "$EXISTING_PROJECT" = "0" ]; then
  log_info "Creating project: $PROJECT_ID"

  if [ "$DRY_RUN" = "0" ]; then
    if [ -n "$ORGANIZATION_ID" ]; then
      execute gcloud projects create "$PROJECT_ID" \
        --organization="$ORGANIZATION_ID" \
        --name="Tailpipe Data Export" \
        --set-as-default $DEBUG_FLAG || {
        log_error "Failed to create project"
        exit 1
      }
    else
      execute gcloud projects create "$PROJECT_ID" \
        --name="Tailpipe Data Export" \
        --set-as-default $DEBUG_FLAG || {
        log_error "Failed to create project"
        exit 1
      }
    fi
    log_success "Project created"
  else
    log_info "[DRY RUN] Would create project: $PROJECT_ID"
  fi
fi

# Link billing account
log_info "Linking billing account to project..."

if [ "$DRY_RUN" = "0" ]; then
  CURRENT_BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || echo "")

  if [ "$CURRENT_BILLING" = "$BILLING_ACCOUNT" ]; then
    log_info "Billing account already linked"
  else
    if ! gcloud billing projects link "$PROJECT_ID" \
      --billing-account="$BILLING_ACCOUNT" $DEBUG_FLAG 2>&1; then
      log_error "Failed to link billing account"
      log_error ""
      log_error "This usually means:"
      log_error "1. You don't have 'Billing Account User' role on the billing account"
      log_error "2. You don't have 'Project Billing Manager' role on the project"
      log_error ""
      log_error "To fix this, a billing administrator needs to run:"
      log_error "  gcloud billing accounts add-iam-policy-binding $BILLING_ACCOUNT \\"
      log_error "    --member='user:$ACTIVE_ACCOUNT' \\"
      log_error "    --role='roles/billing.user'"
      log_error ""
      log_error "Or manually link billing at:"
      log_error "  https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
      exit 1
    fi
    log_success "Billing account linked"
  fi

  # Verify billing is actually enabled
  log_info "Verifying billing is enabled..."
  BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")

  # Convert to lowercase for comparison (gcloud returns "True" with capital T)
  BILLING_ENABLED_LOWER=$(echo "$BILLING_ENABLED" | tr '[:upper:]' '[:lower:]')

  if [ "$BILLING_ENABLED_LOWER" != "true" ]; then
    log_error "Billing account is linked but NOT ENABLED"
    log_error ""
    log_error "This means the billing account '$BILLING_ACCOUNT' is closed or disabled."
    log_error ""
    log_error "To fix this:"
    log_error "1. Go to: https://console.cloud.google.com/billing/$BILLING_ACCOUNT"
    log_error "2. Check if the billing account is 'OPEN' (active)"
    log_error "3. If it shows 'CLOSED', you need to:"
    log_error "   - Add a valid payment method"
    log_error "   - OR reactivate the billing account"
    log_error "   - OR use a different active billing account"
    log_error ""
    log_error "Available billing accounts:"
    gcloud billing accounts list --format="table(name,displayName,open)" 2>/dev/null || true
    log_error ""
    log_error "To use a different billing account, re-run:"
    log_error "  BILLING_ACCOUNT=<active-account-id> ./setup-tailpipe.sh"
    exit 1
  else
    log_success "Billing is enabled and active"
  fi
else
  log_info "[DRY RUN] Would link billing account: $BILLING_ACCOUNT"
fi

# Set default project
execute gcloud config set project "$PROJECT_ID" 2>/dev/null || true

# Enable required APIs
log_info "Enabling required APIs..."

REQUIRED_APIS=(
  "cloudbilling.googleapis.com"
  "bigquery.googleapis.com"
  "storage-api.googleapis.com"
  "storage-component.googleapis.com"
  "iam.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "monitoring.googleapis.com"
  "compute.googleapis.com"
)

for api in "${REQUIRED_APIS[@]}"; do
  enable_api "$api" "$PROJECT_ID" || true
done

log_success "Phase 1 complete: Project configured"

#==============================================================================
# PHASE 2: STORAGE SETUP
#==============================================================================

log_section "Phase 2: Storage Setup"

# Create GCS bucket for billing export
BUCKET_NAME="${BUCKET_PREFIX}-${PROJECT_ID}"
log_info "Creating GCS bucket: $BUCKET_NAME"

if [ "$DRY_RUN" = "0" ]; then
  if gsutil ls -b "gs://$BUCKET_NAME" &>/dev/null; then
    log_warning "Bucket already exists"
  else
    execute gsutil mb -p "$PROJECT_ID" -c STANDARD -l "$REGION" "gs://$BUCKET_NAME" || {
      log_error "Failed to create bucket"
      exit 1
    }
    log_success "Bucket created"
  fi

  # Set lifecycle policy to auto-delete old exports (optional, 90 days)
  log_info "Setting bucket lifecycle policy..."

  LIFECYCLE_FILE=$(mktemp)
  cat > "$LIFECYCLE_FILE" <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {"age": 90}
      }
    ]
  }
}
EOF

  execute gsutil lifecycle set "$LIFECYCLE_FILE" "gs://$BUCKET_NAME" || {
    log_warning "Failed to set lifecycle policy (non-critical)"
  }
  rm -f "$LIFECYCLE_FILE"

else
  log_info "[DRY RUN] Would create bucket: $BUCKET_NAME"
fi

# Create BigQuery dataset for billing export
log_info "Creating BigQuery dataset: $DATASET_NAME"

if [ "$DRY_RUN" = "0" ]; then
  if bq ls -d --project_id="$PROJECT_ID" | grep -q "$DATASET_NAME"; then
    log_warning "Dataset already exists"
  else
    execute bq mk --project_id="$PROJECT_ID" --dataset --location="$REGION" "$DATASET_NAME" || {
      log_error "Failed to create dataset"
      exit 1
    }
    log_success "Dataset created"
  fi
else
  log_info "[DRY RUN] Would create dataset: $DATASET_NAME"
fi

log_success "Phase 2 complete: Storage configured"

#==============================================================================
# PHASE 3: BILLING EXPORT CONFIGURATION
#==============================================================================

log_section "Phase 3: Billing Export Configuration"

if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
  log_info "Configuring billing export for ${#BILLING_ACCOUNTS[@]} billing accounts..."
  log_info "All accounts will export to the same BigQuery dataset: $PROJECT_ID:$DATASET_NAME"
  log_info "Each account creates its own tables with unique names"
else
  log_info "Configuring billing export to BigQuery..."
fi

if [ "$DRY_RUN" = "0" ]; then
  # Note: GCP does not provide a command-line tool for configuring billing export
  # This must be done manually through the Console for each billing account

  log_warning "⚠️  Billing export must be configured manually (no gcloud command available)"
  log_warning ""
  log_warning "Google Cloud does not provide a command-line tool for this configuration."
  log_warning "You need to configure the export in the Console for each billing account."
  log_warning ""

  if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
    log_warning "📋 IMPORTANT: You have selected ${#BILLING_ACCOUNTS[@]} billing accounts."
    log_warning "You need to repeat the steps below for EACH billing account."
    log_warning "All accounts should export to the SAME dataset: $PROJECT_ID:$DATASET_NAME"
    log_warning ""
  fi

  log_warning "Manual configuration steps:"
  log_warning ""

  # Provide instructions for each billing account
  for i in "${!BILLING_ACCOUNTS[@]}"; do
    ba="${BILLING_ACCOUNTS[$i]}"

    if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
      log_warning "━━━ Billing Account $((i + 1)) of ${#BILLING_ACCOUNTS[@]}: $ba ━━━"
    fi

    log_warning "1. Go to: https://console.cloud.google.com/billing/$ba"
    log_warning "2. Click 'Billing Export' in the left sidebar"
    log_warning "3. Under 'BigQuery Export', click 'EDIT SETTINGS'"
    log_warning "4. Select project: $PROJECT_ID"
    log_warning "5. Select dataset: $DATASET_NAME"
    log_warning "6. Enable all three export types:"
    log_warning "   ✓ Standard usage cost (daily cost data)"
    log_warning "   ✓ Detailed usage cost (resource-level data)"
    log_warning "   ✓ Pricing data (SKU pricing information)"
    log_warning "7. Click 'Save'"

    if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
      log_warning ""
      if [ $((i + 1)) -lt ${#BILLING_ACCOUNTS[@]} ]; then
        log_warning "⬇️  Then configure the next billing account..."
      fi
    fi
    log_warning ""
  done

  if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
    log_info "📊 After configuration, all billing accounts will export to:"
    log_info "   Project: $PROJECT_ID"
    log_info "   Dataset: $DATASET_NAME"
    log_info ""
    log_info "Each billing account creates separate tables:"
    for ba in "${BILLING_ACCOUNTS[@]}"; do
      table_name="gcp_billing_export_v1_${ba//-/_}"
      log_info "   - $ba → $table_name"
    done
    log_info ""
  fi

  log_info "After configuration, billing data will appear in BigQuery within 24 hours"
else
  log_info "[DRY RUN] Would provide manual instructions for ${#BILLING_ACCOUNTS[@]} billing account(s)"
fi

log_success "Phase 3 complete: Billing export instructions provided"

#==============================================================================
# PHASE 4: SERVICE ACCOUNT SETUP
#==============================================================================

log_section "Phase 4: Service Account Setup"

SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

log_info "Creating service account: $SERVICE_ACCOUNT_NAME"

if [ "$DRY_RUN" = "0" ]; then
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    log_warning "Service account already exists"
  else
    execute gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
      --project="$PROJECT_ID" \
      --display-name="$SERVICE_ACCOUNT_DISPLAY_NAME" \
      --description="Service account for Tailpipe cost analytics platform" $DEBUG_FLAG || {
      log_error "Failed to create service account"
      exit 1
    }
    log_success "Service account created"
  fi
else
  log_info "[DRY RUN] Would create service account: $SERVICE_ACCOUNT_EMAIL"
fi

# Grant necessary permissions
log_info "Granting permissions to service account..."

# Project-level permissions
PROJECT_ROLES=(
  "roles/bigquery.dataViewer"
  "roles/bigquery.jobUser"
  "roles/storage.objectViewer"
  "roles/monitoring.viewer"
  "roles/compute.viewer"
)

for role in "${PROJECT_ROLES[@]}"; do
  log_info "Granting $role on project..."
  execute gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="$role" \
    --condition=None \
    --no-user-output-enabled $DEBUG_FLAG || {
    log_warning "Failed to grant $role (may already exist)"
  }
done

# Organization-level permissions (if applicable)
if [ -n "$ORGANIZATION_ID" ]; then
  log_info "Granting organization-level permissions..."

  ORG_ROLES=(
    "roles/billing.viewer"
    "roles/monitoring.viewer"
  )

  for role in "${ORG_ROLES[@]}"; do
    log_info "Granting $role on organization..."
    execute gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
      --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
      --role="$role" \
      --condition=None \
      --no-user-output-enabled $DEBUG_FLAG || {
      log_warning "Failed to grant $role (may already exist)"
    }
  done
else
  log_warning "No organization detected, skipping org-level permissions"
fi

log_success "Permissions granted"

# Create and download service account key
log_info "Creating service account key..."

KEY_FILE="tailpipe-gcp-key-${PROJECT_ID}.json"

if [ "$DRY_RUN" = "0" ]; then
  if [ -f "$KEY_FILE" ]; then
    log_warning "Key file already exists: $KEY_FILE"
    if [ "$FORCE" != "1" ]; then
      if confirm "Overwrite existing key?"; then
        rm -f "$KEY_FILE"
      else
        log_info "Keeping existing key"
        KEY_FILE_CREATED=0
      fi
    else
      rm -f "$KEY_FILE"
    fi
  fi

  if [ "${KEY_FILE_CREATED:-1}" != "0" ]; then
    execute gcloud iam service-accounts keys create "$KEY_FILE" \
      --iam-account="$SERVICE_ACCOUNT_EMAIL" \
      --project="$PROJECT_ID" $DEBUG_FLAG || {
      log_error "Failed to create service account key"
      exit 1
    }
    log_success "Service account key created: $KEY_FILE"
    log_warning "⚠️  IMPORTANT: Keep this key file secure! It provides access to your billing data."
  fi
else
  log_info "[DRY RUN] Would create service account key: $KEY_FILE"
fi

log_success "Phase 4 complete: Service account configured"

#==============================================================================
# PHASE 5: WORKLOAD IDENTITY (OPTIONAL)
#==============================================================================

log_section "Phase 5: Workload Identity Federation (Optional)"

log_info "Configuring Workload Identity Federation for Tailpipe..."

# This allows Tailpipe to authenticate without long-lived keys
WORKLOAD_POOL_ID="tailpipe-pool"
WORKLOAD_PROVIDER_ID="tailpipe-provider"

if [ "$DRY_RUN" = "0" ]; then
  # Check if workload identity pool exists
  if gcloud iam workload-identity-pools describe "$WORKLOAD_POOL_ID" \
       --location="global" \
       --project="$PROJECT_ID" &>/dev/null; then
    log_info "Workload identity pool already exists"
  else
    log_info "Creating workload identity pool..."
    execute gcloud iam workload-identity-pools create "$WORKLOAD_POOL_ID" \
      --location="global" \
      --project="$PROJECT_ID" \
      --display-name="Tailpipe Workload Pool" \
      --description="Workload Identity pool for Tailpipe authentication" $DEBUG_FLAG || {
      log_warning "Failed to create workload identity pool (may not be available in all projects)"
    }
  fi

  # Create OIDC provider for Tailpipe
  if gcloud iam workload-identity-pools providers describe "$WORKLOAD_PROVIDER_ID" \
       --location="global" \
       --workload-identity-pool="$WORKLOAD_POOL_ID" \
       --project="$PROJECT_ID" &>/dev/null; then
    log_info "Workload identity provider already exists"
  else
    log_info "Creating workload identity provider..."
    execute gcloud iam workload-identity-pools providers create-oidc "$WORKLOAD_PROVIDER_ID" \
      --location="global" \
      --workload-identity-pool="$WORKLOAD_POOL_ID" \
      --project="$PROJECT_ID" \
      --issuer-uri="https://auth.${TAILPIPE_DOMAIN}" \
      --allowed-audiences="https://${TAILPIPE_DOMAIN}" \
      --attribute-mapping="google.subject=assertion.sub,attribute.tenant=assertion.tenant_id" $DEBUG_FLAG || {
      log_warning "Failed to create workload identity provider (may not be available)"
    }
  fi

  # Bind service account to workload identity
  if gcloud iam workload-identity-pools providers describe "$WORKLOAD_PROVIDER_ID" \
       --location="global" \
       --workload-identity-pool="$WORKLOAD_POOL_ID" \
       --project="$PROJECT_ID" &>/dev/null; then

    log_info "Binding service account to workload identity..."
    WORKLOAD_SA_MEMBER="principalSet://iam.googleapis.com/projects/$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')/locations/global/workloadIdentityPools/$WORKLOAD_POOL_ID/attribute.tenant/*"

    execute gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
      --project="$PROJECT_ID" \
      --role="roles/iam.workloadIdentityUser" \
      --member="$WORKLOAD_SA_MEMBER" \
      --no-user-output-enabled $DEBUG_FLAG || {
      log_warning "Failed to bind workload identity (non-critical)"
    }
  fi
else
  log_info "[DRY RUN] Would configure workload identity federation"
fi

log_info "Workload Identity configuration complete (optional feature)"

#==============================================================================
# PHASE 6: VALIDATION
#==============================================================================

log_section "Phase 6: Validation"

if [ "$DRY_RUN" = "0" ]; then
  log_info "Validating deployment..."

  # Validate project
  if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
    log_success "Project validated"
  else
    log_error "Project validation failed"
  fi

  # Validate bucket
  if gsutil ls -b "gs://$BUCKET_NAME" &>/dev/null; then
    log_success "GCS bucket validated"
  else
    log_error "GCS bucket validation failed"
  fi

  # Validate dataset
  if bq ls -d --project_id="$PROJECT_ID" | grep -q "$DATASET_NAME"; then
    log_success "BigQuery dataset validated"
  else
    log_warning "BigQuery dataset validation failed"
  fi

  # Validate service account
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    log_success "Service account validated"
  else
    log_error "Service account validation failed"
  fi

  # Validate key file
  if [ -f "$KEY_FILE" ]; then
    log_success "Service account key file validated"
  else
    log_warning "Service account key file not found"
  fi
else
  log_info "Validation skipped (dry run mode)"
fi

#==============================================================================
# CONFIGURATION SUMMARY
#==============================================================================

log_section "Configuration Summary"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || echo "unknown")
WORKLOAD_POOL_NAME="projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$WORKLOAD_POOL_ID"
WORKLOAD_PROVIDER_NAME="$WORKLOAD_POOL_NAME/providers/$WORKLOAD_PROVIDER_ID"

# Build billing accounts JSON array
if [ ${#BILLING_ACCOUNTS[@]} -gt 1 ]; then
  BILLING_ACCOUNTS_JSON="["
  for i in "${!BILLING_ACCOUNTS[@]}"; do
    [ $i -gt 0 ] && BILLING_ACCOUNTS_JSON+=", "
    BILLING_ACCOUNTS_JSON+="\"${BILLING_ACCOUNTS[$i]}\""
  done
  BILLING_ACCOUNTS_JSON+="]"
else
  BILLING_ACCOUNTS_JSON="\"$BILLING_ACCOUNT\""
fi

# Build billing export tables JSON
BILLING_TABLES_JSON="{"
for i in "${!BILLING_ACCOUNTS[@]}"; do
  ba="${BILLING_ACCOUNTS[$i]}"
  [ $i -gt 0 ] && BILLING_TABLES_JSON+=", "
  BILLING_TABLES_JSON+="
    \"${ba}\": {
      \"standard\": \"gcp_billing_export_v1_${ba//-/_}\",
      \"detailed\": \"gcp_billing_export_resource_v1_${ba//-/_}\"
    }"
done
BILLING_TABLES_JSON+="
  }"

cat <<JSON_OUTPUT

{
  "platform": "gcp",
  "organizationId": "${ORGANIZATION_ID:-null}",
  "billingAccountId": $BILLING_ACCOUNTS_JSON,
  "project": {
    "id": "$PROJECT_ID",
    "number": "$PROJECT_NUMBER",
    "region": "$REGION"
  },
  "storage": {
    "bucket": "$BUCKET_NAME",
    "bucketUri": "gs://$BUCKET_NAME",
    "dataset": "$DATASET_NAME",
    "datasetFullPath": "$PROJECT_ID:$DATASET_NAME"
  },
  "serviceAccount": {
    "email": "$SERVICE_ACCOUNT_EMAIL",
    "keyFile": "$KEY_FILE",
    "projectRoles": ["bigquery.dataViewer", "bigquery.jobUser", "storage.objectViewer", "monitoring.viewer", "compute.viewer"],
    "organizationRoles": $([ -n "$ORGANIZATION_ID" ] && echo '["billing.viewer", "monitoring.viewer"]' || echo 'null')
  },
  "workloadIdentity": {
    "enabled": $(gcloud iam workload-identity-pools describe "$WORKLOAD_POOL_ID" --location="global" --project="$PROJECT_ID" &>/dev/null && echo "true" || echo "false"),
    "poolName": "$WORKLOAD_POOL_NAME",
    "providerName": "$WORKLOAD_PROVIDER_NAME"
  },
  "billingExport": {
    "type": "BigQuery",
    "dataset": "$PROJECT_ID:$DATASET_NAME",
    "accountCount": ${#BILLING_ACCOUNTS[@]},
    "tables": $BILLING_TABLES_JSON
  }
}
JSON_OUTPUT

log_section "Setup Complete!"

if [ "$DRY_RUN" = "1" ]; then
  log_warning "This was a DRY RUN - no changes were made"
  log_info "Run without DRY_RUN=1 to perform actual deployment"
else
  log_success "Tailpipe has been successfully configured in your GCP environment"
  log_info ""
  log_info "Next steps:"
  log_info "1. Save the JSON configuration above for Tailpipe onboarding"
  log_info "2. Securely store the service account key: $KEY_FILE"
  log_info "3. Billing export data will appear in BigQuery within 24 hours"
  log_info "4. Share the configuration and key file with Tailpipe"
  log_info ""
  log_warning "Manual step required:"
  log_warning "Configure billing export at: https://console.cloud.google.com/billing/$BILLING_ACCOUNT"
  log_warning "Set export to: Project=$PROJECT_ID, Dataset=$DATASET_NAME"
fi

log_info ""
log_info "For troubleshooting and management commands, see README.md"
