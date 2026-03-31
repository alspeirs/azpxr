[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('scan','help')]
    [string]$Command = 'scan',

    [string]$Subscription,
    [string]$Region,
    [string]$Family,
    [switch]$IncludeRestricted,
    [ValidateSet('text','json')]
    [string]$Format = 'text',
    [int]$PageSize = 40,
    [int]$Page = 1,
    [int]$Top = 0,
    [string]$Sku,
    [switch]$RegionsOnly,
    [switch]$NoPager,
    [switch]$Interactive,
    [switch]$SortByMemory,
    [switch]$SortByCpu,
    [switch]$Descending
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Show-Usage {
    @"
azpxr.ps1 - Azure VM availability summary (PowerShell)

Usage:
  ./azpxr.ps1 scan --subscription <id> [--region westus2] [--family dsv5] [--sku NC] [--page-size 40] [--page 1]
  ./azpxr.ps1 scan --subscription <id> --regions-only
  ./azpxr.ps1 scan --subscription <id> --format json

Parameters:
  -Subscription       Azure subscription ID. Falls back to AZURE_SUBSCRIPTION_ID.
  -Region             Limit to a single Azure region.
  -Family             Filter by VM family substring.
  -Sku                Filter by SKU name substring.
  -IncludeRestricted  Include restricted SKUs.
  -Format             text | json
  -PageSize           Number of rows per page in text mode. Default: 40
  -Page               1-based page number in text mode. Default: 1
  -Top                Limit total matching rows before paging.
  -RegionsOnly        Show region summary only.
  -NoPager            Disable paging and print all matching rows.
  -Interactive        Prompt after each page; Enter=next, q=quit.
  -SortByMemory       Sort SKUs by MemoryGB instead of name.
  -SortByCpu          Sort SKUs by vCPUs instead of name.
  -Descending         Reverse sort order.

Requirements:
  - Azure CLI installed and logged in (`az login`)
  - Access to Microsoft.Compute resource SKUs for the subscription
"@
}

function Require-AzCli {
    $cmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw 'Azure CLI (az) not found in PATH.'
    }
}

function Get-SubscriptionId {
    param([string]$Subscription)

    if ($Subscription) { return $Subscription }
    if ($env:AZURE_SUBSCRIPTION_ID) { return $env:AZURE_SUBSCRIPTION_ID }

    $account = az account show --output json 2>$null | ConvertFrom-Json
    if (-not $account -or -not $account.id) {
        throw 'Subscription required: pass -Subscription or set AZURE_SUBSCRIPTION_ID.'
    }
    return [string]$account.id
}

