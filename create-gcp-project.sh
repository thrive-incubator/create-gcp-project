#!/bin/bash
set -euo pipefail

################################################################################
# create-gcp-project.sh
#
# Scaffolds a full-stack GCP Cloud Run project:
#   Backend:  FastAPI + Firestore + Python 3.11
#   Frontend: React 19 + TypeScript + Vite + Tailwind CSS
#
# Creates the GCP project, enables APIs, sets IAM permissions, generates all
# project files, and initializes git.
#
# Usage:
#   ./create-gcp-project.sh
#   ./create-gcp-project.sh --skip-gcp    # Skip GCP setup, files only
#
# Prerequisites:
#   - gcloud CLI (https://cloud.google.com/sdk/docs/install)
#   - git
#   - (optional) gh CLI for GitHub repo creation
################################################################################

# ---------------------------------------------------------------------------
# 0. Color helpers & utilities
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_green()  { echo -e "${GREEN}✓${NC} $1"; }
print_red()    { echo -e "${RED}✗${NC} $1"; }
print_yellow() { echo -e "${YELLOW}⚠${NC} $1"; }
print_blue()   { echo -e "${BLUE}→${NC} $1"; }
print_step()   { echo -e "\n${CYAN}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}"; }

print_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║        GCP Cloud Run Project Scaffolder              ║"
  echo "║   FastAPI + React/Vite/Tailwind + Firestore          ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

validate_slug() {
  local slug="$1"
  if [[ ! "$slug" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    return 1
  fi
  return 0
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Global configuration variables (set during interactive setup)
# ---------------------------------------------------------------------------

PROJECT_SLUG=""
DISPLAY_NAME=""
BILLING_ACCOUNT=""
REGION="us-central1"
SKIP_GCP=false

# Service flags (macOS bash 3.2 compatible -- no associative arrays)
SVC_OPENAI=false
SVC_OPENAI_REALTIME=false
SVC_GEMINI=false
SVC_ANTHROPIC=false
SVC_RESEND=false
SVC_STORAGE=false

INCLUDE_STAGING=false
CREATE_GITHUB=false

# Derived
SA_NAME=""
SA_EMAIL=""
BACKEND_SERVICE=""
FRONTEND_SERVICE=""
TARGET_DIR=""
TOTAL_STEPS=4

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-gcp) SKIP_GCP=true ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done


# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------

preflight_checks() {
  echo -e "${BOLD}Pre-flight checks${NC}"

  if ! command_exists git; then
    print_red "git not found. Please install git."
    exit 1
  fi
  print_green "git found"

  if [ "$SKIP_GCP" = false ]; then
    if ! command_exists gcloud; then
      print_red "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
      exit 1
    fi
    print_green "gcloud found"

    # Check gcloud auth
    if ! gcloud auth print-identity-token > /dev/null 2>&1; then
      print_yellow "Not authenticated with gcloud. Running gcloud auth login..."
      gcloud auth login || { print_red "Authentication failed"; exit 1; }
    fi
    print_green "gcloud authenticated"
  else
    print_yellow "Skipping GCP checks (--skip-gcp)"
  fi

  if command_exists gh; then
    print_green "gh CLI found (GitHub repo creation available)"
  else
    print_yellow "gh CLI not found (GitHub repo creation disabled)"
  fi

  echo ""
}


# ---------------------------------------------------------------------------
# 2. Phase 1: Interactive setup
# ---------------------------------------------------------------------------

phase_1_interactive_setup() {
  print_step 1 "Project Configuration"

  # --- Project slug ---
  while true; do
    echo ""
    read -p "Project slug (lowercase, hyphens, 6-30 chars, e.g. my-cool-app): " PROJECT_SLUG
    if validate_slug "$PROJECT_SLUG"; then
      break
    else
      print_red "Invalid slug. Must be 6-30 chars, start with a letter, lowercase alphanumeric and hyphens only."
    fi
  done
  print_green "Project slug: ${PROJECT_SLUG}"

  # --- Display name ---
  # Default: title-case the slug
  local default_name
  default_name=$(echo "$PROJECT_SLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
  echo ""
  read -p "Display name [${default_name}]: " DISPLAY_NAME
  DISPLAY_NAME="${DISPLAY_NAME:-$default_name}"
  print_green "Display name: ${DISPLAY_NAME}"

  # --- GCP billing account ---
  if [ "$SKIP_GCP" = false ]; then
    echo ""
    echo -e "${BOLD}GCP Billing Account${NC}"
    local accounts
    accounts=$(gcloud billing accounts list --format='csv[no-heading](name,displayName)' --filter='open=true' 2>/dev/null || true)

    if [ -z "$accounts" ]; then
      print_red "No billing accounts found. Create one at https://console.cloud.google.com/billing"
      exit 1
    fi

    local count
    count=$(echo "$accounts" | wc -l | tr -d ' ')

    if [ "$count" -eq 1 ]; then
      BILLING_ACCOUNT=$(echo "$accounts" | cut -d',' -f1)
      local billing_name
      billing_name=$(echo "$accounts" | cut -d',' -f2)
      print_green "Using billing account: ${billing_name} (${BILLING_ACCOUNT})"
    else
      echo "  Available billing accounts:"
      local i=1
      while IFS=',' read -r id name; do
        echo "    [${i}] ${name} (${id})"
        i=$((i + 1))
      done <<< "$accounts"

      read -p "  Select account number: " selection
      BILLING_ACCOUNT=$(echo "$accounts" | sed -n "${selection}p" | cut -d',' -f1)
      if [ -z "$BILLING_ACCOUNT" ]; then
        print_red "Invalid selection"
        exit 1
      fi
      print_green "Selected billing account: ${BILLING_ACCOUNT}"
    fi
  fi

  # --- Region ---
  echo ""
  read -p "GCP region [us-central1]: " REGION
  REGION="${REGION:-us-central1}"
  print_green "Region: ${REGION}"

  # --- Optional services ---
  echo ""
  echo -e "${BOLD}Optional Services${NC}"
  echo "  Toggle numbers (space-separated), then press Enter."
  echo ""

  # Display current state and let user toggle
  while true; do
    echo "  [1] $([ "$SVC_OPENAI" = true ] && echo "[x]" || echo "[ ]") OpenAI (standard API)"
    echo "  [2] $([ "$SVC_OPENAI_REALTIME" = true ] && echo "[x]" || echo "[ ]") OpenAI Realtime (WebRTC voice)"
    echo "  [3] $([ "$SVC_GEMINI" = true ] && echo "[x]" || echo "[ ]") Gemini"
    echo "  [4] $([ "$SVC_ANTHROPIC" = true ] && echo "[x]" || echo "[ ]") Claude / Anthropic"
    echo "  [5] $([ "$SVC_RESEND" = true ] && echo "[x]" || echo "[ ]") Resend (email)"
    echo "  [6] $([ "$SVC_STORAGE" = true ] && echo "[x]" || echo "[ ]") Cloud Storage"
    echo ""
    read -p "  Toggle (e.g. '1 3 4'), or Enter to confirm: " toggles

    if [ -z "$toggles" ]; then
      break
    fi

    for t in $toggles; do
      case $t in
        1) [ "$SVC_OPENAI" = true ] && SVC_OPENAI=false || SVC_OPENAI=true ;;
        2) [ "$SVC_OPENAI_REALTIME" = true ] && SVC_OPENAI_REALTIME=false || SVC_OPENAI_REALTIME=true
           # OpenAI Realtime implies OpenAI
           if [ "$SVC_OPENAI_REALTIME" = true ]; then SVC_OPENAI=true; fi
           ;;
        3) [ "$SVC_GEMINI" = true ] && SVC_GEMINI=false || SVC_GEMINI=true ;;
        4) [ "$SVC_ANTHROPIC" = true ] && SVC_ANTHROPIC=false || SVC_ANTHROPIC=true ;;
        5) [ "$SVC_RESEND" = true ] && SVC_RESEND=false || SVC_RESEND=true ;;
        6) [ "$SVC_STORAGE" = true ] && SVC_STORAGE=false || SVC_STORAGE=true ;;
        *) print_yellow "Unknown option: $t" ;;
      esac
    done
    echo ""
  done

  # --- Staging ---
  echo ""
  read -p "Include staging deployment scripts? (y/N): " staging_answer
  [[ "$staging_answer" =~ ^[Yy]$ ]] && INCLUDE_STAGING=true
  print_green "Staging scripts: $([ "$INCLUDE_STAGING" = true ] && echo "yes" || echo "no")"

  # --- GitHub ---
  if command_exists gh; then
    echo ""
    read -p "Create GitHub repo? (y/N): " github_answer
    [[ "$github_answer" =~ ^[Yy]$ ]] && CREATE_GITHUB=true
    print_green "GitHub repo: $([ "$CREATE_GITHUB" = true ] && echo "yes" || echo "no")"
  fi

  # --- Derived values ---
  SA_NAME="${PROJECT_SLUG}-runner"
  SA_EMAIL="${SA_NAME}@${PROJECT_SLUG}.iam.gserviceaccount.com"
  BACKEND_SERVICE="${PROJECT_SLUG}-backend"
  FRONTEND_SERVICE="${PROJECT_SLUG}-frontend"
  TARGET_DIR="$(pwd)/${PROJECT_SLUG}"
}


