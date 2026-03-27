package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/alspeirs/azpxr/internal/azure"
	"github.com/alspeirs/azpxr/internal/render"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "scan":
		must(runScan(os.Args[2:]))
	case "serve":
		must(runServe(os.Args[2:]))
	case "export":
		must(runExport(os.Args[2:]))
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", os.Args[1])
		usage()
		os.Exit(1)
	}
}

func runScan(args []string) error {
	fs := flag.NewFlagSet("scan", flag.ExitOnError)
	opts, format := addSharedFlags(fs)
	fs.Parse(args)

	result, err := scan(context.Background(), *opts)
	if err != nil {
		return err
	}
	return renderByFormat(os.Stdout, result, *format)
}

func runExport(args []string) error {
	fs := flag.NewFlagSet("export", flag.ExitOnError)
	opts, format := addSharedFlags(fs)
	out := fs.String("out", "", "write output to file instead of stdout")
	fs.Parse(args)

	result, err := scan(context.Background(), *opts)
	if err != nil {
		return err
	}

	writer := os.Stdout
	if strings.TrimSpace(*out) != "" {
		f, err := os.Create(*out)
		if err != nil {
			return fmt.Errorf("create output file: %w", err)
		}
		defer f.Close()
		writer = f
	}
	return renderByFormat(writer, result, *format)
}

func runServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	opts, _ := addSharedFlags(fs)
	listen := fs.String("listen", ":8080", "listen address")
	refresh := fs.Duration("refresh", 0, "optional refresh interval, e.g. 5m")
	fs.Parse(args)

	cache := struct {
		result *azure.ScanResult
		at     time.Time
	}{}

	load := func(ctx context.Context) (*azure.ScanResult, error) {
		if cache.result != nil && (*refresh == 0 || time.Since(cache.at) < *refresh) {
			return cache.result, nil
		}
		result, err := scan(ctx, *opts)
		if err != nil {
			return nil, err
		}
		cache.result = result
		cache.at = time.Now()
		return result, nil
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		result, err := load(r.Context())
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := render.HTML(w, result); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})
	mux.HandleFunc("/data.json", func(w http.ResponseWriter, r *http.Request) {
		result, err := load(r.Context())
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := render.JSON(w, result); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	srv := &http.Server{Addr: *listen, Handler: mux}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("azpxr serving on %s", *listen)
	return srv.ListenAndServe()
}

func scan(ctx context.Context, opts azure.ScanOptions) (*azure.ScanResult, error) {
	if strings.TrimSpace(opts.SubscriptionID) == "" {
		opts.SubscriptionID = os.Getenv("AZURE_SUBSCRIPTION_ID")
	}
	if strings.TrimSpace(opts.SubscriptionID) == "" {
		return nil, fmt.Errorf("subscription required: pass --subscription or set AZURE_SUBSCRIPTION_ID")
	}
	scanner, err := azure.NewScanner()
	if err != nil {
		return nil, err
	}
	return scanner.Scan(ctx, opts)
}

func addSharedFlags(fs *flag.FlagSet) (*azure.ScanOptions, *string) {
	opts := &azure.ScanOptions{}
	fs.StringVar(&opts.SubscriptionID, "subscription", "", "Azure subscription ID")
	fs.StringVar(&opts.Region, "region", "", "limit to a single Azure region")
	fs.StringVar(&opts.FamilyFilter, "family", "", "filter by VM family or SKU substring")
	fs.BoolVar(&opts.IncludeRestricted, "include-restricted", false, "include restricted SKUs")
	format := fs.String("format", "text", "output format: text|json|html")
	return opts, format
}

func renderByFormat(w io.Writer, result *azure.ScanResult, format string) error {
	switch strings.ToLower(strings.TrimSpace(format)) {
	case "text", "txt", "":
		return render.Text(w, result)
	case "json":
		return render.JSON(w, result)
	case "html":
		return render.HTML(w, result)
	default:
		return fmt.Errorf("unsupported format %q", format)
	}
}

func usage() {
	fmt.Print(`azpxr - Azure VM availability summary

Usage:
  azpxr scan   --subscription <id> [--region westus2] [--format text|json|html]
  azpxr serve  --subscription <id> [--region westus2] [--listen :8080]
  azpxr export --subscription <id> [--format json] [--out report.json]

Environment:
  AZURE_SUBSCRIPTION_ID   default subscription when --subscription is omitted

Authentication:
  Uses Azure DefaultAzureCredential. In practice this usually means one of:
  - az login
  - environment credentials
  - managed identity
`)
}

func must(err error) {
	if err == nil {
		return
	}
	if err == http.ErrServerClosed {
		return
	}
	log.Fatal(err)
}
