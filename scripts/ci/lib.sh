#!/usr/bin/env bash
# =============================================================================
# CI function library for the GitHub Actions workflows in .github/workflows/.
#
# Every workflow step is a one-liner that calls ONE function here:
#     ./scripts/ci/lib.sh <function> [args...]
#
# Why: YAML stays short and readable (the "what"), bash holds the logic (the
# "how"), and you can run the same functions on your laptop to debug.
#
# Inputs come from environment variables that the workflows map from GitHub
# repository variables (vars.*). Nothing here is secret: sign-in uses OIDC.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AZD_DIR="$ROOT/deployment"
CASES="$ROOT/scripts/ci/smoke-cases.json"
HOSTED_SERVICE="field-demo-support-triage-hosted"
export FOUNDRY_PROMPT_AGENT_NAME="${FOUNDRY_PROMPT_AGENT_NAME:-field-demo-support-triage-prompt}"
export AZURE_AI_MODEL_DEPLOYMENT_NAME="${AZURE_AI_MODEL_DEPLOYMENT_NAME:-gpt-5.6-sol}"
REQUIRED_VARS=(AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_RESOURCE_GROUP AZURE_ENV_NAME)
DOCS_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-lenvolk/foundry-agent-modalities-demo}/blob/${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}/gh-actions-workflow.md"
TMP_DIR="${RUNNER_TEMP:-/tmp}"

# ----------------------------------------------------------------- helpers ---
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; else echo "$*"; fi; }   # Markdown in the run page
output()  { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }          # job/step outputs
azd_()    { (cd "$AZD_DIR" && AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd "$@" --no-prompt); }

