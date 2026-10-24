package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const stateRoot = "/tmp/zator-desktop-probe"
const settingsFile = "/opt/zator/desktop-probe.json"
const socketFile = stateRoot + "/control.sock"

type request struct {
	Hostname string `json:"hostname"`
	Command  string `json:"command"`
	Owner    string `json:"owner"`
	Session  string `json:"session"`
	Profile  int    `json:"profile"`
	Strategy int    `json:"strategy"`
}
type response map[string]any

func failure(err error) response {
	code := strings.SplitN(err.Error(), ":", 2)[0]
	if !regexpErrorCode.MatchString(code) {
		code = "INTERNAL_ERROR"
	}
	return response{"ok": false, "error": response{"code": code, "message": err.Error(), "retryable": false}}
}
func readSettings() (settings, error) {
	var c settings
	raw, err := readLimited(settingsFile, 4096)
	if err == nil {
		err = json.Unmarshal(raw, &c)
	}
	if err == nil {
		err = c.validate()
	}
	return c, err
}

func capabilities(c settings, active bool) response {
	profiles := map[int][]int{}
	if raw, err := os.ReadFile(filepath.Join(c.ZapretRoot, "config")); err == nil {
		for p := 1; p <= 4; p++ {
			if _, numbers, e := profilePlan(string(raw), p); e == nil {
				profiles[p] = numbers
			}
		}
	}
	_, err := transportFingerprint(c)
	wans, wanErr := discoverWANs()
	if err == nil {
		err = wanErr
	}
	reason := ""
	if err != nil {
		reason = err.Error()
	}
	return response{"ok": true, "api_version": "0.1", "settings_id": c.identity(), "platform": runtime.GOOS + "/" + runtime.GOARCH, "wan_interfaces": wans, "transport": []string{"router_socks_tcp"}, "profiles": profiles, "ipv6_supported": false, "quic_supported": false, "ssh_forwarding_supported": nil, "hardware_validated": false, "session_active": active, "isolation": response{"available": err == nil, "reason": reason}}
}

type agent struct {
	routes                        func() (uint64, bool)
	firewall                      func() (uint64, bool)
	mu                            sync.Mutex
	config                        settings
	session                       string
	owner                         [32]byte
	profile, strategy, generation int
	fingerprint                   string
	lease                         time.Time
	nfq, proxy                    *exec.Cmd
	nfqDone, proxyDone            chan error
	log                           *os.File
}

func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

func (a *agent) stopChildren() {
	for _, child := range []struct {
		cmd  *exec.Cmd
		done chan error
	}{{a.proxy, a.proxyDone}, {a.nfq, a.nfqDone}} {
		if child.cmd == nil {
			continue
		}
		_ = child.cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-child.done:
		case <-time.After(3 * time.Second):
			_ = child.cmd.Process.Kill()
			<-child.done
		}
	}
	a.proxy = nil
	a.nfq = nil
	if a.log != nil {
		a.log.Close()
		a.log = nil
	}
}

func launch(cmd *exec.Cmd) (chan error, error) {
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	return done, nil
}

