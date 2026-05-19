<#
.SYNOPSIS
    Identify and (optionally) delete unused or always-failing Azure Logic Apps (Consumption).

.DESCRIPTION
    Scans the currently active Azure subscription (via az CLI) for Logic Apps Consumption
    workflows and classifies them into two cleanup buckets:

      1. Idle           : No runs in the last -IdleDays days (Logic Apps that have NEVER
                          run are included here).
      2. AlwaysFailing  : Had at least one run in the last -FailureWindowDays days, but
                          none of those runs reached the 'Succeeded' status.

    Logic Apps Standard is NOT in scope.

    After listing, the script offers to export the candidates to CSV, then walks through
    each candidate and prompts y/N/q before deleting it.

.PARAMETER IdleDays
    Number of days of inactivity that qualifies a workflow as "Idle". Default 90.

.PARAMETER FailureWindowDays
    Number of days looked back when deciding if a workflow has any successful run.
    Default 90.

.PARAMETER ResourceGroup
    Optional. Restrict the scan to a single resource group.

.PARAMETER SkipIdle
    Skip the Idle bucket entirely.

.PARAMETER SkipAlwaysFailing
    Skip the AlwaysFailing bucket entirely.

.EXAMPLE
    .\Invoke-LogicAppCleanup.ps1

    Use defaults: 90 days idle, 90 days failure window, current subscription, all RGs.

.EXAMPLE
    .\Invoke-LogicAppCleanup.ps1 -IdleDays 60 -ResourceGroup rg-integration

    Scan only rg-integration, treat 60 days of inactivity as idle.

.NOTES
    Requires: Azure CLI (az) and an active `az login` session.
    Logic Apps Standard is not supported by this script.
#>

[CmdletBinding()]
param(
    [int]    $IdleDays           = 90,
    [int]    $FailureWindowDays  = 90,
    [string] $ResourceGroup,
    [switch] $SkipIdle,
    [switch] $SkipAlwaysFailing
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ---------------------------------------------------------

function Write-Info    { param([string]$m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Ok      { param([string]$m) Write-Host "[ OK ]  $m" -ForegroundColor Green }
function Write-WarnMsg { param([string]$m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-ErrMsg  { param([string]$m) Write-Host "[ERR ]  $m" -ForegroundColor Red }

function Assert-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-ErrMsg "Azure CLI ('az') not found in PATH. Install it from https://aka.ms/azcli and retry."
        exit 1
    }
}

function Assert-AzLogin {
    # Suppress stderr noise; rely on exit code.
    $null = az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-ErrMsg "You are not signed in to Azure CLI."
        Write-Host  "        Run 'az login' (and optionally 'az account set --subscription <id>') and re-run this script." -ForegroundColor Yellow
        exit 1
    }
}

function Get-ActiveSubscription {
    $json = az account show -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        Write-ErrMsg "Failed to read active subscription."
        exit 1
    }
    return ($json | ConvertFrom-Json)
}

function Invoke-AzRestJson {
    <#
        Calls the ARM REST API and returns the parsed JSON object, or $null on failure.
        Uses Invoke-RestMethod with a cached bearer token (via `az account get-access-token`)
        rather than `az rest`, to avoid cmd.exe re-parsing URL '&' separators on Windows.
        Errors are surfaced to the caller via $script:LastAzRestError.
    #>
    param([Parameter(Mandatory)][string]$Url)

    $script:LastAzRestError = $null

    # Refresh token if missing or older than 45 minutes (ARM tokens last ~60min).
    if (-not $script:ArmToken -or
        -not $script:ArmTokenExpiresAt -or
        (Get-Date) -gt $script:ArmTokenExpiresAt) {
        $tokRaw = az account get-access-token --resource 'https://management.azure.com/' -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            $script:LastAzRestError = "Failed to acquire ARM access token: $($tokRaw | Out-String)"
            return $null
        }
        try {
            $tok = $tokRaw | ConvertFrom-Json
            $script:ArmToken          = $tok.accessToken
            $script:ArmTokenExpiresAt = (Get-Date).AddMinutes(45)
        } catch {
            $script:LastAzRestError = "Could not parse access token JSON: $($_.Exception.Message)"
            return $null
        }
    }

    try {
        $headers = @{ Authorization = "Bearer $($script:ArmToken)" }
        return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -ErrorAction Stop
    } catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $script:LastAzRestError = "REST GET failed (HTTP $code): $($_.Exception.Message)"
        return $null
    }
}

function Get-LogicAppWorkflows {
    param([string]$ResourceGroup)

    $azArgs = @('resource','list','--resource-type','Microsoft.Logic/workflows','-o','json')
    if ($ResourceGroup) { $azArgs += @('--resource-group', $ResourceGroup) }

    $raw = az @azArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ErrMsg "Failed to list Logic App workflows: $($raw | Out-String)"
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $items = $raw | ConvertFrom-Json
    if ($null -eq $items) { return @() }

    # Normalize: az resource list returns a flat shape; "state" lives under properties only
    # if we do a `show`. We'll fetch it lazily later only if we need it. For now, return
    # name / rg / id / location.
    return @($items | ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.name
            ResourceGroup = $_.resourceGroup
            Location      = $_.location
            ResourceId    = $_.id
            State         = $null   # filled in on demand
        }
    })
}