# ---------------------------------------------------------------------------
# 3. Confirmation
# ---------------------------------------------------------------------------

confirm_selections() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}Configuration Summary${NC}                              ${CYAN}║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC}  Project slug:    ${BOLD}${PROJECT_SLUG}${NC}"
  echo -e "${CYAN}║${NC}  Display name:    ${DISPLAY_NAME}"
  [ "$SKIP_GCP" = false ] && echo -e "${CYAN}║${NC}  Billing account: ${BILLING_ACCOUNT}"
  echo -e "${CYAN}║${NC}  Region:          ${REGION}"
  echo -e "${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  Services:"
  [ "$SVC_OPENAI" = true ] && echo -e "${CYAN}║${NC}    ${GREEN}✓${NC} OpenAI"
  [ "$SVC_OPENAI_REALTIME" = true ] && echo -e "${CYAN}║${NC}    ${GREEN}✓${NC} OpenAI Realtime"
  [ "$SVC_GEMINI" = true ] && echo -e "${CYAN}║${NC}    ${GREEN}✓${NC} Gemini"
  [ "$SVC_ANTHROPIC" = true ] && echo -e "${CYAN}║${NC}    ${GREEN}✓${NC} Claude / Anthropic"
  [ "$SVC_RESEND" = true ] && echo -e "${CYAN}║${NC}    ${GREEN}✓${NC} Resend"
  [ "$SVC_STORAGE" = true ] && echo -e "${CYAN}║${NC}    ${GREEN}✓${NC} Cloud Storage"
  local any_service=false
  for svc in "$SVC_OPENAI" "$SVC_OPENAI_REALTIME" "$SVC_GEMINI" "$SVC_ANTHROPIC" "$SVC_RESEND" "$SVC_STORAGE"; do
    [ "$svc" = true ] && any_service=true
  done
  [ "$any_service" = false ] && echo -e "${CYAN}║${NC}    (none)"
  echo -e "${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  Staging scripts: $([ "$INCLUDE_STAGING" = true ] && echo "yes" || echo "no")"
  echo -e "${CYAN}║${NC}  GitHub repo:     $([ "$CREATE_GITHUB" = true ] && echo "yes" || echo "no")"
  echo -e "${CYAN}║${NC}  Target dir:      ${TARGET_DIR}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  read -p "Proceed? (Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}


# ---------------------------------------------------------------------------
# 4. Phase 2: GCP Setup
# ---------------------------------------------------------------------------

phase_2_gcp_setup() {
  if [ "$SKIP_GCP" = true ]; then
    print_step 2 "Skipping GCP Setup (--skip-gcp)"
    return
  fi

  print_step 2 "GCP Project Setup"

  # 2a. Create project (with retry on name collision)
  while true; do
    print_blue "Creating GCP project: ${PROJECT_SLUG}..."
    if gcloud projects describe "$PROJECT_SLUG" > /dev/null 2>&1; then
      print_yellow "Project ${PROJECT_SLUG} already exists, continuing..."
      break
    fi

    if gcloud projects create "$PROJECT_SLUG" --name="$DISPLAY_NAME" 2>/dev/null; then
      print_green "Project created"
      break
    fi

    # Creation failed -- offer options
    local suggested="${PROJECT_SLUG}-$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $((RANDOM % 9000 + 1000)))"
    print_red "Failed to create project '${PROJECT_SLUG}'. The ID may be taken globally."
    echo ""
    echo "  [1] Use suggested name: ${suggested}"
    echo "  [2] Enter a different name"
    echo "  [3] Abort"
    echo ""
    read -p "  Choice (1/2/3): " choice

    case "$choice" in
      1)
        PROJECT_SLUG="$suggested"
        # Update derived values
        SA_NAME="${PROJECT_SLUG}-runner"
        SA_EMAIL="${SA_NAME}@${PROJECT_SLUG}.iam.gserviceaccount.com"
        BACKEND_SERVICE="${PROJECT_SLUG}-backend"
        FRONTEND_SERVICE="${PROJECT_SLUG}-frontend"
        TARGET_DIR="$(pwd)/${PROJECT_SLUG}"
        ;;
      2)
        while true; do
          read -p "  New project slug: " PROJECT_SLUG
          if validate_slug "$PROJECT_SLUG"; then
            break
          else
            print_red "Invalid slug. Must be 6-30 chars, start with a letter, lowercase alphanumeric and hyphens only."
          fi
        done
        # Update derived values
        SA_NAME="${PROJECT_SLUG}-runner"
        SA_EMAIL="${SA_NAME}@${PROJECT_SLUG}.iam.gserviceaccount.com"
        BACKEND_SERVICE="${PROJECT_SLUG}-backend"
        FRONTEND_SERVICE="${PROJECT_SLUG}-frontend"
        TARGET_DIR="$(pwd)/${PROJECT_SLUG}"
        ;;
      *)
        echo "Aborted."
        exit 1
        ;;
    esac
  done

  gcloud config set project "$PROJECT_SLUG" 2>/dev/null

  # 2b. Link billing
  print_blue "Linking billing account..."
  gcloud billing projects link "$PROJECT_SLUG" --billing-account="$BILLING_ACCOUNT" 2>/dev/null || {
    print_red "Failed to link billing account. Check permissions."
    exit 1
  }
  print_green "Billing linked"

  # 2c. Enable APIs
  print_blue "Enabling APIs..."
  local APIS="run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com artifactregistry.googleapis.com firestore.googleapis.com"
  if [ "$SVC_STORAGE" = true ]; then
    APIS="$APIS storage.googleapis.com"
  fi
  for API in $APIS; do
    gcloud services enable "$API" --quiet 2>/dev/null || true
  done
  print_green "APIs enabled"

  echo "  Waiting 10 seconds for service accounts to be created..."
  sleep 10

  # 2d. Create Firestore database
  print_blue "Creating Firestore database..."
  gcloud firestore databases create --location="$REGION" --type=firestore-native 2>/dev/null || {
    print_yellow "Firestore database may already exist (this is OK)"
  }

  # 2e. Create Artifact Registry repo
  print_blue "Creating Artifact Registry repository..."
  if ! gcloud artifacts repositories create gcr.io \
    --repository-format=docker \
    --location=us \
    --project="$PROJECT_SLUG" 2>&1; then
    print_yellow "Artifact Registry repo may already exist (this is OK)"
  fi

  # 2f. Create service account
  print_blue "Setting up service account: ${SA_NAME}..."
  if ! gcloud iam service-accounts describe "$SA_EMAIL" > /dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" \
      --display-name="${DISPLAY_NAME} Cloud Run Service Account"
    print_green "Service account created"
  else
    print_yellow "Service account already exists"
  fi

  # 2g. Grant IAM roles
  print_blue "Granting IAM roles..."
  local PROJECT_NUMBER
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_SLUG" --format='value(projectNumber)')

  local CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
  local COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

  # Cloud Build SA
  for ROLE in roles/cloudbuild.builds.builder roles/artifactregistry.admin roles/storage.admin roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_SLUG" \
      --member="serviceAccount:${CLOUDBUILD_SA}" --role="$ROLE" --quiet 2>/dev/null || true
  done

  # Compute SA
  for ROLE in roles/artifactregistry.admin roles/storage.admin roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_SLUG" \
      --member="serviceAccount:${COMPUTE_SA}" --role="$ROLE" --quiet 2>/dev/null || true
  done

  # Runner SA
  for ROLE in \
    roles/datastore.user roles/storage.objectAdmin roles/storage.admin \
    roles/secretmanager.secretAccessor roles/secretmanager.viewer \
    roles/logging.logWriter roles/run.admin \
    roles/cloudbuild.builds.builder roles/cloudbuild.builds.editor \
    roles/artifactregistry.writer roles/iam.serviceAccountUser \
    roles/serviceusage.serviceUsageAdmin roles/resourcemanager.projectViewer \
    roles/viewer; do
    gcloud projects add-iam-policy-binding "$PROJECT_SLUG" \
      --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --quiet 2>/dev/null || true
  done
  print_green "IAM roles granted"

  # 2h. Create secrets
  print_blue "Setting up secrets..."

  # Always create jwt-secret-key with auto-generated value
  if ! gcloud secrets describe jwt-secret-key > /dev/null 2>&1; then
    local jwt_secret
    jwt_secret=$(openssl rand -hex 32)
    echo -n "$jwt_secret" | gcloud secrets create jwt-secret-key --data-file=- --replication-policy=automatic 2>/dev/null
    print_green "Secret 'jwt-secret-key' created (auto-generated)"
  else
    print_yellow "Secret 'jwt-secret-key' already exists"
  fi

  # Conditional secrets
  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    if ! gcloud secrets describe openai-api-key > /dev/null 2>&1; then
      echo ""
      read -sp "  Enter your OpenAI API key (sk-...): " secret_val
      echo ""
      echo -n "$secret_val" | gcloud secrets create openai-api-key --data-file=- --replication-policy=automatic 2>/dev/null
      print_green "Secret 'openai-api-key' created"
    else
      print_yellow "Secret 'openai-api-key' already exists"
    fi
  fi

  if [ "$SVC_GEMINI" = true ]; then
    if ! gcloud secrets describe gemini-api-key > /dev/null 2>&1; then
      echo ""
      read -sp "  Enter your Gemini API key: " secret_val
      echo ""
      echo -n "$secret_val" | gcloud secrets create gemini-api-key --data-file=- --replication-policy=automatic 2>/dev/null
      print_green "Secret 'gemini-api-key' created"
    else
      print_yellow "Secret 'gemini-api-key' already exists"
    fi
  fi

  if [ "$SVC_ANTHROPIC" = true ]; then
    if ! gcloud secrets describe anthropic-api-key > /dev/null 2>&1; then
      echo ""
      read -sp "  Enter your Anthropic API key (sk-ant-...): " secret_val
      echo ""
      echo -n "$secret_val" | gcloud secrets create anthropic-api-key --data-file=- --replication-policy=automatic 2>/dev/null
      print_green "Secret 'anthropic-api-key' created"
    else
      print_yellow "Secret 'anthropic-api-key' already exists"
    fi
  fi

  # 2i. Wait for IAM propagation
  echo "  Waiting 15 seconds for IAM propagation..."
  sleep 15
  print_green "GCP setup complete"

  # 2j. Service account key
  echo ""
  print_yellow "Service account key"
  echo "  For local development, you can use: gcloud auth application-default login"
  echo "  For CI/CD, consider Workload Identity Federation."
  echo ""
  read -p "  Download service account key now? (y/N): " download_key
  if [[ "$download_key" =~ ^[Yy]$ ]]; then
    gcloud iam service-accounts keys create "${TARGET_DIR}/sa-key.json" \
      --iam-account="$SA_EMAIL" 2>/dev/null || {
      # Target dir may not exist yet, save to current dir
      gcloud iam service-accounts keys create "sa-key.json" \
        --iam-account="$SA_EMAIL"
      echo "  Key saved to ./sa-key.json (will be moved to project dir)"
    }
    print_green "Service account key downloaded"
    print_yellow "IMPORTANT: Never commit sa-key.json to git (it's in .gitignore)"
  else
    echo "  To download later:"
    echo "    gcloud iam service-accounts keys create sa-key.json --iam-account=${SA_EMAIL}"
  fi
}


