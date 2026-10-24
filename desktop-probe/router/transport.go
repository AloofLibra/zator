package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type settings struct {
	Backend    string `json:"backend"`
	Queue      int    `json:"queue"`
	ProxyUID   int    `json:"proxy_uid"`
	NfqUID     int    `json:"nfq_uid"`
	Port       int    `json:"port"`
	Mark       uint32 `json:"mark"`
	RawMark    uint32 `json:"raw_mark"`
	WAN        string `json:"wan"`
	ZatorRoot  string `json:"zator_root"`
	ZapretRoot string `json:"zapret_root"`
}

func (c settings) identity() string {
	raw, _ := json.Marshal(c)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

type boundedOutput struct{ bytes.Buffer }

func (b *boundedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 4*1024*1024 {
		return 0, fmt.Errorf("OUTPUT_LIMIT")
	}
	return b.Buffer.Write(p)
}

var runCommand = func(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	var out boundedOutput
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.Bytes(), err
}
var ifacePattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,32}$`)
var rootPattern = regexp.MustCompile(`^/[a-zA-Z0-9_/-]+$`)
var hexPattern = regexp.MustCompile(`0[xX][0-9a-fA-F]+`)
var regexpErrorCode = regexp.MustCompile(`^[A-Z_]+$`)
var queueRulePattern = regexp.MustCompile(`(?:--queue-num|--queue-balance|to)\s+([0-9]+)(?:[:-]([0-9]+))?`)

func (c settings) validate() error {
	if c.Backend != "nft" && c.Backend != "iptables" {
		return fmt.Errorf("UNSUPPORTED_PLATFORM: select nft or iptables explicitly")
	}
	if c.Queue < 1 || c.Queue > 65534 || c.ProxyUID < 1 || c.NfqUID < 1 || c.ProxyUID > 65534 || c.NfqUID > 65534 || c.ProxyUID == c.NfqUID || c.ProxyUID == 65533 || c.NfqUID == 65533 {
		return fmt.Errorf("RESOURCE_COLLISION")
	}
	if c.Port < 1024 || c.Port > 61999 || !ifacePattern.MatchString(c.WAN) || !rootPattern.MatchString(c.ZatorRoot) || !rootPattern.MatchString(c.ZapretRoot) {
		return fmt.Errorf("INVALID_SETTINGS")
	}
	if c.Mark == 0 || c.Mark&(c.Mark-1) != 0 || c.Mark&0x7800ff00 != 0 || c.RawMark != 0x40000000 {
		return fmt.Errorf("MARK_COLLISION")
	}
	return nil
}

// Unique UID classification replaces Supersweep's source-port selector.
func transportRules(c settings) string {
	m := fmt.Sprintf("0x%x", c.Mark)
	raw := fmt.Sprintf("0x%x", c.RawMark)
	suffix := ` comment "zator_desktop_probe"`
	lines := []string{
		"add chain inet zapret2 zator_dp_output { type route hook output priority -1; policy accept; }",
		"add chain inet zapret2 zator_dp_out",
		"add chain inet zapret2 zator_dp_in",
		fmt.Sprintf("add rule inet zapret2 zator_dp_output meta nfproto ipv4 meta skuid %d tcp dport 443 ct mark set ct mark | %s meta mark set meta mark | %s%s", c.ProxyUID, m, m, suffix),
		fmt.Sprintf("add rule inet zapret2 zator_dp_output meta nfproto ipv4 meta skuid %d meta l4proto tcp meta mark set meta mark | %s | %s%s", c.NfqUID, m, raw, suffix),
		fmt.Sprintf("add rule inet zapret2 zator_dp_out meta mark & %s == 0 meta mark set meta mark | 0x20000000 counter queue num %d bypass%s", raw, c.Queue, suffix),
		"add rule inet zapret2 zator_dp_out return" + suffix,
		fmt.Sprintf("add rule inet zapret2 zator_dp_in counter queue num %d bypass%s", c.Queue, suffix),
		"add rule inet zapret2 zator_dp_in return" + suffix,
		// Insert return first: nft inserts at the head, so jump executes before return.
		fmt.Sprintf("insert rule inet zapret2 postnat_hook meta nfproto ipv4 meta l4proto tcp meta mark & %s != 0 return%s", m, suffix),
		fmt.Sprintf("insert rule inet zapret2 postnat_hook meta nfproto ipv4 meta l4proto tcp meta mark & %s != 0 jump zator_dp_out%s", m, suffix),
		fmt.Sprintf("insert rule inet zapret2 prenat_hook meta nfproto ipv4 meta l4proto tcp ct direction reply ct mark & %s != 0 return%s", m, suffix),
		fmt.Sprintf("insert rule inet zapret2 prenat_hook meta nfproto ipv4 meta l4proto tcp ct direction reply ct mark & %s != 0 jump zator_dp_in%s", m, suffix),
	}
	return strings.Join(lines, "\n") + "\n"
}

func nftApply(rules string) error {
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(rules)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("NFT_TRANSACTION_FAILED: %s: %w", out, err)
	}
	return nil
}

func nftFingerprint(c settings) (string, error) {
	var all []byte
	for _, chain := range []string{"zator_dp_output", "zator_dp_out", "zator_dp_in", "postnat_hook", "prenat_hook"} {
		out, err := runCommand("nft", "-s", "-a", "list", "chain", "inet", "zapret2", chain)
		if err != nil {
			return "", fmt.Errorf("TRANSPORT_CHANGED")
		}
		if chain == "postnat_hook" || chain == "prenat_hook" {
			rows := []string{}
			for _, line := range strings.Split(string(out), "\n") {
				line = strings.TrimSpace(line)
				if strings.Contains(line, "# handle") && !strings.HasPrefix(line, "chain ") && !strings.HasPrefix(line, "table ") {
					rows = append(rows, line)
				}
			}
			if len(rows) < 2 || !strings.Contains(rows[0], `comment "zator_desktop_probe"`) || !strings.Contains(rows[1], `comment "zator_desktop_probe"`) || !strings.Contains(rows[0], "jump zator_dp_") || !strings.Contains(rows[1], "return") {
				return "", fmt.Errorf("TRANSPORT_CHANGED")
			}
		}
		all = append(all, out...)
	}
	if strings.Count(string(all), `comment "zator_desktop_probe"`) != 10 {
		return "", fmt.Errorf("TRANSPORT_CHANGED")
	}
	text := string(all)
	if !strings.Contains(text, "meta mark set meta mark | 0x20000000") {
		return "", fmt.Errorf("TRANSPORT_SETTINGS_MISMATCH")
	}
	if !strings.Contains(text, fmt.Sprintf("meta skuid %d ", c.ProxyUID)) || !strings.Contains(text, fmt.Sprintf("meta skuid %d ", c.NfqUID)) || strings.Count(text, fmt.Sprintf("queue flags bypass to %d ", c.Queue)) != 2 || !strings.Contains(text, fmt.Sprintf("0x%08x", c.Mark)) {
		return "", fmt.Errorf("TRANSPORT_SETTINGS_MISMATCH")
	}
	sum := sha256.Sum256(all)
	return hex.EncodeToString(sum[:]), nil
}

func transportFingerprint(c settings) (string, error) {
	if err := configCompatible(c); err != nil {
		return "", err
	}
	var state string
	var err error
	if c.Backend == "iptables" {
		state, err = ipFingerprint(c)
	} else {
		state, err = nftFingerprint(c)
	}
	if err != nil {
		return "", err
	}
	generation, err := os.ReadFile(stateRoot + "/transport-generation")
	if err != nil {
		return "", fmt.Errorf("TRANSPORT_CHANGED")
	}
	state += string(generation)
	for _, path := range []string{c.ZapretRoot + "/config", c.ZatorRoot + "/lua/locked.lua", c.ZatorRoot + "/lua/fake-adapt.lua"} {
		raw, e := readLimited(path, 1024*1024)
		if e != nil {
			return "", fmt.Errorf("CONFIG_CHANGED")
		}
		sum := sha256.Sum256(raw)
		state += hex.EncodeToString(sum[:])
	}
	for _, args := range [][]string{{"-4", "rule"}, {"-4", "route", "show", "table", "all"}} {
		out, e := runCommand("ip", args...)
		if e != nil {
			return "", fmt.Errorf("ROUTE_UNAVAILABLE")
		}
		state += string(out)
	}
	sum := sha256.Sum256([]byte(state))
	return hex.EncodeToString(sum[:]), nil
}

func installTransport(c settings, reconcile bool) error {
	if err := configCompatible(c); err != nil {
		return err
	}
	if reconcile {
		if _, err := os.Stat(stateRoot + "/disabled"); err == nil {
			return fmt.Errorf("COMPONENT_DISABLED")
		}
	}
	if reconcile {
		active := false
		if out, err := rpc(request{Command: "capabilities"}); err == nil {
			active = out["session_active"] == true
			if active && out["settings_id"] != c.identity() {
				return fmt.Errorf("SESSION_BUSY: settings changed")
			}
		}
		if !active {
			if err := resourceConflicts(c, "/proc"); err != nil {
				return err
			}
		}
	}
	if _, err := transportFingerprint(c); err == nil {
		if reconcile {
			return os.WriteFile(stateRoot+"/transport-generation", []byte(randomID()), 0600)
		}
		if !reconcile {
			if err = os.Remove(stateRoot + "/disabled"); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
		return nil
	}
	if !reconcile {
		if err := resourceConflicts(c, "/proc"); err != nil {
			return err
		}
	}
	if c.Backend == "iptables" {
		if reconcile {
			if err := ipRemove(c); err != nil {
				return err
			}
		}
		if err := ipInstall(c); err != nil {
			return err
		}
	} else {
		rules := ""
		if reconcile {
			listing, err := runCommand("nft", "-a", "list", "table", "inet", "zapret2")
			if err != nil {
				return err
			}
			rules, err = transportRemoveRules(string(listing))
			if err != nil {
				return err
			}
		}
		if err := nftApply(rules + transportRules(c)); err != nil {
			return err
		}
	}
	if err := os.WriteFile(stateRoot+"/transport-generation", []byte(randomID()), 0600); err != nil {
		return err
	}
	if !reconcile {
		if err := os.Remove(stateRoot + "/disabled"); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func resourceConflicts(c settings, procRoot string) error {
	if err := c.validate(); err != nil {
		return err
	}
	if err := configCompatible(c); err != nil {
		return err
	}
	var rules []byte
	var err error
	if c.Backend == "iptables" {
		rules, err = runCommand("iptables-save", "-t", "mangle")
	} else {
		rules, err = runCommand("nft", "-s", "list", "ruleset")
	}
	if err != nil {
		return fmt.Errorf("UNSUPPORTED_CAPABILITY: nft ruleset")
	}
	for _, line := range strings.Split(string(rules), "\n") {
		if strings.Contains(line, `comment "zator_desktop_probe"`) {
			continue
		}
		if strings.Contains(strings.ToLower(line), "queue") {
			for _, match := range queueRulePattern.FindAllStringSubmatch(line, -1) {
				first, _ := strconv.Atoi(match[1])
				last := first
				if match[2] != "" {
					last, _ = strconv.Atoi(match[2])
				}
				if c.Queue >= first && c.Queue <= last {
					return fmt.Errorf("QUEUE_COLLISION")
				}
			}
		}
		for _, text := range hexPattern.FindAllString(line, -1) {
			value, e := strconv.ParseUint(text[2:], 16, 32)
			if e != nil || uint32(value)&c.Mark != 0 {
				return fmt.Errorf("MARK_COLLISION")
			}
		}
	}
	policies, e := runCommand("ip", "-4", "rule")
	if e != nil {
		return fmt.Errorf("ROUTE_UNAVAILABLE")
	}
	for _, text := range hexPattern.FindAllString(string(policies), -1) {
		bits, e := strconv.ParseUint(text[2:], 16, 32)
		if e != nil || uint32(bits)&c.Mark != 0 {
			return fmt.Errorf("MARK_COLLISION")
		}
	}
	raw, err := os.ReadFile(procRoot + "/net/netfilter/nfnetlink_queue")
	if err != nil {
		return fmt.Errorf("UNSUPPORTED_CAPABILITY: nfnetlink_queue")
	}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) > 0 && f[0] == strconv.Itoa(c.Queue) {
			return fmt.Errorf("QUEUE_COLLISION")
		}
	}
	proxyID, nfqID := strconv.Itoa(c.ProxyUID), strconv.Itoa(c.NfqUID)
	for _, path := range []string{"/etc/passwd", "/etc/group"} {
		accounts, err := readLimited(path, 1024*1024)
		if err != nil {
			return err
		}
		for _, line := range strings.Split(string(accounts), "\n") {
			f := strings.Split(line, ":")
			if len(f) > 2 && (f[2] == proxyID || f[2] == nfqID) {
				return fmt.Errorf("UID_COLLISION")
			}
			if path == "/etc/passwd" && len(f) > 3 && (f[3] == proxyID || f[3] == nfqID) {
				return fmt.Errorf("UID_COLLISION")
			}
		}
	}
	processes, err := os.ReadDir(procRoot)
	if err != nil {
		return err
	}
	for _, p := range processes {
		if _, err := strconv.Atoi(p.Name()); err != nil {
			continue
		}
		status, err := os.ReadFile(procRoot + "/" + p.Name() + "/status")
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		for _, line := range strings.Split(string(status), "\n") {
			if strings.HasPrefix(line, "Uid:") || strings.HasPrefix(line, "Gid:") {
				for _, uid := range strings.Fields(line)[1:] {
					if uid == proxyID || uid == nfqID {
						return fmt.Errorf("UID_COLLISION")
					}
				}
			}
		}
	}
	return nil
}

func transportRemoveRules(listing string) (string, error) {
	chain := ""
	var rules []string
	for _, line := range strings.Split(listing, "\n") {
		f := strings.Fields(line)
		if len(f) > 1 && f[0] == "chain" {
			chain = f[1]
		}
		if !strings.Contains(line, `comment "zator_desktop_probe"`) {
			continue
		}
		if !ifacePattern.MatchString(chain) {
			return "", fmt.Errorf("INVALID_NFT_CHAIN")
		}
		for i := 0; i+1 < len(f); i++ {
			if f[i] == "handle" {
				if _, err := strconv.ParseUint(f[i+1], 10, 64); err != nil {
					return "", err
				}
				rules = append(rules, "delete rule inet zapret2 "+chain+" handle "+f[i+1])
				break
			}
		}
	}
	for _, name := range []string{"zator_dp_output", "zator_dp_out", "zator_dp_in"} {
		if strings.Contains(listing, "chain "+name+" {") {
			rules = append(rules, "delete chain inet zapret2 "+name)
		}
	}
	return strings.Join(rules, "\n") + "\n", nil
}
