[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [switch]$IncludeZeroQuota,
    [switch]$ExportCsv,
    [string]$CsvPath = ".\foundry-region-model-quota.csv",
    [string]$Region,
    [string]$ModelName,
    [string]$ModelVersion,
    [string]$ModelFormat,
    [int]$PageSize = 40,
    [int]$Page = 1,
    [switch]$NoPager,
    [switch]$Interactive,
    [switch]$Help,
    [ValidateRange(1,32)]
    [int]$ThrottleLimit = 6
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Show-Usage {
@"
azfmxr.ps1 - Azure Foundry/OpenAI regional model quota report

Usage:
  ./azfmxr.ps1
  ./azfmxr.ps1 -SubscriptionId <subscription-id>
  ./azfmxr.ps1 -Region eastus -ModelName gpt-4o
  ./azfmxr.ps1 -Interactive -PageSize 25
  ./azfmxr.ps1 -ExportCsv -CsvPath .\quota.csv

What it does:
  - finds Microsoft.CognitiveServices accounts of kind OpenAI or AIServices
  - lists models exposed by those resources
  - queries regional modelCapacities from ARM
  - shows quota-bearing results in the terminal by default

Filters:
  -Region         Limit displayed/query results to a region
  -ModelName      Filter by model name substring
  -ModelVersion   Filter by model version substring
  -ModelFormat    Filter by model format substring

Output:
  -PageSize       Rows per page in text mode (default 40)
  -Page           1-based page number in text mode (default 1)
  -NoPager        Print all rows
  -Interactive    Prompt after each page; Enter=next, q=quit
  -ThrottleLimit  Max concurrent ARM capacity lookups (default 6)
  -ExportCsv      Save CSV as well
  -IncludeZeroQuota Include zero-capacity rows
"@
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and $Args -notcontains '--subscription' -and $Args -notcontains '-s') {
        $Args = @($Args + @('--subscription', $SubscriptionId))
    }

    $result = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Args -join ' ')`n$($result -join "`n")"
    }

    if ([string]::IsNullOrWhiteSpace(($result -join "`n"))) {
        return $null
    }

    return (($result -join "`n") | ConvertFrom-Json -Depth 100)
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = & az rest --method get --url $Url --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ([string]::IsNullOrWhiteSpace(($result -join "`n"))) {
                return $null
            }
            return (($result -join "`n") | ConvertFrom-Json -Depth 100)
        }

        $text = ($result -join "`n")
        $shouldRetry = ($attempt -lt $MaxAttempts) -and ($text -match '429|TooManyRequests|Retry-After|temporar|timeout|5\d\d|InternalServerError|BadGateway|ServiceUnavailable|GatewayTimeout')
        if (-not $shouldRetry) {
            throw "ARM GET failed:`n$Url`n$text"
        }

        Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt)))
    }
}

function Get-PropValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }

    return $null
}

