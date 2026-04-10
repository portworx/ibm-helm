set -euo pipefail

# =============================================================================
# IBM Helm Release Automation Script
# Usage: ./release.sh --px=<PX_VERSION> --stork=<STORK_VERSION> \
#          --operator=<OPERATOR_VERSION> --jira=<JIRA_TICKET> [--release]
# By default runs in dry-run mode (no git commit/push).
# Pass --release to commit and push to remote.
# Example: ./release.sh --px=3.5.3 --stork=26.2.0 \
#            --operator=25.7.0 --jira=PXDO-6000
# Release: ./release.sh --px=3.5.3 --stork=26.2.0 \
#            --operator=25.7.0 --jira=PXDO-6000 --release
# =============================================================================

usage() {
  echo "Usage: $0 --px=<PX_VERSION> --stork=<STORK_VERSION> \\"
  echo "         --operator=<OPERATOR_VERSION> --jira=<JIRA_TICKET> [--release]"
  echo ""
  echo "By default runs in dry-run mode (no git commit/push)."
  echo "Pass --release to commit and push to remote."
  echo ""
  echo "Example: $0 --px=3.5.3 --stork=26.2.0 \\"
  echo "           --operator=25.7.0 --jira=PXDO-6000"
  exit 1
}

PX_VERSION=""
STORK_VERSION=""
OPERATOR_VERSION=""
JIRA_TICKET=""
RELEASE_MODE=false

for arg in "$@"; do
  case "${arg}" in
    --px=*)       PX_VERSION="${arg#*=}" ;;
    --stork=*)    STORK_VERSION="${arg#*=}" ;;
    --operator=*) OPERATOR_VERSION="${arg#*=}" ;;
    --jira=*)     JIRA_TICKET="${arg#*=}" ;;
    --release)    RELEASE_MODE=true ;;
    *)
      echo "ERROR: Unknown argument: ${arg}"
      usage
      ;;
  esac
done

if [[ -z "${PX_VERSION}" || -z "${STORK_VERSION}" || -z "${OPERATOR_VERSION}" || -z "${JIRA_TICKET}" ]]; then
  echo "ERROR: All arguments are required."
  usage
fi

