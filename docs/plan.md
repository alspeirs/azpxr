# azpxr plan

## Problem
Azure makes it awkward to quickly see which VM SKUs are available in which regions and zones for a specific account/subscription.

## MVP scope
- Resolve current subscription context
- Query available regions for the subscription
- Query VM SKUs/sizes per region
- Surface zone support when available
- Output:
  - CLI summary
  - simple HTML view

## Nice-to-have later
- Export JSON/CSV
- Filters by family, vCPU, memory, GPU
- Quota awareness
- Spot / ephemeral OS disk flags
- Diff between subscriptions

## Data model
- Subscription
- Region
- Zone
- SKU
- Capabilities
- Restrictions

## Candidate commands
- `azpxr scan`
- `azpxr serve`
- `azpxr export`

## Candidate outputs
- Human-readable CLI summary
- JSON for automation
- HTML dashboard for quick browsing
