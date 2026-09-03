// Mock of the Alloy web API and of a Mimir ruler readiness endpoint, used by
// run-tests.sh to exercise scripts/mimir-rules-liveness-probe.sh.
//
// The JSON served by the components endpoints mirrors what Alloy itself emits:
// componentDetail matches internal/component/component_provider.go, jsonAttr
// and jsonValue match syntax/encoding/alloyjson/types.go, and writeJSON gzips
// exactly like the CompressionHandler Alloy wraps its handlers with. The probe
// parses those responses by hand, so the field names and their order matter.
//
// Both listeners bind an ephemeral port and their addresses are printed on
// stdout, so concurrent runs never collide. Component addresses may therefore
// not be known upfront: the RULER and RULER_LOCALHOST placeholders are replaced
// with the ruler address once it is bound.
package main

import (
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
)

type health struct {
	State       string `json:"state"`
	Message     string `json:"message"`
	UpdatedTime string `json:"updatedTime"`
}

type jsonValue struct {
	Type  string `json:"type"`
	Value any    `json:"value"`
}

type jsonAttr struct {
	Name  string    `json:"name"`
	Type  string    `json:"type"`
	Value jsonValue `json:"value"`
}

type componentDetail struct {
	Name         string     `json:"name"`
	Type         string     `json:"type,omitempty"`
	LocalID      string     `json:"localID"`
	ModuleID     string     `json:"moduleID"`
	Label        string     `json:"label,omitempty"`
	References   []string   `json:"referencesTo"`
	ReferencedBy []string   `json:"referencedBy"`
	Health       *health    `json:"health"`
	Original     string     `json:"original"`
	Arguments    []jsonAttr `json:"arguments,omitempty"`
}

// specs holds the repeatable -component flag, each "label=health=address".
type specs []string

func (s *specs) String() string     { return strings.Join(*s, ",") }
func (s *specs) Set(v string) error { *s = append(*s, v); return nil }

func main() {
	var comps specs
	rulerStatus := flag.Int("ruler-status", http.StatusOK, "status code returned by the ruler /ready endpoint")
	hang := flag.Bool("hang", false, "accept requests on the Alloy API but never answer them")
	flag.Var(&comps, "component", "mimir.rules.kubernetes component to serve, as label=health=address")
	flag.Parse()

	rulerListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	alloyListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	rulerAddr := rulerListener.Addr().String()

	details := map[string]componentDetail{}
	var list []componentDetail
	for _, c := range comps {
		parts := strings.SplitN(c, "=", 3)
		if len(parts) != 3 {
			log.Fatalf("malformed -component %q, want label=health=address", c)
		}
		address := strings.NewReplacer(
			"RULER_LOCALHOST", "http://localhost:"+portOf(rulerAddr),
			"RULER", "http://"+rulerAddr,
		).Replace(parts[2])

		d := componentDetail{
			Name:         "mimir.rules.kubernetes",
			LocalID:      "mimir.rules.kubernetes." + parts[0],
			Label:        parts[0],
			References:   []string{},
			ReferencedBy: []string{},
			Health:       &health{State: parts[1], Message: "boom", UpdatedTime: "2026-09-01T00:00:00Z"},
			Arguments: []jsonAttr{
				{Name: "address", Type: "attr", Value: jsonValue{Type: "string", Value: address}},
				{Name: "tenant_id", Type: "attr", Value: jsonValue{Type: "string", Value: "anonymous"}},
			},
		}
		details[d.LocalID] = d
		list = append(list, d)
	}
	// An unhealthy component of another type, so that a probe matching on
	// health alone rather than on the component name would be caught.
	list = append(list, componentDetail{
		Name:    "prometheus.remote_write",
		LocalID: "prometheus.remote_write.default",
		Health:  &health{State: "unhealthy"},
	})

	alloy := http.NewServeMux()
	alloy.HandleFunc("/api/v0/web/components", func(w http.ResponseWriter, r *http.Request) {
		if *hang {
			<-r.Context().Done()
			return
		}
		writeJSON(w, r, list)
	})
	alloy.HandleFunc("/api/v0/web/components/", func(w http.ResponseWriter, r *http.Request) {
		d, ok := details[strings.TrimPrefix(r.URL.Path, "/api/v0/web/components/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, r, d)
	})

	ruler := http.NewServeMux()
	ruler.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(*rulerStatus)
		fmt.Fprintln(w, "ready")
	})

	fmt.Printf("ruler=%s\nalloy=%s\n", rulerAddr, alloyListener.Addr())

	go func() { log.Fatal(http.Serve(rulerListener, ruler)) }()
	log.Fatal(http.Serve(alloyListener, alloy))
}

func portOf(addr string) string {
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		log.Fatal(err)
	}
	return port
}

// writeJSON mimics Alloy's CompressionHandler: gzip when the client asks for it.
func writeJSON(w http.ResponseWriter, r *http.Request, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		defer gz.Close()
		_, _ = gz.Write(b)
		return
	}
	_, _ = w.Write(b)
}
