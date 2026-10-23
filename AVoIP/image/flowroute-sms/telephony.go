package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type telephonyStatus struct {
	Name   string `json:"name"`
	State  string `json:"state"`
	Detail string `json:"detail,omitempty"`
}

type liveCall struct {
	System    string    `json:"system"`
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Caller    string    `json:"caller"`
	Called    string    `json:"called"`
	State     string    `json:"state"`
	StartedAt time.Time `json:"started_at,omitempty"`
}

type cdrRecord struct {
	System      string    `json:"system"`
	StartedAt   time.Time `json:"started_at"`
	Caller      string    `json:"caller"`
	Called      string    `json:"called"`
	Duration    int64     `json:"duration"`
	Disposition string    `json:"disposition"`
}

func telephonyEnv(name string) string { return strings.TrimSpace(os.Getenv(name)) }

// controlTargets expands a headless Service into every currently published
// pod endpoint while retaining support for explicit single-endpoint overrides.
func controlTargets(ctx context.Context, address string) []string {
	address = strings.TrimSpace(address)
	if address == "" {
		return nil
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil || host == "" || net.ParseIP(host) != nil {
		return []string{address}
	}
	ips, err := net.DefaultResolver.LookupHost(ctx, host)
	if err != nil || len(ips) == 0 {
		return []string{address}
	}
	out := make([]string, 0, len(ips))
	for _, ip := range ips {
		out = append(out, net.JoinHostPort(ip, port))
	}
	return out
}

func kamailioControlTargets(ctx context.Context) []string {
	var configured []string
	if json.Unmarshal([]byte(telephonyEnv("AVOIP_KAMAILIO_CONTROL_ADDRESSES")), &configured) != nil {
		return nil
	}
	var out []string
	for _, address := range configured {
		out = append(out, controlTargets(ctx, address)...)
	}
	return out
}

func safeInterfaceError(err error) string {
	if err == nil {
		return ""
	}
	if strings.Contains(strings.ToLower(err.Error()), "not configured") {
		return "Not configured"
	}
	return "Connection or query failed"
}

// telephonyErrorClass is deliberately coarse: it gives operators enough
// information to diagnose the private control path without putting ESL
// addresses, credentials, or dial strings in logs.
func telephonyErrorClass(err error) string {
	if err == nil {
		return ""
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "authentication") || strings.Contains(message, "auth"):
		return "authentication_failed"
	case strings.Contains(message, "deadline") || strings.Contains(message, "timeout"):
		return "connection_timeout"
	case strings.Contains(message, "connect") || strings.Contains(message, "dial"):
		return "connection_failed"
	case strings.Contains(message, "command") || strings.Contains(message, "-err"):
		return "command_rejected"
	default:
		return "control_path_failed"
	}
}