func (a *agent) startChildren() error {
	dir := stateRoot + "/" + a.session
	public := dir + "/nfq"
	for _, name := range []string{"proxy/flows.jsonl", "evidence/invocations.tsv"} {
		if err := os.Remove(dir + "/" + name); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	args, err := prepareConfig(a.config, public, a.profile, a.strategy)
	if err != nil {
		return err
	}
	binary := filepath.Join(a.config.ZapretRoot, "nfq2/nfqws2")
	help, _ := runCommand(binary, "--help")
	if strings.Contains(string(help), "--autoexclude") {
		args = append([]string{"--autoexclude=0"}, args...)
	}
	a.log, err = os.OpenFile(dir+"/nfqws.log", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	a.nfq = exec.Command(binary, args...)
	isolateChild(a.nfq, 0)
	a.nfq.Stdout = a.log
	a.nfq.Stderr = a.log
	a.nfqDone, err = launch(a.nfq)
	if err != nil {
		a.nfq = nil
		return err
	}
	ready := false
	for i := 0; i < 50; i++ {
		if _, err = queueCounter(a.config.Queue, a.nfq.Process.Pid); err == nil {
			ready = true
			break
		}
		select {
		case <-a.nfqDone:
			return fmt.Errorf("NFQWS_EXITED")
		default:
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		return fmt.Errorf("NFQUEUE_NOT_ACTIVE")
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	a.proxy = exec.Command(self, "--socks", strconv.Itoa(a.config.Port), dir+"/proxy/flows.jsonl")
	isolateChild(a.proxy, a.config.ProxyUID)
	a.proxyDone, err = launch(a.proxy)
	if err != nil {
		a.proxy = nil
		return err
	}
	for i := 0; i < 50; i++ {
		conn, e := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", a.config.Port), 100*time.Millisecond)
		if e == nil {
			conn.Close()
			if proxyListening(a.config.Port, a.config.ProxyUID) {
				return nil
			}
		}
		select {
		case <-a.proxyDone:
			return fmt.Errorf("SOCKS_DOWN")
		default:
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("SOCKS_DOWN")
}

func queueCounter(queue, ownerPID int) (uint64, error) {
	raw, err := os.ReadFile("/proc/net/netfilter/nfnetlink_queue")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) >= 8 && f[0] == strconv.Itoa(queue) {
			if f[1] != strconv.Itoa(ownerPID) {
				return 0, fmt.Errorf("QUEUE_COLLISION")
			}
			if f[5] != "0" || f[6] != "0" {
				return 0, fmt.Errorf("NFQUEUE_DROPPED")
			}
			return strconv.ParseUint(f[7], 10, 64)
		}
	}
	return 0, fmt.Errorf("NFQUEUE_NOT_ACTIVE")
}

func alive(cmd *exec.Cmd, done chan error) bool {
	if cmd == nil {
		return false
	}
	select {
	case <-done:
		return false
	default:
		return true
	}
}

func proxyListening(port, uid int) bool {
	raw, err := readLimited("/proc/net/tcp", 2*1024*1024)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) < 10 {
			continue
		}
		local := strings.ToUpper(f[1])
		if (local == fmt.Sprintf("0100007F:%04X", port) || local == fmt.Sprintf("7F000001:%04X", port)) && f[3] == "0A" && f[7] == strconv.Itoa(uid) {
			return true
		}
	}
	return false
}

func (a *agent) status() (response, error) {
	if a.routes == nil {
		return nil, fmt.Errorf("ROUTE_MONITOR_LOST")
	}
	_, healthy := a.routes()
	if !healthy {
		return nil, fmt.Errorf("ROUTE_MONITOR_LOST")
	}
	fingerprint, err := transportFingerprint(a.config)
	if err != nil || fingerprint != a.fingerprint {
		return nil, fmt.Errorf("TRANSPORT_CHANGED")
	}
	if !alive(a.nfq, a.nfqDone) {
		return nil, fmt.Errorf("NFQWS_EXITED")
	}
	if !alive(a.proxy, a.proxyDone) || !proxyListening(a.config.Port, a.config.ProxyUID) {
		return nil, fmt.Errorf("SOCKS_DOWN")
	}
	counter, err := queueCounter(a.config.Queue, a.nfq.Process.Pid)
	if err != nil {
		return nil, err
	}
	log, err := readLimited(stateRoot+"/"+a.session+"/nfqws.log", 2*1024*1024)
	if err != nil {
		return nil, err
	}
	if strings.Contains(string(log), "LUA ERROR") || strings.Contains(string(log), "desync ERROR") {
		return nil, fmt.Errorf("NFQWS_LUA_ERROR")
	}
	flows := []flow{}
	f, err := os.Open(stateRoot + "/" + a.session + "/proxy/flows.jsonl")
	if err == nil {
		info, e := f.Stat()
		if e != nil || info.Size() > 256*1024 {
			f.Close()
			return nil, fmt.Errorf("EVIDENCE_LIMIT")
		}
		scanner := bufio.NewScanner(io.LimitReader(f, 256*1024))
		for scanner.Scan() {
			var v flow
			if json.Unmarshal(scanner.Bytes(), &v) != nil {
				f.Close()
				return nil, fmt.Errorf("EVIDENCE_INVALID")
			}
			flows = append(flows, v)
		}
		if err = scanner.Err(); err != nil {
			f.Close()
			return nil, err
		}
		f.Close()
	}
	conntrack, _ := readLimited("/proc/net/nf_conntrack", 2*1024*1024)
	if len(conntrack) == 0 {
		conntrack, _ = readLimited("/proc/net/ip_conntrack", 2*1024*1024)
	}
	events, _ := readLimited(stateRoot+"/"+a.session+"/evidence/invocations.tsv", 256*1024)
	proof, err := flowProof(a.config, flows, string(conntrack), string(events), a.strategy)
	if err != nil {
		return nil, err
	}
	routeGeneration, healthy := a.routes()
	if !healthy {
		return nil, fmt.Errorf("ROUTE_MONITOR_LOST")
	}
	firewallGeneration, healthy := a.firewall()
	if !healthy {
		return nil, fmt.Errorf("TRANSPORT_CHANGED")
	}
	return response{
		"ok": true, "api_version": "0.1", "agent_pid": os.Getpid(), "session_id": a.session, "state": "ready",
		"route_generation": routeGeneration, "firewall_generation": firewallGeneration,
		"profile": a.profile, "strategy": a.strategy, "strategy_generation": a.generation, "transport_generation": a.fingerprint,
		"lease_expires_at": a.lease.UTC().Format(time.RFC3339), "mode": "router_socks_tcp", "protocol_scope": "TCP_HTTPS_IPV4",
		"nfqws": response{"pid": a.nfq.Process.Pid, "alive": true, "lua_errors": 0},
		"proxy": response{"host": "127.0.0.1", "port": a.config.Port, "alive": true, "pid": a.proxy.Process.Pid, "connections_started": len(flows)},
		"queue": response{"number": a.config.Queue, "alive": true, "counter": counter}, "flows": flows, "proof": proof,
	}, nil
}

func (a *agent) handle(r request) (response, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if r.Command == "capabilities" {
		return capabilities(a.config, a.session != ""), nil
	}
	if r.Command == "resolve-profile" {
		p, err := resolveProfile(a.config, r.Hostname)
		return response{"ok": err == nil, "profile": p}, err
	}
	if r.Command == "shutdown" {
		if a.session != "" {
			return nil, fmt.Errorf("SESSION_BUSY")
		}
		return response{"ok": true, "state": "stopped"}, nil
	}
	if r.Command == "admin-stop" {
		a.stopChildren()
		a.session = ""
		return response{"ok": true, "state": "stopped"}, nil
	}
	if len(r.Owner) != 64 {
		return nil, fmt.Errorf("SESSION_NOT_OWNER")
	}
	if _, err := hex.DecodeString(r.Owner); err != nil {
		return nil, fmt.Errorf("SESSION_NOT_OWNER")
	}
	token := sha256.Sum256([]byte(r.Owner))
	if a.session != "" && (subtle.ConstantTimeCompare(token[:], a.owner[:]) != 1 || r.Session != a.session) {
		return nil, fmt.Errorf("SESSION_NOT_OWNER")
	}
	if a.session != "" && time.Now().After(a.lease) {
		a.stopChildren()
		a.session = ""
		return nil, fmt.Errorf("SESSION_EXPIRED")
	}
	switch r.Command {
	case "start":
		if _, err := discoverWANs(); err != nil {
			return nil, err
		}
		if _, e := os.Stat(stateRoot + "/disabled"); e == nil {
			return nil, fmt.Errorf("COMPONENT_DISABLED")
		}
		if a.session != "" {
			return nil, fmt.Errorf("SESSION_BUSY")
		}
		if err := resourceConflicts(a.config, "/proc"); err != nil {
			return nil, err
		}
		reserved, e := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", a.config.Port))
		if e != nil {
			return nil, fmt.Errorf("SOCKS_PORT_COLLISION")
		}
		reserved.Close()
		cfg, err := os.ReadFile(filepath.Join(a.config.ZapretRoot, "config"))
		if err != nil {
			return nil, err
		}
		if _, _, err = profilePlan(string(cfg), r.Profile); err != nil {
			return nil, err
		}
		a.fingerprint, err = transportFingerprint(a.config)
		if err != nil {
			return nil, err
		}
		a.session = randomID()
		a.owner = token
		a.profile = r.Profile
		a.strategy = 0
		a.generation = 1
		a.lease = time.Now().Add(90 * time.Second)
		dir := stateRoot + "/" + a.session
		for _, path := range []string{dir, dir + "/nfq", dir + "/proxy", dir + "/evidence"} {
			if err = os.Mkdir(path, 0711); err != nil {
				a.session = ""
				return nil, err
			}
			if err = os.Chmod(path, 0711); err != nil {
				a.session = ""
				return nil, err
			}
		}
		if err = os.Chown(dir+"/proxy", a.config.ProxyUID, a.config.ProxyUID); err != nil {
			a.session = ""
			return nil, err
		}
		if err = os.Chown(dir+"/evidence", a.config.NfqUID, a.config.NfqUID); err != nil {
			a.session = ""
			return nil, err
		}
		if err = a.startChildren(); err != nil {
			a.stopChildren()
			a.session = ""
			return nil, err
		}
		return a.status()
	case "stop", "recover":
		a.stopChildren()
		a.session = ""
		return response{"ok": true, "state": "stopped"}, nil
	case "set-strategy":
		if a.session == "" {
			return nil, fmt.Errorf("SESSION_EXPIRED")
		}
		if _, err := a.status(); err != nil {
			return nil, err
		}
		raw, err := os.ReadFile(filepath.Join(a.config.ZapretRoot, "config"))
		if err != nil {
			return nil, err
		}
		_, numbers, err := profilePlan(string(raw), a.profile)
		if err != nil {
			return nil, err
		}
		if r.Strategy < 0 || (r.Strategy != 0 && !contains(numbers, r.Strategy)) {
			return nil, fmt.Errorf("STRATEGY_UNKNOWN")
		}
		a.stopChildren()
		a.strategy = r.Strategy
		a.generation++
		a.lease = time.Now().Add(90 * time.Second)
		// Restart only test children: guarantees no cached circular_locked host state.
		if err = a.startChildren(); err != nil {
			a.stopChildren()
			return nil, err
		}
		return a.status()
	case "status", "telemetry", "heartbeat":
		if a.session == "" {
			return nil, fmt.Errorf("SESSION_EXPIRED")
		}
		a.lease = time.Now().Add(90 * time.Second)
		return a.status()
	default:
		return nil, fmt.Errorf("UNKNOWN_COMMAND")
	}
}

func supervise(c settings) error {
	if err := secureState(); err != nil {
		return err
	}
	unlock, err := managerLock()
	if err != nil {
		return err
	}
	defer unlock()
	listener, err := net.Listen("unix", socketFile)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(socketFile)
	if err = os.Chmod(socketFile, 0600); err != nil {
		return err
	}
	routes, closeRoutes, err := routeMonitor()
	if err != nil {
		return err
	}
	defer closeRoutes()
	firewall := func() (uint64, bool) { return 0, true }
	if c.Backend == "nft" {
		var closeFirewall func()
		firewall, closeFirewall, err = firewallMonitor()
		if err != nil {
			return err
		}
		defer closeFirewall()
	}
	a := &agent{config: c, routes: routes, firewall: firewall}
	defer func() { a.mu.Lock(); defer a.mu.Unlock(); a.stopChildren() }()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer cancel()
	go func() { <-ctx.Done(); listener.Close() }()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
				a.mu.Lock()
				expired := a.session != "" && time.Now().After(a.lease)
				if expired {
					a.stopChildren()
					a.session = ""
				}
				a.mu.Unlock()
				if expired {
					cancel()
					return
				}
			}
		}
	}()
	for {
		conn, e := listener.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return nil
			}
			return e
		}
		go func() {
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
			var r request
			decoder := json.NewDecoder(io.LimitReader(conn, 4096))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&r); err != nil {
				_ = json.NewEncoder(conn).Encode(failure(fmt.Errorf("INVALID_REQUEST")))
				return
			}
			out, err := a.handle(r)
			if err != nil {
				out = failure(err)
			}
			_ = json.NewEncoder(conn).Encode(out)
			if (r.Command == "shutdown" || r.Command == "stop" || r.Command == "recover") && err == nil {
				cancel()
			}
		}()
	}
}

