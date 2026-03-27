# azpxr

azpxr is a simple tool that summarizes the VM sizes available to a given Azure account by region and availability zone.

It provides:

- a CLI interface for querying and summarizing VM availability
- a simple HTML view for browsing the same information

## Goals

- Authenticate against Azure
- Enumerate regions available to the current subscription/account
- Enumerate VM sizes by region
- Show zone-level availability where possible
- Present the data in:
  - terminal-friendly CLI output
  - a lightweight HTML interface

## Proposed MVP

1. Authenticate using Azure CLI or DefaultAzureCredential
2. Accept a subscription ID or use the active Azure CLI context
3. Query Azure Compute APIs for VM size and SKU availability
4. Group results by:
   - region
   - zone
   - VM family / SKU
5. Render:
   - CLI table / text summary
   - HTML report or tiny local web app

## Proposed Tech

- Language: Go
- Azure SDK: Azure Resource Manager / Compute SDK
- HTML: server-rendered templates with minimal JS

## Initial CLI ideas

```bash
azpxr scan --subscription <id>
azpxr scan --region westus2
azpxr serve --subscription <id> --listen :8080
azpxr export --format json
```

## Questions to settle

- Should we support multiple subscriptions in the first version?
- Should the HTML mode be a static report or a live local web server?
- Do we need quota/usage visibility, or just available VM sizes/SKUs?
- How should restricted/preview SKUs be shown?