func (s *server) telephony(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	result := map[string]any{"site": telephonyEnv("AVOIP_SITE"), "checked_at": time.Now().UTC(), "systems": []telephonyStatus{}, "calls": []liveCall{}, "cdr": []cdrRecord{}}
	var systems []telephonyStatus
	var calls []liveCall
	var cdr []cdrRecord
	if host := telephonyEnv("AVOIP_AMI_ADDRESS"); host != "" {
		var amiCalls []liveCall
		var err error
		connected := false
		for _, target := range controlTargets(ctx, host) {
			current, currentErr := asteriskCalls(ctx, target, telephonyEnv("AVOIP_AMI_USERNAME"), telephonyEnv("AVOIP_AMI_SECRET"))
			if currentErr == nil {
				connected = true
				amiCalls = append(amiCalls, current...)
			} else {
				err = currentErr
			}
		}
		if connected {
			err = nil
		}
		state := "connected"
		if err != nil {
			state = "unavailable"
		} else {
			calls = append(calls, amiCalls...)
		}
		detail := ""
		if err != nil {
			detail = safeInterfaceError(err)
		}
		systems = append(systems, telephonyStatus{Name: "Asterisk AMI", State: state, Detail: detail})
	} else {
		systems = append(systems, telephonyStatus{Name: "Asterisk AMI", State: "not configured"})
	}
	if address := telephonyEnv("AVOIP_ESL_ADDRESS"); address != "" {
		var err error
		connected := false
		for _, target := range controlTargets(ctx, address) {
			if _, currentErr := freeSwitchStatus(ctx, target, telephonyEnv("AVOIP_ESL_SECRET")); currentErr == nil {
				connected = true
			} else {
				err = currentErr
			}
			if currentCalls, currentErr := freeSwitchCalls(ctx, target, telephonyEnv("AVOIP_ESL_SECRET")); currentErr == nil {
				calls = append(calls, currentCalls...)
			}
		}
		if connected {
			err = nil
		}
		state := "connected"
		if err != nil {
			s.logger.Warn("freeswitch event socket health check failed", "reason", telephonyErrorClass(err), "detail", safeInterfaceError(err))
			state = "unavailable"
		}
		detail := ""
		if err != nil {
			detail = safeInterfaceError(err)
		}
		systems = append(systems, telephonyStatus{Name: "FreeSWITCH Event Socket", State: state, Detail: detail})
	} else {
		systems = append(systems, telephonyStatus{Name: "FreeSWITCH Event Socket", State: "not configured"})
	}
	for _, target := range kamailioControlTargets(ctx) {
		conn, err := (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "tcp", target)
		state := "connected"
		if err != nil {
			state = "unavailable"
		} else {
			_ = conn.Close()
		}
		systems = append(systems, telephonyStatus{Name: "Kamailio ctl", State: state})
	}
	for _, config := range []struct{ name, url, table, started, caller, called, duration, disposition string }{
		{"Asterisk CDR", telephonyEnv("AVOIP_ASTERISK_CDR_URL"), telephonyEnv("AVOIP_ASTERISK_CDR_TABLE"), "calldate", "src", "dst", "billsec", "disposition"},
		{"FreeSWITCH CDR", telephonyEnv("AVOIP_FREESWITCH_CDR_URL"), telephonyEnv("AVOIP_FREESWITCH_CDR_TABLE"), "start_stamp", "caller_id_number", "destination_number", "billsec", "hangup_cause"},
	} {
		if config.url == "" {
			systems = append(systems, telephonyStatus{Name: config.name, State: "not configured"})
			continue
		}
		rows, err := queryCDR(ctx, config.url, config.table, config.started, config.caller, config.called, config.duration, config.disposition)
		state := "connected"
		if err != nil {
			state = "unavailable"
		} else {
			cdr = append(cdr, rows...)
		}
		detail := ""
		if err != nil {
			detail = safeInterfaceError(err)
		}
		systems = append(systems, telephonyStatus{Name: config.name, State: state, Detail: detail})
	}
	result["systems"], result["calls"], result["cdr"] = systems, calls, cdr
	writeJSON(w, result)
}

func freeSwitchStatus(ctx context.Context, address, secret string) (string, error) {
	return eslCommand(ctx, address, secret, "status")
}