func rpc(r request) (response, error) {
	conn, err := net.DialTimeout("unix", socketFile, time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	if err = json.NewEncoder(conn).Encode(r); err != nil {
		return nil, err
	}
	var out response
	err = json.NewDecoder(io.LimitReader(conn, 1024*1024)).Decode(&out)
	return out, err
}

func main() {
	err := entry()
	if err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(failure(err))
		os.Exit(1)
	}
}
func entry() error {
	if len(os.Args) < 2 {
		return fmt.Errorf("USAGE: capabilities|start|set-strategy|status|telemetry|heartbeat|stop|recover; JSON request on stdin")
	}
	if os.Args[1] == "--check-settings" {
		if len(os.Args) != 3 {
			return fmt.Errorf("INVALID_REQUEST")
		}
		raw, err := os.ReadFile(os.Args[2])
		if err != nil {
			return err
		}
		var c settings
		if err = json.Unmarshal(raw, &c); err != nil {
			return err
		}
		if err = c.validate(); err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(response{"ok": true, "state": "validated"})
	}
	if os.Args[1] == "--socks" {
		if len(os.Args) != 4 {
			return fmt.Errorf("INVALID_REQUEST")
		}
		port, err := strconv.Atoi(os.Args[2])
		if err != nil {
			return err
		}
		return serveSOCKS(port, os.Args[3])
	}
	if runtime.GOOS != "linux" {
		return fmt.Errorf("UNSUPPORTED_PLATFORM")
	}
	c, err := readSettings()
	if err != nil {
		switch os.Args[1] {
		case "stop", "shutdown", "admin-stop", "recover", "status", "telemetry", "heartbeat":
		default:
			return err
		}
	}
	if os.Args[1] == "--serve" {
		return supervise(c)
	}
	if os.Args[1] == "--guard" {
		return guardSupervisor()
	}
	if os.Args[1] == "install-transport" || os.Args[1] == "reconcile-transport" || os.Args[1] == "uninstall-transport" {
		unlock, e := fileLock("transport.lock")
		if e != nil {
			return e
		}
		defer unlock()
		if err = secureState(); err != nil {
			return err
		}
		if os.Args[1] == "uninstall-transport" {
			if err = os.WriteFile(stateRoot+"/disabled", []byte("uninstall\n"), 0600); err != nil {
				return err
			}
			if out, e := rpc(request{Command: "capabilities"}); e == nil && out != nil {
				if out["session_active"] == true {
					if _, e = rpc(request{Command: "admin-stop"}); e != nil {
						return e
					}
				}
				if _, e = rpc(request{Command: "shutdown"}); e != nil {
					return e
				}
			}
			if c.Backend == "iptables" {
				if e := ipRemove(c); e != nil {
					return e
				}
				return json.NewEncoder(os.Stdout).Encode(response{"ok": true, "state": "uninstalled"})
			}
			listing, e := runCommand("nft", "-a", "list", "table", "inet", "zapret2")
			if e != nil {
				tables, err := runCommand("nft", "list", "tables")
				if err != nil {
					return err
				}
				if strings.Contains(string(tables), "table inet zapret2") {
					return e
				}
				return json.NewEncoder(os.Stdout).Encode(response{"ok": true, "state": "uninstalled"})
			}
			rules, e := transportRemoveRules(string(listing))
			if e != nil {
				return e
			}
			if strings.TrimSpace(rules) != "" {
				if e = nftApply(rules); e != nil {
					return e
				}
			}
			return json.NewEncoder(os.Stdout).Encode(response{"ok": true, "state": "uninstalled"})
		}
		if err = installTransport(c, os.Args[1] == "reconcile-transport"); err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(response{"ok": true, "state": "installed"})
	}
	r := request{Command: os.Args[1]}
	if r.Command == "resolve-profile" {
		var input request
		if err = json.NewDecoder(io.LimitReader(os.Stdin, 4096)).Decode(&input); err != nil {
			return fmt.Errorf("INVALID_REQUEST")
		}
		p, e := resolveProfile(c, input.Hostname)
		if e != nil {
			return e
		}
		return json.NewEncoder(os.Stdout).Encode(response{"ok": true, "profile": p})
	}
	if r.Command == "capabilities" {
		out, e := rpc(r)
		if e != nil {
			out = capabilities(c, false)
		}
		return json.NewEncoder(os.Stdout).Encode(out)
	}
	if r.Command != "capabilities" && r.Command != "shutdown" && r.Command != "admin-stop" {
		decoder := json.NewDecoder(io.LimitReader(os.Stdin, 4096))
		decoder.DisallowUnknownFields()
		if err = decoder.Decode(&r); err != nil {
			return fmt.Errorf("INVALID_REQUEST")
		}
		if r.Command != os.Args[1] {
			return fmt.Errorf("INVALID_REQUEST")
		}
	}
	out, err := rpc(r)
	if err != nil && r.Command == "start" {
		// An existing socket may belong to a live supervisor: never unlink or steal it.
		if _, e := os.Lstat(socketFile); e == nil {
			return fmt.Errorf("AGENT_UNREACHABLE: recover stale socket after verifying no supervisor is alive")
		}
		self, e := os.Executable()
		if e != nil {
			return e
		}
		if e = secureState(); e != nil {
			return e
		}
		log, e := os.OpenFile(stateRoot+"/supervisor.log", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if e != nil {
			return e
		}
		cmd := exec.Command(self, "--guard")
		cmd.Stdout = log
		cmd.Stderr = log
		detachSupervisor(cmd)
		if e = cmd.Start(); e != nil {
			log.Close()
			return e
		}
		log.Close()
		_ = cmd.Process.Release()
		for i := 0; i < 30; i++ {
			time.Sleep(100 * time.Millisecond)
			out, err = rpc(r)
			if err == nil {
				break
			}
		}
	}
	if err != nil {
		if r.Command == "recover" || r.Command == "shutdown" || r.Command == "admin-stop" {
			var unlock func()
			var e error
			for n := 0; n < 10; n++ {
				unlock, e = managerLock()
				if e == nil {
					break
				}
				time.Sleep(100 * time.Millisecond)
			}
			if e != nil {
				return e
			}
			defer unlock()
			info, e := os.Lstat(socketFile)
			if e == nil {
				if info.Mode()&os.ModeSocket == 0 {
					return fmt.Errorf("UNSAFE_STATE_DIRECTORY")
				}
				if e = os.Remove(socketFile); e != nil {
					return e
				}
			} else if !os.IsNotExist(e) {
				return e
			}
			out = response{"ok": true, "state": "stopped"}
		} else if errors.Is(err, os.ErrNotExist) && (r.Command == "stop" || r.Command == "shutdown" || r.Command == "admin-stop") {
			out = response{"ok": true, "state": "stopped"}
		} else {
			return fmt.Errorf("AGENT_UNREACHABLE: %w", err)
		}
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
