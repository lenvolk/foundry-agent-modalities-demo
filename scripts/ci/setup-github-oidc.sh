#!/usr/bin/env bash
# =============================================================================
# One-time setup: connect YOUR GitHub fork to YOUR Azure subscription with
# OIDC (no secrets). Safe to re-run (idempotent), e.g. after Teardown deleted
# the resource group and its role assignments.
#
# Creates / updates:
#   Azure     resource group, app registration + service principal,
#             federated credentials, role assignments (RG scope + 1 small
#             subscription-level custom role)
#   GitHub    repository variables, environments dev + prod (prod = approval)
#
# Usage (prompts for anything not set):
#   az login --tenant <TENANT_ID>   &&   gh auth login
#   GITHUB_REPO=<you>/foundry-agent-modalities-demo ./scripts/ci/setup-github-oidc.sh
#
# Optional env vars: AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP
#   AZURE_LOCATION AZURE_ENV_NAME AZURE_AI_MODEL_DEPLOYMENT_NAME GITHUB_REPO
#   EXTRA_BRANCHES (comma list, e.g. "feat/action_workflow") PROD_REVIEWER
# =============================================================================
set -euo pipefail

FOUNDRY_USER_ROLE="53ca6127-db72-4b80-b1b0-d745d6d5456d"   # Foundry User (formerly Azure AI User)
RBAC_ADMIN_ROLE="f58310d9-a9f6-439a-9e8d-f62e7b41a168"     # Role Based Access Control Administrator
CONTRIBUTOR_ROLE="b24988ac-6180-42a0-ab88-20f7382dd24c"    # Contributor
CUSTOM_ROLE_NAME="Foundry CI subscription deployer"

ask() {   # ask VAR "question" "default"
  local current="${!1:-}"
  if [[ -z "$current" ]]; then
    read -r -p "$2${3:+ [$3]}: " current
    current="${current:-${3:-}}"
  fi
  [[ -n "$current" ]] || { echo "$1 is required" >&2; exit 1; }
  printf -v "$1" '%s' "$current"
}
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- inputs ---
step "Inputs"
ask AZURE_TENANT_ID       "Tenant ID"        "$(az account show --query tenantId -o tsv 2>/dev/null || true)"
ask AZURE_SUBSCRIPTION_ID "Subscription ID"  "$(az account show --query id -o tsv 2>/dev/null || true)"
ask AZURE_RESOURCE_GROUP  "Resource group"   "FoundryModalitiesCI"
ask AZURE_LOCATION        "Region"           "northcentralus"
ask AZURE_ENV_NAME        "azd env / Foundry project name" "foundry-modalities-ci"
ask AZURE_AI_MODEL_DEPLOYMENT_NAME "Model deployment name" "gpt-5.6-sol"
ask GITHUB_REPO           "GitHub repo (owner/name)" "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
ask PROD_REVIEWER         "GitHub user who approves prod" "$(gh api user -q .login 2>/dev/null || true)"
EXTRA_BRANCHES="${EXTRA_BRANCHES:-}"
APP_NAME="${APP_NAME:-gh-${GITHUB_REPO//\//-}-foundry-ci}"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
[[ "$(az account show --query tenantId -o tsv)" == "$AZURE_TENANT_ID" ]] \
  || { echo "Signed in to a different tenant. Run: az login --tenant $AZURE_TENANT_ID" >&2; exit 1; }
SUB_SCOPE="/subscriptions/$AZURE_SUBSCRIPTION_ID"
RG_SCOPE="$SUB_SCOPE/resourceGroups/$AZURE_RESOURCE_GROUP"

# -------------------------------------------------------- resource group ---
step "Resource group $AZURE_RESOURCE_GROUP"
az group create -n "$AZURE_RESOURCE_GROUP" -l "$AZURE_LOCATION" -o none

# ------------------------------------------- app registration + principal ---
step "App registration $APP_NAME"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
[[ -n "$APP_ID" ]] || APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
SP_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || az ad sp create --id "$APP_ID" --query id -o tsv)"
echo "client id: $APP_ID"