# ---------------------------------------------------------------------------
# 5. Phase 3: File Scaffolding
# ---------------------------------------------------------------------------

phase_3_file_scaffolding() {
  print_step 3 "Creating Project Files"

  mkdir -p "$TARGET_DIR"
  cd "$TARGET_DIR"

  # Move sa-key.json if it was saved to parent dir
  if [ -f "../sa-key.json" ] && [ ! -f "sa-key.json" ]; then
    mv ../sa-key.json ./sa-key.json
  fi

  create_root_files
  create_backend_files
  create_frontend_files
  create_docs_dir

  print_green "All project files created"
}


# ===== ROOT FILES =====

create_root_files() {
  print_blue "Creating root files..."

  create_gitignore
  create_deploy_sh
  [ "$INCLUDE_STAGING" = true ] && create_deploy_staging_sh
  create_run_local_sh
  create_fix_permissions_sh
  create_claude_md
  create_readme_md
}

create_gitignore() {
  cat > .gitignore << 'GITIGNORE_EOF'
# Python
__pycache__/
*.pyc
*.pyo
venv/
.venv/
*.egg-info/

# Node
node_modules/
dist/

# Environment & secrets
.env
.env.local
service_account.json
sa-key.json
credentials.json

# IDE
.vscode/
.idea/
*.swp
*.swo
.DS_Store

# Build
*.log
logs/
tsconfig.tsbuildinfo

# Docker
*.tar

# Tools
.gstack/
GITIGNORE_EOF
}

create_deploy_sh() {
  # Build --set-secrets dynamically
  local SECRETS_FLAG=""
  local secret_pairs=""

  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    secret_pairs="${secret_pairs}OPENAI_API_KEY=openai-api-key:latest,"
  fi
  if [ "$SVC_GEMINI" = true ]; then
    secret_pairs="${secret_pairs}GEMINI_API_KEY=gemini-api-key:latest,"
  fi
  if [ "$SVC_ANTHROPIC" = true ]; then
    secret_pairs="${secret_pairs}ANTHROPIC_API_KEY=anthropic-api-key:latest,"
  fi
  # Always include JWT
  secret_pairs="${secret_pairs}JWT_SECRET_KEY=jwt-secret-key:latest,"
  # Remove trailing comma
  secret_pairs="${secret_pairs%,}"
  SECRETS_FLAG="--set-secrets=\"${secret_pairs}\""

  # Build REQUIRED_SECRETS array for validation
  local secrets_array_str="\"jwt-secret-key\""
  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    secrets_array_str="${secrets_array_str} \"openai-api-key\""
  fi
  if [ "$SVC_GEMINI" = true ]; then
    secrets_array_str="${secrets_array_str} \"gemini-api-key\""
  fi
  if [ "$SVC_ANTHROPIC" = true ]; then
    secrets_array_str="${secrets_array_str} \"anthropic-api-key\""
  fi

  cat > deploy.sh << DEPLOY_EOF
#!/bin/bash
set -euo pipefail

# ---- Configuration ----
PROJECT_ID="${PROJECT_SLUG}"
REGION="\${REGION:-${REGION}}"
BACKEND_SERVICE="${BACKEND_SERVICE}"
FRONTEND_SERVICE="${FRONTEND_SERVICE}"
BACKEND_IMAGE="gcr.io/\${PROJECT_ID}/${BACKEND_SERVICE}"
FRONTEND_IMAGE="gcr.io/\${PROJECT_ID}/${FRONTEND_SERVICE}"

# ---- Parse arguments ----
DEPLOY_BACKEND=true
DEPLOY_FRONTEND=true
SKIP_BUILD=false

while [[ \$# -gt 0 ]]; do
  case \$1 in
    --backend-only) DEPLOY_FRONTEND=false ;;
    --frontend-only) DEPLOY_BACKEND=false ;;
    --skip-build) SKIP_BUILD=true ;;
    --region) REGION="\$2"; shift ;;
    *) echo "Unknown option: \$1"; exit 1 ;;
  esac
  shift
done

# ---- Pre-flight ----
echo "=== Pre-flight checks ==="
gcloud auth print-identity-token > /dev/null 2>&1 || gcloud auth login
gcloud config set project \$PROJECT_ID

# ---- Auto-run fix_permissions.sh on first deploy ----
SA_NAME="${SA_NAME}"
SA_EMAIL="\${SA_NAME}@\${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe \$SA_EMAIL > /dev/null 2>&1; then
  echo "First deploy detected — running fix_permissions.sh to set up IAM..."
  SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "\${SCRIPT_DIR}/fix_permissions.sh" ]; then
    bash "\${SCRIPT_DIR}/fix_permissions.sh"
  else
    echo "ERROR: fix_permissions.sh not found. Run it manually first."
    exit 1
  fi
fi

# ---- Secrets ----
echo "=== Checking secrets ==="
REQUIRED_SECRETS=(${secrets_array_str})

for SECRET in "\${REQUIRED_SECRETS[@]}"; do
  if ! gcloud secrets describe \$SECRET > /dev/null 2>&1; then
    echo "Secret '\$SECRET' not found. Create it:"
    echo "  gcloud secrets create \$SECRET --replication-policy=automatic"
    echo "  echo -n 'VALUE' | gcloud secrets versions add \$SECRET --data-file=-"
    exit 1
  fi
done

# ---- Backend Deploy ----
if [ "\$DEPLOY_BACKEND" = true ]; then
  echo "=== Deploying Backend ==="

  if [ "\$SKIP_BUILD" = false ]; then
    cd backend
    gcloud builds submit --tag \$BACKEND_IMAGE .
    cd ..
  fi

  BACKEND_URL=\$(gcloud run deploy \$BACKEND_SERVICE \\
    --image \$BACKEND_IMAGE \\
    --region \$REGION \\
    --platform managed \\
    --service-account \$SA_EMAIL \\
    --memory 2Gi \\
    --cpu 1 \\
    --min-instances 0 \\
    --max-instances 5 \\
    --timeout 300 \\
    --allow-unauthenticated \\
    ${SECRETS_FLAG} \\
    --set-env-vars="FIREBASE_PROJECT_ID=\${PROJECT_ID},DEBUG=false" \\
    --format='value(status.url)')

  echo "Backend deployed: \$BACKEND_URL"
