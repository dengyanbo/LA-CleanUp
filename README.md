# Logic App Consumption Cleanup

`Invoke-LogicAppCleanup.ps1` — a PowerShell utility that finds and (with per-item confirmation) deletes Azure **Logic Apps Consumption** workflows that are likely abandoned or broken.

> ⚠️ This script targets **Logic Apps Consumption only**. Logic Apps **Standard** is not supported.

## What it does

For the **currently active `az` subscription**, the script classifies every Logic App Consumption workflow into one of two buckets:

| Bucket | Criterion |
|---|---|
| **Idle** | No workflow runs in the last `-IdleDays` days (default `90`). Logic Apps that have **never** run are included here. |
| **AlwaysFailing** | At least one run exists in the last `-FailureWindowDays` days (default `90`), but **none** of those runs reached the `Succeeded` status. |

It then:

1. Prints two tables (Idle and AlwaysFailing) with name, resource group, last status, and last run time.
2. Asks `Export the candidates to CSV? (y/N)`. If yes, a timestamped CSV is written next to the script.
3. Walks through each candidate and prompts `Delete [Category] <name> in <rg> ? (y/N/q)`:
   - `y` — runs `az resource delete --ids <id>`
   - `N` or Enter — skip
   - `q` — quit the loop (remaining items are skipped)
4. Prints a final summary (scanned, idle, always-failing, deleted, skipped, failed).

## Prerequisites

- **Azure CLI** (`az`) installed and on `PATH` — install from <https://aka.ms/azcli>.
- An active session: run `az login` *before* invoking the script. The script will exit if you are not signed in (it does **not** auto-trigger `az login`).
- The signed-in principal must have permission to **list** Logic App workflows and **delete** them in the target subscription (e.g., Contributor on the relevant resource groups, or Logic App Contributor).
- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+ (cross-platform).

If you need to target a different subscription than the current one, run `az account set --subscription <id>` first.

## Parameters

| Name | Default | Description |
|---|---|---|
| `-IdleDays` | `90` | A workflow with no runs in this many days is flagged **Idle**. |
| `-FailureWindowDays` | `90` | A workflow that ran in this window but never succeeded in it is flagged **AlwaysFailing**. |
| `-ResourceGroup` | *(none)* | Restrict the scan to a single resource group. |
| `-SkipIdle` | switch | Skip the Idle bucket. |
| `-SkipAlwaysFailing` | switch | Skip the AlwaysFailing bucket. |

## Examples

Scan the whole subscription with defaults:

```powershell
.\Invoke-LogicAppCleanup.ps1
```

Tighter idle threshold and one resource group:

```powershell
.\Invoke-LogicAppCleanup.ps1 -IdleDays 60 -ResourceGroup rg-integration
```

Only review always-failing apps:

```powershell
.\Invoke-LogicAppCleanup.ps1 -SkipIdle
```

## How it works (technical deep dive)

A few engineering decisions in the script meaningfully affect correctness and performance. They're worth calling out in case you're adapting the script or just curious.

### 1. Enumeration via `az resource list`, not `az logic`

```powershell
az resource list --resource-type Microsoft.Logic/workflows -o json
```

A generic ARM list is used instead of the `az logic` extension because:

- It avoids depending on an extension that's marked Preview on some installations.
- One ARM call returns `id`, `name`, `resourceGroup`, and `location` for every Consumption workflow in the active subscription.
- `properties.state` (Enabled/Disabled) is **not** in that projection. The script fetches it lazily with `az resource show --query properties.state` only for workflows that become candidates. On a subscription with hundreds of workflows but only a handful of candidates, that's an order of magnitude fewer ARM calls than `show`-ing every one.

### 2. Server-side `$filter` on run history

For each surviving workflow the script asks two questions of the Logic Apps Management REST API (`api-version=2016-06-01`):

```
GET /subscriptions/.../workflows/{wf}/runs
    ?api-version=2016-06-01
    &$top=1
    &$filter=startTime ge 2026-02-18T02:20:00Z
```

and

```
GET .../runs
    ?api-version=2016-06-01
    &$top=1
    &$filter=startTime ge 2026-02-18T02:20:00Z and status eq 'Succeeded'
```

`$top=1` is the important bit — we never need to page run history, only check **existence**. Even on a chatty workflow with thousands of runs in the window the server still answers in O(1) because the filter is indexed.

### 3. Bearer-token caching instead of `az rest`

The script calls `Invoke-RestMethod` with a bearer token cached on `$script:ArmToken`, refreshed proactively at 45 minutes (ARM tokens last ~60). It does **not** use `az rest`. Why:

On **Windows PowerShell**, `az` is a `.cmd` shim, so the URL passed to `az rest --uri "..."` is re-parsed by `cmd.exe`. The `&` characters separating OData query parameters (`$top=1&$filter=...`) get split into multiple commands. Symptoms range from `'$filter' is not recognized as an internal or external command` to silent wrong-page returns. Quoting heroics don't fully solve it.

Switching to:

```powershell
$tok = az account get-access-token --resource 'https://management.azure.com/' -o json | ConvertFrom-Json
Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $($tok.accessToken)" }
```

bypasses the shell entirely. Bonus: caching the token makes the script noticeably faster on subscriptions with many candidates, since we're no longer shelling out for every REST call.

### 4. Lazy `State` fetch

`State` (Enabled/Disabled) is only fetched for workflows that end up as candidates, never for healthy ones. Same principle as the lazy enumeration above — don't pay for data you don't show.

### 5. CSV as audit trail

`LogicAppCleanup-Candidates-<yyyyMMdd-HHmmss>.csv` is written next to the script when you answer `y` to the export prompt. Columns are stable and grep-friendly:

```
Category, Name, ResourceGroup, Location, State, LastStatus, LastRunTime, ResourceId
```

The `ResourceId` column makes it trivial to feed a CSV back into a different deletion pipeline (`az resource delete --ids ...`) or to diff two runs week-over-week.

### 6. Deletion semantics

Deletion uses:

```powershell
az resource delete --ids $c.ResourceId
```

Workflow **run history is removed by Azure automatically** when the workflow itself is deleted — no separate purge call is needed. The script does **not** delete `Microsoft.Web/connections` referenced by the workflow definition (see considerations below).

## Considerations and limitations

These are deliberate scope decisions, not bugs. Read them before running the script in a subscription you don't fully own.

- **Per-item confirmation is the only safety net.** There is no `-WhatIf` and no `-Force`. If you want a dry run, answer `N` to every delete prompt — the report and CSV are still produced.
- **Consumption only.** Logic Apps **Standard** workflows live inside an App Service (`Microsoft.Web/sites` with `kind=workflowapp`) and store run history in storage tables, not in the management plane. This script does not handle them. For Standard, see tools like [`LogicAppAdvancedTool`](https://github.com/Azure/logicappadvancedtool).
- **Permissions.** You need to be able to **list** and **delete** workflows — `Contributor` on the relevant resource groups, or `Logic App Contributor`, both work. `az account get-access-token` only needs the standard ARM scope your `az login` already granted.
- **API connections are not removed.** `Microsoft.Web/connections` referenced via `parameters.$connections` in the workflow definition are usually shared. Deleting them blindly when their last consumer goes away is dangerous, so the script leaves them alone. GC them with a separate pass.
- **Enabled vs. Disabled is reported, not enforced.** A `Disabled` workflow can still be Idle (no runs ever or no runs in the window). The script shows the state in the table so you can decide; it does not soft-action Disabled workflows.
- **"AlwaysFailing" means "no `Succeeded` in the window".** Workflows whose runs are `Running`, `Waiting`, or `Cancelled` but never `Succeeded` will be classified as AlwaysFailing. That's usually what you want, but slow workflows that legitimately haven't completed yet look the same — widen `-FailureWindowDays` for those.
- **Run history is gone after deletion.** Once a workflow is deleted you can't browse its history in the portal. The CSV is your audit trail. Keep it.
- **Single subscription per invocation.** The script operates on the **active** subscription only — it does not enumerate all subscriptions you have access to. Use `az account set --subscription <id>` to switch, deliberately.

## Field-tested safety pattern

If you're running this on a subscription you don't fully own, this rollout has worked well:

1. Run with `-SkipAlwaysFailing` first. Idle workflows are the safe pile — they haven't done anything in 90+ days, so deleting them rarely surprises anyone.
2. Export the CSV. Don't delete yet — answer `q` at the first delete prompt.
3. Drop the CSV in a Teams channel or PR. Give owners a few days to object.
4. Re-run and actually delete the ones nobody claimed.
5. *Then* run with `-SkipIdle` for the AlwaysFailing bucket. These often have an owner who just hasn't noticed the breakage — treat the first pass as a bug-bash list, not a delete list.

## CSV format

Columns: `Category, Name, ResourceGroup, Location, State, LastStatus, LastRunTime, ResourceId`.
File name: `LogicAppCleanup-Candidates-<yyyyMMdd-HHmmss>.csv` in the script's directory.
