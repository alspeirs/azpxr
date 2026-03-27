package azure

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v6"
)

type Scanner struct {
	cred azcore.TokenCredential
}

type ScanOptions struct {
	SubscriptionID    string
	Region            string
	FamilyFilter      string
	IncludeRestricted bool
}

type ScanResult struct {
	SubscriptionID string     `json:"subscriptionId"`
	Regions        []RegionVM `json:"regions"`
	Summary        Summary    `json:"summary"`
}

type RegionVM struct {
	Name      string  `json:"name"`
	Display   string  `json:"displayName"`
	ZoneCount int     `json:"zoneCount"`
	SKUCount  int     `json:"skuCount"`
	SKUs      []SKUVM `json:"skus"`
}

type SKUVM struct {
	Name         string            `json:"name"`
	Tier         string            `json:"tier,omitempty"`
	Size         string            `json:"size,omitempty"`
	Family       string            `json:"family,omitempty"`
	Locations    []string          `json:"locations,omitempty"`
	Zones        []string          `json:"zones,omitempty"`
	Capabilities map[string]string `json:"capabilities,omitempty"`
	Restrictions []string          `json:"restrictions,omitempty"`
}

type Summary struct {
	RegionCount int `json:"regionCount"`
	SKUCount    int `json:"skuCount"`
}

func NewScanner() (*Scanner, error) {
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("create Azure credential: %w", err)
	}
	return &Scanner{cred: cred}, nil
}

func (s *Scanner) Scan(ctx context.Context, opts ScanOptions) (*ScanResult, error) {
	if strings.TrimSpace(opts.SubscriptionID) == "" {
		return nil, fmt.Errorf("subscription ID is required")
	}

	skuClient, err := armcompute.NewResourceSKUsClient(opts.SubscriptionID, s.cred, nil)
	if err != nil {
		return nil, fmt.Errorf("create resource SKU client: %w", err)
	}

	wantedRegion := strings.ToLower(strings.TrimSpace(opts.Region))
	regionMap := map[string]*RegionVM{}

	pager := skuClient.NewListPager(nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list Azure SKUs: %w", err)
		}

		for _, item := range page.Value {
			if item == nil || item.ResourceType == nil || item.Name == nil {
				continue
			}
			if !strings.EqualFold(ptr(item.ResourceType), "virtualMachines") {
				continue
			}

			locations := normalizeLocations(item.Locations)
			if len(locations) == 0 {
				continue
			}

			restrictions := collectRestrictions(item.Restrictions)
			if len(restrictions) > 0 && !opts.IncludeRestricted {
				continue
			}

			family := ptr(item.Family)
			if opts.FamilyFilter != "" && !strings.Contains(strings.ToLower(family), strings.ToLower(opts.FamilyFilter)) && !strings.Contains(strings.ToLower(ptr(item.Name)), strings.ToLower(opts.FamilyFilter)) {
				continue
			}

			for _, region := range locations {
				if wantedRegion != "" && region != wantedRegion {
					continue
				}
				bucket := regionMap[region]
				if bucket == nil {
					bucket = &RegionVM{Name: region, Display: region}
					regionMap[region] = bucket
				}

				sku := SKUVM{
					Name:         ptr(item.Name),
					Tier:         ptr(item.Tier),
					Size:         capabilityValue(item.Capabilities, "vCPUs"),
					Family:       family,
					Locations:    locations,
					Zones:        normalizeZones(item.LocationInfo, region),
					Capabilities: collectCapabilities(item.Capabilities),
					Restrictions: restrictions,
				}
				bucket.SKUs = append(bucket.SKUs, sku)
			}
		}
	}

	regions := make([]string, 0, len(regionMap))
	for region := range regionMap {
		regions = append(regions, region)
	}
	sort.Strings(regions)

	if wantedRegion != "" && len(regions) == 0 {
		return nil, fmt.Errorf("region %q not found in returned SKU data for subscription %s", opts.Region, opts.SubscriptionID)
	}

	result := &ScanResult{SubscriptionID: opts.SubscriptionID}
	for _, region := range regions {
		bucket := regionMap[region]
		sort.Slice(bucket.SKUs, func(i, j int) bool {
			return bucket.SKUs[i].Name < bucket.SKUs[j].Name
		})
		bucket.SKUCount = len(bucket.SKUs)
		zoneSet := map[string]struct{}{}
		for _, sku := range bucket.SKUs {
			for _, zone := range sku.Zones {
				zoneSet[zone] = struct{}{}
			}
		}
		bucket.ZoneCount = len(zoneSet)
		result.Summary.SKUCount += bucket.SKUCount
		result.Regions = append(result.Regions, *bucket)
	}
	result.Summary.RegionCount = len(result.Regions)

	return result, nil
}

func normalizeLocations(locations []*string) []string {
	var out []string
	for _, loc := range locations {
		if loc == nil {
			continue
		}
		out = append(out, strings.ToLower(*loc))
	}
	sort.Strings(out)
	return out
}

func normalizeZones(info []*armcompute.ResourceSKULocationInfo, region string) []string {
	set := map[string]struct{}{}
	for _, entry := range info {
		if entry == nil || entry.Location == nil {
			continue
		}
		if strings.ToLower(*entry.Location) != region {
			continue
		}
		for _, zone := range entry.Zones {
			if zone == nil {
				continue
			}
			set[*zone] = struct{}{}
		}
	}
	zones := make([]string, 0, len(set))
	for zone := range set {
		zones = append(zones, zone)
	}
	sort.Strings(zones)
	return zones
}

func collectCapabilities(caps []*armcompute.ResourceSKUCapabilities) map[string]string {
	out := map[string]string{}
	for _, cap := range caps {
		if cap == nil || cap.Name == nil || cap.Value == nil {
			continue
		}
		out[*cap.Name] = *cap.Value
	}
	return out
}

func capabilityValue(caps []*armcompute.ResourceSKUCapabilities, name string) string {
	for _, cap := range caps {
		if cap == nil || cap.Name == nil || cap.Value == nil {
			continue
		}
		if strings.EqualFold(*cap.Name, name) {
			return *cap.Value
		}
	}
	return ""
}

func collectRestrictions(items []*armcompute.ResourceSKURestrictions) []string {
	var out []string
	for _, item := range items {
		if item == nil {
			continue
		}
		parts := []string{}
		if item.Type != nil {
			parts = append(parts, string(*item.Type))
		}
		if item.ReasonCode != nil {
			parts = append(parts, string(*item.ReasonCode))
		}
		if len(parts) > 0 {
			out = append(out, strings.Join(parts, ":"))
		}
	}
	sort.Strings(out)
	return out
}

func ptr[T ~string](v *T) string {
	if v == nil {
		return ""
	}
	return string(*v)
}