function To-Number {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Join-OrDash {
    param($Items)
    if ($null -eq $Items) { return '-' }
    $arr = @($Items | Where-Object { $_ -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($arr.Count -eq 0) { return '-' }
    return ($arr -join ',')
}

function Get-FilteredSkuData {
    param(
        [string]$Subscription,
        [string]$Region,
        [string]$Family,
        [string]$Sku,
        [bool]$IncludeRestricted
    )

    $args = @('vm','list-skus','--subscription',$Subscription,'--resource-type','virtualMachines','--all','--output','json')
    $raw = az @args
    if (-not $raw) {
        throw 'Azure CLI returned no data.'
    }

    $items = $raw | ConvertFrom-Json
    $wantedRegion = if ($Region) { $Region.ToLowerInvariant() } else { $null }
    $familyFilter = if ($Family) { $Family.ToLowerInvariant() } else { $null }
    $skuFilter    = if ($Sku) { $Sku.ToLowerInvariant() } else { $null }

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($item in $items) {
        if ($null -eq $item.name -or $null -eq $item.locations) { continue }

        $restrictions = @($item.restrictions)
        if (-not $IncludeRestricted -and $restrictions.Count -gt 0) { continue }

        $familyName = [string]$item.family
        $skuName = [string]$item.name

        if ($familyFilter -and ($skuName.ToLowerInvariant() -notlike "*$familyFilter*") -and ($familyName.ToLowerInvariant() -notlike "*$familyFilter*")) { continue }
        if ($skuFilter -and ($skuName.ToLowerInvariant() -notlike "*$skuFilter*")) { continue }

        $capabilities = @{}
        foreach ($cap in @($item.capabilities)) {
            if ($null -ne $cap.name -and $null -ne $cap.value) {
                $capabilities[[string]$cap.name] = [string]$cap.value
            }
        }

        foreach ($loc in @($item.locations)) {
            if ($null -eq $loc) { continue }
            $regionName = ([string]$loc).ToLowerInvariant()
            if ($wantedRegion -and $regionName -ne $wantedRegion) { continue }

            $zones = New-Object System.Collections.Generic.List[string]
            foreach ($locInfo in @($item.locationInfo)) {
                if ($null -eq $locInfo -or $null -eq $locInfo.location) { continue }
                if (([string]$locInfo.location).ToLowerInvariant() -ne $regionName) { continue }
                foreach ($zone in @($locInfo.zones)) {
                    if ($null -ne $zone -and -not $zones.Contains([string]$zone)) {
                        [void]$zones.Add([string]$zone)
                    }
                }
            }

            $restrictionLabels = foreach ($r in $restrictions) {
                $parts = @()
                if ($null -ne $r.type) { $parts += [string]$r.type }
                if ($null -ne $r.reasonCode) { $parts += [string]$r.reasonCode }
                if ($parts.Count -gt 0) { $parts -join ':' }
            }

            $rows.Add([pscustomobject]@{
                Region        = $regionName
                Name          = $skuName
                Family        = $familyName
                Tier          = [string]$item.tier
                vCPUs         = $capabilities['vCPUs']
                MemoryGB      = $capabilities['MemoryGB']
                CpuNumeric    = To-Number $capabilities['vCPUs']
                MemoryNumeric = To-Number $capabilities['MemoryGB']
                Zones         = @($zones | Sort-Object)
                Restrictions  = @($restrictionLabels | Sort-Object -Unique)
                Capabilities  = $capabilities
            })
        }
    }

    return @($rows)
}

function Show-RegionSummary {
    param([object[]]$Rows, [string]$Subscription)

    $grouped = $Rows | Group-Object Region | Sort-Object Name
    Write-Host ("Subscription: {0}" -f $Subscription)
    Write-Host ("Regions: {0} | SKUs: {1}" -f $grouped.Count, $Rows.Count)
    Write-Host ''

    foreach ($group in $grouped) {
        $zoneCount = @($group.Group | ForEach-Object { $_.Zones } | Where-Object { $_ } | Select-Object -Unique).Count
        "{0,-20} SKUs={1,5}  ZonesSeen={2}" -f $group.Name, $group.Count, $zoneCount
    }
}

function Show-TextReport {
    param(
        [object[]]$Rows,
        [string]$Subscription,
        [int]$PageSize,
        [int]$Page,
        [int]$Top,
        [bool]$NoPager,
        [bool]$Interactive,
        [bool]$SortByMemory,
        [bool]$SortByCpu,
        [bool]$Descending
    )

    if ($SortByMemory) {
        $sorted = $Rows | Sort-Object @{Expression = { if ($null -eq $_.MemoryNumeric) { -1 } else { $_.MemoryNumeric } }; Descending = $Descending }, Region, Name
    } elseif ($SortByCpu) {
        $sorted = $Rows | Sort-Object @{Expression = { if ($null -eq $_.CpuNumeric) { -1 } else { $_.CpuNumeric } }; Descending = $Descending }, Region, Name
    } else {
        $sorted = @($Rows | Sort-Object Region, Name)
        if ($Descending -and $sorted.Count -gt 0) { $sorted = @($sorted[($sorted.Count-1)..0]) }
    }

    if ($Top -gt 0) {
        $sorted = @($sorted | Select-Object -First $Top)
    }

    $total = @($sorted).Count
    Write-Host ("Subscription: {0}" -f $Subscription)
    Write-Host ("Matching rows: {0}" -f $total)
    Write-Host ''

    if ($total -eq 0) {
        Write-Host 'No matching SKUs found.'
        return
    }

    if ($NoPager) {
        $pageRows = $sorted
        $start = 1
        $end = $total

        $pageRows |
            Select-Object Region, Name, Family,
                @{Name='vCPU';Expression={ if ($_.vCPUs) { $_.vCPUs } else { '-' } }},
                @{Name='MemGB';Expression={ if ($_.MemoryGB) { $_.MemoryGB } else { '-' } }},
                @{Name='Zones';Expression={ Join-OrDash $_.Zones }},
                @{Name='Restrictions';Expression={ Join-OrDash $_.Restrictions }} |
            Format-Table -AutoSize
        return
    }

    if ($PageSize -lt 1) { throw 'PageSize must be >= 1.' }
    if ($Page -lt 1) { throw 'Page must be >= 1.' }
    $pageCount = [Math]::Ceiling($total / [double]$PageSize)

    if ($Interactive) {
        for ($currentPage = 1; $currentPage -le $pageCount; $currentPage++) {
            $skip = ($currentPage - 1) * $PageSize
            $pageRows = @($sorted | Select-Object -Skip $skip -First $PageSize)
            $start = $skip + 1
            $end = $skip + $pageRows.Count

            if ($currentPage -gt 1) {
                Write-Host ''
            }
            Write-Host ("Page {0}/{1}  (rows {2}-{3})" -f $currentPage, $pageCount, $start, $end)
            Write-Host ''

            $pageRows |
                Select-Object Region, Name, Family,
                    @{Name='vCPU';Expression={ if ($_.vCPUs) { $_.vCPUs } else { '-' } }},
                    @{Name='MemGB';Expression={ if ($_.MemoryGB) { $_.MemoryGB } else { '-' } }},
                    @{Name='Zones';Expression={ Join-OrDash $_.Zones }},
                    @{Name='Restrictions';Expression={ Join-OrDash $_.Restrictions }} |
                Format-Table -AutoSize

            if ($currentPage -lt $pageCount) {
                $response = Read-Host "Press Enter for next page, or type q to quit"
                if ($response -match '^(q|quit)$') {
                    break
                }
            }
        }

        Write-Host ''
        Write-Host ("Tip: use -PageSize <n>, -Top <n>, -SortByCpu, -SortByMemory, -Region, -Family, or -Sku to narrow things down.")
        return
    }

    if ($Page -gt $pageCount) {
        throw ("Page {0} is out of range. Last page is {1}." -f $Page, $pageCount)
    }
    $skip = ($Page - 1) * $PageSize
    $pageRows = @($sorted | Select-Object -Skip $skip -First $PageSize)
    $start = $skip + 1
    $end = $skip + $pageRows.Count
    Write-Host ("Page {0}/{1}  (rows {2}-{3})" -f $Page, $pageCount, $start, $end)
    Write-Host ''

    $pageRows |
        Select-Object Region, Name, Family,
            @{Name='vCPU';Expression={ if ($_.vCPUs) { $_.vCPUs } else { '-' } }},
            @{Name='MemGB';Expression={ if ($_.MemoryGB) { $_.MemoryGB } else { '-' } }},
            @{Name='Zones';Expression={ Join-OrDash $_.Zones }},
            @{Name='Restrictions';Expression={ Join-OrDash $_.Restrictions }} |
        Format-Table -AutoSize

    Write-Host ''
    Write-Host ("Tip: use -Page <n>, -PageSize <n>, -Top <n>, -Interactive, -SortByCpu, -SortByMemory, -Region, -Family, or -Sku to narrow things down.")
}

if ($Command -eq 'help') {
    Show-Usage
    exit 0
}

Require-AzCli
$resolvedSubscription = Get-SubscriptionId -Subscription $Subscription
$rows = Get-FilteredSkuData -Subscription $resolvedSubscription -Region $Region -Family $Family -Sku $Sku -IncludeRestricted:$IncludeRestricted

if ($Format -eq 'json') {
    $result = [pscustomobject]@{
        subscriptionId = $resolvedSubscription
        summary = [pscustomobject]@{
            regionCount = @($rows | Select-Object -ExpandProperty Region -Unique).Count
            skuCount    = $rows.Count
        }
        rows = $rows
    }
    $result | ConvertTo-Json -Depth 8
    exit 0
}

if ($RegionsOnly) {
    Show-RegionSummary -Rows $rows -Subscription $resolvedSubscription
    exit 0
}

Show-TextReport -Rows $rows -Subscription $resolvedSubscription -PageSize $PageSize -Page $Page -Top $Top -NoPager:$NoPager -Interactive:$Interactive -SortByMemory:$SortByMemory -SortByCpu:$SortByCpu -Descending:$Descending