func (s *server) hangupCall(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request struct {
		System string `json:"system"`
		ID     string `json:"id"`
	}
	if json.NewDecoder(r.Body).Decode(&request) != nil || request.ID == "" || len(request.ID) > 256 {
		http.Error(w, "invalid call", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	var err error
	switch request.System {
	case "freeswitch":
		for _, target := range controlTargets(ctx, telephonyEnv("AVOIP_ESL_ADDRESS")) {
			if currentErr := freeSwitchHangup(ctx, target, telephonyEnv("AVOIP_ESL_SECRET"), request.ID); currentErr == nil {
				err = nil
				break
			} else {
				err = currentErr
			}
		}
	case "asterisk":
		for _, target := range controlTargets(ctx, telephonyEnv("AVOIP_AMI_ADDRESS")) {
			if currentErr := asteriskHangup(ctx, target, telephonyEnv("AVOIP_AMI_USERNAME"), telephonyEnv("AVOIP_AMI_SECRET"), request.ID); currentErr == nil {
				err = nil
				break
			} else {
				err = currentErr
			}
		}
	default:
		http.Error(w, "unknown telephony system", http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, "hangup failed", http.StatusBadGateway)
		return
	}
	_, auditErr := s.pool.Exec(ctx, `INSERT INTO public.avoip_admin_audit(actor,action,object_id) VALUES($1,'call_hangup',$2)`, r.Header.Get("X-Authentik-Username"), request.System+":"+request.ID)
	if auditErr != nil {
		http.Error(w, "hangup sent but audit write failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func queryCDR(ctx context.Context, databaseURL, table, started, caller, called, duration, disposition string) ([]cdrRecord, error) {
	if !validSQLIdentifier(table) {
		return nil, errors.New("invalid CDR table")
	}
	config, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}
	config.RuntimeParams["default_transaction_read_only"] = "on"
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		return nil, err
	}
	defer conn.Close(context.Background())
	if err = conn.Ping(ctx); err != nil {
		return nil, err
	}
	startExpr := started
	if started == "start_stamp" {
		startExpr = "NULLIF(start_stamp,'')::timestamp"
	}
	query := fmt.Sprintf("SELECT %s, %s, %s, COALESCE(%s,0), COALESCE(%s,'') FROM %s ORDER BY %s DESC LIMIT 50", startExpr, caller, called, duration, disposition, table, started)
	rows, err := conn.Query(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []cdrRecord{}
	name := "Asterisk"
	if started == "start_stamp" {
		name = "FreeSWITCH"
	}
	for rows.Next() {
		var item cdrRecord
		item.System = name
		var startedValue any
		if err = rows.Scan(&startedValue, &item.Caller, &item.Called, &item.Duration, &item.Disposition); err != nil {
			return nil, err
		}
		switch value := startedValue.(type) {
		case time.Time:
			item.StartedAt = value
		case string:
			item.StartedAt, _ = time.Parse("2006-01-02 15:04:05", value)
		case []byte:
			item.StartedAt, _ = time.Parse("2006-01-02 15:04:05", string(value))
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func validSQLIdentifier(value string) bool {
	if value == "" {
		return false
	}
	for i, r := range value {
		if !(r == '_' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || i > 0 && r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}

func asteriskCalls(ctx context.Context, address, username, secret string) ([]liveCall, error) {
	if address == "" || username == "" || secret == "" {
		return nil, errors.New("AMI not configured")
	}
	c, err := net.DialTimeout("tcp", address, 4*time.Second)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(8 * time.Second))
	r := bufio.NewReader(c)
	if _, err = r.ReadString('\n'); err != nil {
		return nil, err
	}
	if err = writeAMI(c, map[string]string{"Action": "Login", "Username": username, "Secret": secret, "Events": "off"}); err != nil {
		return nil, err
	}
	login, err := readAMIResponse(r)
	if err != nil {
		return nil, err
	}
	if login["Response"] != "Success" {
		return nil, errors.New("AMI login rejected")
	}
	if err = writeAMI(c, map[string]string{"Action": "CoreShowChannels"}); err != nil {
		return nil, err
	}
	calls := []liveCall{}
	for {
		headers, e := readAMIResponse(r)
		if e != nil {
			return nil, e
		}
		if headers["Event"] == "CoreShowChannel" {
			calls = append(calls, liveCall{System: "asterisk", ID: headers["Channel"], Name: headers["Channel"], Caller: headers["CallerIDNum"], Called: headers["Exten"], State: headers["ChannelStateDesc"]})
		}
		if headers["Event"] == "CoreShowChannelsComplete" {
			break
		}
	}
	return calls, nil
}

func asteriskHangup(ctx context.Context, address, username, secret, id string) error {
	if address == "" || username == "" || secret == "" {
		return errors.New("AMI not configured")
	}
	c, err := net.DialTimeout("tcp", address, 4*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(6 * time.Second))
	r := bufio.NewReader(c)
	if _, err = r.ReadString('\n'); err != nil {
		return err
	}
	if err = writeAMI(c, map[string]string{"Action": "Login", "Username": username, "Secret": secret, "Events": "off"}); err != nil {
		return err
	}
	login, err := readAMIResponse(r)
	if err != nil {
		return err
	}
	if login["Response"] != "Success" {
		return errors.New("AMI login rejected")
	}
	if strings.ContainsAny(id, "\r\n") || id == "" {
		return errors.New("invalid AMI channel")
	}
	if err = writeAMI(c, map[string]string{"Action": "Hangup", "Channel": id}); err != nil {
		return err
	}
	resp, err := readAMIResponse(r)
	if err != nil {
		return err
	}
	if resp["Response"] != "Success" {
		return errors.New("AMI rejected hangup")
	}
	return nil
}

func writeAMI(c net.Conn, headers map[string]string) error {
	for k, v := range headers {
		if strings.ContainsAny(v, "\r\n") {
			return errors.New("invalid AMI value")
		}
		if _, err := fmt.Fprintf(c, "%s: %s\r\n", k, v); err != nil {
			return err
		}
	}
	_, err := fmt.Fprint(c, "\r\n")
	return err
}
func readAMIResponse(r *bufio.Reader) (map[string]string, error) {
	out := map[string]string{}
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			if len(out) == 0 {
				continue
			}
			return out, nil
		}
		key, value, ok := strings.Cut(line, ":")
		if ok {
			out[key] = strings.TrimSpace(value)
		}
	}
}

func freeSwitchCalls(ctx context.Context, address, secret string) ([]liveCall, error) {
	response, err := eslCommand(ctx, address, secret, "show channels as json")
	if err != nil {
		return nil, err
	}
	var payload struct {
		Rows []struct {
			UUID    string `json:"uuid"`
			Name    string `json:"name"`
			CIDNum  string `json:"cid_num"`
			Dest    string `json:"dest"`
			State   string `json:"state"`
			Created string `json:"created"`
		} `json:"rows"`
	}
	if err = json.Unmarshal([]byte(response), &payload); err != nil {
		return nil, err
	}
	out := []liveCall{}
	for _, row := range payload.Rows {
		t, _ := time.Parse("2006-01-02 15:04:05", row.Created)
		out = append(out, liveCall{System: "freeswitch", ID: row.UUID, Name: row.Name, Caller: row.CIDNum, Called: row.Dest, State: row.State, StartedAt: t})
	}
	return out, nil
}
func freeSwitchHangup(ctx context.Context, address, secret, id string) error {
	if id == "" || len(id) > 64 {
		return errors.New("invalid UUID")
	}
	for _, r := range id {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F' || r == '-') {
			return errors.New("invalid UUID")
		}
	}
	_, err := eslCommand(ctx, address, secret, "uuid_kill "+id+" NORMAL_CLEARING")
	return err
}

func freeSwitchUUIDExists(ctx context.Context, address, secret, uuid string) (bool, error) {
	if uuid == "" || !correlationID.MatchString(uuid) {
		return false, errors.New("invalid UUID")
	}
	response, err := eslCommand(ctx, address, secret, "uuid_exists "+uuid)
	if err != nil {
		return false, err
	}
	return strings.EqualFold(strings.TrimSpace(response), "true"), nil
}

func freeSwitchVariable(ctx context.Context, address, secret, uuid, name string) (string, error) {
	if uuid == "" || strings.ContainsAny(uuid, "\r\n ") || !correlationID.MatchString(uuid) || name == "" || strings.ContainsAny(name, "\r\n ") {
		return "", errors.New("invalid channel variable request")
	}
	return eslCommand(ctx, address, secret, "uuid_getvar "+uuid+" "+name)
}
func eslCommand(ctx context.Context, address, secret, command string) (string, error) {
	if address == "" || secret == "" {
		return "", errors.New("event socket not configured")
	}
	d := net.Dialer{Timeout: 4 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", address)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	reader := bufio.NewReader(conn)
	if _, err = readESLFrame(reader); err != nil {
		return "", err
	}
	if _, err = fmt.Fprintf(conn, "auth %s\n\n", secret); err != nil {
		return "", err
	}
	auth, err := readESLFrame(reader)
	if err != nil || !strings.Contains(auth, "+OK accepted") {
		return "", errors.New("event socket authentication failed")
	}
	request := eslWireCommand(command)
	if _, err = fmt.Fprintf(conn, "%s\n\n", request); err != nil {
		return "", err
	}
	result, err := readESLFrame(reader)
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(strings.TrimSpace(result), "-ERR") {
		return "", errors.New("event socket command failed")
	}
	return result, nil
}

func eslWireCommand(command string) string {
	if strings.HasPrefix(command, "bgapi ") {
		// bgapi is an ESL command, not an API command. Prefixing it with
		// `api` produces `api bgapi ...`, which FreeSWITCH rejects instead of
		// starting the requested asynchronous job.
		return command
	}
	return "api " + command
}
func readESLFrame(r *bufio.Reader) (string, error) {
	headers := map[string]string{}
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return "", err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		k, v, ok := strings.Cut(line, ":")
		if ok {
			headers[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	n, _ := strconv.Atoi(headers["Content-Length"])
	if n <= 0 {
		// Authentication and command replies commonly carry their result in
		// Reply-Text rather than a body. Preserve it for callers such as the
		// ESL auth handshake and bgapi originate acknowledgement.
		return headers["Reply-Text"], nil
	}
	buf := make([]byte, n)
	_, err := io.ReadFull(r, buf)
	return string(buf), err
}