BRANCH_NAME="${JIRA_TICKET}-px-${PX_VERSION}"
COMMIT_MSG="${JIRA_TICKET} Add PXE ${PX_VERSION} Release"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Cross-platform sed in-place: macOS requires -i '', GNU sed requires -i
sedi() {
  if sed --version 2>/dev/null | grep -q 'GNU'; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

MAKEFILE="${REPO_ROOT}/Makefile"
CHART_YAML="${REPO_ROOT}/chart/portworx/Chart.yaml"
VALUES_YAML="${REPO_ROOT}/chart/portworx/values.yaml"
VERSIONS_CM="${REPO_ROOT}/chart/portworx/templates/px-versions-cm.yaml"

if [[ "${RELEASE_MODE}" == true ]]; then
  echo "=== IBM Helm Release Automation (RELEASE MODE) ==="
else
  echo "=== IBM Helm Release Automation (DRY-RUN MODE) ==="
fi
echo "PX Version:       ${PX_VERSION}"
echo "Stork Version:    ${STORK_VERSION}"
echo "Operator Version: ${OPERATOR_VERSION}"
echo "JIRA Ticket:      ${JIRA_TICKET}"
echo "Branch:           ${BRANCH_NAME}"
echo ""

# --- Step 1: Git setup (reset to clean state from origin/master) ---
echo ">>> Step 1: Resetting to origin/master and creating branch..."
cd "${REPO_ROOT}"
git fetch origin master
git checkout master
git reset --hard origin/master
echo "  Reset to origin/master (clean state)."

# Check if branch already exists (locally or remotely) and clean up
LOCAL_EXISTS=$(git branch --list "${BRANCH_NAME}")
REMOTE_EXISTS=$(git ls-remote --heads origin "${BRANCH_NAME}" 2>/dev/null)

if [[ -n "${LOCAL_EXISTS}" || -n "${REMOTE_EXISTS}" ]]; then
  echo "WARNING: Branch '${BRANCH_NAME}' already exists."
  [[ -n "${LOCAL_EXISTS}" ]] && echo "  - Found locally"
  [[ -n "${REMOTE_EXISTS}" ]] && echo "  - Found on remote"
  read -rp "Do you want to delete and recreate it? (y/N): " CONFIRM
  if [[ "${CONFIRM}" =~ ^[Yy]$ ]]; then
    [[ -n "${LOCAL_EXISTS}" ]] && git branch -D "${BRANCH_NAME}" && echo "  Deleted local branch."
    [[ -n "${REMOTE_EXISTS}" ]] && git push origin --delete "${BRANCH_NAME}" && echo "  Deleted remote branch."
  else
    echo "Aborting. Please resolve the branch conflict manually."
    exit 1
  fi
fi
git checkout -b "${BRANCH_NAME}"

# --- Step 2: Fetch version data from install.portworx.com ---
echo ">>> Step 2: Fetching version data from https://install.portworx.com/${PX_VERSION}/version ..."
VERSION_DATA=$(curl -fsSL "https://install.portworx.com/${PX_VERSION}/version")
echo "Fetched version data successfully."

# Parse components from the version YAML (simple grep/sed parsing)
parse_component() {
  local key="$1"
  echo "${VERSION_DATA}" | grep "^  ${key}:" | sed "s/^  ${key}: //"
}

# --- Step 3: Update Makefile ---
echo ">>> Step 3: Updating Makefile..."
OLD_PX_VERSION=$(grep '^PX_VERSION := ' "${MAKEFILE}" | sed 's/PX_VERSION := //')
sedi "s/^PX_VERSION := .*/PX_VERSION := ${PX_VERSION}/" "${MAKEFILE}"
echo "  PX_VERSION: ${OLD_PX_VERSION} -> ${PX_VERSION}"

# --- Step 4: Update Chart.yaml ---
echo ">>> Step 4: Updating Chart.yaml..."
# Always read the base chart version from master to ensure we only increment once
BASE_CHART_VERSION=$(git show master:chart/portworx/Chart.yaml | grep '^version: ' | sed 's/version: //')
OLD_CHART_VERSION=$(grep '^version: ' "${CHART_YAML}" | sed 's/version: //')
# Increment the patch version from master base (e.g., 1.0.84 -> 1.0.85)
NEW_CHART_VERSION=$(echo "${BASE_CHART_VERSION}" | awk -F. '{printf "%s.%s.%s", $1, $2, $3+1}')
sedi "s/^version: .*/version: ${NEW_CHART_VERSION}/" "${CHART_YAML}"
sedi "s/^appVersion: .*/appVersion: \"${PX_VERSION}\"/" "${CHART_YAML}"
echo "  version: ${OLD_CHART_VERSION} -> ${NEW_CHART_VERSION} (base from master: ${BASE_CHART_VERSION})"
echo "  appVersion: -> ${PX_VERSION}"

# --- Step 5: Update values.yaml ---
echo ">>> Step 5: Updating values.yaml..."
sedi "s/^storkVersion: .*/storkVersion: ${STORK_VERSION}                 # Defaults to empty, operator will get the version from manifest based on portworx image version./" "${VALUES_YAML}"
sedi "s/^imageVersion: .*/imageVersion: ${PX_VERSION}                # Version of the PX Image./" "${VALUES_YAML}"
sedi "s/^pxOperatorImageVersion: .*/pxOperatorImageVersion: ${OPERATOR_VERSION}       # Version of the PX operator image./" "${VALUES_YAML}"
echo "  storkVersion: -> ${STORK_VERSION}"
echo "  imageVersion: -> ${PX_VERSION}"
echo "  pxOperatorImageVersion: -> ${OPERATOR_VERSION}"

# --- Step 6: Update px-versions-cm.yaml ---
echo ">>> Step 6: Updating px-versions-cm.yaml..."

# Build the new version block from fetched data, overriding stork
COMPONENTS=""
while IFS= read -r line; do
  # Skip non-component lines
  if [[ "${line}" =~ ^[[:space:]]*version: ]] || [[ "${line}" =~ ^components: ]] || [[ -z "${line}" ]]; then
    continue
  fi
  # Extract key and value
  key=$(echo "${line}" | sed 's/^[[:space:]]*//' | cut -d: -f1)
  value=$(echo "${line}" | sed 's/^[[:space:]]*//' | cut -d' ' -f2-)

  # Override stork with user-provided version
  if [[ "${key}" == "stork" ]]; then
    # Extract image name without tag
    img_name=$(echo "${value}" | cut -d: -f1)
    value="${img_name}:${STORK_VERSION}"
  fi

  COMPONENTS="${COMPONENTS}      ${key}: ${value}\n"
done <<< "${VERSION_DATA}"

# Find the first {{- if eq line and insert the new block before it
# The new block becomes the first condition, and the old first becomes an else-if
FIRST_IF_LINE=$(grep -n '{{- if eq .Values.imageVersion' "${VERSIONS_CM}" | head -1 | cut -d: -f1)

if [[ -z "${FIRST_IF_LINE}" ]]; then
  echo "ERROR: Could not find the first version condition in px-versions-cm.yaml"
  exit 1
fi

# Get the current first version
OLD_FIRST_VERSION=$(sed -n "${FIRST_IF_LINE}p" "${VERSIONS_CM}" | grep -o '"[^"]*"' | tr -d '"')

if [[ "${OLD_FIRST_VERSION}" == "${PX_VERSION}" ]]; then
  echo "  Version ${PX_VERSION} already exists as the first entry. Skipping px-versions-cm.yaml update."
else
  # Replace the first {{- if with {{- else if (demoting old first to else-if)
  sedi "${FIRST_IF_LINE}s/{{- if eq/{{- else if eq/" "${VERSIONS_CM}"

  # Build the new block to insert before the (now else-if) line
  NEW_BLOCK="      {{- if eq .Values.imageVersion \"${PX_VERSION}\" }}\n${COMPONENTS}"

  # Insert the new block before the old first condition line
  # Use awk for reliable multi-line insertion
  awk -v line="${FIRST_IF_LINE}" -v block="${NEW_BLOCK}" '
    NR == line { printf "%s", block }
    { print }
  ' "${VERSIONS_CM}" > "${VERSIONS_CM}.tmp"
  mv "${VERSIONS_CM}.tmp" "${VERSIONS_CM}"

  echo "  Added new version block for ${PX_VERSION}"
fi

# --- Step 7: Run package-helm ---
echo ">>> Step 7: Running 'GIT_BRANCH=master make package-helm'..."
cd "${REPO_ROOT}"
GIT_BRANCH=master make package-helm
echo "  Helm package created successfully."

# --- Step 8: Commit and push (release mode only) ---
if [[ "${RELEASE_MODE}" == true ]]; then
  echo ">>> Step 8: Committing and pushing..."
  cd "${REPO_ROOT}"
  git add -A
  git commit -m "* ${COMMIT_MSG}"
  git push origin "${BRANCH_NAME}"
  echo "  Pushed branch ${BRANCH_NAME} to origin."
else
  echo ">>> Step 8: Skipping commit and push (dry-run mode)."
  echo "  Run with --release to commit and push."
fi

echo ""
echo "=== Release automation complete! ==="
echo "Branch: ${BRANCH_NAME}"
if [[ "${RELEASE_MODE}" == true ]]; then
  echo "Changes committed and pushed to origin/${BRANCH_NAME}."
else
  echo "DRY-RUN: Files updated locally. Review changes and re-run with --release to commit and push."
fi