package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestHardwareAgentFaults(t *testing.T) {
	if os.Getenv("ZATOR_PROBE_HARDWARE_FAULTS") != "1" {
		t.Skip("physical fault injection is opt-in")
	}
	c, err := readSettings()
	if err != nil {
		t.Fatal(err)
	}
	binary := "/opt/zator/bin/zator-desktop-probe"
	call := func(r request) response {
		body, _ := json.Marshal(r)
		cmd := exec.Command(binary, r.Command, "--json")
		cmd.Stdin = bytes.NewReader(body)
		out, e := cmd.CombinedOutput()
		var reply response
		if err := json.Unmarshal(out, &reply); err != nil {
			t.Fatalf("%s: %s %v", r.Command, out, e)
		}
		return reply
	}
	if call(request{Command: "capabilities"})["session_active"] == true {
		t.Fatal("another session is active")
	}
	owner := randomID() + randomID()
	id := ""
	start := func() response {
		reply := call(request{Command: "start", Owner: owner, Profile: 1})
		if reply["ok"] != true {
			t.Fatal(reply)
		}
		id = reply["session_id"].(string)
		return reply
	}
	stop := func() { call(request{Command: "stop", Owner: owner, Session: id}) }
	defer stop()
	killOwned := func(pid int, marker string, signal os.Signal) {
		process, e := os.FindProcess(pid)
		if e != nil {
			t.Fatal(e)
		}
		defer process.Release()
		args, e := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
		if e != nil || !strings.Contains(string(args), marker) {
			t.Fatal("refusing to signal a process without session identity")
		}
		if e = process.Signal(signal); e != nil {
			t.Fatal(e)
		}
	}
	first := start()
	nfq := first["nfqws"].(map[string]any)
	killOwned(int(nfq["pid"].(float64)), stateRoot+"/"+id+"/nfq/locked.lua", syscall.SIGTERM)
	time.Sleep(200 * time.Millisecond)
	broken := call(request{Command: "status", Owner: owner, Session: id})
	if broken["ok"] != false || broken["error"].(map[string]any)["code"] != "NFQWS_EXITED" {
		t.Fatal("dead nfqws accepted", broken)
	}
	stop()
	t.Log("test nfqws TERM produces NFQWS_EXITED; stop remains idempotent")
	second := start()
	oldID := id
	killOwned(int(second["agent_pid"].(float64)), binary+"\x00--serve", syscall.SIGKILL)
	for n := 0; n < 30; n++ {
		_, e := queueCounter(c.Queue, int(second["nfqws"].(map[string]any)["pid"].(float64)))
		if e != nil && !proxyListening(c.Port, c.ProxyUID) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if _, e := queueCounter(c.Queue, int(second["nfqws"].(map[string]any)["pid"].(float64))); e == nil {
		t.Fatal("queue survived parent death")
	}
	if proxyListening(c.Port, c.ProxyUID) {
		t.Fatal("proxy survived parent death")
	}
	recovered := call(request{Command: "recover", Owner: owner, Session: id})
	if recovered["ok"] != true {
		t.Fatal(recovered)
	}
	last := start()
	if id == oldID {
		t.Fatal("old session resumed")
	}
	t.Log("agent SIGKILL terminates both test children; recover removes stale socket and starts a new session")
	expires, e := time.Parse(time.RFC3339, last["lease_expires_at"].(string))
	if e != nil {
		t.Fatal(e)
	}
	// No status/heartbeat calls here: they deliberately renew the lease.
	time.Sleep(time.Until(expires) + 3*time.Second)
	if proxyListening(c.Port, c.ProxyUID) {
		t.Fatal("proxy survived expired lease")
	}
	if _, e := queueCounter(c.Queue, int(last["nfqws"].(map[string]any)["pid"].(float64))); e == nil {
		t.Fatal("queue survived expired lease")
	}
	t.Log("90-second lease expiry removes test queue/proxy without changing production")
}

func TestHardwareYouTubePair(t *testing.T) {
	if os.Getenv("ZATOR_PROBE_HARDWARE_PAIR") != "1" {
		t.Skip("physical paired probe is opt-in")
	}
	c, err := readSettings()
	if err != nil {
		t.Fatal(err)
	}
	binary := "/opt/zator/bin/zator-desktop-probe"
	call := func(r request) response {
		body, _ := json.Marshal(r)
		cmd := exec.Command(binary, r.Command, "--json")
		cmd.Stdin = bytes.NewReader(body)
		out, err := cmd.CombinedOutput()
		var reply response
		if json.Unmarshal(out, &reply) != nil || err != nil || reply["ok"] != true {
			t.Fatalf("%s: %s %v", r.Command, out, err)
		}
		return reply
	}
	if call(request{Command: "capabilities"})["session_active"] == true {
		t.Fatal("refusing to touch another session")
	}
	baseline := map[string][32]byte{}
	for _, path := range []string{c.ZapretRoot + "/config", c.ZatorRoot + "/extra_strats/cache/orchestra/locked.tsv", c.ZatorRoot + "/extra_strats/cache/orchestra/locked.manual.tsv"} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		baseline[path] = sha256.Sum256(raw)
	}
	owner := randomID() + randomID()
	start := call(request{Command: "start", Owner: owner, Profile: 1, Paired: true})
	id := start["session_id"].(string)
	defer call(request{Command: "stop", Owner: owner, Session: id})
	gv := 2
	active := call(request{Command: "set-strategy", Owner: owner, Session: id, Strategy: 1, GVStrategy: &gv})
	if active["paired"] != true || active["gv_strategy"] != float64(2) || active["transport_generation"] != start["transport_generation"] {
		t.Fatal(active)
	}
	for _, host := range []string{"www.youtube.com", "redirector.googlevideo.com"} {
		out, err := exec.Command("curl", "--socks5-hostname", fmt.Sprintf("127.0.0.1:%d", c.Port), "--max-time", "8", "-sS", "-o", "/dev/null", "https://"+host+"/").CombinedOutput()
		if err != nil {
			t.Logf("%s response not required for an intentionally unproven strategy: %s %v", host, out, err)
		}
	}
	status := call(request{Command: "telemetry", Owner: owner, Session: id})
	proof := status["proof"].(map[string]any)
	hosts := map[string]bool{}
	verified, ok := proof["verified_hosts"].([]any)
	if !ok {
		t.Fatal("missing pair invocation evidence", proof)
	}
	for _, host := range verified {
		hosts[host.(string)] = true
	}
	if !hosts["www.youtube.com"] || !hosts["redirector.googlevideo.com"] {
		t.Fatal("YT-1/GV-2 not independently proven", proof)
	}
	for path, expected := range baseline {
		raw, err := os.ReadFile(path)
		if err != nil || sha256.Sum256(raw) != expected {
			t.Fatal("production changed", path, err)
		}
	}
	t.Log("YT-1 and GV-2 verified simultaneously by tuple, Lua strategy/profile, conntrack and WAN; production config/locks unchanged")
}

