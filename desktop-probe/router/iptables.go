package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var ownIPComment = regexp.MustCompile(`(?:^|\s)--comment\s+(?:"zator_desktop_probe"|zator_desktop_probe)(?:\s|$)`)

func (c settings) markMask() uint32 {
	if c.Backend == "iptables" && c.Mark&0x07000000 != 0 {
		return 0x0f000000
	}
	return c.Mark
}

func (c settings) ownsMark(mark uint32) bool { return mark&c.markMask() == c.Mark }

func parseIPMark(value string) (uint32, uint32, error) {
	parts := strings.Split(value, "/")
	if len(parts) > 2 {
		return 0, 0, fmt.Errorf("MARK_COLLISION: invalid mark")
	}
	v, err := strconv.ParseUint(parts[0], 0, 32)
	mask := uint64(0xffffffff)
	if err == nil && len(parts) == 2 {
		mask, err = strconv.ParseUint(parts[1], 0, 32)
	}
	return uint32(v), uint32(mask), err
}

var ipQuoted = regexp.MustCompile(`"(?:[^"\\]|\\.)*"`)

// Full-word assignments/copies outside our tag are safe: probe hooks terminate
// each mangle path before foreign rules. Partial tag writes remain unsupported.
func ipMarkConflicts(c settings, rules, policies string) error {
	ns := c.markMask()
	bad := func() error { return fmt.Errorf("MARK_COLLISION: foreign rule can produce the probe tag") }
	for _, line := range strings.Split(rules, "\n") {
		if ownIPComment.MatchString(line) {
			continue
		}
		fields := strings.Fields(ipQuoted.ReplaceAllString(line, `""`))
		nfmask, ctmask := uint32(0xffffffff), uint32(0xffffffff)
		copyMark := false
		markTarget, operation := false, false
		for i, word := range fields {
			if word == "--save-mark" || word == "--restore-mark" {
				copyMark = true
				operation = true
			}
			if word == "HMARK" || word == "--map-mark" {
				return bad()
			}
			if i+1 == len(fields) {
				continue
			}
			if (word == "-j" || word == "--jump") && (fields[i+1] == "MARK" || fields[i+1] == "CONNMARK" || fields[i+1] == "TPROXY") {
				markTarget = true
			}
			switch word {
			case "--set-mark", "--set-xmark", "--or-mark", "--and-mark", "--xor-mark", "--tproxy-mark", "--nfmask", "--ctmask":
				value, mask, err := parseIPMark(fields[i+1])
				if err != nil {
					return bad()
				}
				if word != "--nfmask" && word != "--ctmask" {
					operation = true
				}
				switch word {
				case "--nfmask":
					nfmask = value
				case "--ctmask":
					ctmask = value
				case "--and-mark":
					if value&ns != ns && value&c.Mark == c.Mark {
						return bad()
					}
				case "--or-mark":
					if value&ns == c.Mark {
						return bad()
					}
				case "--xor-mark":
					if value&ns != 0 {
						return bad()
					}
				default:
					if mask&ns != 0 && (mask&ns != ns || value&ns == c.Mark) {
						return bad()
					}
				}
			}
		}
		if markTarget && !operation {
			return bad()
		}
		if copyMark && ((nfmask&ns != 0 && nfmask&ns != ns) || (ctmask&ns != 0 && ctmask&ns != ns) || nfmask&ns != ctmask&ns) {
			return bad()
		}
	}
	for _, line := range strings.Split(policies, "\n") {
		fields := strings.Fields(line)
		for i, word := range fields {
			if word != "fwmark" || i+1 == len(fields) {
				continue
			}
			value, mask, err := parseIPMark(fields[i+1])
			if err != nil || (mask&ns != 0 && c.Mark&mask == value&mask) {
				return fmt.Errorf("MARK_COLLISION: policy selects probe tag")
			}
		}
	}
	return nil
}

type ipRule struct {
	chain string
	args  []string
}