function Get-WorkflowState {
    param([string]$ResourceId)
    $raw = az resource show --ids $ResourceId --query "properties.state" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { return 'Unknown' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'Unknown' }
    return $raw.Trim()
}

function Get-CutoffIso {
    param([int]$Days)
    return ([DateTime]::UtcNow.AddDays(-$Days)).ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-LatestRunInWindow {
    <#
        Returns the most recent run object for $WorkflowId with startTime >= $CutoffIso,
        or $null if there are no runs in that window.
    #>
    param([string]$WorkflowId, [string]$CutoffIso)

    $filter   = "startTime ge $CutoffIso"
    $filterEnc = [System.Uri]::EscapeDataString($filter)
    $url = "https://management.azure.com$WorkflowId/runs?api-version=2016-06-01&" +
           "`$top=1&`$filter=$filterEnc"

    $resp = Invoke-AzRestJson -Url $url
    if ($null -eq $resp) { return $null }
    if (-not $resp.value -or $resp.value.Count -eq 0) { return $null }
    return $resp.value[0]
}

function Test-HasSucceededRunInWindow {
    <#
        Returns $true if at least one run with status='Succeeded' exists in the window,
        $false otherwise. $null on REST error.
    #>
    param([string]$WorkflowId, [string]$CutoffIso)

    $filter    = "startTime ge $CutoffIso and status eq 'Succeeded'"
    $filterEnc = [System.Uri]::EscapeDataString($filter)
    $url = "https://management.azure.com$WorkflowId/runs?api-version=2016-06-01&" +
           "`$top=1&`$filter=$filterEnc"

    $resp = Invoke-AzRestJson -Url $url
    if ($null -eq $resp) {
        if ($script:LastAzRestError) { return $null }
        return $false
    }
    return ($resp.value -and $resp.value.Count -gt 0)
}

function Get-LastRunEver {
    <#
        Returns the most recent run regardless of date, or $null if the workflow has
        never run.
    #>
    param([string]$WorkflowId)

    $url = "https://management.azure.com$WorkflowId/runs?api-version=2016-06-01&`$top=1"
    $resp = Invoke-AzRestJson -Url $url
    if ($null -eq $resp) { return $null }
    if (-not $resp.value -or $resp.value.Count -eq 0) { return $null }
    return $resp.value[0]
}

# ---------- main ------------------------------------------------------------

Assert-AzCli
Assert-AzLogin

$sub = Get-ActiveSubscription
Write-Info "Active subscription: $($sub.name)  ($($sub.id))"
if ($sub.user -and $sub.user.name) { Write-Info "Signed in as       : $($sub.user.name)" }

$idleCutoff    = Get-CutoffIso -Days $IdleDays
$failureCutoff = Get-CutoffIso -Days $FailureWindowDays
Write-Info "Idle cutoff        : runs older than $idleCutoff (>$IdleDays days)"
Write-Info "Failure window     : checking runs since $failureCutoff (last $FailureWindowDays days)"
if ($ResourceGroup) { Write-Info "Resource group     : $ResourceGroup" }

Write-Info "Listing Logic App (Consumption) workflows..."
$workflows = Get-LogicAppWorkflows -ResourceGroup $ResourceGroup
Write-Ok   "Found $($workflows.Count) workflow(s)."

if ($workflows.Count -eq 0) {
    Write-Info "Nothing to do."
    return
}

$idle          = New-Object System.Collections.Generic.List[object]
$alwaysFailing = New-Object System.Collections.Generic.List[object]
$scanErrors    = 0
$idx = 0

foreach ($wf in $workflows) {
    $idx++
    Write-Host ("  [{0,3}/{1}] {2}  ({3})" -f $idx, $workflows.Count, $wf.Name, $wf.ResourceGroup)

    try {
        # ---- Idle check (most recent run in last IdleDays) ----
        $recent = Get-LatestRunInWindow -WorkflowId $wf.ResourceId -CutoffIso $idleCutoff
        if ($null -eq $recent -and $script:LastAzRestError) {
            throw $script:LastAzRestError
        }

        if ($null -eq $recent) {
            if ($SkipIdle) { continue }
            $wf.State = Get-WorkflowState -ResourceId $wf.ResourceId
            $lastEver = Get-LastRunEver -WorkflowId $wf.ResourceId
            $lastTime = if ($lastEver) { $lastEver.properties.startTime } else { $null }
            $lastStat = if ($lastEver) { $lastEver.properties.status }    else { 'Never' }

            $idle.Add([PSCustomObject]@{
                Category      = 'Idle'
                Name          = $wf.Name
                ResourceGroup = $wf.ResourceGroup
                Location      = $wf.Location
                State         = $wf.State
                LastStatus    = $lastStat
                LastRunTime   = $lastTime
                ResourceId    = $wf.ResourceId
            }) | Out-Null
            continue
        }

        # ---- AlwaysFailing check (any Succeeded run in failure window?) ----
        if ($SkipAlwaysFailing) { continue }

        $hadSuccess = Test-HasSucceededRunInWindow -WorkflowId $wf.ResourceId -CutoffIso $failureCutoff
        if ($null -eq $hadSuccess) {
            throw $script:LastAzRestError
        }

        if (-not $hadSuccess) {
            $wf.State = Get-WorkflowState -ResourceId $wf.ResourceId
            $alwaysFailing.Add([PSCustomObject]@{
                Category      = 'AlwaysFailing'
                Name          = $wf.Name
                ResourceGroup = $wf.ResourceGroup
                Location      = $wf.Location
                State         = $wf.State
                LastStatus    = $recent.properties.status
                LastRunTime   = $recent.properties.startTime
                ResourceId    = $wf.ResourceId
            }) | Out-Null
        }
    }
    catch {
        $scanErrors++
        Write-WarnMsg "Scan failed for $($wf.Name) in $($wf.ResourceGroup): $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Ok "Scan complete. Idle: $($idle.Count), AlwaysFailing: $($alwaysFailing.Count), Errors: $scanErrors"
Write-Host ""

if ($idle.Count -gt 0) {
    Write-Host "=== Idle Logic Apps (no runs in last $IdleDays days) ===" -ForegroundColor Magenta
    $idle | Select-Object Name, ResourceGroup, Location, State, LastStatus, LastRunTime |
        Format-Table -AutoSize | Out-Host
}

if ($alwaysFailing.Count -gt 0) {
    Write-Host "=== Always-Failing Logic Apps (no successful run in last $FailureWindowDays days) ===" -ForegroundColor Magenta
    $alwaysFailing | Select-Object Name, ResourceGroup, Location, State, LastStatus, LastRunTime |
        Format-Table -AutoSize | Out-Host
}

$candidates = @()
$candidates += $idle
$candidates += $alwaysFailing

if ($candidates.Count -eq 0) {
    Write-Ok "No cleanup candidates found. You're done."
    return
}

# ---- CSV export prompt ----
$csvAns = Read-Host "Export the $($candidates.Count) candidate(s) to CSV? (y/N)"
if ($csvAns -and $csvAns.Trim().ToLowerInvariant() -eq 'y') {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $csvPath = Join-Path $scriptDir "LogicAppCleanup-Candidates-$stamp.csv"
    try {
        $candidates |
            Select-Object Category, Name, ResourceGroup, Location, State, LastStatus, LastRunTime, ResourceId |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Ok "CSV written: $csvPath"
    } catch {
        Write-ErrMsg "Failed to write CSV: $($_.Exception.Message)"
    }
}

# ---- Per-item deletion loop ----
Write-Host ""
Write-Host "Starting per-item deletion review. Answer y to delete, N (or Enter) to skip, q to quit." -ForegroundColor Yellow

$deleted   = 0
$skipped   = 0
$failed    = 0
$quitEarly = $false
$ci = 0

foreach ($c in $candidates) {
    $ci++
    if ($quitEarly) { $skipped++; continue }

    $prompt = "  ({0}/{1}) Delete [{2}] {3} in {4} ? (y/N/q)" -f `
              $ci, $candidates.Count, $c.Category, $c.Name, $c.ResourceGroup
    $ans = Read-Host $prompt
    $a = ($ans + '').Trim().ToLowerInvariant()

    switch ($a) {
        'q' {
            Write-WarnMsg "Quit requested. Remaining candidates will be skipped."
            $quitEarly = $true
            $skipped++
        }
        'y' {
            Write-Info "Deleting $($c.Name) ..."
            $null = az resource delete --ids $c.ResourceId 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Deleted: $($c.Name)"
                $deleted++
            } else {
                Write-ErrMsg "Failed to delete $($c.Name) (az exit $LASTEXITCODE)"
                $failed++
            }
        }
        default {
            Write-Host "  Skipped." -ForegroundColor DarkGray
            $skipped++
        }
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Magenta
Write-Host ("Scanned         : {0}" -f $workflows.Count)
Write-Host ("Idle            : {0}" -f $idle.Count)
Write-Host ("Always-failing  : {0}" -f $alwaysFailing.Count)
Write-Host ("Scan errors     : {0}" -f $scanErrors)
Write-Host ("Deleted         : {0}" -f $deleted) -ForegroundColor Green
Write-Host ("Skipped         : {0}" -f $skipped)
Write-Host ("Delete failures : {0}" -f $failed) -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Gray' })
