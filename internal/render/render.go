package render

import (
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"strings"

	"github.com/alspeirs/azpxr/internal/azure"
)

func JSON(w io.Writer, result *azure.ScanResult) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(result)
}

func Text(w io.Writer, result *azure.ScanResult) error {
	if _, err := fmt.Fprintf(w, "Subscription: %s\nRegions: %d | SKUs: %d\n\n", result.SubscriptionID, result.Summary.RegionCount, result.Summary.SKUCount); err != nil {
		return err
	}

	for _, region := range result.Regions {
		if _, err := fmt.Fprintf(w, "%s (%s)\n", region.Name, fallback(region.Display, region.Name)); err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "  SKUs: %d | Zones seen: %d\n", region.SKUCount, region.ZoneCount); err != nil {
			return err
		}
		for _, sku := range region.SKUs {
			zones := "-"
			if len(sku.Zones) > 0 {
				zones = strings.Join(sku.Zones, ",")
			}
			family := fallback(sku.Family, "-")
			vcpu := fallback(sku.Capabilities["vCPUs"], fallback(sku.Size, "-"))
			memory := fallback(sku.Capabilities["MemoryGB"], "-")
			if _, err := fmt.Fprintf(w, "  - %-20s family=%-16s vcpu=%-4s mem=%-6s zones=%s\n", sku.Name, family, vcpu, memory, zones); err != nil {
				return err
			}
		}
		if _, err := io.WriteString(w, "\n"); err != nil {
			return err
		}
	}
	return nil
}

func HTML(w io.Writer, result *azure.ScanResult) error {
	const page = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>azpxr</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2rem; background: #0b1020; color: #edf2f7; }
    h1,h2,h3 { margin-bottom: 0.4rem; }
    .muted { color: #a0aec0; }
    .region { border: 1px solid #2d3748; border-radius: 12px; padding: 1rem; margin: 1rem 0; background: #111827; }
    table { width: 100%; border-collapse: collapse; margin-top: 0.75rem; font-size: 0.95rem; }
    th, td { text-align: left; padding: 0.5rem; border-bottom: 1px solid #253047; vertical-align: top; }
    th { color: #93c5fd; }
    .pill { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 999px; background: #1f2937; border: 1px solid #334155; margin-right: 0.3rem; }
  </style>
</head>
<body>
  <h1>azpxr</h1>
  <p class="muted">Subscription: {{ .SubscriptionID }} · Regions: {{ .Summary.RegionCount }} · SKUs: {{ .Summary.SKUCount }}</p>
  {{ range .Regions }}
    <section class="region">
      <h2>{{ .Name }}</h2>
      <div class="muted">{{ if .Display }}{{ .Display }}{{ else }}{{ .Name }}{{ end }} · {{ .SKUCount }} SKUs · {{ .ZoneCount }} zones seen</div>
      <table>
        <thead>
          <tr>
            <th>SKU</th>
            <th>Family</th>
            <th>vCPUs</th>
            <th>Memory GB</th>
            <th>Zones</th>
            <th>Restrictions</th>
          </tr>
        </thead>
        <tbody>
        {{ range .SKUs }}
          <tr>
            <td>{{ .Name }}</td>
            <td>{{ .Family }}</td>
            <td>{{ index .Capabilities "vCPUs" }}</td>
            <td>{{ index .Capabilities "MemoryGB" }}</td>
            <td>
              {{ if .Zones }}
                {{ range .Zones }}<span class="pill">{{ . }}</span>{{ end }}
              {{ else }}-
              {{ end }}
            </td>
            <td>
              {{ if .Restrictions }}
                {{ range .Restrictions }}<span class="pill">{{ . }}</span>{{ end }}
              {{ else }}-
              {{ end }}
            </td>
          </tr>
        {{ end }}
        </tbody>
      </table>
    </section>
  {{ end }}
</body>
</html>`

	tmpl, err := template.New("page").Parse(page)
	if err != nil {
		return err
	}
	return tmpl.Execute(w, result)
}

func fallback(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
