package main

import (
	"fmt"
	"strings"
)

type ipRule struct {
	chain string
	args  []string
}

func ipRules(c settings) ([]string, []ipRule, []ipRule) {
	m := fmt.Sprintf("0x%x/0x%x", c.Mark, c.Mark)
	raw := fmt.Sprintf("0x%x/0x%x", c.RawMark, c.RawMark)
	comment := []string{"-m", "comment", "--comment", "zator_desktop_probe"}
	rule := func(chain string, args ...string) ipRule { return ipRule{chain, append(args, comment...)} }
	hooks := []ipRule{
		rule("POSTROUTING", "-p", "tcp", "-m", "mark", "--mark", m, "-m", "mark", "!", "--mark", raw, "-j", "Z2R_DP_POST"),
		rule("PREROUTING", "-p", "tcp", "-m", "conntrack", "--ctdir", "REPLY", "-m", "connmark", "--mark", m, "-j", "Z2R_DP_PRE"),
		rule("INPUT", "-p", "tcp", "-m", "conntrack", "--ctdir", "REPLY", "-m", "connmark", "--mark", m, "-j", "ACCEPT"),
		rule("OUTPUT", "-p", "tcp", "--dport", "443", "-m", "owner", "--uid-owner", fmt.Sprint(c.ProxyUID), "-j", "Z2R_DP_OUT"),
		rule("OUTPUT", "-p", "tcp", "-m", "owner", "--uid-owner", fmt.Sprint(c.NfqUID), "-j", "Z2R_DP_RAW"),
		rule("POSTROUTING", "-p", "tcp", "-m", "mark", "--mark", m, "-m", "mark", "--mark", raw, "-j", "ACCEPT"),
	}
	body := []ipRule{
		rule("Z2R_DP_OUT", "-j", "MARK", "--or-mark", fmt.Sprintf("0x%x", c.Mark)),
		rule("Z2R_DP_OUT", "-j", "CONNMARK", "--or-mark", fmt.Sprintf("0x%x", c.Mark)),
		rule("Z2R_DP_OUT", "-j", "ACCEPT"),
		rule("Z2R_DP_RAW", "-j", "MARK", "--or-mark", fmt.Sprintf("0x%x", c.Mark|c.RawMark)),
		rule("Z2R_DP_RAW", "-j", "ACCEPT"),
		rule("Z2R_DP_POST", "-j", "NFQUEUE", "--queue-num", fmt.Sprint(c.Queue), "--queue-bypass"),
		rule("Z2R_DP_POST", "-j", "ACCEPT"),
		rule("Z2R_DP_PRE", "-j", "NFQUEUE", "--queue-num", fmt.Sprint(c.Queue), "--queue-bypass"),
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
	chains, body, hooks := ipRules(c)
	wait := ipWait()
	for _, r := range append(body, hooks...) {
		if _, err := ipCall(wait, "-C", r); err != nil {
			return "", fmt.Errorf("TRANSPORT_CHANGED")
		}
	}
	var state strings.Builder
	for _, chain := range append(chains, "OUTPUT", "POSTROUTING", "PREROUTING", "INPUT") {
		out, err := ipCall(wait, "-S", ipRule{chain: chain})
		if err != nil {
			return "", err
		}
		expected := map[string]int{"OUTPUT": 2, "POSTROUTING": 2, "PREROUTING": 1, "INPUT": 1}[chain]
		for _, line := range strings.Split(string(out), "\n") {
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
		state.Write(out)
	}
	return state.String(), nil
}
