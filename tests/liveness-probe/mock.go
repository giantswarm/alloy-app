// Mock of the Alloy web API and of a Mimir ruler config API, used by
// run-tests.sh to exercise scripts/mimir-rules-liveness-probe.sh.
//
// The JSON served by the components endpoints mirrors what Alloy itself emits:
// componentDetail matches internal/component/component_provider.go, jsonAttr
// and jsonValue match syntax/encoding/alloyjson/types.go, and writeJSON gzips
// exactly like the CompressionHandler Alloy wraps its handlers with. The probe
// parses those responses by hand, so the field names and their order matter.
//
// The ruler is served both in plain HTTP and, from a self-signed certificate
// generated on startup, over TLS, so that both probe transports are exercised.
//
// Every listener binds an ephemeral port and their addresses are printed on
// stdout, so concurrent runs never collide. Component addresses may therefore
// not be known upfront: the RULER, RULER_LOCALHOST and RULER_TLS placeholders
// are replaced with the ruler address once it is bound.
package main

import (
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"strings"
	"time"
)

// rulerRulesPath is the ruler config API, which the probe uses to tell a Mimir
// that is down from an Alloy that is stuck.
const rulerRulesPath = "/prometheus/config/v1/rules"

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
	rulerStatus := flag.Int("ruler-status", http.StatusOK, "status code returned by the ruler config API to an authenticated request")
	rulerAuth := flag.String("ruler-auth", "", "basic auth user:password the ruler config API requires, empty to require none")
	rulerTenant := flag.String("ruler-tenant", "", "X-Scope-OrgID the ruler config API requires, empty to require none")
	hang := flag.Bool("hang", false, "accept requests on the Alloy API but never answer them")
	tenantID := flag.String("tenant-id", "anonymous", "tenant_id argument reported for every component")
	chunked := flag.Bool("chunked", false, "flush the Alloy API responses, so they are framed as chunked")
	flag.Var(&comps, "component", "mimir.rules.kubernetes component to serve, as label=health=address")
	flag.Parse()

	rulerListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	rulerTLSListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	alloyListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	rulerAddr := rulerListener.Addr().String()
	rulerTLSAddr := rulerTLSListener.Addr().String()

	details := map[string]componentDetail{}
	var list []componentDetail
	for _, c := range comps {
		parts := strings.SplitN(c, "=", 3)
		if len(parts) != 3 {
			log.Fatalf("malformed -component %q, want label=health=address", c)
		}
		address := strings.NewReplacer(
			"RULER_LOCALHOST", "http://localhost:"+portOf(rulerAddr),
			"RULER_TLS", "https://"+rulerTLSAddr,
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
				{Name: "tenant_id", Type: "attr", Value: jsonValue{Type: "string", Value: *tenantID}},
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
		writeJSON(w, r, *chunked, list)
	})
	alloy.HandleFunc("/api/v0/web/components/", func(w http.ResponseWriter, r *http.Request) {
		d, ok := details[strings.TrimPrefix(r.URL.Path, "/api/v0/web/components/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, r, *chunked, d)
	})

	ruler := http.NewServeMux()
	ruler.HandleFunc(rulerRulesPath, func(w http.ResponseWriter, r *http.Request) {
		// A Mimir behind a gateway answers 401 at the edge, without ever
		// asking the ruler, so an unauthenticated request says nothing about
		// whether the ruler is up.
		if *rulerAuth != "" {
			user, pass, ok := r.BasicAuth()
			if !ok || user+":"+pass != *rulerAuth {
				w.WriteHeader(http.StatusUnauthorized)
				fmt.Fprintln(w, "unauthorized")
				return
			}
		}
		if *rulerTenant != "" && r.Header.Get("X-Scope-OrgID") != *rulerTenant {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprintln(w, "wrong tenant")
			return
		}
		w.WriteHeader(*rulerStatus)
		fmt.Fprintln(w, "rules")
	})

	fmt.Printf("ruler=%s\nruler_tls=%s\nalloy=%s\n", rulerAddr, rulerTLSAddr, alloyListener.Addr())

	go func() { log.Fatal(http.Serve(rulerListener, ruler)) }()
	go func() {
		l := tls.NewListener(rulerTLSListener, &tls.Config{Certificates: []tls.Certificate{selfSigned()}})
		log.Fatal(http.Serve(l, ruler))
	}()
	log.Fatal(http.Serve(alloyListener, alloy))
}

// selfSigned builds a throwaway certificate for 127.0.0.1. The probe checks
// that the ruler answers at all, not who it is, so it does not verify the chain.
func selfSigned() tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatal(err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "mock-mimir-ruler"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		log.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func portOf(addr string) string {
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		log.Fatal(err)
	}
	return port
}

// writeJSON mimics Alloy's CompressionHandler: gzip when the client asks for it.
// Flushing first leaves the response without a Content-Length, so that Go frames
// it in chunks the way Alloy does for its larger payloads.
func writeJSON(w http.ResponseWriter, r *http.Request, chunked bool, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if chunked {
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
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