fi

# ---- Frontend Deploy ----
if [ "\$DEPLOY_FRONTEND" = true ]; then
  echo "=== Deploying Frontend ==="

  # Get backend URL if not already set
  if [ -z "\${BACKEND_URL:-}" ]; then
    BACKEND_URL=\$(gcloud run services describe \$BACKEND_SERVICE --region \$REGION --format='value(status.url)')
  fi

  VITE_API_URL="\${BACKEND_URL}/api/v1"

  if [ "\$SKIP_BUILD" = false ]; then
    cd frontend
    gcloud builds submit \\
      --config=cloudbuild.yaml \\
      --substitutions="_VITE_API_URL=\${VITE_API_URL},_IMAGE_NAME=\${FRONTEND_IMAGE}" .
    cd ..
  fi

  gcloud run deploy \$FRONTEND_SERVICE \\
    --image \$FRONTEND_IMAGE \\
    --region \$REGION \\
    --platform managed \\
    --memory 512Mi \\
    --cpu 1 \\
    --min-instances 0 \\
    --max-instances 3 \\
    --allow-unauthenticated

  FRONTEND_URL=\$(gcloud run services describe \$FRONTEND_SERVICE --region \$REGION --format='value(status.url)')
  echo "Frontend deployed: \$FRONTEND_URL"

  # Build the new-format URL (project-number based) that GCP is migrating to
  PROJECT_NUMBER=\$(gcloud projects describe \$PROJECT_ID --format='value(projectNumber)')
  FRONTEND_URL_NEW="https://\${FRONTEND_SERVICE}-\${PROJECT_NUMBER}.\${REGION}.run.app"

  # ---- Update CORS (allow both URL formats) ----
  echo "=== Updating backend CORS ==="
  echo "  Old format: \$FRONTEND_URL"
  echo "  New format: \$FRONTEND_URL_NEW"
  gcloud run services update \$BACKEND_SERVICE \\
    --region \$REGION \\
    --update-env-vars "^||^CORS_ORIGINS=\${FRONTEND_URL},\${FRONTEND_URL_NEW}||FRONTEND_BASE_URL=\${FRONTEND_URL_NEW}"
fi

echo "=== Deployment complete ==="
DEPLOY_EOF

  chmod +x deploy.sh
}

create_deploy_staging_sh() {
  # Build --set-secrets dynamically (same as production)
  local secret_pairs=""
  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    secret_pairs="${secret_pairs}OPENAI_API_KEY=openai-api-key:latest,"
  fi
  if [ "$SVC_GEMINI" = true ]; then
    secret_pairs="${secret_pairs}GEMINI_API_KEY=gemini-api-key:latest,"
  fi
  if [ "$SVC_ANTHROPIC" = true ]; then
    secret_pairs="${secret_pairs}ANTHROPIC_API_KEY=anthropic-api-key:latest,"
  fi
  secret_pairs="${secret_pairs}JWT_SECRET_KEY=jwt-secret-key:latest,"
  secret_pairs="${secret_pairs%,}"

  cat > deploy-staging.sh << STAGING_EOF
#!/bin/bash
set -euo pipefail

################################################################################
# Deploy to staging Cloud Run services
################################################################################

# ---- Configuration ----
PROJECT_ID="${PROJECT_SLUG}"
REGION="\${REGION:-${REGION}}"
BACKEND_SERVICE="${BACKEND_SERVICE}-staging"
FRONTEND_SERVICE="${FRONTEND_SERVICE}-staging"
BACKEND_IMAGE="gcr.io/\${PROJECT_ID}/${BACKEND_SERVICE}-staging"
FRONTEND_IMAGE="gcr.io/\${PROJECT_ID}/${FRONTEND_SERVICE}-staging"
SA_EMAIL="${SA_EMAIL}"

# ---- Parse arguments ----
DEPLOY_BACKEND=true
DEPLOY_FRONTEND=true
SKIP_BUILD=false

while [[ \$# -gt 0 ]]; do
  case \$1 in
    --backend-only) DEPLOY_FRONTEND=false ;;
    --frontend-only) DEPLOY_BACKEND=false ;;
    --skip-build) SKIP_BUILD=true ;;
    --region) REGION="\$2"; shift ;;
    *) echo "Unknown option: \$1"; exit 1 ;;
  esac
  shift
done

# ---- Pre-flight ----
echo "=== Staging deployment ==="
gcloud config set project \$PROJECT_ID 2>/dev/null

if ! gcloud auth print-identity-token > /dev/null 2>&1; then
  echo "ERROR: Not authenticated with gcloud."
  echo "  Run: gcloud auth activate-service-account --key-file=sa-key.json --project=\$PROJECT_ID"
  exit 1
fi

# ---- Auto-run fix_permissions.sh on first deploy ----
SA_CHECK="${SA_EMAIL}"
if ! gcloud iam service-accounts describe \$SA_CHECK > /dev/null 2>&1; then
  echo "First deploy detected — running fix_permissions.sh to set up IAM..."
  SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "\${SCRIPT_DIR}/fix_permissions.sh" ]; then
    bash "\${SCRIPT_DIR}/fix_permissions.sh"
  else
    echo "ERROR: fix_permissions.sh not found. Run it manually first."
    exit 1
  fi
fi

# ---- Backend Deploy ----
if [ "\$DEPLOY_BACKEND" = true ]; then
  echo "=== Deploying Staging Backend ==="

  if [ "\$SKIP_BUILD" = false ]; then
    cd backend
    gcloud builds submit --tag \$BACKEND_IMAGE .
    cd ..
  fi

  BACKEND_URL=\$(gcloud run deploy \$BACKEND_SERVICE \\
    --image \$BACKEND_IMAGE \\
    --region \$REGION \\
    --platform managed \\
    --service-account \$SA_EMAIL \\
    --memory 2Gi \\
    --cpu 1 \\
    --min-instances 0 \\
    --max-instances 5 \\
    --timeout 300 \\
    --allow-unauthenticated \\
    --set-secrets="${secret_pairs}" \\
    --set-env-vars="FIREBASE_PROJECT_ID=\${PROJECT_ID},DEBUG=true" \\
    --format='value(status.url)')

  echo "Staging backend deployed: \$BACKEND_URL"
fi

# ---- Frontend Deploy ----
if [ "\$DEPLOY_FRONTEND" = true ]; then
  echo "=== Deploying Staging Frontend ==="

  if [ -z "\${BACKEND_URL:-}" ]; then
    BACKEND_URL=\$(gcloud run services describe \$BACKEND_SERVICE --region \$REGION --format='value(status.url)')
  fi

  VITE_API_URL="\${BACKEND_URL}/api/v1"

  if [ "\$SKIP_BUILD" = false ]; then
    cd frontend
    gcloud builds submit \\
      --config=cloudbuild.yaml \\
      --substitutions="_VITE_API_URL=\${VITE_API_URL},_IMAGE_NAME=\${FRONTEND_IMAGE}" .
    cd ..
  fi

  gcloud run deploy \$FRONTEND_SERVICE \\
    --image \$FRONTEND_IMAGE \\
    --region \$REGION \\
    --platform managed \\
    --memory 512Mi \\
    --cpu 1 \\
    --min-instances 0 \\
    --max-instances 3 \\
    --allow-unauthenticated

  FRONTEND_URL=\$(gcloud run services describe \$FRONTEND_SERVICE --region \$REGION --format='value(status.url)')

  PROJECT_NUMBER=\$(gcloud projects describe \$PROJECT_ID --format='value(projectNumber)')
  FRONTEND_URL_NEW="https://\${FRONTEND_SERVICE}-\${PROJECT_NUMBER}.\${REGION}.run.app"

  echo "=== Updating staging backend CORS ==="
  gcloud run services update \$BACKEND_SERVICE \\
    --region \$REGION \\
    --update-env-vars "^||^CORS_ORIGINS=\${FRONTEND_URL},\${FRONTEND_URL_NEW}||FRONTEND_BASE_URL=\${FRONTEND_URL_NEW}"

  echo "Staging frontend deployed: \$FRONTEND_URL"
fi

echo ""
echo "=== Staging deployment complete ==="
STAGING_EOF

  chmod +x deploy-staging.sh
}

create_run_local_sh() {
  cat > run-local.sh << RUNLOCAL_EOF
#!/bin/bash
set -euo pipefail

################################################################################
# Run backend + frontend locally with optional tunnel
#
# Prerequisites:
#   - backend/.env with required config
#   - Python 3.11+, Node.js 20+
#   - (optional) cloudflared for tunnel
#
# Usage:
#   ./run-local.sh                # Start with tunnel
#   ./run-local.sh --no-tunnel    # Local only
#   ./run-local.sh --skip-deps    # Skip dependency install
################################################################################

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="\${SCRIPT_DIR}/backend"
FRONTEND_DIR="\${SCRIPT_DIR}/frontend"
BACKEND_PORT=8000
FRONTEND_PORT=5173

# ---- Parse arguments ----
USE_TUNNEL=true
SKIP_DEPS=false

while [[ \$# -gt 0 ]]; do
  case \$1 in
    --no-tunnel) USE_TUNNEL=false ;;
    --skip-deps) SKIP_DEPS=true ;;
    *) echo "Unknown option: \$1"; exit 1 ;;
  esac
  shift