func ipRules(c settings) ([]string, []ipRule, []ipRule) {
	m := fmt.Sprintf("0x%x/0x%x", c.Mark, c.markMask())
	raw := fmt.Sprintf("0x%x/0x%x", c.RawMark, c.RawMark)
	comment := []string{"-m", "comment", "--comment", "zator_desktop_probe"}
	rule := func(chain string, args ...string) ipRule { return ipRule{chain, append(args, comment...)} }
	queue := func(chain, direction string, limit int) ipRule {
		args := []string{}
		if limit > 0 {
			args = append(args, "-m", "connbytes", "--connbytes", fmt.Sprintf("1:%d", limit), "--connbytes-mode", "packets", "--connbytes-dir", direction)
		}
		return rule(chain, append(args, "-j", "NFQUEUE", "--queue-num", fmt.Sprint(c.Queue), "--queue-bypass")...)
	}
	hooks := []ipRule{
		rule("POSTROUTING", "-p", "tcp", "-m", "mark", "--mark", m, "-m", "mark", "!", "--mark", raw, "-j", "Z2R_DP_POST"),
		rule("PREROUTING", "-p", "tcp", "-m", "conntrack", "--ctdir", "REPLY", "-m", "connmark", "--mark", m, "-j", "Z2R_DP_PRE"),
		rule("INPUT", "-p", "tcp", "-m", "conntrack", "--ctdir", "REPLY", "-m", "connmark", "--mark", m, "-j", "ACCEPT"),
		rule("OUTPUT", "-p", "tcp", "-m", "connmark", "--mark", m, "-j", "Z2R_DP_OUT"),
		rule("OUTPUT", "-p", "tcp", "--dport", "443", "-m", "owner", "--uid-owner", fmt.Sprint(c.ProxyUID), "-j", "Z2R_DP_OUT"),
		rule("OUTPUT", "-p", "tcp", "-m", "owner", "--uid-owner", fmt.Sprint(c.NfqUID), "-j", "Z2R_DP_RAW"),
		rule("POSTROUTING", "-p", "tcp", "-m", "mark", "--mark", m, "-m", "mark", "--mark", raw, "-j", "ACCEPT"),
	}
	body := []ipRule{
		rule("Z2R_DP_OUT", "-j", "MARK", "--set-xmark", m),
		rule("Z2R_DP_OUT", "-j", "CONNMARK", "--set-xmark", m),
		rule("Z2R_DP_OUT", "-j", "ACCEPT"),
		rule("Z2R_DP_RAW", "-j", "MARK", "--set-xmark", fmt.Sprintf("0x%x/0x%x", c.Mark|c.RawMark, c.markMask()|c.RawMark)),
		rule("Z2R_DP_RAW", "-j", "ACCEPT"),
		queue("Z2R_DP_POST", "original", c.packetOut),
		rule("Z2R_DP_POST", "-j", "ACCEPT"),
		queue("Z2R_DP_PRE", "reply", c.packetIn),
		rule("Z2R_DP_PRE", "-j", "ACCEPT"),
	}
	return []string{"Z2R_DP_OUT", "Z2R_DP_RAW", "Z2R_DP_POST", "Z2R_DP_PRE"}, body, hooks
}

func ipWait() []string {
	if _, err := runCommand("iptables", "-w", "5", "-t", "mangle", "-nL", "OUTPUT"); err == nil {
		return []string{"-w", "5"}
	}
	if _, err := runCommand("iptables", "-w", "-t", "mangle", "-nL", "OUTPUT"); err == nil {
		return []string{"-w"}
	}
	return nil
}
func ipCall(wait []string, op string, r ipRule) ([]byte, error) {
	args := append(append([]string{}, wait...), "-t", "mangle", op, r.chain)
	args = append(args, r.args...)
	out, err := runCommand("iptables", args...)
	if err != nil {
		return out, fmt.Errorf("IPTABLES_FAILED: %s", out)
	}
	return out, nil
}

func ipInstall(c settings) error {
	chains, body, hooks := ipRules(c)
	wait := ipWait()
	// Refuse foreign/stale chains rather than flushing a resource we did not create.
	for _, chain := range chains {
		if _, err := ipCall(wait, "-S", ipRule{chain: chain}); err == nil {
			return fmt.Errorf("RESOURCE_COLLISION: " + chain)
		}
	}
	created := []string{}
	inserted := []ipRule{}
	rollback := func() {
		for i := len(inserted) - 1; i >= 0; i-- {
			_, _ = ipCall(wait, "-D", inserted[i])
		}
		for i := len(created) - 1; i >= 0; i-- {
			_, _ = ipCall(wait, "-F", ipRule{chain: created[i]})
			_, _ = ipCall(wait, "-X", ipRule{chain: created[i]})
		}
	}
	for _, chain := range chains {
		if _, err := ipCall(wait, "-N", ipRule{chain: chain}); err != nil {
			rollback()
			return err
		}
		created = append(created, chain)
	}
	for _, r := range body {
		if _, err := ipCall(wait, "-A", r); err != nil {
			rollback()
			return err
		}
	}
	for _, r := range hooks {
		if _, err := ipCall(wait, "-I", r); err != nil {
			rollback()
			return err
		}
		inserted = append(inserted, r)
	}
	return nil
}