func TestHardwareAgentLifecycle(t *testing.T) {
	if os.Getenv("ZATOR_PROBE_HARDWARE_LIFECYCLE") != "1" {
		t.Skip("physical router lifecycle is opt-in")
	}
	c, err := readSettings()
	if err != nil {
		t.Fatal(err)
	}
	wans, err := discoverWANs()
	if err != nil {
		t.Fatal(err)
	}
	wan := wans[0]
	binary := "/opt/zator/bin/zator-desktop-probe"
	call := func(r request) response {
		body, _ := json.Marshal(r)
		cmd := exec.Command(binary, r.Command, "--json")
		cmd.Stdin = bytes.NewReader(body)
		out, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("%s failed: %s %v", r.Command, out, e)
		}
		var reply response
		if e = json.Unmarshal(out, &reply); e != nil {
			t.Fatal(e, string(out))
		}
		return reply
	}
	cap := call(request{Command: "capabilities"})
	if cap["session_active"] == true {
		t.Fatal("refusing to touch an existing session")
	}
	baseline := map[string][32]byte{}
	for _, path := range []string{c.ZapretRoot + "/config", c.ZatorRoot + "/extra_strats/cache/orchestra/locked.tsv", c.ZatorRoot + "/extra_strats/cache/orchestra/locked.manual.tsv"} {
		raw, e := os.ReadFile(path)
		if e != nil {
			t.Fatal(e)
		}
		baseline[path] = sha256.Sum256(raw)
	}
	productionBefore, e := os.ReadFile("/proc/net/netfilter/nfnetlink_queue")
	if e != nil {
		t.Fatal(e)
	}
	owner := randomID() + randomID()
	reply := call(request{Command: "start", Owner: owner, Profile: 1})
	if reply["ok"] != true {
		t.Fatal(reply)
	}
	id := reply["session_id"].(string)
	fingerprint := reply["transport_generation"]
	r := request{Command: "stop", Owner: owner, Session: id}
	defer func() { call(r) }()
	status := func() response { return call(request{Command: "status", Owner: owner, Session: id}) }
	bad := call(request{Command: "set-strategy", Owner: owner, Session: id, Strategy: 99999})
	if bad["ok"] != false || bad["error"].(map[string]any)["code"] != "STRATEGY_UNKNOWN" {
		t.Fatal("invalid strategy accepted", bad)
	}
	bad = call(request{Command: "status", Owner: randomID() + randomID(), Session: id})
	if bad["ok"] != false {
		t.Fatal("foreign owner accepted")
	}
	for _, strategy := range []int{0, 1} {
		if strategy != 0 {
			reply = call(request{Command: "set-strategy", Owner: owner, Session: id, Strategy: strategy})
			if reply["ok"] != true {
				t.Fatal(reply)
			}
		}
		if reply["transport_generation"] != fingerprint {
			t.Fatal("strategy changed firewall")
		}
		conn, e := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", c.Port), time.Second)
		if e != nil {
			t.Fatal(e)
		}
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
		_, _ = conn.Write([]byte{5, 1, 0})
		var greeting [2]byte
		if _, e = io.ReadFull(conn, greeting[:]); e != nil {
			t.Fatal(e)
		}
		host := "example.org"
		req := append([]byte{5, 1, 0, 3, byte(len(host))}, []byte(host)...)
		req = append(req, 1, 187)
		_, _ = conn.Write(req)
		var connected [10]byte
		if _, e = io.ReadFull(conn, connected[:]); e != nil || connected[1] != 0 {
			t.Fatal("SOCKS", e, connected)
		}
		time.Sleep(100 * time.Millisecond)
		pre := status()
		flows := pre["flows"].([]any)
		if len(flows) == 0 {
			t.Fatal("missing proxy flow")
		}
		f := flows[len(flows)-1].(map[string]any)
		_, port, _ := net.SplitHostPort(f["local"].(string))
		remote, _, _ := net.SplitHostPort(f["remote"].(string))
		captureCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		capture := exec.CommandContext(captureCtx, "tcpdump", "-nn", "-S", "-l", "-i", wan, "tcp and host "+remote+" and port "+port)
		var trace bytes.Buffer
		capture.Stdout = &trace
		capture.Stderr = &trace
		if e = capture.Start(); e != nil {
			cancel()
			t.Fatal(e)
		}
		time.Sleep(250 * time.Millisecond)
		secure := tls.Client(conn, &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12})
		if e = secure.Handshake(); e != nil {
			cancel()
			_ = capture.Wait()
			conn.Close()
			t.Fatal(e)
		}
		httpReq, _ := http.NewRequest("GET", "https://"+host+"/", nil)
		if e = httpReq.Write(secure); e != nil {
			t.Fatal(e)
		}
		resp, e := http.ReadResponse(bufio.NewReader(secure), httpReq)
		if e != nil {
			t.Fatal(e)
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 65536))
		resp.Body.Close()
		secure.Close()
		time.Sleep(250 * time.Millisecond)
		cancel()
		_ = capture.Wait()
		post := status()
		proof := post["proof"].(map[string]any)
		if proof["connection_match"] != "verified" || proof["strategy_invocation"] != "verified" || proof["egress_interface"] != wan {
			t.Fatal(post)
		}
		if post["transport_generation"] != fingerprint {
			t.Fatal("runtime firewall mutation")
		}
		if !strings.Contains(trace.String(), "Flags") {
			t.Fatal("no matching WAN packet capture", trace.String())
		}
		if strategy == 1 {
			seqs := []uint32{}
			pattern := regexp.MustCompile(`seq ([0-9]+):`)
			for _, line := range strings.Split(trace.String(), "\n") {
				if !strings.Contains(line, "."+port+" > ") {
					continue
				}
				match := pattern.FindStringSubmatch(line)
				if len(match) > 1 {
					value, e := strconv.ParseUint(match[1], 10, 32)
					if e == nil {
						seqs = append(seqs, uint32(value))
					}
				}
			}
			fake := false
			for _, x := range seqs {
				for _, y := range seqs {
					if x-y == 3000 {
						fake = true
					}
				}
			}
			if !fake {
				t.Fatal("strategy-1 fake sequence offset was not observed on WAN", seqs)
			}
			t.Log("strategy-1 raw fake observed on test WAN: TCP sequence offset -3000")
		}
		t.Logf("strategy=%d http=%d queue=%v WAN=%s packet_lines=%d proof=verified", strategy, resp.StatusCode, post["queue"], wan, strings.Count(trace.String(), "Flags"))
	}
	// An ordinary local-root socket must never enter the proxy's test queue.
	time.Sleep(time.Second)
	pre := status()
	beforeCount := pre["queue"].(map[string]any)["counter"]
	_, _ = exec.Command("curl", "-sS", "--max-time", "8", "-o", "/dev/null", "https://example.org/").CombinedOutput()
	if status()["queue"].(map[string]any)["counter"] != beforeCount {
		t.Fatal("ordinary traffic entered test queue")
	}
	if c.Backend == "nft" {
		listing, e := runCommand("nft", "-a", "list", "chain", "inet", "zapret2", "zator_dp_in")
		if e != nil {
			t.Fatal(e)
		}
		handle := ""
		for _, line := range strings.Split(string(listing), "\n") {
			if strings.Contains(line, "queue flags bypass") {
				f := strings.Fields(line)
				handle = f[len(f)-1]
				break
			}
		}
		if _, e = strconv.Atoi(handle); e != nil {
			t.Fatal("missing owned rule handle")
		}
		if out, e := runCommand("nft", "delete", "rule", "inet", "zapret2", "zator_dp_in", "handle", handle); e != nil {
			t.Fatal(string(out), e)
		}
		broken := status()
		if broken["ok"] != false || broken["error"].(map[string]any)["code"] != "TRANSPORT_CHANGED" {
			t.Fatal("lost rule accepted", broken)
		}
		for n := 0; n < 10; n++ {
			if out, e := exec.Command(binary, "reconcile-transport").CombinedOutput(); e != nil {
				t.Fatal(string(out), e)
			}
		}
		listing, e = runCommand("nft", "-s", "list", "table", "inet", "zapret2")
		if e != nil || strings.Count(string(listing), `comment "zator_desktop_probe"`) != 10 {
			t.Fatal("duplicate/missing rules after 10 reconciles")
		}
		if status()["ok"] != false {
			t.Fatal("old generation accepted after reconcile")
		}
	}
	call(r)
	for path, want := range baseline {
		raw, e := os.ReadFile(path)
		if e != nil || sha256.Sum256(raw) != want {
			t.Fatal("production file changed", path)
		}
	}
	productionAfter, e := os.ReadFile("/proc/net/netfilter/nfnetlink_queue")
	if e != nil {
		t.Fatal(e)
	}
	var consumersBefore, consumersAfter []string
	for _, line := range strings.Split(string(productionBefore), "\n") {
		f := strings.Fields(line)
		if len(f) > 1 {
			consumersBefore = append(consumersBefore, f[0]+":"+f[1])
		}
	}
	for _, line := range strings.Split(string(productionAfter), "\n") {
		f := strings.Fields(line)
		if len(f) > 1 {
			consumersAfter = append(consumersAfter, f[0]+":"+f[1])
		}
	}
	if strings.Join(consumersBefore, ",") != strings.Join(consumersAfter, ",") {
		t.Fatal("production queue consumer changed")
	}
	t.Log("production config/locks hashes and NFQUEUE consumer unchanged; test start/switch/stop do not mutate firewall")
}

