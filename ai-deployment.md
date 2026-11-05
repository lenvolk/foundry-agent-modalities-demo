# AI deployment guide

Instructions for an AI coding agent to deploy this demo end to end. A human can follow them too. Path A validated on November 1, 2026; Path B on November 5, 2026. Both on Windows 11 (PowerShell 7) in North Central US.

## Choose a path

| | **Path A: local** | **Path B: GitHub Actions** (recommended for repeatable deploys) |
|---|---|---|
| Who runs `azd` | you / the agent, on this machine | GitHub runners, signed in with OIDC |
| Good for | a one-off demo, local debugging | every change tested + deployed the same way; dev → prod approval |
| Azure identity | the signed-in user | a CI service principal with least-privilege roles |
| Steps | [1–15](#path-a-local) | [B1–B11](#path-b-github-actions) |
| Explains the *why* | — | [gh-actions-workflow.md](gh-actions-workflow.md) |

Both create the same Foundry resources. Use **one** path per resource group.

## Rules for the agent

- Get the user's approval before creating Azure resources. Ask them to sign in. Never handle their password.
- Prefix every `azd` command with `AZURE_DEV_USER_AGENT=microsoft_foundry_skill` (inline only, never persisted). The workflows do this inside `scripts/ci/lib.sh`.
- Never commit `.env` files, endpoints, connection strings, client/subscription/tenant IDs.
- Path A: run `create_and_run.py` **once**. Use `invoke.py` afterwards.
- Run commands from the repo root unless a step says `deployment/`.
- Path B: never push to a branch the user didn't name, and run **Teardown** only when the user says so.

PowerShell: set `$env:AZURE_DEV_USER_AGENT='microsoft_foundry_skill'` once per shell instead of the inline prefix.

## What gets created

Both paths:

```text
Resource group <RESOURCE_GROUP>
├── Foundry account  cog-<token>
│   ├── project  <ENV_NAME>
│   │   ├── Prompt Agent   field-demo-support-triage-prompt
│   │   ├── Hosted Agent   field-demo-support-triage-hosted   (container runs on Microsoft-managed compute)
│   │   └── connection     appi-<name>   (App Insights, for traces)
│   └── model deployment   gpt-5.6-sol  (GlobalStandard, 10K TPM)
├── Log Analytics workspace  log-<name>      (Path B: log-<ENV_NAME>)
└── Application Insights     appi-<name>     (Path B: appi-<ENV_NAME>, workspace-based)
```

Path B also creates (by `scripts/ci/setup-github-oidc.ps1|.sh`):

| Where | What | Why |
|---|---|---|
| Entra ID | App registration + service principal `gh-<owner>-<repo>-foundry-ci` | The identity the workflows use |
| Entra ID | 3 federated credentials: `<prefix>:environment:dev`, `:environment:prod`, `:ref:refs/heads/main` | OIDC sign-in, no secret. `<prefix>` comes from GitHub (see B9) |
| Resource group | **Contributor**, **Foundry User**, **RBAC Administrator** (condition: may assign only Foundry User) | Create resources; call agents; let `azd deploy` give the agent identity Foundry User |
| Subscription | Custom role **Foundry CI subscription deployer**: `Microsoft.Resources/deployments/*`, read subscription/RGs, purge deleted Foundry accounts | azd's Foundry provider runs a **subscription-scope** ARM deployment; Teardown purges. Each resource inside is still checked against the RG roles |
| GitHub | 7 repository variables (B4) | Read by every workflow |
| GitHub | Environments `dev` (no rules) and `prod` (required reviewer) | Approval gate before prod |

<a id="path-a-local"></a>

# Path A: local

## 1. Collect inputs

| Input | Example / default |
|---|---|
| `TENANT_ID` | ask the user |
| `SUBSCRIPTION_ID` | ask the user |
| `RESOURCE_GROUP` | `FoundryModalitiesDemo` |
| `LOCATION` | `northcentralus` (validated) |
| `ENV_NAME` | `foundry-modalities-demo` (also becomes the project name) |
| `MODEL` | `gpt-5.6-sol`, version `2026-07-09` (set in `deployment/azure.yaml`) |

## 2. Check prerequisites

| Tool | Validated version | Install |
|---|---|---|
| Azure CLI | 2.91 | <https://aka.ms/azcli> |
| Azure Developer CLI | 1.37.2 (≥ 1.32 required) | <https://aka.ms/azd> |
| `azure.ai.agents` extension | 1.0.0-beta.23 (≥ beta.13) | `azd extension install azure.ai.agents --source azd` |
| `microsoft.foundry` extension | 1.0.0-beta.4 | `azd extension install microsoft.foundry --source azd` |
| Python | 3.13 | Windows: `py -0` should list 3.13 |
| Git | any | Windows: Git Bash is useful for `.sh` helpers |

```bash
az version; azd version; azd extension list
```

## 3. Sign in

Use device code so the agent can show the user a code. Ask the user to complete each sign-in, then continue.

```bash
az login --tenant <TENANT_ID> --use-device-code
azd auth login --tenant-id <TENANT_ID> --use-device-code
az account set --subscription <SUBSCRIPTION_ID>
az account show --query "{sub:name, tenant:tenantId, user:user.name}"
```

`azd` tokens expire after 90 days of inactivity (`AADSTS700082`). Re-run `azd auth login` if you see it.

## 4. Check model quota

Need ≥ 10 free units of `OpenAI.GlobalStandard.gpt-5.6-sol` in the region.

```powershell
az cognitiveservices usage list -l northcentralus -o json | ConvertFrom-Json |
  ? { $_.name.value -match 'gpt-5.6-sol' } | % { "$($_.name.value) $($_.currentValue)/$($_.limit)" }
```

```bash
az cognitiveservices usage list -l northcentralus \
  --query "[?contains(name.value,'gpt-5.6-sol')].{name:name.value,used:currentValue,limit:limit}" -o table
```

No quota? Pick another region from the [availability table](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability) or change the model in `deployment/azure.yaml`. Tell the user why.

## 5. Test the Python rules (no cloud)

```bash
py -3.13 -m unittest discover -s deployment/src/agent-framework-agent-with-local-tools-responses/tests -v      # Windows
python3.13 -m unittest discover -s deployment/src/agent-framework-agent-with-local-tools-responses/tests -v    # macOS/Linux
```

Expect `Ran 4 tests … OK`.

## 6. Create the azd environment

```bash
cd deployment
azd env new <ENV_NAME> --subscription <SUBSCRIPTION_ID> --location <LOCATION> --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <SUBSCRIPTION_ID>
azd env set AZURE_TENANT_ID <TENANT_ID>
azd env set AZURE_LOCATION <LOCATION>
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME gpt-5.6-sol
azd env set AZURE_RESOURCE_GROUP <RESOURCE_GROUP>     # forces the exact RG name
```

`AZURE_RESOURCE_GROUP` feeds the `microsoft.foundry` provider's `resourceGroupName` parameter. Confirm before creating anything:

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd provision --preview --no-prompt
```

Expect `Create : Resource group : <RESOURCE_GROUP>`, plus the AI Services account, model deployment, and project.

## 7. Provision

```bash
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd provision --no-state --no-prompt     # ~1–2 min
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai agent doctor
```

Expect only one failed check: `Hosted agents are active … run azd deploy`. That's correct at this stage.

## 8. Write the local `.env` files

macOS/Linux (from repo root):

```bash
bash scripts/configure-local-env.sh
```

Windows PowerShell (same result):

```powershell
Push-Location deployment
$ep = azd env get-value FOUNDRY_PROJECT_ENDPOINT; $m = azd env get-value AZURE_AI_MODEL_DEPLOYMENT_NAME
Pop-Location
"FOUNDRY_PROJECT_ENDPOINT=$ep`nFOUNDRY_MODEL_NAME=$m`nFOUNDRY_PROMPT_AGENT_NAME=field-demo-support-triage-prompt`nDELETE_AFTER_RUN=false`n" |
  Set-Content -NoNewline -Encoding ascii prompt_agent\.env
"FOUNDRY_PROJECT_ENDPOINT=$ep`nAZURE_AI_MODEL_DEPLOYMENT_NAME=$m`n" |
  Set-Content -NoNewline -Encoding ascii deployment\src\agent-framework-agent-with-local-tools-responses\.env
```

Both files are git-ignored.

## 9. Create the Prompt Agent (once)

```bash
# macOS/Linux
python3.13 -m venv prompt_agent/.venv
prompt_agent/.venv/bin/python -m pip install -r prompt_agent/requirements.txt
prompt_agent/.venv/bin/python prompt_agent/create_and_run.py
```

```powershell
# Windows
py -3.13 -m venv prompt_agent\.venv
prompt_agent\.venv\Scripts\python.exe -m pip install -r prompt_agent\requirements.txt
$env:PYTHONIOENCODING='utf-8'; prompt_agent\.venv\Scripts\python.exe prompt_agent\create_and_run.py
```

Expect `Prompt Agent created: … version=1`, then P0 / 8 / four reason codes.

## 10. Run the Hosted Agent locally

```bash
# macOS/Linux
python3.13 -m venv deployment/src/agent-framework-agent-with-local-tools-responses/.venv
deployment/src/agent-framework-agent-with-local-tools-responses/.venv/bin/python -m pip install \
  -r deployment/src/agent-framework-agent-with-local-tools-responses/requirements.txt
bash scripts/run-local-demo.sh
```

```powershell
# Windows
$src = 'deployment\src\agent-framework-agent-with-local-tools-responses'
py -3.13 -m venv "$src\.venv"
& "$src\.venv\Scripts\python.exe" -m pip install -r "$src\requirements.txt"
./scripts/run-local-demo.ps1
```

The script starts `azd ai agent run --no-client`, waits for `localhost:8088`, invokes once, prints the tool-call count, and stops the server. Expect P0 / 8 and `Python tool calls (calculate_case_priority): 1`. The pip install takes a few minutes the first time.

## 11. Deploy the Hosted Agent

```bash
cd deployment
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd deploy field-demo-support-triage-hosted --no-prompt   # ~2 min
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai agent show field-demo-support-triage-hosted --output json
```

Expect `"status": "active"`, `"version": "1"`. This is a code deploy: no container registry is created. The warning `AZURE_CONTAINER_REGISTRY_ENDPOINT not set; skipping ACR role check` is harmless. The deploy output prints the Hosted Agent's portal link.

## 12. Connect tracing (Log Analytics + Application Insights)

The project has no App Insights after provisioning. This step does what the portal's **Agents → Traces → Connect** button does.

```bash
RG=<RESOURCE_GROUP>; LOC=<LOCATION>; LAW=log-<name>; APPI=appi-<name>
ACCOUNT=$(cd deployment && azd env get-value AZURE_AI_ACCOUNT_NAME)
PROJECT=$(cd deployment && azd env get-value AZURE_AI_PROJECT_NAME)

az extension add -n application-insights --only-show-errors
az monitor log-analytics workspace create -g $RG -n $LAW -l $LOC --sku PerGB2018 --retention-time 30
az monitor app-insights component create -g $RG -a $APPI -l $LOC --kind web --application-type web \
  --workspace "$(az monitor log-analytics workspace show -g $RG -n $LAW --query id -o tsv)"
```

Create the project connection (category `AppInsights`). The connection string goes in a temp file that is deleted right after.

```bash
# bash
APPI_ID=$(az monitor app-insights component show -g $RG -a $APPI --query id -o tsv)
APPI_CS=$(az monitor app-insights component show -g $RG -a $APPI --query connectionString -o tsv)
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
cat >"$TMP" <<EOF
{"properties":{"category":"AppInsights","target":"$APPI_ID","authType":"ApiKey","isSharedToAll":false,
 "credentials":{"key":"$APPI_CS"},"metadata":{"ApiType":"Azure","ResourceId":"$APPI_ID"}}}
EOF
az rest --method put --body "@$TMP" --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT/projects/$PROJECT/connections/$APPI?api-version=2026-07-01"
(cd deployment && azd env set APPLICATIONINSIGHTS_CONNECTION_STRING "$APPI_CS")
```

```powershell
# PowerShell ($RG, $APPI, $ACCOUNT, $PROJECT set as above)
$appi = az monitor app-insights component show -g $RG -a $APPI -o json | ConvertFrom-Json
$body = @{ properties = @{ category='AppInsights'; target=$appi.id; authType='ApiKey'; isSharedToAll=$false
  credentials=@{ key=$appi.connectionString }; metadata=@{ ApiType='Azure'; ResourceId=$appi.id } } } | ConvertTo-Json -Depth 5
$tmp = New-TemporaryFile; Set-Content $tmp $body -Encoding utf8
try { az rest --method put --body "@$tmp" --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT/projects/$PROJECT/connections/${APPI}?api-version=2026-07-01" }
finally { Remove-Item $tmp }
Push-Location deployment; azd env set APPLICATIONINSIGHTS_CONNECTION_STRING $appi.connectionString; Pop-Location
```

**No redeploy needed.** Foundry injects `APPLICATIONINSIGHTS_CONNECTION_STRING` into every new Hosted Agent session. Invoke once, then confirm:

```bash
cd deployment
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai agent monitor field-demo-support-triage-hosted --tail 200 | grep appinsights_configured
```

Expect `appinsights_configured=True`. The log also shows `ModuleNotFoundError: No module named 'agents'` once per container start. That's an optional instrumentation for a different SDK; ignore it.

**RBAC:** the user who created the resources can query them. Teammates who only need to read traces need **Log Analytics Reader** on the App Insights resource.

## 13. Verify both deployed agents

```bash
bash scripts/run-customer-demo.sh          # macOS/Linux
```

```powershell
# Windows
$env:PYTHONIOENCODING='utf-8'; prompt_agent\.venv\Scripts\python.exe prompt_agent\invoke.py
Push-Location deployment
azd ai agent invoke field-demo-support-triage-hosted --new-session --new-conversation 'Triage this support case. Customer: Contoso Retail. Annual contract: $240,000. Production outage: 95 minutes. Regulated regions affected: 2. Renewal in: 21 days. Summarize the priority, reason codes, first response, and next three actions.'
Pop-Location
```

`azd ai agent invoke` prints the answer twice. It's one call.

Portal links: `bash scripts/show-portal-links.sh`. On Windows, compute the subscription segment with Python. .NET `Guid.ToByteArray()` uses a different byte order and gives a wrong link.

```powershell
Push-Location deployment; $sub = azd env get-value AZURE_SUBSCRIPTION_ID; $rg = azd env get-value AZURE_RESOURCE_GROUP
$acct = azd env get-value AZURE_AI_ACCOUNT_NAME; $proj = azd env get-value AZURE_AI_PROJECT_NAME
$ver = azd env get-value AGENT_FIELD_DEMO_SUPPORT_TRIAGE_HOSTED_VERSION; Pop-Location
$enc = py -3.13 -c "import base64,uuid,sys;print(base64.urlsafe_b64encode(uuid.UUID(sys.argv[1]).bytes).rstrip(b'=').decode())" $sub
$base = "https://ai.azure.com/nextgen/r/$enc,$rg,,$acct,$proj/build/agents"
"$base/field-demo-support-triage-prompt/build"; "$base/field-demo-support-triage-hosted/build?version=$ver"
```

Wait 2–5 minutes after invoking, then check traces with KQL:

```kql
dependencies
| where timestamp > ago(1h)
| summarize n = count() by cloud_RoleName, name, op = tostring(customDimensions["gen_ai.operation.name"])
```

```bash
# bash
az monitor app-insights query -g $RG --app $APPI --analytics-query '<KQL>'
```

```powershell
# PowerShell: call the REST API (az.cmd mangles quotes and newlines in KQL on Windows)
$appId = az monitor app-insights component show -g $RG -a $APPI --query appId -o tsv
$tok = az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv
(Invoke-RestMethod -Method Post -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" `
  -Headers @{Authorization="Bearer $tok"} -ContentType 'application/json' -Body (@{query='<KQL>'} | ConvertTo-Json)).tables[0].rows
```

## 14. Expected results

| Check | Expected |
|---|---|
| Unit tests | 4 pass |
| Prompt Agent (95 min) | P0, 8, `OUTAGE_60` `STRATEGIC_CONTRACT` `REGULATED_IMPACT` `RENEWAL_30` |
| Hosted Agent local + deployed (95 min) | same, plus 1 `calculate_case_priority` call |
| Both agents (30 min) | P1, 5, no `OUTAGE_60` |
| `azd ai agent doctor` after deploy | 11 passed, 0 failed |
| KQL `dependencies` | `execute_tool calculate_case_priority`, `chat gpt-5.6-sol` (role = hosted agent); `invoke_agent field-demo-support-triage-prompt:1` + `chat` (role = `responsesapi`) |

## Windows vs macOS/Linux

| Upstream (bash) | Windows equivalent |
|---|---|
| `python3.13` | `py -3.13` |
| `.venv/bin/python` | `.venv\Scripts\python.exe` |
| `source .venv/bin/activate` | not needed: `run-local-demo.ps1` sets `VIRTUAL_ENV` and `PATH` |
| `scripts/configure-local-env.sh` | PowerShell block in step 8 (or Git Bash) |
| `scripts/show-portal-links.sh` | PowerShell block in step 13 |
| `scripts/run-customer-demo.sh` | PowerShell block in step 13 (or Git Bash) |
| `az monitor app-insights query` | REST call in step 13 |
| Unicode output | set `PYTHONIOENCODING=utf-8` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `AADSTS700082 refresh token expired` | `azd auth login --tenant-id <TENANT_ID> --use-device-code` |
| RG gets an auto name (`rg-<env>`) | `azd env set AZURE_RESOURCE_GROUP …` before provisioning; check with `--preview` |
| Doctor: `Hosted agents are active` fails | expected before step 11; run `azd deploy` |
| Model not found | `azd env get-value AZURE_AI_MODEL_DEPLOYMENT_NAME` must match `azure.yaml`; rewrite `.env` files |
| No traces | connection missing, or wait 2–5 min; new session needed (`--new-session`) |
| Port 8088 busy | stop the earlier `azd ai agent run` (find PID with `Get-NetTCPConnection -LocalPort 8088` or `lsof -i :8088`) |

## 15. Clean up

Get user approval first. This deletes everything in the resource group.

```bash
cd deployment
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd down --force --purge
az group exists --name <RESOURCE_GROUP>       # if true (monitoring resources remain):
az group delete --name <RESOURCE_GROUP> --yes
```

Optional local cleanup: delete both `.venv` folders and both `.env` files.

<a id="path-b-github-actions"></a>

# Path B: GitHub Actions

GitHub runs `azd` for you. Feature-by-feature explanations, diagrams, and the role rationale are in [gh-actions-workflow.md](gh-actions-workflow.md); this section is the exact *how*.

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push / PR touching `deployment/src/**`, `prompt_agent/**`, `scripts/ci/**`, `.github/**` | Unit tests (Python 3.12 + 3.13), ShellCheck |
| `provision.yml` | Run workflow (`deploy` checkbox, default on) | `azd provision` + tracing, then deploy + smoke to `dev` |
| `cd.yml` | push to `main` touching `deployment/**` or `prompt_agent/**`; Run workflow | CI → deploy changed agent(s) to `dev` → smoke → **approval** → `prod` → smoke |
| `teardown.yml` | Run workflow, input `confirm` = resource group name | Delete RG, purge soft-deleted Foundry account |

## B1. Prerequisites

| Need | Check |
|---|---|
| Fork (or repo) the user owns, **admin** on it | `gh auth status` shows that account; `gh repo view <owner>/<repo> --json viewerPermission` → `ADMIN` |
| Workflows on the **default branch** | `workflow_dispatch` only works for workflow files on the default branch. Push to `main` (or whatever the default is) |
| Azure: **Owner** (or User Access Administrator + Contributor) on the subscription | `az role assignment list --assignee <user> --all --include-inherited -o table` |
| Entra: may create app registrations | default for members; otherwise Application Developer role |
| Tools | `az` ≥ 2.91, `gh`, PowerShell 7 **or** bash, `jq` (bash only). `azd` is not needed locally |
| Model quota | [step 4](#4-check-model-quota): ≥ 10 units of `gpt-5.6-sol` GlobalStandard |

## B2. Collect inputs

| Input | Example / default |
|---|---|
| `TENANT_ID`, `SUBSCRIPTION_ID` | ask the user |
| `RESOURCE_GROUP` | `FoundryModalitiesCI` (use a different RG from Path A) |
| `LOCATION` | `northcentralus` |
| `ENV_NAME` | `foundry-modalities-ci` (= azd env = Foundry project name) |
| `MODEL` | `gpt-5.6-sol` |
| `REPO` | `<owner>/foundry-agent-modalities-demo` |
| `PROD_REVIEWER` | GitHub login that approves prod (usually the user) |

## B3. Sign in

```bash
az login --tenant <TENANT_ID> --use-device-code      # ask the user to complete it
az account set --subscription <SUBSCRIPTION_ID>
gh auth status                                       # must be the repo owner
```

## B4. Run the setup script

```powershell
./scripts/ci/setup-github-oidc.ps1 -TenantId <TENANT_ID> -SubscriptionId <SUBSCRIPTION_ID> `
  -ResourceGroup <RESOURCE_GROUP> -Location <LOCATION> -EnvName <ENV_NAME> -Model <MODEL> `
  -GitHubRepo <REPO> -ProdReviewer <PROD_REVIEWER>
```

```bash
MSYS_NO_PATHCONV=1 \
AZURE_TENANT_ID=<TENANT_ID> AZURE_SUBSCRIPTION_ID=<SUBSCRIPTION_ID> AZURE_RESOURCE_GROUP=<RESOURCE_GROUP> \
AZURE_LOCATION=<LOCATION> AZURE_ENV_NAME=<ENV_NAME> AZURE_AI_MODEL_DEPLOYMENT_NAME=<MODEL> \
GITHUB_REPO=<REPO> PROD_REVIEWER=<PROD_REVIEWER> ./scripts/ci/setup-github-oidc.sh
```

`MSYS_NO_PATHCONV=1` is only needed in Git Bash on Windows (it stops `/subscriptions/...` being rewritten to a Windows path). Omitted inputs are prompted for. ~1–2 min. Expected output, in order: `Resource group`, `App registration` + `client id`, 3 × `+ <prefix>:…` federated credentials, custom role, 4 × `+ <role> @ …`, GitHub variables, environments, `Done`. Re-runs print `✓` for existing items. `WARNING: Argument '--condition' is in preview` is harmless.

Add `-ExtraBranches feat/x` (PowerShell) or `EXTRA_BRANCHES=feat/x` (bash) only if a non-`main` branch must sign in to Azure outside an environment.

## B5. Verify the configuration

```bash
gh variable list -R <REPO>        # 7 names: AZURE_AI_MODEL_DEPLOYMENT_NAME AZURE_CLIENT_ID AZURE_ENV_NAME AZURE_LOCATION AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID
gh api repos/<REPO>/environments -q '.environments[] | {name, rules: [.protection_rules[]?.type]}'
#   {"name":"dev","rules":[]}  {"name":"prod","rules":["required_reviewers"]}
az ad app federated-credential list --id <CLIENT_ID> --query "[].subject" -o tsv
az role assignment list --all --assignee <CLIENT_ID> --query "[].{role:roleDefinitionName, scope:scope}" -o table
#   Contributor, Foundry User, Role Based Access Control Administrator (RG) + Foundry CI subscription deployer (subscription)
```

## B6. Provision

```bash
gh workflow run provision.yml -R <REPO> --ref main
gh run list -R <REPO> -w Provision -L 1          # get the run ID
gh run watch <RUN_ID> -R <REPO> --exit-status    # ~10 min
```

Expected jobs, all green: `preflight / Check repository variables`, `azd provision + tracing` (~3 min), `deploy / Plan test matrix`, `deploy / Deploy (dev)` (~4 min; first Hosted deploy), 4 × `deploy / Smoke …`. Run with `-f deploy=false` to provision only. Re-running Provision is safe (no changes).

## B7. Deploy dev → prod (CD)

```bash
gh workflow run cd.yml -R <REPO> --ref main      # manual run deploys both agents
gh run watch <RUN_ID> -R <REPO>                  # stops being "in progress" at the prod gate
```

When `prod / Deploy (prod)` is `waiting`, **ask the user** to open the run URL → **Review deployments** → tick `prod` → **Approve and deploy**. Don't approve on the user's behalf. Then watch again until `completed`.

## B8. Verify

```bash
gh run view <RUN_ID> -R <REPO> --json conclusion,jobs -q '.conclusion, (.jobs[] | "\(.name): \(.conclusion)")'
```

Must be green: `preflight`, `ci` (3 jobs), `What changed?`, and for **each** of `dev` / `prod`: `Plan test matrix`, `Deploy`, and 4 smoke legs:

| Leg | Mode | Expected answer |
|---|---|---|
| `hosted × contoso-95min-outage` | strict (fails the job on mismatch) | P0, score 8, `OUTAGE_60` `STRATEGIC_CONTRACT` `REGULATED_IMPACT` `RENEWAL_30` |
| `hosted × contoso-30min-outage` | strict | P1, score 5, no `OUTAGE_60` |
| `prompt × contoso-95min-outage` | soft (`::warning::` only) | same as hosted |
| `prompt × contoso-30min-outage` | soft | same as hosted |

A yellow warning on a **prompt** leg is acceptable (the model does the math); a red **hosted** leg is a real failure. Check annotations:

```bash
gh api repos/<REPO>/check-runs/<JOB_ID>/annotations -q '.[].message'
```

The run page's step summaries show: preflight variable table (✅/❌), "Deploy to `dev`" table (Hosted version + `active`, Prompt version or *Unchanged*), and one section per smoke leg with the agent's full answer. Deploy logs show `Published … version N` or `Unchanged (content_sha=…)`; unchanged Hosted code also keeps its version. In prod (same project here) both are usually *Unchanged*.

Traces: same KQL as [step 13](#13-verify-both-deployed-agents) against `appi-<ENV_NAME>`; expect `execute_tool calculate_case_priority`.

## B9. Push-triggered deploys

| You push | CI | CD |
|---|---|---|
| docs only (`*.md`, `docs/**`) | — | — |
| `scripts/ci/**`, `.github/**` | runs | — |
| `deployment/**` | runs | Hosted deployed, Prompt skipped |
| `prompt_agent/instructions.md` | runs | Prompt published (new version), Hosted skipped |

Each still waits for prod approval.

## B10. Teardown and re-setup

Only when the user says they're done:

```bash
gh workflow run teardown.yml -R <REPO> --ref main -f confirm=<RESOURCE_GROUP>
```

Deletes Log Analytics (force, no soft delete), the resource group, and purges the soft-deleted Foundry account. Keeps the app registration, federated credentials, GitHub variables and environments. The RG role assignments are deleted **with the RG**, so before the next Provision re-run B4 (idempotent: recreates the RG and its 3 role assignments, `✓` for the rest).

## B11. Troubleshooting (hit during validation)

| Symptom | Fix |
|---|---|
| `Workflow does not have 'workflow_dispatch' trigger` / workflow not in the Actions list | Workflow files must be on the **default** branch |
| `AADSTS700213: No matching federated identity record … subject 'repo:owner@123/repo@456:…'` | GitHub uses **immutable-ID subjects** for new repos. Re-run B4: it reads `gh api repos/<REPO>/actions/oidc/customization/sub -q .sub_claim_prefix`. Delete stale `repo:owner/repo:…` credentials |
| `ERROR: failed to download artifact … status code: 504` in *Install azd Foundry extensions* | Transient; `setup-foundry` retries 3×. Else **Re-run failed jobs** |
| Git Bash: `--scope` becomes `C:/Program Files/Git/subscriptions/…` | `MSYS_NO_PATHCONV=1` |
| Git Bash: `Failed to parse string as JSON: /tmp/tmp.…` | Already fixed (script writes temp files to the current folder). Pull latest |
| Setup script: `RemoteDisconnected` traceback from `az role assignment list` | Transient Graph error; re-run B4 |
| Preflight green, Azure jobs grey | No variables set; run B4 |
| Preflight red `X is not set` | Partial config; run B4 or add the listed variables |
| `AuthorizationFailed … Microsoft.Resources/deployments/write` | Custom subscription role missing; re-run B4 |
| `No Foundry project … Run the 'Provision' workflow first` | Run B6 |
| Prompt leg `unexpected reason code OUTAGE_60` | Model wrote the code on a line without "not"; soft warning, expected occasionally |

Local smoke check of the library functions (no Azure): `./scripts/ci/lib.sh case_ids` and `./scripts/ci/lib.sh case_prompt contoso-30min-outage`.