func ipRemove(c settings) error {
	chains, _, hooks := ipRules(c)
	wait := ipWait()
	for i := len(hooks) - 1; i >= 0; i-- {
		r := hooks[i]
		if _, err := ipCall(wait, "-C", r); err != nil {
			if _, e := ipCall(wait, "-S", ipRule{chain: r.chain}); e != nil {
				return e
			}
			continue
		}
		if _, err := ipCall(wait, "-D", r); err != nil {
			return err
		}
	}
	for _, chain := range chains {
		listing, err := ipCall(wait, "-S", ipRule{chain: chain})
		if err != nil {
			all, e := runCommand("iptables-save", "-t", "mangle")
			if e != nil {
				return e
			}
			if strings.Contains(string(all), ":"+chain+" ") {
				return err
			}
			continue
		}
		for _, line := range strings.Split(string(listing), "\n") {
			if strings.HasPrefix(line, "-A ") && !strings.Contains(line, "zator_desktop_probe") {
				return fmt.Errorf("FOREIGN_CHAIN_RULE")
			}
		}
		if _, err = ipCall(wait, "-F", ipRule{chain: chain}); err != nil {
			return err
		}
		if _, err = ipCall(wait, "-X", ipRule{chain: chain}); err != nil {
			return err
		}
	}
	all, err := runCommand("iptables-save", "-t", "mangle")
	if err != nil {
		return err
	}
	if strings.Contains(string(all), "zator_desktop_probe") {
		return fmt.Errorf("CLEANUP_INCOMPLETE")
	}
	return nil
}

func ipFingerprint(c settings) (string, error) {
	return ipFingerprintWithChecks(c, true)
}

func ipFingerprintWithChecks(c settings, verifyRules bool) (string, error) {
	chains, body, hooks := ipRules(c)
	if verifyRules {
		wait := ipWait()
		for _, r := range append(body, hooks...) {
			if _, err := ipCall(wait, "-C", r); err != nil {
				return "", fmt.Errorf("TRANSPORT_CHANGED")
			}
		}
	}
	snapshot, err := runCommand("iptables-save", "-t", "mangle")
	if err != nil {
		return "", err
	}
	definitions, rows := map[string]string{}, map[string][]string{}
	for _, line := range strings.Split(string(snapshot), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.HasPrefix(fields[0], ":") {
			name := strings.TrimPrefix(fields[0], ":")
			definitions[name] = "-N " + name
			if fields[1] != "-" {
				definitions[name] = "-P " + name + " " + fields[1]
			}
		} else if len(fields) >= 3 && fields[0] == "-A" {
			rows[fields[1]] = append(rows[fields[1]], line)
		}
	}
	var state strings.Builder
	for _, chain := range append(chains, "OUTPUT", "POSTROUTING", "PREROUTING", "INPUT") {
		definition, found := definitions[chain]
		if !found {
			return "", fmt.Errorf("TRANSPORT_CHANGED")
		}
		expected := map[string]int{"OUTPUT": 3, "POSTROUTING": 2, "PREROUTING": 1, "INPUT": 1}[chain]
		private := strings.HasPrefix(chain, "Z2R_DP_")
		privateCount := 0
		for _, line := range rows[chain] {
			if private && strings.HasPrefix(line, "-A ") {
				if !strings.Contains(line, "zator_desktop_probe") {
					return "", fmt.Errorf("TRANSPORT_CHANGED")
				}
				privateCount++
			}
			if expected > 0 && strings.HasPrefix(line, "-A ") {
				if !strings.Contains(line, "zator_desktop_probe") {
					return "", fmt.Errorf("TRANSPORT_CHANGED")
				}
				expected--
			}
		}
		if expected != 0 {
			return "", fmt.Errorf("TRANSPORT_CHANGED")
		}
		if private {
			wanted := 0
			for _, r := range body {
				if r.chain == chain {
					wanted++
				}
			}
			if privateCount != wanted {
				return "", fmt.Errorf("TRANSPORT_CHANGED")
			}
		}
		state.WriteString(definition + "\n")
		for _, line := range rows[chain] {
			state.WriteString(line + "\n")
		}
	}
	return state.String(), nil
}