# ------------------------------------------------------------- preflight ---
# 0 variables set  -> configured=false, exit 0  (downstream jobs SKIP, run stays green)
# some missing     -> exit 1 with the exact list (fail fast, clear message)
# all set          -> configured=true
preflight() {
  local v present=0 missing=()
  for v in "${REQUIRED_VARS[@]}"; do
    if [[ -n "${!v:-}" ]]; then present=$((present + 1)); else missing+=("$v"); fi
  done

  if (( present == 0 )); then
    output configured false
    echo "::notice title=Azure not configured::Azure jobs skipped. See $DOCS_URL#use-it-in-your-fork"
    summary "## ⏭️ Azure jobs skipped"
    summary "No Azure repository variables are set, so Azure jobs were **skipped** (not failed)."
    summary "Follow [Use it in your fork]($DOCS_URL#use-it-in-your-fork) to enable them."
    return 0
  fi

  summary "## Preflight: repository variables"
  summary "| Variable | Status |"
  summary "|---|---|"
  for v in "${REQUIRED_VARS[@]}"; do
    if [[ -n "${!v:-}" ]]; then summary "| \`$v\` | ✅ set |"; else summary "| \`$v\` | ❌ missing |"; fi
  done

  if (( ${#missing[@]} )); then
    output configured false
    for v in "${missing[@]}"; do
      echo "::error title=Missing repository variable::$v is not set. Settings → Secrets and variables → Actions → Variables. Guide: $DOCS_URL#use-it-in-your-fork"
    done
    summary ""
    summary "❌ **${#missing[@]} variable(s) missing.** Run \`scripts/ci/setup-github-oidc.sh\` (or \`.ps1\`) or add them by hand: [checklist]($DOCS_URL#use-it-in-your-fork)."
    return 1
  fi
  output configured true
  summary ""
  summary "✅ All required variables are set."
}

# --------------------------------------------------------------- azd env ---
# CI runners start empty, so we (re)create the azd environment on every job.
azd_env_init() {
  local v
  azd_ env select "$AZURE_ENV_NAME" >/dev/null 2>&1 \
    || azd_ env new "$AZURE_ENV_NAME" --subscription "$AZURE_SUBSCRIPTION_ID" --location "$AZURE_LOCATION"
  for v in AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID AZURE_LOCATION AZURE_RESOURCE_GROUP AZURE_AI_MODEL_DEPLOYMENT_NAME; do
    azd_ env set "$v" "${!v}" >/dev/null
  done
}

# Find the Foundry account the Provision workflow created (names are generated).
foundry_discover() {
  ACCOUNT="$(az cognitiveservices account list -g "$AZURE_RESOURCE_GROUP" \
    --query "[?kind=='AIServices'] | [0].name" -o tsv 2>/dev/null || true)"
  if [[ -z "$ACCOUNT" ]]; then
    echo "::error title=No Foundry project::Nothing found in resource group '$AZURE_RESOURCE_GROUP'. Run the 'Provision' workflow first."
    return 1
  fi
  PROJECT="$AZURE_ENV_NAME"
  PROJECT_ID="$(az cognitiveservices account show -g "$AZURE_RESOURCE_GROUP" -n "$ACCOUNT" --query id -o tsv)/projects/$PROJECT"
  export FOUNDRY_PROJECT_ENDPOINT="https://$ACCOUNT.services.ai.azure.com/api/projects/$PROJECT"
}

# azd env + the values `azd provision` would have written locally.
azd_env_load() {
  azd_env_init
  foundry_discover
  local kv
  for kv in "AZURE_AI_ACCOUNT_NAME=$ACCOUNT" "AZURE_AI_PROJECT_NAME=$PROJECT" "AZURE_AI_PROJECT_ID=$PROJECT_ID" \
            "FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT" "AZURE_AI_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT"; do
    azd_ env set "${kv%%=*}" "${kv#*=}" >/dev/null
  done
}

# ------------------------------------------------------------- provision ---
provision() {
  azd_env_init
  azd_ provision
  connect_tracing
  summary "## 🏗️ Provisioned"
  summary "| Resource | Name |"
  summary "|---|---|"
  summary "| Resource group | \`$AZURE_RESOURCE_GROUP\` |"
  summary "| Foundry account / project | \`$ACCOUNT\` / \`$PROJECT\` |"
  summary "| Model deployment | \`$AZURE_AI_MODEL_DEPLOYMENT_NAME\` |"
  summary "| Tracing | \`log-$AZURE_ENV_NAME\` + \`appi-$AZURE_ENV_NAME\` (connected to the project) |"
}

# Log Analytics + workspace-based Application Insights + project connection.
# Same as the portal's "Agents → Traces → Connect". Every call is idempotent.
connect_tracing() {
  foundry_discover
  local law="log-$AZURE_ENV_NAME" appi="appi-$AZURE_ENV_NAME" law_id appi_id appi_cs body
  az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors
  az monitor log-analytics workspace create -g "$AZURE_RESOURCE_GROUP" -n "$law" -l "$AZURE_LOCATION" \
    --sku PerGB2018 --retention-time 30 -o none
  law_id="$(az monitor log-analytics workspace show -g "$AZURE_RESOURCE_GROUP" -n "$law" --query id -o tsv)"
  az monitor app-insights component create -g "$AZURE_RESOURCE_GROUP" -a "$appi" -l "$AZURE_LOCATION" \
    --kind web --application-type web --workspace "$law_id" -o none --only-show-errors
  appi_id="$(az monitor app-insights component show -g "$AZURE_RESOURCE_GROUP" -a "$appi" --query id -o tsv)"
  appi_cs="$(az monitor app-insights component show -g "$AZURE_RESOURCE_GROUP" -a "$appi" --query connectionString -o tsv)"
  echo "::add-mask::$appi_cs"   # never print the connection string in logs

  body="$(mktemp)"
  jq -n --arg id "$appi_id" --arg cs "$appi_cs" '{properties: {
      category: "AppInsights", target: $id, authType: "ApiKey", isSharedToAll: false,
      credentials: {key: $cs}, metadata: {ApiType: "Azure", ResourceId: $id}}}' > "$body"
  az rest --method put --body "@$body" -o none \
    --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT/projects/$PROJECT/connections/$appi?api-version=2026-07-01"
  rm -f "$body"
  echo "Tracing connected: $appi → $ACCOUNT/$PROJECT"
}

# ---------------------------------------------------------------- deploy ---
deploy_hosted() {
  azd_env_load
  azd_ deploy "$HOSTED_SERVICE"
  local info status version
  info="$(azd_ ai agent show "$HOSTED_SERVICE" --output json)"
  status="$(jq -r '.status // .versions.latest.status // "unknown"' <<<"$info")"
  version="$(jq -r '.version // .versions.latest.version // "unknown"' <<<"$info")"
  output version "$version"
  summary "| 🐍 Hosted Agent | \`$HOSTED_SERVICE\` | version **$version** | $status |"
}

publish_prompt() {
  foundry_discover
  local msg
  msg="$(python "$ROOT/scripts/ci/prompt_agent_ci.py" publish)"
  echo "$msg"
  summary "| 📝 Prompt Agent | \`$FOUNDRY_PROMPT_AGENT_NAME\` | $msg | |"
}

deploy_summary_header() {
  summary "## 🚀 Deploy to \`${1:-?}\`"
  summary "| Agent | Name | Result | Status |"
  summary "|---|---|---|---|"
}

skip_note() { summary "| $1 | — | ⏭️ skipped (no changes in its folder) | |"; }

# ------------------------------------------------------------ smoke tests ---
case_ids() { jq -c '[.[].id]' "$CASES"; }   # feeds the job matrix

case_prompt() {
  jq -r --arg id "$1" '.[] | select(.id == $id) |
    "Triage this support case. Customer: \(.customer). Annual contract: $\(.annual_contract_usd). " +
    "Production outage: \(.outage_minutes) minutes. Regulated regions affected: \(.regulated_regions). " +
    "Renewal in: \(.renewal_days) days. Summarize the priority, score, reason codes, first response, and next three actions."' "$CASES"
}

invoke_agent() {   # invoke_agent <hosted|prompt> <case-id>
  local prompt; prompt="$(case_prompt "$2")"
  case "$1" in
    hosted) azd_env_load >&2   # keep setup chatter out of the captured answer
            azd_ ai agent invoke "$HOSTED_SERVICE" --new-session --new-conversation "$prompt" ;;
    prompt) foundry_discover
            python "$ROOT/scripts/ci/prompt_agent_ci.py" invoke "$prompt" ;;
    *)      echo "::error::Unknown agent '$1'"; return 1 ;;
  esac
}

