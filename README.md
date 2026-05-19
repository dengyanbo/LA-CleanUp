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

## Notes & limitations

- **Per-item confirmation** is the only safety net. There is no `-WhatIf` and no `-Force`. If you need a dry run, answer `N` to every delete prompt — the report and CSV are still produced.
- **API connections** (`Microsoft.Web/connections`) referenced by the deleted workflows are **not** removed by this script (they are often shared). Clean them up separately if needed.
- The script uses the Logic Apps Management REST API (`api-version=2016-06-01`) via `az rest`, so the `az logic` extension is **not** required.
- Run history is queried with server-side `$filter` on `startTime` / `status`, so it is efficient even for chatty workflows.
- Deletion uses `az resource delete --ids <resourceId>`. Workflow run history is removed by Azure when the workflow itself is deleted.

## CSV format

Columns: `Category, Name, ResourceGroup, Location, State, LastStatus, LastRunTime, ResourceId`.
File name: `LogicAppCleanup-Candidates-<yyyyMMdd-HHmmss>.csv` in the script's directory.