function Get-NestedPropValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $value = Get-PropValue -Object $Object -Names $Names
    if ($null -ne $value) {
        return $value
    }

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains 'properties') {
        return (Get-PropValue -Object $Object.properties -Names $Names)
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

function Matches-Filter {
    param(
        [string]$Value,
        [string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.ToLowerInvariant().Contains($Filter.ToLowerInvariant())
}

function Show-TextReport {
    param(
        [object[]]$Rows,
        [int]$PageSize,
        [int]$Page,
        [bool]$NoPager,
        [bool]$Interactive
    )

    $total = @($Rows).Count
    $regionCount = @($Rows | Select-Object -ExpandProperty Region -Unique).Count
    $modelCount = @($Rows | ForEach-Object { "{0}|{1}|{2}" -f $_.ModelFormat, $_.ModelName, $_.ModelVersion } | Select-Object -Unique).Count
    Write-Host ("Rows: {0} | Regions: {1} | Models: {2}" -f $total, $regionCount, $modelCount)
    Write-Host ''

    if ($total -eq 0) {
        Write-Warning 'No matching quota-bearing model capacities were found.'
        return
    }

    if ($NoPager) {
        $Rows |
            Select-Object Region, ModelFormat, ModelName, ModelVersion, Publisher, SkuName, AvailableCapacity, AvailableFinetuneCapacity |
            Format-Table -AutoSize
        return
    }

    if ($PageSize -lt 1) { throw 'PageSize must be >= 1.' }
    if ($Page -lt 1) { throw 'Page must be >= 1.' }

    $pageCount = [Math]::Ceiling($total / [double]$PageSize)

    if ($Interactive) {
        for ($currentPage = 1; $currentPage -le $pageCount; $currentPage++) {
            $skip = ($currentPage - 1) * $PageSize
            $pageRows = @($Rows | Select-Object -Skip $skip -First $PageSize)
            $start = $skip + 1
            $end = $skip + $pageRows.Count

            Write-Host ("Page {0}/{1} (rows {2}-{3})" -f $currentPage, $pageCount, $start, $end)
            Write-Host ''

            $pageRows |
                Select-Object Region, ModelFormat, ModelName, ModelVersion, Publisher, SkuName, AvailableCapacity, AvailableFinetuneCapacity |
                Format-Table -AutoSize

            if ($currentPage -lt $pageCount) {
                $response = Read-Host 'Press Enter for next page, or type q to quit'
                if ($response -match '^(q|quit)$') {
                    break
                }
                Write-Host ''
            }
        }
        return
    }

    if ($Page -gt $pageCount) {
        throw ("Page {0} is out of range. Last page is {1}." -f $Page, $pageCount)
    }

    $skip = ($Page - 1) * $PageSize
    $pageRows = @($Rows | Select-Object -Skip $skip -First $PageSize)
    $start = $skip + 1
    $end = $skip + $pageRows.Count

    Write-Host ("Page {0}/{1} (rows {2}-{3})" -f $Page, $pageCount, $start, $end)
    Write-Host ''

    $pageRows |
        Select-Object Region, ModelFormat, ModelName, ModelVersion, Publisher, SkuName, AvailableCapacity, AvailableFinetuneCapacity |
        Format-Table -AutoSize
}

if ($MyInvocation.BoundParameters.ContainsKey('Help')) {
    Show-Usage
    exit 0
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is not installed or not on PATH.'
}

try {
    $accountArgs = @('account', 'show', '-o', 'json')
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $accountArgs += @('--subscription', $SubscriptionId)
    }
    $subscription = Invoke-AzCliJson -Args $accountArgs
}
catch {
    throw 'You are not logged in, or the requested subscription is invalid. Run: az login'
}

$resolvedSubscriptionId = $subscription.id

Write-Host "Using subscription: $($subscription.name) ($resolvedSubscriptionId)" -ForegroundColor Cyan

$accounts = Invoke-AzCliJson -Args @('cognitiveservices', 'account', 'list', '-o', 'json')
$foundryAccounts = @(
    $accounts | Where-Object {
        $_.kind -in @('OpenAI', 'AIServices')
    }
)

if (-not $foundryAccounts -or $foundryAccounts.Count -eq 0) {
    throw 'No Microsoft.CognitiveServices accounts of kind OpenAI or AIServices were found in this subscription.'
}

Write-Host "Found $($foundryAccounts.Count) candidate Foundry/OpenAI resources." -ForegroundColor Cyan

$regionModelIndex = @{}

foreach ($acct in $foundryAccounts) {
    $rg = $acct.resourceGroup
    $name = $acct.name
    $acctRegion = $acct.location

    if (-not (Matches-Filter -Value $acctRegion -Filter $Region)) {
        continue
    }

    Write-Host "Discovering models for $name in $acctRegion..." -ForegroundColor DarkCyan

    try {
        $models = Invoke-AzCliJson -Args @(
            'cognitiveservices', 'account', 'list-models',
            '-g', $rg,
            '-n', $name,
            '-o', 'json'
        )
    }
    catch {
        Write-Warning "Could not list models for $name ($acctRegion): $($_.Exception.Message)"
        continue
    }

    foreach ($model in @($models)) {
        $discoveredModelName = [string](Get-NestedPropValue -Object $model -Names @('name', 'modelName'))
        $discoveredModelVersion = [string](Get-NestedPropValue -Object $model -Names @('version', 'modelVersion'))
        $discoveredModelFormat = [string](Get-NestedPropValue -Object $model -Names @('format', 'modelFormat'))
        $publisher = [string](Get-NestedPropValue -Object $model -Names @('publisher'))

        if ([string]::IsNullOrWhiteSpace($discoveredModelName) -or [string]::IsNullOrWhiteSpace($discoveredModelVersion)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($discoveredModelFormat)) {
            $discoveredModelFormat = 'OpenAI'
        }

        if (-not (Matches-Filter -Value $discoveredModelName -Filter $ModelName)) { continue }
        if (-not (Matches-Filter -Value $discoveredModelVersion -Filter $ModelVersion)) { continue }
        if (-not (Matches-Filter -Value $discoveredModelFormat -Filter $ModelFormat)) { continue }

        $key = "$acctRegion|$discoveredModelFormat|$discoveredModelName|$discoveredModelVersion"
        if (-not $regionModelIndex.ContainsKey($key)) {
            $regionModelIndex[$key] = [PSCustomObject]@{
                Region       = $acctRegion
                ModelFormat  = $discoveredModelFormat
                ModelName    = $discoveredModelName
                ModelVersion = $discoveredModelVersion
                Publisher    = $publisher
            }
        }
    }
}

if ($regionModelIndex.Count -eq 0) {
    throw 'No model/version pairs were discovered from your Foundry/OpenAI resources.'
}

Write-Host "Checking quota capacity for $($regionModelIndex.Count) region/model/version combinations with throttle $ThrottleLimit..." -ForegroundColor Cyan

$capacityInputs = @($regionModelIndex.Values | Sort-Object Region, ModelFormat, ModelName, ModelVersion)
$parallelResults = $capacityInputs | ForEach-Object -Parallel {
    $entry = $_
    $subscriptionId = $using:resolvedSubscriptionId
    $regionFilter = $using:Region
    $modelNameFilter = $using:ModelName
    $modelVersionFilter = $using:ModelVersion
    $modelFormatFilter = $using:ModelFormat
    $includeZeroQuota = $using:IncludeZeroQuota

    function Get-LocalPropValue {
        param($Object, [string[]]$Names)
        foreach ($name in $Names) {
            if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
                $value = $Object.$name
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                    return $value
                }
            }
        }
        return $null
    }

    function Matches-LocalFilter {
        param([string]$Value, [string]$Filter)
        if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }
        if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
        return $Value.ToLowerInvariant().Contains($Filter.ToLowerInvariant())
    }

    $encodedRegion = [uri]::EscapeDataString($entry.Region)
    $encodedFormat = [uri]::EscapeDataString($entry.ModelFormat)
    $encodedName = [uri]::EscapeDataString($entry.ModelName)
    $encodedVersion = [uri]::EscapeDataString($entry.ModelVersion)
    $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/locations/$encodedRegion/modelCapacities?api-version=2024-10-01&modelFormat=$encodedFormat&modelName=$encodedName&modelVersion=$encodedVersion"

    $capacityResponse = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $result = & az rest --method get --url $url --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace(($result -join "`n"))) {
                $capacityResponse = (($result -join "`n") | ConvertFrom-Json -Depth 100)
            }
            break
        }

        $text = ($result -join "`n")
        $shouldRetry = ($attempt -lt 3) -and ($text -match '429|TooManyRequests|Retry-After|temporar|timeout|5\d\d|InternalServerError|BadGateway|ServiceUnavailable|GatewayTimeout')
        if (-not $shouldRetry) {
            Write-Warning "Capacity lookup failed for $($entry.Region) / $($entry.ModelName) / $($entry.ModelVersion): $text"
            return
        }

        Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt)))
    }

    if ($null -eq $capacityResponse -or $null -eq $capacityResponse.value) {
        return
    }

    foreach ($item in @($capacityResponse.value)) {
        $itemProperties = $null
        if ($null -ne $item -and $item.PSObject.Properties.Name -contains 'properties') {
            $itemProperties = $item.properties
        }

        $itemModel = $null
        if ($null -ne $itemProperties -and $itemProperties.PSObject.Properties.Name -contains 'model') {
            $itemModel = $itemProperties.model
        }

        $available = Get-LocalPropValue -Object $itemProperties -Names @('availableCapacity')
        $availableFineTune = Get-LocalPropValue -Object $itemProperties -Names @('availableFinetuneCapacity')
        $skuName = Get-LocalPropValue -Object $itemProperties -Names @('skuName')
        $capModel = Get-LocalPropValue -Object $itemModel -Names @('name')
        $capVersion = Get-LocalPropValue -Object $itemModel -Names @('version')
        $capFormat = Get-LocalPropValue -Object $itemModel -Names @('format')
        $capPublisher = Get-LocalPropValue -Object $itemModel -Names @('publisher')
        $capRegion = [string]$item.location

        if (-not (Matches-LocalFilter -Value $capRegion -Filter $regionFilter)) { continue }
        if (-not (Matches-LocalFilter -Value $capModel -Filter $modelNameFilter)) { continue }
        if (-not (Matches-LocalFilter -Value $capVersion -Filter $modelVersionFilter)) { continue }
        if (-not (Matches-LocalFilter -Value $capFormat -Filter $modelFormatFilter)) { continue }

        if (-not $includeZeroQuota) {
            $hasQuota = ((($available -as [double]) -gt 0) -or (($availableFineTune -as [double]) -gt 0))
            if (-not $hasQuota) { continue }
        }

        [PSCustomObject]@{
            Region                    = $capRegion
            ModelFormat               = $capFormat
            ModelName                 = $capModel
            ModelVersion              = $capVersion
            Publisher                 = $capPublisher
            SkuName                   = $skuName
            AvailableCapacity         = $available
            AvailableFinetuneCapacity = $availableFineTune
        }
    }
} -ThrottleLimit $ThrottleLimit

$results = @(
    $parallelResults |
        Where-Object { $null -ne $_ } |
        Sort-Object Region, ModelName, ModelVersion, SkuName |
        Select-Object Region, ModelFormat, ModelName, ModelVersion, Publisher, SkuName, AvailableCapacity, AvailableFinetuneCapacity -Unique
)

Show-TextReport -Rows $results -PageSize $PageSize -Page $Page -NoPager:$NoPager -Interactive:$Interactive

if ($ExportCsv -and $results.Count -gt 0) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Saved CSV to $CsvPath" -ForegroundColor Green
}