# Prints one line per failed check (empty output = pass).
check_response() {   # check_response <file> <case-id>
  local file="$1" exp want_p want_s got_p got_s code text
  exp="$(jq -c --arg id "$2" '.[] | select(.id == $id).expect' "$CASES")"
  want_p="$(jq -r .priority <<<"$exp")"; want_s="$(jq -r .score <<<"$exp")"
  text="$(tr -d '*`' < "$file")"                          # ignore Markdown bold/code
  got_p="$(grep -oE '\bP[0-3]\b' <<<"$text" | head -1 || true)"
  got_s="$(sed -E 's/\bP[0-3]\b/Px/g' <<<"$text" | grep -oiE 'score[^0-9]{0,25}[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)"
  [[ "$got_p" == "$want_p" ]] || echo "priority: expected $want_p, got ${got_p:-nothing}"
  [[ "$got_s" == "$want_s" ]] || echo "score: expected $want_s, got ${got_s:-nothing}"
  for code in $(jq -r '.reason_codes[]' <<<"$exp"); do grep -q "$code" <<<"$text" || echo "missing reason code $code"; done
  for code in $(jq -r '.absent_codes[]' <<<"$exp"); do   # ignore lines like "OUTAGE_60 not triggered"
    ! grep -viE "\bnot\b|n't|\bno\b|without|none" <<<"$text" | grep -q "$code" || echo "unexpected reason code $code"
  done
}

# strict = fail the job on mismatch (Hosted: Python computes the answer)
# soft   = warn only            (Prompt: the model computes the answer)
smoke_test() {   # smoke_test <hosted|prompt> <case-id> <strict|soft>
  local agent="$1" id="$2" mode="$3" out="$TMP_DIR/$1-$2.txt" failures line
  invoke_agent "$agent" "$id" | tee "$out"
  failures="$( [[ -s "$out" ]] && check_response "$out" "$id" || echo "empty response")"

  if [[ -z "$failures" ]]; then
    summary "### ✅ $agent × \`$id\` ($mode)"
    summary "All checks passed: priority, score, reason codes."
  else
    summary "### $([[ $mode == strict ]] && echo ❌ || echo ⚠️) $agent × \`$id\` ($mode)"
    while IFS= read -r line; do summary "- $line"; done <<<"$failures"
  fi
  summary "<details><summary>Agent response</summary>"
  summary ""
  summary '```text'
  summary "$(head -c 4000 "$out")"
  summary '```'
  summary "</details>"

  [[ -z "$failures" ]] && return 0
  if [[ "$mode" == strict ]]; then
    while IFS= read -r line; do echo "::error title=$agent × $id::$line"; done <<<"$failures"
    return 1
  fi
  while IFS= read -r line; do echo "::warning title=$agent × $id (soft)::$line"; done <<<"$failures"
  summary ""
  summary "> ⚠️ Soft check: a Prompt Agent's model does the arithmetic, so results can vary between runs. That's the lesson; the Hosted Agent's Python is strict."
}

# -------------------------------------------------------------- teardown ---
# Deletes Azure resources only. Keeps the app registration, federated
# credentials, GitHub variables/environments, workflows and docs.
teardown() {
  if [[ "$(az group exists -n "$AZURE_RESOURCE_GROUP")" != "true" ]]; then
    summary "## 🧹 Nothing to delete: resource group \`$AZURE_RESOURCE_GROUP\` does not exist."
    return 0
  fi
  local accounts law a
  accounts="$(az cognitiveservices account list -g "$AZURE_RESOURCE_GROUP" --query "[].[name, location]" -o tsv)"
  for law in $(az monitor log-analytics workspace list -g "$AZURE_RESOURCE_GROUP" --query "[].name" -o tsv); do
    az monitor log-analytics workspace delete -g "$AZURE_RESOURCE_GROUP" -n "$law" --force --yes -o none   # skip 14-day soft delete
  done
  az group delete -n "$AZURE_RESOURCE_GROUP" --yes
  while read -r a loc; do
    [[ -n "$a" ]] || continue
    az cognitiveservices account purge -g "$AZURE_RESOURCE_GROUP" -n "$a" -l "$loc"   # free the name + model quota now
  done <<<"$accounts"
  summary "## 🧹 Torn down"
  summary "Deleted resource group \`$AZURE_RESOURCE_GROUP\` and purged soft-deleted Foundry/Log Analytics resources."
  summary ""
  summary "Kept: app registration, federated credentials, GitHub variables and environments. Before the next **Provision**, re-run \`scripts/ci/setup-github-oidc.sh\` to recreate the resource group and its role assignments."
}

# ------------------------------------------------------------- dispatcher ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -ge 1 ]] || { grep -E '^[a-z_]+\(\)' "$0" | sed 's/().*//'; exit 1; }
  "$@"
fi
