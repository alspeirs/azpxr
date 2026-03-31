# azpxr

azpxr stands for **Azure Products By Region**.

Today, the Go CLI in this repo focuses on **Azure VM availability by region and availability zone**. The PowerShell companions now split by product area so the naming is less muddy.

It provides:
- a Go CLI interface for querying and summarizing Azure VM SKUs
- single-file PowerShell CLIs for specific Azure product areas
- a simple HTML view for browsing VM availability information

## What it does today

MVP features:
- authenticates with Azure using `DefaultAzureCredential`
- lists VM SKUs from Azure Resource SKUs for a subscription
- derives available regions from returned SKU metadata
- groups results by region
- surfaces zone support when Azure returns it
- renders output as text, JSON, or HTML
- serves a lightweight local web view

## Requirements

- Go 1.22+
- Azure access to the target subscription
- authentication via one of:
  - `az login`
  - environment credentials
  - managed identity

## Build

```bash
go mod tidy
go build ./cmd/azpxr
```

## Usage

### Go CLI: scan and print a text summary

```bash
azpxr scan --subscription <subscription-id>
```

### Limit to a region

```bash
azpxr scan --subscription <subscription-id> --region westus2
```

### Filter by family or SKU name

```bash
azpxr scan --subscription <subscription-id> --family dsv5
```

### Emit JSON

```bash
azpxr scan --subscription <subscription-id> --format json
```

### Emit HTML to stdout or file

```bash
azpxr export --subscription <subscription-id> --format html --out report.html
```

### Run the local HTML server

```bash
azpxr serve --subscription <subscription-id> --listen :8080
```

Then open:
- `http://localhost:8080/`
- `http://localhost:8080/data.json`

## PowerShell scripts

The repo also includes single-file PowerShell versions:

- `azvmxr.ps1` for **Azure VM** SKU availability by region/zone
- `azfmxr.ps1` for **Azure Foundry Models** quota/capacity by region

```powershell
./azvmxr.ps1 scan -Subscription <subscription-id>
```

Examples:

```powershell
# Region summary only
./azvmxr.ps1 scan -Subscription <subscription-id> -RegionsOnly

# First page of West US 2 Dsv5-family SKUs
./azvmxr.ps1 scan -Subscription <subscription-id> -Region westus2 -Family dsv5 -PageSize 25 -Page 1

# Filter by SKU name substring and sort by CPU descending
./azvmxr.ps1 scan -Subscription <subscription-id> -Sku NC -SortByCpu -Descending

# Interactive paging: Enter for next page, q to quit
./azvmxr.ps1 scan -Subscription <subscription-id> -Interactive -PageSize 25

# Print everything without paging
./azvmxr.ps1 scan -Subscription <subscription-id> -NoPager

# Emit JSON instead of table output
./azvmxr.ps1 scan -Subscription <subscription-id> -Format json
```

`azvmxr.ps1` is designed for console-only use and supports:
- region filtering
- family filtering
- SKU name filtering
- restricted SKU inclusion
- page size / page number
- interactive paging in the terminal
- top-N limiting
- sort by CPU or memory
- JSON output when needed

### azfmxr.ps1

`azfmxr.ps1` discovers Azure Foundry / OpenAI model quota by region for the current subscription.

Examples:

```powershell
# Basic run against current Azure CLI subscription
./azfmxr.ps1

# Limit to one region or model
./azfmxr.ps1 -Region eastus -ModelName gpt-4o

# Show interactive paging in the terminal
./azfmxr.ps1 -Interactive -PageSize 25

# Tune parallel ARM lookups
./azfmxr.ps1 -ThrottleLimit 8

# Include zero-capacity entries and export CSV
./azfmxr.ps1 -IncludeZeroQuota -ExportCsv -CsvPath .\foundry-region-model-quota.csv
```

`azfmxr.ps1` supports:
- optional subscription selection
- discovery of OpenAI and AIServices Cognitive Services accounts
- model and version discovery from those resources
- regional capacity lookup via ARM
- filtering by region, model name, model version, and model format
- interactive or fixed paging in the terminal
- bounded parallel ARM lookups via `-ThrottleLimit`
- optional CSV export

## Environment

You can omit `--subscription` if this is set:

```bash
export AZURE_SUBSCRIPTION_ID=<subscription-id>
```

## Notes

- Data comes from Azure Resource SKU metadata and subscription locations.
- Zone information depends on what Azure exposes for each SKU/location.
- Restricted SKUs are excluded by default; add `--include-restricted` to include them.

## Naming

- `azpxr` = **Azure Products By Region**
- `azvmxr` = **Azure VMs By Region**
- `azfmxr` = **Azure Foundry Models By Region**

## Likely next steps

- add more product-specific companions under the azpxr umbrella
- richer CLI formatting
- paging / top-N views for large subscriptions
- static HTML export improvements
- quota awareness
- filters for vCPU, memory, GPU, ephemeral disk, spot support
