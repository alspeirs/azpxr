# azpxr

azpxr summarizes Azure VM availability for a given subscription by region and availability zone.

It provides:
- a CLI interface for querying and summarizing VM SKUs
- a simple HTML view for browsing the same information

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

### Scan and print a text summary

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

## Environment

You can omit `--subscription` if this is set:

```bash
export AZURE_SUBSCRIPTION_ID=<subscription-id>
```

## Notes

- Data comes from Azure Resource SKU metadata and subscription locations.
- Zone information depends on what Azure exposes for each SKU/location.
- Restricted SKUs are excluded by default; add `--include-restricted` to include them.

## Likely next steps

- richer CLI formatting
- paging / top-N views for large subscriptions
- static HTML export improvements
- quota awareness
- filters for vCPU, memory, GPU, ephemeral disk, spot support