done

# ---- Cleanup on exit ----
PIDS=()
TUNNEL_LOG=""

cleanup() {
  echo ""
  echo "=== Shutting down ==="
  if [ \${#PIDS[@]} -gt 0 ]; then
    for pid in "\${PIDS[@]}"; do
      kill "\$pid" 2>/dev/null && echo "  Stopped process \$pid" || true
    done
  fi
  [ -n "\$TUNNEL_LOG" ] && rm -f "\$TUNNEL_LOG"
  echo "Done."
}
trap cleanup EXIT INT TERM

# ---- Validate prerequisites ----
if [ ! -f "\${BACKEND_DIR}/.env" ]; then
  echo "ERROR: backend/.env not found."
  echo "  Copy backend/.env.example to backend/.env and fill in your API keys."
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found"; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "ERROR: npm not found"; exit 1; }

# ---- Start tunnel (if requested) ----
TUNNEL_URL=""

if [ "\$USE_TUNNEL" = true ]; then
  echo "=== Starting tunnel ==="
  TUNNEL_LOG=\$(mktemp)

  if command -v cloudflared >/dev/null 2>&1; then
    echo "  Using cloudflared..."
    cloudflared tunnel --url "http://localhost:\${FRONTEND_PORT}" > "\$TUNNEL_LOG" 2>&1 &
    PIDS+=(\$!)

    for i in \$(seq 1 15); do
      TUNNEL_URL=\$(grep -o 'https://[^ ]*\\.trycloudflare\\.com' "\$TUNNEL_LOG" 2>/dev/null | head -1 || true)
      if [ -n "\$TUNNEL_URL" ]; then break; fi
      sleep 1
    done
  elif command -v npx >/dev/null 2>&1; then
    echo "  Using localtunnel via npx..."
    npx localtunnel --port "\${FRONTEND_PORT}" > "\$TUNNEL_LOG" 2>&1 &
    PIDS+=(\$!)

    for i in \$(seq 1 15); do
      TUNNEL_URL=\$(grep -o 'https://[^ ]*\\.loca\\.lt' "\$TUNNEL_LOG" 2>/dev/null | head -1 || true)
      if [ -n "\$TUNNEL_URL" ]; then break; fi
      sleep 1
    done
  else
    echo "  WARNING: No tunnel tool found (cloudflared or npx)."
    echo "  Install cloudflared: brew install cloudflared"
    echo "  Continuing without tunnel..."
    USE_TUNNEL=false
  fi

  if [ "\$USE_TUNNEL" = true ] && [ -z "\$TUNNEL_URL" ]; then
    echo "  WARNING: Could not detect tunnel URL after 15s. Continuing without tunnel."
    USE_TUNNEL=false
  fi
fi

# ---- Install dependencies ----
if [ "\$SKIP_DEPS" = false ]; then
  echo "=== Installing backend dependencies ==="
  cd "\${BACKEND_DIR}"
  if [ ! -d "venv" ]; then
    python3 -m venv venv
  fi
  source venv/bin/activate
  pip install -r requirements.txt --quiet
  deactivate

  echo "=== Installing frontend dependencies ==="
  cd "\${FRONTEND_DIR}"
  npm install --silent
fi

# ---- Start backend ----
echo "=== Starting backend on port \${BACKEND_PORT} ==="
cd "\${BACKEND_DIR}"
source venv/bin/activate

CORS_VALUE="http://localhost:\${FRONTEND_PORT}"
if [ -n "\$TUNNEL_URL" ]; then
  CORS_VALUE="\${CORS_VALUE},\${TUNNEL_URL}"
fi

CORS_ORIGINS="\$CORS_VALUE" FRONTEND_BASE_URL="\${TUNNEL_URL:-http://localhost:\${FRONTEND_PORT}}" \\
  uvicorn app.main:app --host 0.0.0.0 --port "\${BACKEND_PORT}" --reload &
PIDS+=(\$!)

# ---- Start frontend ----
echo "=== Starting frontend on port \${FRONTEND_PORT} ==="
cd "\${FRONTEND_DIR}"
npm run dev &
PIDS+=(\$!)

# ---- Print summary ----
sleep 2
echo ""
echo "============================================"
echo "  ${DISPLAY_NAME} - Running Locally"
echo "============================================"
echo ""
echo "  Backend:   http://localhost:\${BACKEND_PORT}"
echo "  Frontend:  http://localhost:\${FRONTEND_PORT}"
if [ -n "\$TUNNEL_URL" ]; then
echo ""
echo "  Public URL (share this):"
echo "  >>> \${TUNNEL_URL} <<<"
fi
echo ""
echo "  Press Ctrl+C to stop all services"
echo "============================================"

wait
RUNLOCAL_EOF

  chmod +x run-local.sh
}

create_fix_permissions_sh() {
  # Build required secrets list
  local secrets_check_str="jwt-secret-key"
  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    secrets_check_str="${secrets_check_str} openai-api-key"
  fi
  if [ "$SVC_GEMINI" = true ]; then
    secrets_check_str="${secrets_check_str} gemini-api-key"
  fi
  if [ "$SVC_ANTHROPIC" = true ]; then
    secrets_check_str="${secrets_check_str} anthropic-api-key"
  fi

  cat > fix_permissions.sh << FIXPERM_EOF
#!/bin/bash

################################################################################
# Fix IAM permissions for Cloud Build, Artifact Registry, and Cloud Run
#
# Run this script once before first deployment. Safe to re-run.
################################################################################

set -e

PROJECT_ID="${PROJECT_SLUG}"

echo "Getting project number for \$PROJECT_ID..."
PROJECT_NUMBER=\$(gcloud projects describe \$PROJECT_ID --format='value(projectNumber)')

echo "Project ID: \$PROJECT_ID"
echo "Project Number: \$PROJECT_NUMBER"

gcloud config set project \$PROJECT_ID

# ---------------------------------------------------------------------------
# 0. Enable required APIs
# ---------------------------------------------------------------------------
echo ""
echo "=== Enabling required APIs ==="
gcloud services enable \\
    cloudbuild.googleapis.com \\
    artifactregistry.googleapis.com \\
    run.googleapis.com \\
    secretmanager.googleapis.com \\
    firestore.googleapis.com \\
    storage.googleapis.com \\
    --quiet

echo "Waiting 10 seconds for service accounts to be created..."
sleep 10

# ---------------------------------------------------------------------------
# 1. Create Artifact Registry repository
# ---------------------------------------------------------------------------
echo ""
echo "=== Creating Artifact Registry repository ==="
gcloud artifacts repositories create gcr.io \\
    --repository-format=docker \\
    --location=us \\
    --project=\$PROJECT_ID \\
    2>/dev/null || echo "Repository already exists"

# ---------------------------------------------------------------------------
# 2. Cloud Build service account permissions
# ---------------------------------------------------------------------------
echo ""
echo "=== Granting permissions to Cloud Build service account ==="
CLOUDBUILD_SA="\${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

for ROLE in \\
    roles/cloudbuild.builds.builder \\
    roles/artifactregistry.admin \\
    roles/storage.admin \\
    roles/logging.logWriter; do
    echo "  Granting \$ROLE to Cloud Build SA..."
    gcloud projects add-iam-policy-binding \$PROJECT_ID \\
        --member="serviceAccount:\${CLOUDBUILD_SA}" \\
        --role="\$ROLE" \\
        --quiet 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 3. Compute service account permissions
# ---------------------------------------------------------------------------
echo ""
echo "=== Granting permissions to Compute service account ==="
COMPUTE_SA="\${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

for ROLE in \\
    roles/artifactregistry.admin \\
    roles/storage.admin \\
    roles/logging.logWriter; do
    echo "  Granting \$ROLE to Compute SA..."
    gcloud projects add-iam-policy-binding \$PROJECT_ID \\
        --member="serviceAccount:\${COMPUTE_SA}" \\
        --role="\$ROLE" \\
        --quiet 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 4. Cloud Run runner service account
# ---------------------------------------------------------------------------
echo ""
echo "=== Setting up Cloud Run service account ==="
SA_NAME="${SA_NAME}"
SA_EMAIL="\${SA_NAME}@\${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe \$SA_EMAIL > /dev/null 2>&1; then
    echo "  Creating service account \${SA_NAME}..."
    gcloud iam service-accounts create \$SA_NAME \\
        --display-name="${DISPLAY_NAME} Cloud Run Service Account"
else
    echo "  Service account \${SA_NAME} already exists"
fi

for ROLE in \\
    roles/datastore.user \\
    roles/storage.objectAdmin \\
    roles/storage.admin \\
    roles/secretmanager.secretAccessor \\
    roles/secretmanager.viewer \\
    roles/logging.logWriter \\
    roles/run.admin \\
    roles/cloudbuild.builds.builder \\
    roles/cloudbuild.builds.editor \\
    roles/artifactregistry.writer \\
    roles/iam.serviceAccountUser \\
    roles/serviceusage.serviceUsageAdmin \\
    roles/resourcemanager.projectViewer \\
    roles/viewer; do
    echo "  Granting \$ROLE to \${SA_NAME}..."
    gcloud projects add-iam-policy-binding \$PROJECT_ID \\
        --member="serviceAccount:\${SA_EMAIL}" \\
        --role="\$ROLE" \\
        --quiet 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 5. Verify secrets exist
# ---------------------------------------------------------------------------
echo ""
echo "=== Checking required secrets ==="
MISSING_SECRETS=()
for SECRET in ${secrets_check_str}; do
    if gcloud secrets describe \$SECRET > /dev/null 2>&1; then
        echo "  ✓ \$SECRET exists"
    else
        echo "  ✗ \$SECRET MISSING"
        MISSING_SECRETS+=(\$SECRET)
    fi
done

if [ \${#MISSING_SECRETS[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  Missing secrets. Create them with:"
    for SECRET in "\${MISSING_SECRETS[@]}"; do
        echo "  echo -n 'YOUR_VALUE' | gcloud secrets create \$SECRET --data-file=- --replication-policy=automatic"
    done
fi

# ---------------------------------------------------------------------------
# 6. Verify Firestore
# ---------------------------------------------------------------------------
echo ""
echo "=== Checking Firestore ==="
if gcloud firestore databases describe > /dev/null 2>&1; then
    echo "  ✓ Firestore database exists"
else
    echo "  ✗ Firestore database not found"
    echo "  Create it at: https://console.cloud.google.com/firestore/databases?project=\$PROJECT_ID"
    echo "  Choose Native mode, ${REGION} region"
fi

# ---------------------------------------------------------------------------
# 7. Wait for IAM propagation
# ---------------------------------------------------------------------------
echo ""
echo "Waiting 15 seconds for IAM propagation..."
sleep 15

echo ""
echo "=== Permissions setup complete! ==="
echo ""
echo "You can now run ./deploy.sh to deploy the application."
FIXPERM_EOF

  chmod +x fix_permissions.sh
}

create_claude_md() {
  # Build tech stack lines
  local ai_services=""
  [ "$SVC_OPENAI" = true ] && ai_services="${ai_services}\n- **OpenAI** - AI API"
  [ "$SVC_OPENAI_REALTIME" = true ] && ai_services="${ai_services}\n- **OpenAI Realtime** - Voice conversations via WebRTC"
  [ "$SVC_GEMINI" = true ] && ai_services="${ai_services}\n- **Gemini AI** - Google AI"
  [ "$SVC_ANTHROPIC" = true ] && ai_services="${ai_services}\n- **Anthropic Claude** - AI API"
  [ "$SVC_RESEND" = true ] && ai_services="${ai_services}\n- **Resend** - Email delivery"

  # Build secrets list
  local secrets_list="- \`jwt-secret-key\`"
  [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ] && secrets_list="${secrets_list}, \`openai-api-key\`"
  [ "$SVC_GEMINI" = true ] && secrets_list="${secrets_list}, \`gemini-api-key\`"
  [ "$SVC_ANTHROPIC" = true ] && secrets_list="${secrets_list}, \`anthropic-api-key\`"

  cat > CLAUDE.md << CLAUDEMD_EOF
# CLAUDE.md

## Project Overview

**${DISPLAY_NAME}** - [Brief description to be filled in]

- **GCP Project**: \`${PROJECT_SLUG}\`

## Tech Stack

### Backend
- **FastAPI** - Python web framework
- **Google Firestore** - NoSQL database$(echo -e "$ai_services")

### Frontend
- **React 19** + **TypeScript**
- **Tailwind CSS v3** - Styling
- **Vite** - Build tool

### Infrastructure
- **Google Cloud Run** - Deployment via \`deploy.sh\`

## Commands

### Backend
\`\`\`bash
cd backend
source venv/bin/activate
uvicorn app.main:app --reload        # Run dev server (port 8000)
\`\`\`

### Frontend
\`\`\`bash
cd frontend
npm run dev      # Dev server (port 5173, proxies /api to backend)
npm run build    # Production build (tsc + vite)
npm run lint     # Lint
\`\`\`

### Deployment
\`\`\`bash
./deploy.sh                  # Deploy both services
./deploy.sh --backend-only   # Backend only
./deploy.sh --frontend-only  # Frontend only
\`\`\`

## API Endpoints

All endpoints prefixed with \`/api/v1/\`:

| Method | Endpoint | Description |
|--------|----------|-------------|
| \`GET\` | \`/health\` | Health check (at root, not under /api/v1) |

## Deployment

- **GCP Project**: \`${PROJECT_SLUG}\`
- **Region**: \`${REGION}\`
- **Services**: \`${BACKEND_SERVICE}\`, \`${FRONTEND_SERVICE}\`
- **Secrets**: ${secrets_list}

## Code Conventions

- Backend: \`snake_case\` (Python)
- Frontend: \`camelCase\` (TypeScript)
- API responses: \`camelCase\`

## Important Guidelines

### Dependencies
Always check PyPI for the latest dependency versions before adding to \`requirements.txt\`.

### What NOT to Do
- Don't implement more than requested
- Don't delete code without discussion
- Don't make definitive claims about bugs without testing
- Don't skip checking for existing patterns in the codebase
CLAUDEMD_EOF
}

create_readme_md() {
  cat > README.md << README_EOF
# ${DISPLAY_NAME}

[Brief description to be filled in]

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | FastAPI + Python 3.11 |
| Frontend | React 19 + TypeScript + Vite |
| Styling | Tailwind CSS v3 |
| Database | Google Firestore |
| Infrastructure | Google Cloud Run |

## Quick Start

### Prerequisites

- Python 3.11+
- Node.js 20+
- Google Cloud SDK (\`gcloud\`)

### Local Development

1. Copy the environment template:
   \`\`\`bash
   cp backend/.env.example backend/.env
   # Fill in your API keys
   \`\`\`

2. Start both services:
   \`\`\`bash
   ./run-local.sh
   \`\`\`

3. Open http://localhost:5173

### Deploy to Cloud Run

\`\`\`bash
# First time: set up GCP permissions
./fix_permissions.sh

# Deploy both services
./deploy.sh
\`\`\`
README_EOF
}


# ===== BACKEND FILES =====

create_backend_files() {
  print_blue "Creating backend files..."

  mkdir -p backend/app/core
  mkdir -p backend/app/api

  create_backend_dockerfile
  create_backend_dockerignore
  create_backend_gcloudignore
  create_backend_env_example
  create_backend_requirements
  create_backend_init_files
  create_backend_main_py
  create_backend_config_py
  create_backend_api_init
}

create_backend_dockerfile() {
  cat > backend/Dockerfile << 'DOCKERFILE_EOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Remove any secrets that might have been copied
RUN rm -f .env .env.example service_account.json credentials.json

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
DOCKERFILE_EOF
}

create_backend_dockerignore() {
  cat > backend/.dockerignore << 'DOCKERIGNORE_EOF'
.env
.env.example
service_account.json
credentials.json
venv/
__pycache__/
*.pyc
logs/
tests/
.pytest_cache/
.git/
DOCKERIGNORE_EOF
}

create_backend_gcloudignore() {
  cat > backend/.gcloudignore << 'GCLOUDIGNORE_EOF'
.env
.env.example
service_account.json
credentials.json
venv/
__pycache__/
*.pyc
*.pyo
logs/
tests/
.pytest_cache/
.git/
.dockerignore
.gcloudignore
GCLOUDIGNORE_EOF
}

create_backend_env_example() {
  cat > backend/.env.example << ENVEOF
# --- Application ---
DEBUG=true
CORS_ORIGINS=http://localhost:5173
FRONTEND_BASE_URL=http://localhost:5173

# --- Firebase ---
FIREBASE_PROJECT_ID=${PROJECT_SLUG}

# --- Authentication ---
JWT_SECRET_KEY=change-me-in-production
ENVEOF

  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    cat >> backend/.env.example << 'ENVEOF'

# --- OpenAI ---
OPENAI_API_KEY=sk-your-openai-api-key
ENVEOF
  fi

  if [ "$SVC_OPENAI_REALTIME" = true ]; then
    cat >> backend/.env.example << 'ENVEOF'
OPENAI_REALTIME_MODEL=gpt-realtime
ENVEOF
  fi

  if [ "$SVC_GEMINI" = true ]; then
    cat >> backend/.env.example << 'ENVEOF'

# --- Gemini ---
GEMINI_API_KEY=your-gemini-api-key
GEMINI_MODEL_PRO=gemini-3-pro-preview
GEMINI_MODEL_FLASH=gemini-2.5-flash
ENVEOF
  fi

  if [ "$SVC_ANTHROPIC" = true ]; then
    cat >> backend/.env.example << 'ENVEOF'

# --- Anthropic ---
ANTHROPIC_API_KEY=sk-ant-your-anthropic-api-key
ENVEOF
  fi

  if [ "$SVC_RESEND" = true ]; then
    cat >> backend/.env.example << 'ENVEOF'

# --- Email (optional for local dev, leave empty for console fallback) ---
RESEND_API_KEY=
ENVEOF
  fi
}

create_backend_requirements() {
  cat > backend/requirements.txt << 'REQEOF'
# Web framework
fastapi==0.115.12
uvicorn[standard]==0.34.0
pydantic-settings==2.13.1

# Firebase / Firestore
google-cloud-firestore==2.20.1

# HTTP client
httpx==0.28.1

# Auth
PyJWT==2.10.1

# Utilities
python-dotenv==1.1.0
REQEOF

  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    echo "" >> backend/requirements.txt
    echo "# OpenAI" >> backend/requirements.txt
    echo "openai" >> backend/requirements.txt
  fi

  if [ "$SVC_GEMINI" = true ]; then
    echo "" >> backend/requirements.txt
    echo "# Gemini" >> backend/requirements.txt
    echo "google-genai" >> backend/requirements.txt
  fi

  if [ "$SVC_ANTHROPIC" = true ]; then
    echo "" >> backend/requirements.txt
    echo "# Anthropic" >> backend/requirements.txt
    echo "anthropic" >> backend/requirements.txt
  fi

  if [ "$SVC_RESEND" = true ]; then
    echo "" >> backend/requirements.txt
    echo "# Email" >> backend/requirements.txt
    echo "resend==2.7.0" >> backend/requirements.txt
  fi

  if [ "$SVC_STORAGE" = true ]; then
    echo "" >> backend/requirements.txt
    echo "# Cloud Storage" >> backend/requirements.txt
    echo "google-cloud-storage" >> backend/requirements.txt
  fi
}

create_backend_init_files() {
  touch backend/app/__init__.py
  touch backend/app/core/__init__.py
  touch backend/app/api/__init__.py
}

create_backend_main_py() {
  cat > backend/app/main.py << MAINPY_EOF
"""FastAPI application entry point."""

import logging
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

settings = get_settings()

logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: runs on startup and shutdown."""
    logger.info("[STARTUP] ${DISPLAY_NAME} backend starting...")
    logger.info("[STARTUP] Debug mode: %s", settings.debug)
    logger.info("[STARTUP] CORS origins: %s", settings.cors_origins)
    yield
    logger.info("[SHUTDOWN] ${DISPLAY_NAME} backend shutting down...")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="${DISPLAY_NAME} API",
    version="0.1.0",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# CORS middleware
# ---------------------------------------------------------------------------

origins = [origin.strip() for origin in settings.cors_origins.split(",") if origin.strip()]

if settings.debug:
    debug_origins = [
        "http://localhost:5173",
        "http://localhost:5174",
        "http://localhost:3000",
        "http://127.0.0.1:5173",
    ]
    for o in debug_origins:
        if o not in origins:
            origins.append(o)

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# API routes
# ---------------------------------------------------------------------------

API_V1_PREFIX = "/api/v1"

# Mount your routers here:
# from app.api import my_router
# app.include_router(my_router.router, prefix=API_V1_PREFIX)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "${PROJECT_SLUG}-backend",
        "version": "0.1.0",
    }
MAINPY_EOF
}

create_backend_config_py() {
  cat > backend/app/core/config.py << CONFIGPY_START
"""Application settings using Pydantic Settings."""

from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application configuration loaded from environment variables and .env file."""

    # Application
    debug: bool = True
    cors_origins: str = "http://localhost:5173"
    frontend_base_url: str = "http://localhost:5173"

    # Firebase
    firebase_project_id: str = ""

    # Authentication
    jwt_secret_key: str = "change-me-in-production"
CONFIGPY_START

  if [ "$SVC_OPENAI" = true ] || [ "$SVC_OPENAI_REALTIME" = true ]; then
    cat >> backend/app/core/config.py << 'CONFIGPY_OPENAI'

    # OpenAI
    openai_api_key: str = ""
CONFIGPY_OPENAI
  fi

  if [ "$SVC_OPENAI_REALTIME" = true ]; then
    cat >> backend/app/core/config.py << 'CONFIGPY_REALTIME'
    openai_realtime_model: str = "gpt-realtime"
CONFIGPY_REALTIME
  fi

  if [ "$SVC_GEMINI" = true ]; then
    cat >> backend/app/core/config.py << 'CONFIGPY_GEMINI'

    # Gemini
    gemini_api_key: str = ""
    gemini_model_pro: str = "gemini-3-pro-preview"
    gemini_model_flash: str = "gemini-2.5-flash"
CONFIGPY_GEMINI
  fi

  if [ "$SVC_ANTHROPIC" = true ]; then
    cat >> backend/app/core/config.py << 'CONFIGPY_ANTHROPIC'

    # Anthropic
    anthropic_api_key: str = ""
CONFIGPY_ANTHROPIC
  fi

  if [ "$SVC_RESEND" = true ]; then
    cat >> backend/app/core/config.py << 'CONFIGPY_RESEND'

    # Email
    resend_api_key: str = ""
CONFIGPY_RESEND
  fi

  cat >> backend/app/core/config.py << 'CONFIGPY_END'

    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8",
    }


@lru_cache()
def get_settings() -> Settings:
    """Return cached Settings singleton."""
    return Settings()
CONFIGPY_END
}

create_backend_api_init() {
  # Already created by create_backend_init_files
  true
}


# ===== FRONTEND FILES =====

create_frontend_files() {
  print_blue "Creating frontend files..."

  mkdir -p frontend/src/pages
  mkdir -p frontend/src/services
  mkdir -p frontend/public

  create_frontend_dockerfile
  create_frontend_dockerignore
  create_frontend_gcloudignore
  create_frontend_nginx_conf
  create_frontend_docker_entrypoint
  create_frontend_cloudbuild_yaml
  create_frontend_index_html
  create_frontend_package_json
  create_frontend_vite_config
  create_frontend_tsconfig
  create_frontend_tailwind_config
  create_frontend_postcss_config
  create_frontend_eslint_config
  create_frontend_env
  create_frontend_src_main
  create_frontend_src_app
  create_frontend_src_index_css
  create_frontend_src_vite_env
  create_frontend_src_home
  create_frontend_src_api
}

create_frontend_dockerfile() {
  cat > frontend/Dockerfile << 'FEDF_EOF'
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL

RUN npm run build

# --- Production ---
FROM nginx:alpine

COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:${PORT}/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
FEDF_EOF
}

create_frontend_dockerignore() {
  cat > frontend/.dockerignore << 'FEDI_EOF'
node_modules/
dist/
.env
.env.local
.git/
FEDI_EOF
}

create_frontend_gcloudignore() {
  cat > frontend/.gcloudignore << 'FEGI_EOF'
node_modules/
dist/
.env
.env.local
.git/
.dockerignore
.gcloudignore
FEGI_EOF
}

create_frontend_nginx_conf() {
  cat > frontend/nginx.conf << 'NGINX_EOF'
server {
    listen ${PORT};
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
NGINX_EOF
}

create_frontend_docker_entrypoint() {
  cat > frontend/docker-entrypoint.sh << 'ENTRY_EOF'
#!/bin/sh
export PORT=${PORT:-8080}
envsubst '${PORT}' < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'
ENTRY_EOF
  chmod +x frontend/docker-entrypoint.sh
}

create_frontend_cloudbuild_yaml() {
  cat > frontend/cloudbuild.yaml << CLOUDBUILD_EOF
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '--build-arg'
      - 'VITE_API_URL=\${_VITE_API_URL}'
      - '-t'
      - '\${_IMAGE_NAME}'
      - '.'
    timeout: 1200s

images:
  - '\${_IMAGE_NAME}'

options:
  machineType: 'E2_HIGHCPU_8'
  logging: CLOUD_LOGGING_ONLY

substitutions:
  _IMAGE_NAME: gcr.io/\${PROJECT_ID}/${FRONTEND_SERVICE}
  _VITE_API_URL: http://localhost:8000/api/v1
CLOUDBUILD_EOF
}

create_frontend_index_html() {
  cat > frontend/index.html << INDEXHTML_EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/vite.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${DISPLAY_NAME}</title>
    <script>
      // Detect dark mode preference
      if (localStorage.theme === 'dark' || (!('theme' in localStorage) && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
        document.documentElement.classList.add('dark');
      }
    </script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
INDEXHTML_EOF

  # Create a simple SVG favicon
  cat > frontend/public/vite.svg << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="20" fill="#4F46E5"/>
  <text x="50" y="68" font-family="system-ui" font-size="50" font-weight="bold" fill="white" text-anchor="middle">G</text>
</svg>
SVGEOF
}

create_frontend_package_json() {
  cat > frontend/package.json << PKGJSON_EOF
{
  "name": "${PROJECT_SLUG}-frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "lint": "eslint .",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "react-router-dom": "^7.1.0"
  },
  "devDependencies": {
    "typescript": "^5.7.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "vite": "^6.0.0",
    "@vitejs/plugin-react": "^4.3.0",
    "tailwindcss": "^3.4.0",
    "autoprefixer": "^10.4.0",
    "postcss": "^8.4.0",
    "eslint": "^9.17.0",
    "@eslint/js": "^9.17.0",
    "eslint-plugin-react-hooks": "^5.0.0",
    "eslint-plugin-react-refresh": "^0.4.0",
    "globals": "^15.0.0",
    "typescript-eslint": "^8.18.0"
  }
}
PKGJSON_EOF
}

create_frontend_vite_config() {
  cat > frontend/vite.config.ts << 'VITECONF_EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
      '/health': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
    allowedHosts: [
      ".trycloudflare.com"
    ]
  },
});
VITECONF_EOF
}

create_frontend_tsconfig() {
  cat > frontend/tsconfig.json << 'TSCONF_EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "moduleDetection": "force",
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    }
  },
  "include": ["src"]
}
TSCONF_EOF
}

create_frontend_tailwind_config() {
  cat > frontend/tailwind.config.ts << 'TWCONF_EOF'
import type { Config } from 'tailwindcss';

const config: Config = {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {},
  },
  plugins: [],
};

export default config;
TWCONF_EOF
}

create_frontend_postcss_config() {
  cat > frontend/postcss.config.js << 'POSTCSS_EOF'
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
POSTCSS_EOF
}

create_frontend_eslint_config() {
  cat > frontend/eslint.config.js << 'ESLINT_EOF'
import js from '@eslint/js';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist'] },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],
      '@typescript-eslint/no-unused-vars': [
        'warn',
        { argsIgnorePattern: '^_' },
      ],
    },
  },
);
ESLINT_EOF
}

create_frontend_env() {
  cat > frontend/.env << 'FRONTENV_EOF'
VITE_API_URL=http://localhost:8000/api/v1
FRONTENV_EOF
}

create_frontend_src_main() {
  cat > frontend/src/main.tsx << 'SRCMAIN_EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App';
import './index.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
);
SRCMAIN_EOF
}

create_frontend_src_app() {
  cat > frontend/src/App.tsx << 'SRCAPP_EOF'
import { Routes, Route, Navigate } from 'react-router-dom';
import Home from './pages/Home';

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Home />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
SRCAPP_EOF
}

create_frontend_src_index_css() {
  cat > frontend/src/index.css << 'SRCCSS_EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

html {
  scroll-behavior: smooth;
}

body {
  font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
    'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
SRCCSS_EOF
}

create_frontend_src_vite_env() {
  cat > frontend/src/vite-env.d.ts << 'VITEENV_EOF'
/// <reference types="vite/client" />
VITEENV_EOF
}

create_frontend_src_home() {
  cat > frontend/src/pages/Home.tsx << HOMETS_EOF
import { useState } from 'react';
import { checkHealth } from '../services/api';

export default function Home() {
  const [status, setStatus] = useState<'idle' | 'loading' | 'success' | 'error'>('idle');
  const [response, setResponse] = useState<string>('');

  const handleCheck = async () => {
    setStatus('loading');
    try {
      const data = await checkHealth();
      setResponse(JSON.stringify(data, null, 2));
      setStatus('success');
    } catch (err) {
      setResponse(err instanceof Error ? err.message : 'Unknown error');
      setStatus('error');
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center p-4">
      <div className="max-w-md w-full bg-white dark:bg-gray-800 rounded-2xl shadow-lg p-8 text-center">
        <h1 className="text-3xl font-bold text-gray-900 dark:text-white mb-2">
          ${DISPLAY_NAME}
        </h1>
        <p className="text-gray-500 dark:text-gray-400 mb-8">Your project is ready.</p>

        <button
          onClick={handleCheck}
          disabled={status === 'loading'}
          className="w-full px-6 py-3 bg-indigo-600 text-white rounded-xl font-medium
                     hover:bg-indigo-700 disabled:opacity-50 transition-colors cursor-pointer"
        >
          {status === 'loading' ? 'Checking...' : 'Test Backend Connection'}
        </button>

        {status === 'success' && (
          <div className="mt-6 p-4 bg-green-50 dark:bg-green-900/30 border border-green-200 dark:border-green-800 rounded-xl">
            <p className="text-green-700 dark:text-green-400 font-medium mb-2">Connected successfully</p>
            <pre className="text-xs text-green-600 dark:text-green-300 text-left overflow-auto">{response}</pre>
          </div>
        )}

        {status === 'error' && (
          <div className="mt-6 p-4 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-xl">
            <p className="text-red-700 dark:text-red-400 font-medium mb-2">Connection failed</p>
            <pre className="text-xs text-red-600 dark:text-red-300 text-left overflow-auto">{response}</pre>
          </div>
        )}
      </div>
    </div>
  );
}
HOMETS_EOF
}

create_frontend_src_api() {
  cat > frontend/src/services/api.ts << 'APITS_EOF'
const BASE_URL = import.meta.env.VITE_API_URL || '/api/v1';

interface RequestOptions extends RequestInit {
  headers?: Record<string, string>;
}

async function apiFetch<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...options.headers,
  };

  // Add auth token if available
  const token = localStorage.getItem('token');
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  const response = await fetch(`${BASE_URL}${path}`, { ...options, headers });

  if (!response.ok) {
    const errorBody = await response.text().catch(() => '');
    throw new Error(
      `API error ${response.status}: ${response.statusText}${errorBody ? ` - ${errorBody}` : ''}`
    );
  }

  if (response.status === 204) return undefined as T;
  return response.json();
}

export function checkHealth() {
  // Health endpoint is at root, not under /api/v1
  return fetch('/health').then((r) => {
    if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
    return r.json();
  });
}

export { apiFetch, BASE_URL };
APITS_EOF
}


# ===== DOCS =====

create_docs_dir() {
  mkdir -p docs
  touch docs/.gitkeep
}


# ---------------------------------------------------------------------------
# 6. Phase 4: Initialize
# ---------------------------------------------------------------------------

phase_4_initialize() {
  print_step 4 "Initializing Project"

  cd "$TARGET_DIR"

  # Git init
  if [ ! -d ".git" ]; then
    git init --quiet
    print_green "Git repository initialized"
  else
    print_yellow "Git repository already exists"
  fi

  git add -A
  git commit -m "Initial scaffold: ${DISPLAY_NAME}

FastAPI + React/Vite/Tailwind on GCP Cloud Run.
Generated by create-gcp-project.sh." --quiet 2>/dev/null || print_yellow "Nothing to commit"

  print_green "Initial commit created"

  # GitHub repo
  if [ "$CREATE_GITHUB" = true ] && command_exists gh; then
    print_blue "Creating GitHub repository..."
    gh repo create "$PROJECT_SLUG" --private --source=. --remote=origin --push 2>/dev/null || {
      print_yellow "GitHub repo creation failed (may already exist). You can create it manually:"
      echo "  gh repo create ${PROJECT_SLUG} --private --source=. --remote=origin --push"
    }
  fi
}


# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------

print_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}Project Created Successfully!${NC}                      ${GREEN}║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}Project:${NC}  ${DISPLAY_NAME}"
  echo -e "${GREEN}║${NC}  ${BOLD}Location:${NC} ${TARGET_DIR}"
  echo -e "${GREEN}║${NC}  ${BOLD}GCP ID:${NC}   ${PROJECT_SLUG}"
  echo -e "${GREEN}║${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}Next steps:${NC}"
  echo -e "${GREEN}║${NC}"
  echo -e "${GREEN}║${NC}  1. cd ${PROJECT_SLUG}"
  echo -e "${GREEN}║${NC}  2. cp backend/.env.example backend/.env"
  echo -e "${GREEN}║${NC}     (fill in your API keys)"
  echo -e "${GREEN}║${NC}  3. ./run-local.sh --no-tunnel"
  echo -e "${GREEN}║${NC}  4. Open http://localhost:5173"
  echo -e "${GREEN}║${NC}     Click 'Test Backend Connection'"
  echo -e "${GREEN}║${NC}  5. ./deploy.sh"
  echo -e "${GREEN}║${NC}     (auto-runs fix_permissions.sh on first deploy)"
  echo -e "${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
}


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
  print_banner
  preflight_checks
  phase_1_interactive_setup
  confirm_selections
  phase_2_gcp_setup
  phase_3_file_scaffolding
  phase_4_initialize
  print_summary
}

main
