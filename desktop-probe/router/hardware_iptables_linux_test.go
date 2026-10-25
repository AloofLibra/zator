package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestHardwareIPTablesCoexistence(t *testing.T) {
	if os.Getenv("ZATOR_PROBE_HARDWARE_IPTABLES") != "1" {
		t.Skip("physical iptables coexistence is opt-in")
	}
	c, err := readSettings()
	if err != nil {
		t.Fatal(err)
	}
	if c.Backend != "iptables" {
		t.Skip("iptables only")
	}
	command := func(name string, args ...string) string {
		t.Helper()
		out, e := exec.Command(name, args...).CombinedOutput()
		if e != nil {
			t.Fatal(name, e, string(out))
		}
		return string(out)
	}
	counters := regexp.MustCompile(`\[\d+:\d+\]`)
	foreign := func() string {
		var rows []string
		for _, row := range strings.Split(command("iptables-save", "-t", "mangle"), "\n") {
			if !strings.HasPrefix(row, "#") && !strings.HasPrefix(row, ":Z2R_DP_") && !strings.Contains(row, "zator_desktop_probe") {
				rows = append(rows, counters.ReplaceAllString(row, "[counters]"))
			}
		}
		return strings.Join(rows, "\n")
	}
	rules, policies, pids := foreign(), command("ip", "-4", "rule"), command("pidof", "nfqws2")
	baseline := map[string][32]byte{}
	for _, path := range []string{c.ZapretRoot + "/config", c.ZatorRoot + "/extra_strats/cache/orchestra/locked.tsv"} {
		raw, e := os.ReadFile(path)
		if e != nil {
			t.Fatal(e)
		}
		baseline[path] = sha256.Sum256(raw)
	}
	call := func(r request) response {
		t.Helper()
		body, _ := json.Marshal(r)
		cmd := exec.Command("/opt/zator/bin/zator-desktop-probe", r.Command, "--json")
		cmd.Stdin = bytes.NewReader(body)
		out, e := cmd.CombinedOutput()
		var reply response
		if json.Unmarshal(out, &reply) != nil || e != nil || reply["ok"] != true {
			t.Fatal(r.Command, e, string(out))
		}
		return reply
	}
	if call(request{Command: "capabilities"})["session_active"] == true {
		t.Fatal("foreign session active")
	}
	owner := randomID() + randomID()
	started := call(request{Command: "start", Owner: owner, Profile: 1})
	id := started["session_id"].(string)
	defer func() {
		if id != "" {
			call(request{Command: "stop", Owner: owner, Session: id})
		}
	}()
	status := func() response { return call(request{Command: "status", Owner: owner, Session: id}) }
	count := func(s response) float64 { return s["queue"].(map[string]any)["counter"].(float64) }
	before := count(status())
	command("curl", "-fsS", "--max-time", "15", "-o", "/dev/null", "https://example.org/")
	var markErr error
	dialer := net.Dialer{Timeout: 8 * time.Second, Control: func(_, _ string, raw syscall.RawConn) error {
		return raw.Control(func(fd uintptr) {
			markErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_MARK, 0x4d616769)
		})
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	conn, e := dialer.DialContext(ctx, "tcp4", "example.org:443")
	cancel()
	if markErr != nil || e != nil {
		t.Fatal("foreign-mark connection not established", markErr, e)
	}
	conn.Close()
	time.Sleep(200 * time.Millisecond)
	if count(status()) != before {
		t.Fatal("ordinary or MagiTrickle-marked traffic entered private NFQUEUE")
	}
	for _, strategy := range []int{0, 1} {
		if strategy != 0 {
			call(request{Command: "set-strategy", Owner: owner, Session: id, Strategy: strategy})
		}
		pre := count(status())
		code := command("curl", "-sS", "--socks5-hostname", fmt.Sprintf("127.0.0.1:%d", c.Port), "--max-time", "15", "-o", "/dev/null", "-w", "%{http_code}", "https://example.org/")
		if strings.TrimSpace(code) != "200" {
			t.Fatal("HTTP", strategy, code)
		}
		after := call(request{Command: "telemetry", Owner: owner, Session: id})
		proof := after["proof"].(map[string]any)
		if count(after) <= pre || proof["connection_match"] != "verified" || proof["strategy_invocation"] != "verified" || proof["route"] != "kernel_route_verified" {
			t.Fatal("missing isolated flow/strategy/route proof", strategy, proof)
		}
	}
	call(request{Command: "stop", Owner: owner, Session: id})
	id = ""
	if foreign() != rules || command("ip", "-4", "rule") != policies || command("pidof", "nfqws2") != pids {
		t.Fatal("foreign firewall, policy routes or production process changed")
	}
	for path, digest := range baseline {
		raw, e := os.ReadFile(path)
		if e != nil || sha256.Sum256(raw) != digest {
			t.Fatal("production file changed", path, e)
		}
	}
	t.Log("ordinary + MagiTrickle-marked connections bypass private queue; DIRECT/strategy 1 verified; production and policies unchanged")
}