# -------------------------------------------------- federated credentials ---
# The OIDC token's "subject" must match one of these exactly.
step "Federated credentials (who may sign in as this app)"
subjects=("environment:dev" "environment:prod" "ref:refs/heads/main")
IFS=',' read -r -a extra <<<"$EXTRA_BRANCHES"
for b in ${extra[@]+"${extra[@]}"}; do if [[ -n "$b" ]]; then subjects+=("ref:refs/heads/$b"); fi; done
# GitHub decides the subject prefix. Newer repos use immutable IDs: repo:owner@123/name@456
prefix="$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" -q .sub_claim_prefix 2>/dev/null || true)"
prefix="${prefix:-repo:$GITHUB_REPO}"
existing="$(az ad app federated-credential list --id "$APP_ID" --query "[].subject" -o tsv)"
for s in "${subjects[@]}"; do
  subject="$prefix:$s"
  if grep -qxF "$subject" <<<"$existing"; then echo "  ✓ $subject"; continue; fi
  name="gh-$(tr -c 'A-Za-z0-9-' '-' <<<"$s" | cut -c1-100 | sed 's/-*$//')"
  az ad app federated-credential create --id "$APP_ID" -o none --parameters "$(printf \
    '{"name":"%s","issuer":"https://token.actions.githubusercontent.com","subject":"%s","audiences":["api://AzureADTokenExchange"]}' \
    "$name" "$subject")"
  echo "  + $subject"
done

# ------------------------------------------------------------------ RBAC ---
step "Custom role: $CUSTOM_ROLE_NAME (subscription-level deployments + purge)"
role_json="$(mktemp ./.foundry-ci-role.XXXXXX)"; trap 'rm -f "$role_json"' EXIT   # relative path: works for az on Windows Git Bash too
cat >"$role_json" <<EOF
{
  "Name": "$CUSTOM_ROLE_NAME",
  "IsCustom": true,
  "Description": "azd's Foundry provider runs a subscription-scope ARM deployment; teardown purges soft-deleted Foundry accounts. Each resource inside the deployment is still checked against the caller's RG-scoped roles.",
  "Actions": [
    "Microsoft.Resources/deployments/*",
    "Microsoft.Resources/subscriptions/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/read",
    "Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/delete",
    "Microsoft.CognitiveServices/locations/operationResults/read",
    "Microsoft.CognitiveServices/locations/usages/read",
    "Microsoft.CognitiveServices/locations/models/read"
  ],
  "NotActions": [],
  "AssignableScopes": ["$SUB_SCOPE"]
}
EOF
if [[ -n "$(az role definition list --custom-role-only true --name "$CUSTOM_ROLE_NAME" --query "[0].name" -o tsv)" ]]; then
  az role definition update --role-definition "$role_json" -o none
else
  az role definition create --role-definition "$role_json" -o none
  sleep 20   # new role definitions take a moment to replicate
fi

assign() {   # assign <label> <role name or id> <scope> [condition]
  local label="$1"; shift
  label="$label @ $([[ "$2" == "$SUB_SCOPE" ]] && echo subscription || echo "resource group $AZURE_RESOURCE_GROUP")"
  if [[ -n "$(az role assignment list --scope "$2" --role "$1" --query "[?principalId=='$SP_ID'] | [0].id" -o tsv)" ]]; then
    echo "  ✓ $label"; return
  fi
  local extra_args=()
  if [[ -n "${3:-}" ]]; then extra_args=(--condition "$3" --condition-version 2.0); fi
  for attempt in 1 2 3 4 5; do   # a brand-new principal can take a minute to replicate
    az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
      --role "$1" --scope "$2" ${extra_args[@]+"${extra_args[@]}"} -o none && { echo "  + $label"; return; }
    echo "  … retrying ($attempt)"; sleep 15
  done
  exit 1
}

# Only allow assigning/removing the Foundry User role (azd deploy gives it to the agent's identity).
CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$FOUNDRY_USER_ROLE})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$FOUNDRY_USER_ROLE}))"

step "Role assignments"
assign "Contributor"                      "$CONTRIBUTOR_ROLE"  "$RG_SCOPE"
assign "Foundry User"                     "$FOUNDRY_USER_ROLE" "$RG_SCOPE"
assign "RBAC Administrator (conditional)" "$RBAC_ADMIN_ROLE"   "$RG_SCOPE" "$CONDITION"
assign "$CUSTOM_ROLE_NAME"                "$CUSTOM_ROLE_NAME"  "$SUB_SCOPE"

# ---------------------------------------------------------------- GitHub ---
step "GitHub variables on $GITHUB_REPO"
for v in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_LOCATION AZURE_ENV_NAME AZURE_AI_MODEL_DEPLOYMENT_NAME; do
  gh variable set "$v" -R "$GITHUB_REPO" -b "${!v}"
done
gh variable set AZURE_CLIENT_ID -R "$GITHUB_REPO" -b "$APP_ID"

step "GitHub environments (dev = automatic, prod = $PROD_REVIEWER approves)"
gh api -X PUT "repos/$GITHUB_REPO/environments/dev" --silent
reviewer_id="$(gh api "users/$PROD_REVIEWER" -q .id)"
gh api -X PUT "repos/$GITHUB_REPO/environments/prod" --silent --input - <<EOF
{"reviewers":[{"type":"User","id":$reviewer_id}],"prevent_self_review":false}
EOF

step "Done"
echo "Next: GitHub → Actions → Provision → Run workflow."
