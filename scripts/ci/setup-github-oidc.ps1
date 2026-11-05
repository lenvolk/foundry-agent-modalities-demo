<#
.SYNOPSIS
  One-time setup: connect YOUR GitHub fork to YOUR Azure subscription with OIDC (no secrets).
  Safe to re-run (idempotent), e.g. after Teardown deleted the resource group and its role assignments.

.DESCRIPTION
  Azure : resource group, app registration + service principal, federated credentials,
          role assignments (RG scope + 1 small subscription-level custom role)
  GitHub: repository variables, environments dev + prod (prod = approval)

  Same steps as setup-github-oidc.sh. Prerequisites: az login --tenant <TENANT_ID>; gh auth login.

.EXAMPLE
  ./scripts/ci/setup-github-oidc.ps1 -GitHubRepo <you>/foundry-agent-modalities-demo
#>
#Requires -Version 7
[CmdletBinding()]
param(
  [string]$TenantId       = $env:AZURE_TENANT_ID,
  [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
  [string]$ResourceGroup  = $env:AZURE_RESOURCE_GROUP,
  [string]$Location       = $env:AZURE_LOCATION,
  [string]$EnvName        = $env:AZURE_ENV_NAME,
  [string]$Model          = $env:AZURE_AI_MODEL_DEPLOYMENT_NAME,
  [string]$GitHubRepo     = $env:GITHUB_REPO,
  [string]$ProdReviewer   = $env:PROD_REVIEWER,
  [string[]]$ExtraBranches = @(),        # e.g. -ExtraBranches feat/action_workflow
  [string]$AppName
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$FoundryUserRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'   # Foundry User (formerly Azure AI User)
$RbacAdminRole   = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'   # Role Based Access Control Administrator
$ContributorRole = 'b24988ac-6180-42a0-ab88-20f7382dd24c'   # Contributor
$CustomRoleName  = 'Foundry CI subscription deployer'

function Ask([string]$Value, [string]$Question, [string]$Default) {
  if ($Value) { return $Value }
  $answer = Read-Host "$Question$(if ($Default) { " [$Default]" })"
  if (-not $answer) { $answer = $Default }
  if (-not $answer) { throw "$Question is required" }
  return $answer
}
function Step([string]$Text) { Write-Host "`n▶ $Text" -ForegroundColor Cyan }
function Quiet([scriptblock]$Block) { try { & $Block 2>$null } catch { $null } }

# ---------------------------------------------------------------- inputs ---
Step 'Inputs'
$TenantId       = Ask $TenantId       'Tenant ID'       (Quiet { az account show --query tenantId -o tsv })
$SubscriptionId = Ask $SubscriptionId 'Subscription ID' (Quiet { az account show --query id -o tsv })
$ResourceGroup  = Ask $ResourceGroup  'Resource group'  'FoundryModalitiesCI'
$Location       = Ask $Location       'Region'          'northcentralus'
$EnvName        = Ask $EnvName        'azd env / Foundry project name' 'foundry-modalities-ci'
$Model          = Ask $Model          'Model deployment name' 'gpt-5.6-sol'
$GitHubRepo     = Ask $GitHubRepo     'GitHub repo (owner/name)' (Quiet { gh repo view --json nameWithOwner -q .nameWithOwner })
$ProdReviewer   = Ask $ProdReviewer   'GitHub user who approves prod' (Quiet { gh api user -q .login })
if (-not $AppName) { $AppName = "gh-$($GitHubRepo -replace '/', '-')-foundry-ci" }

az account set --subscription $SubscriptionId
if ((az account show --query tenantId -o tsv) -ne $TenantId) { throw "Signed in to a different tenant. Run: az login --tenant $TenantId" }
$SubScope = "/subscriptions/$SubscriptionId"
$RgScope  = "$SubScope/resourceGroups/$ResourceGroup"
$tmp = New-TemporaryFile

try {
  # ------------------------------------------------------ resource group ---
  Step "Resource group $ResourceGroup"
  az group create -n $ResourceGroup -l $Location -o none

  # ----------------------------------------- app registration + principal ---
  Step "App registration $AppName"
  $AppId = az ad app list --display-name $AppName --query '[0].appId' -o tsv
  if (-not $AppId) { $AppId = az ad app create --display-name $AppName --query appId -o tsv }
  $SpId = Quiet { az ad sp show --id $AppId --query id -o tsv }
  if (-not $SpId) { $SpId = az ad sp create --id $AppId --query id -o tsv }
  Write-Host "client id: $AppId"

  # ------------------------------------------------ federated credentials ---
  # The OIDC token's "subject" must match one of these exactly.
  Step 'Federated credentials (who may sign in as this app)'
  $subjects = @('environment:dev', 'environment:prod', 'ref:refs/heads/main') + ($ExtraBranches | ForEach-Object { "ref:refs/heads/$_" })
  # GitHub decides the subject prefix. Newer repos use immutable IDs: repo:owner@123/name@456
  $prefix = Quiet { gh api "repos/$GitHubRepo/actions/oidc/customization/sub" -q .sub_claim_prefix }
  if (-not $prefix) { $prefix = "repo:$GitHubRepo" }
  $existing = @(az ad app federated-credential list --id $AppId --query '[].subject' -o tsv)
  foreach ($s in $subjects) {
    $subject = "${prefix}:$s"
    if ($existing -contains $subject) { Write-Host "  ✓ $subject"; continue }
    $name = 'gh-' + (($s -replace '[^A-Za-z0-9-]', '-').TrimEnd('-'))
    @{ name = $name; issuer = 'https://token.actions.githubusercontent.com'; subject = $subject
       audiences = @('api://AzureADTokenExchange') } | ConvertTo-Json | Set-Content $tmp -Encoding utf8
    az ad app federated-credential create --id $AppId --parameters "@$tmp" -o none
    Write-Host "  + $subject"
  }

  # ---------------------------------------------------------------- RBAC ---
  Step "Custom role: $CustomRoleName (subscription-level deployments + purge)"
  @{
    Name = $CustomRoleName; IsCustom = $true
    Description = "azd's Foundry provider runs a subscription-scope ARM deployment; teardown purges soft-deleted Foundry accounts. Each resource inside the deployment is still checked against the caller's RG-scoped roles."
    Actions = @(
      'Microsoft.Resources/deployments/*',
      'Microsoft.Resources/subscriptions/read',
      'Microsoft.Resources/subscriptions/resourceGroups/read',
      'Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/read',
      'Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/delete',
      'Microsoft.CognitiveServices/locations/operationResults/read',
      'Microsoft.CognitiveServices/locations/usages/read',
      'Microsoft.CognitiveServices/locations/models/read')
    NotActions = @(); AssignableScopes = @($SubScope)
  } | ConvertTo-Json | Set-Content $tmp -Encoding utf8
  if (az role definition list --custom-role-only true --name $CustomRoleName --query '[0].name' -o tsv) {
    az role definition update --role-definition "@$tmp" -o none
  } else {
    az role definition create --role-definition "@$tmp" -o none
    Start-Sleep 20   # new role definitions take a moment to replicate
  }

  function Assign([string]$Label, [string]$Role, [string]$Scope, [string]$Condition) {
    $label = "$Label @ $(if ($Scope -eq $SubScope) { 'subscription' } else { "resource group $ResourceGroup" })"
    if (az role assignment list --scope $Scope --role $Role --query "[?principalId=='$SpId'] | [0].id" -o tsv) { Write-Host "  ✓ $label"; return }
    $extra = if ($Condition) { @('--condition', $Condition, '--condition-version', '2.0') } else { @() }
    foreach ($attempt in 1..5) {   # a brand-new principal can take a minute to replicate
      try {
        az role assignment create --assignee-object-id $SpId --assignee-principal-type ServicePrincipal `
          --role $Role --scope $Scope @extra -o none
        Write-Host "  + $label"; return
      } catch { Write-Host "  … retrying ($attempt)"; Start-Sleep 15 }
    }
    throw "Could not assign $label"
  }

  # Only allow assigning/removing the Foundry User role (azd deploy gives it to the agent's identity).
  $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$FoundryUserRole})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$FoundryUserRole}))"

  Step 'Role assignments'
  Assign 'Contributor'                      $ContributorRole $RgScope
  Assign 'Foundry User'                     $FoundryUserRole $RgScope
  Assign 'RBAC Administrator (conditional)' $RbacAdminRole   $RgScope $condition
  Assign $CustomRoleName                    $CustomRoleName  $SubScope

  # -------------------------------------------------------------- GitHub ---
  Step "GitHub variables on $GitHubRepo"
  $vars = [ordered]@{
    AZURE_CLIENT_ID = $AppId; AZURE_TENANT_ID = $TenantId; AZURE_SUBSCRIPTION_ID = $SubscriptionId
    AZURE_RESOURCE_GROUP = $ResourceGroup; AZURE_LOCATION = $Location; AZURE_ENV_NAME = $EnvName
    AZURE_AI_MODEL_DEPLOYMENT_NAME = $Model
  }
  foreach ($k in $vars.Keys) { gh variable set $k -R $GitHubRepo -b $vars[$k] }

  Step "GitHub environments (dev = automatic, prod = $ProdReviewer approves)"
  gh api -X PUT "repos/$GitHubRepo/environments/dev" --silent
  $reviewerId = gh api "users/$ProdReviewer" -q .id
  "{`"reviewers`":[{`"type`":`"User`",`"id`":$reviewerId}],`"prevent_self_review`":false}" | Set-Content $tmp -Encoding ascii
  gh api -X PUT "repos/$GitHubRepo/environments/prod" --silent --input $tmp

  Step 'Done'
  Write-Host 'Next: GitHub → Actions → Provision → Run workflow.'
}
finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
