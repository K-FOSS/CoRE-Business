package main

import (
	"encoding/xml"
	"errors"
	"os"
	"strings"
)

// Init-container mode writes credential-bearing XML to an emptyDir, never to
// a rendered ConfigMap, logs, an image layer or the browser.
func renderFreeSwitchConfig() error {
	token := os.Getenv("AVOIP_ROUTING_TOKEN")
	base := os.Getenv("AVOIP_ADMIN_INTERNAL_URL")
	if len(token) < 16 || !strings.HasPrefix(base, "http://") {
		return errors.New("routing credentials or URL unavailable")
	}
	var escaped strings.Builder
	xml.EscapeText(&escaped, []byte("routing:"+token))
	config := `<configuration name="xml_curl.conf" description="CoRE managed dialplan"><bindings><binding name="core-managed"><param name="gateway-url" value="` + base + `/routing/freeswitch" bindings="dialplan"/><param name="gateway-credentials" value="` + escaped.String() + `"/><param name="auth-scheme" value="basic"/><param name="timeout" value="1"/><param name="disable-100-continue" value="true"/></binding></bindings></configuration>`
	return os.WriteFile("/config/xml_curl.conf.xml", []byte(config), 0600)
}
