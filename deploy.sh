#!/usr/bin/env bash
# =============================================================================
# One-shot deploy wrapper for the Gemini Enterprise + Model Armor dashboard.
#
# Usage:
#   ./deploy.sh <PROJECT_ID> [extra terraform apply args...]
#
# What it does:
#   1. terraform -chdir=terraform init
#   2. terraform -chdir=terraform apply -var="project_id=<PROJECT_ID>" ...
#      (Terraform will still show its own plan + interactive yes/no prompt
#      unless you pass -auto-approve yourself as an extra arg.)
#   3. On success, prints the Looker Studio "create report" URL from the
#      `looker_studio_create_url` output so you have a working dashboard link
#      immediately.
#
# This script does not run automatically as part of authoring this repo —
# it's meant for YOU to run when you're ready to actually deploy.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <PROJECT_ID> [extra terraform apply args...]" >&2
  echo "Example: $0 my-gcp-project" >&2
  echo "Example (skip the interactive prompt): $0 my-gcp-project -auto-approve" >&2
  exit 1
fi

PROJECT_ID="$1"
shift
EXTRA_ARGS=("$@")

echo ">>> Deploying Gemini Enterprise + Model Armor dashboard to project: ${PROJECT_ID}"
echo ">>> terraform -chdir=${TF_DIR} init"
terraform -chdir="${TF_DIR}" init

echo ">>> terraform -chdir=${TF_DIR} apply -var=\"project_id=${PROJECT_ID}\" ${EXTRA_ARGS[*]}"
echo ">>> NOTE: this includes a 300s (5 min) wait for IAM propagation before the"
echo ">>>       remote model is created — expect ~7 minutes total for a fresh project."
terraform -chdir="${TF_DIR}" apply -var="project_id=${PROJECT_ID}" "${EXTRA_ARGS[@]}"

echo
echo ">>> Deploy complete. Looker Studio dashboard create URL:"
terraform -chdir="${TF_DIR}" output -raw looker_studio_create_url
echo
echo
echo ">>> Open the URL above in a browser to create your Looker Studio report."