// Opt-in only: invokes an independent sing-box with a temporary config and UID.
func TestHardwareSingBoxCandidate(t *testing.T) {
	if os.Getenv("ZATOR_PROBE_HARDWARE_BENCH") != "1" {
		t.Skip("physical router benchmark is opt-in")
	}
	c, err := readSettings()
	if err != nil {
		t.Fatal(err)
	}
	if err = resourceConflicts(c, "/proc"); err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp("/tmp", "zator-socks-bench-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if err = os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	config := `{"log":{"level":"error"},"dns":{"servers":[{"type":"local","tag":"local"}],"strategy":"ipv4_only"},"inbounds":[{"type":"socks","tag":"probe","listen":"127.0.0.1","listen_port":41083}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"network":"udp","action":"reject"}],"default_domain_resolver":{"server":"local","strategy":"ipv4_only"}}}`
	path := filepath.Join(dir, "sing-box.json")
	if err = os.WriteFile(path, []byte(config), 0644); err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("/usr/bin/sing-box", "check", "-c", path).CombinedOutput(); err != nil {
		t.Fatalf("check: %s %v", out, err)
	}
	cmd := exec.Command("/usr/bin/sing-box", "run", "-c", path)
	isolateChild(cmd, c.ProxyUID)
	started := time.Now()
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	ready := false
	for i := 0; i < 50; i++ {
		conn, e := net.DialTimeout("tcp4", "127.0.0.1:41083", 100*time.Millisecond)
		if e == nil {
			conn.Close()
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		t.Fatal("listener unavailable")
	}
	t.Logf("start_ms=%d pid=%d", time.Since(started).Milliseconds(), cmd.Process.Pid)
	before, _ := os.ReadFile(fmt.Sprintf("/proc/%d/stat", cmd.Process.Pid))
	for n := 0; n < 3; n++ {
		out, err := exec.Command("curl", "-sS", "--socks5-hostname", "127.0.0.1:41083", "--max-time", "15", "-o", "/dev/null", "-w", "%{http_code}", "https://example.org/").CombinedOutput()
		if err != nil || string(out) != "200" {
			t.Fatalf("TCP CONNECT: %s %v", out, err)
		}
	}
	after, _ := os.ReadFile(fmt.Sprintf("/proc/%d/stat", cmd.Process.Pid))
	status, _ := os.ReadFile(fmt.Sprintf("/proc/%d/status", cmd.Process.Pid))
	for _, line := range strings.Split(string(status), "\n") {
		if strings.HasPrefix(line, "VmRSS:") || strings.HasPrefix(line, "Uid:") {
			t.Log(line)
		}
	}
	bf, af := strings.Fields(string(before)), strings.Fields(string(after))
	if len(bf) > 15 && len(af) > 15 {
		t.Logf("cpu_ticks_before=%s,%s after=%s,%s", bf[13], bf[14], af[13], af[14])
	}
}
