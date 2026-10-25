package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestIPTablesMarkNamespaceCoexistence(t *testing.T) {
	c := testSettings()
	c.Backend = "iptables"
	good := []string{
		"",
		"-A MT_TEST -j MARK --set-xmark 0x4d616769/0xffffffff\n-A MT_TEST -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff",
		"-A OUTPUT -j CONNMARK --restore-mark\n-A OUTPUT -j MARK --set-xmark 0x200/0xff00",
		"-A OUTPUT -j MARK --and-mark 0xffff00ff\n-A OUTPUT -j MARK --or-mark 0x40000000",
		`-A OUTPUT -m comment --comment "diagnostic --set-mark 0x4000000" -j ACCEPT`,
		"-A OUTPUT -j MARK --set-xmark 0xffffaaa/0xffffffff",
	}
	for _, rules := range good {
		if err := ipMarkConflicts(c, rules, "100: from all fwmark 0x4d616769 lookup 1298229097\n200: from all fwmark 0x200/0xff00 lookup main"); err != nil {
			t.Fatalf("unrelated rules rejected: %s: %v", rules, err)
		}
	}
	bad := []string{
		"-A OUTPUT -j MARK --set-xmark 0x4000000/0xffffffff",
		"-A OUTPUT -j CONNMARK --set-mark 67108864",
		"-A OUTPUT -j MARK --set-xmark 0x0/0x1000000",
		"-A OUTPUT -j MARK --or-mark 0x4000001",
		"-A OUTPUT -j MARK --and-mark 0x4000001",
		"-A OUTPUT -j MARK --xor-mark 0x1000000",
		"-A OUTPUT -j CONNMARK --restore-mark --nfmask 0x4000000 --ctmask 0x4000000",
		"-A OUTPUT -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xff00",
		"-A OUTPUT -j HMARK --hmark-offset 0",
		"-A OUTPUT -j SET --map-mark",
		"-A OUTPUT -j MARK --set-return 0x4000000",
		"-A OUTPUT -j MARK --set-mark 4294967296",
	}
	for _, rules := range bad {
		if ipMarkConflicts(c, rules, "") == nil {
			t.Fatalf("unsafe assignment accepted: %s", rules)
		}
	}
	for _, rule := range []string{"from all fwmark 0x4000000 lookup 10", "from all fwmark 0x4000000/0xf000000 lookup 10", "from all fwmark 0x0/0x1000000 lookup 10"} {
		if ipMarkConflicts(c, "", rule) == nil {
			t.Fatal("policy can capture probe", rule)
		}
	}
	for _, mark := range []uint32{0x4d616769, 0x4d616772, 0xffffaaa, 0x0c000000, 0x08000000, 0} {
		if c.ownsMark(mark) {
			t.Fatalf("foreign conntrack mark classified as probe: %x", mark)
		}
	}
	for _, mark := range []uint32{c.Mark, c.Mark | 0xff00} {
		if !c.ownsMark(mark) {
			t.Fatalf("own identity lost: %x", mark)
		}
	}
	_, body, hooks := ipRules(c)
	text := fmt.Sprint(body, hooks)
	if strings.Contains(text, "--or-mark") || !strings.Contains(text, "0x4000000/0xf000000") {
		t.Fatal("bit-only transport remains", text)
	}
}

func TestIPTablesEvidenceRejectsForeignTagSharingTheOldBit(t *testing.T) {
	saved := runCommand
	defer func() { runCommand = saved }()
	runCommand = func(string, ...string) ([]byte, error) { return []byte("default dev wan"), nil }
	c := testSettings()
	c.Backend = "iptables"
	f := flow{Host: "example.org", Local: "192.0.2.1:37024", Remote: "93.184.216.34:443"}
	for _, mark := range []uint32{0x4d616769, 0xffffaaa} {
		_, err := flowProof(c, []flow{f}, "", fmt.Sprintf("192.0.2.1\t37024\t93.184.216.34\t443\t1\tmark=%d\tegress=wan\n", mark), 1)
		if err == nil || err.Error() != "FLOW_MARK_MISMATCH" {
			t.Fatal("foreign invocation accepted", mark, err)
		}
	}
}

func TestIPTablesFingerprintRequiresAllHooksBeforeForeignRules(t *testing.T) {
	saved := runCommand
	defer func() { runCommand = saved }()
	c := testSettings()
	c.Backend = "iptables"
	chains, body, hooks := ipRules(c)
	listing := map[string]string{}
	for _, chain := range append(chains, "OUTPUT", "POSTROUTING", "PREROUTING", "INPUT") {
		listing[chain] = "-N " + chain + "\n"
	}
	for _, r := range body {
		listing[r.chain] += "-A " + r.chain + " " + strings.Join(r.args, " ") + "\n"
	}
	for i := len(hooks) - 1; i >= 0; i-- {
		r := hooks[i]
		listing[r.chain] += "-A " + r.chain + " " + strings.Join(r.args, " ") + "\n"
	}
	runCommand = func(name string, args ...string) ([]byte, error) {
		for i, word := range args {
			if word == "-S" {
				return []byte(listing[args[i+1]]), nil
			}
		}
		return nil, nil
	}
	listing["OUTPUT"] += "-A OUTPUT -j MT_TEST\n"
	if _, err := ipFingerprint(c); err != nil {
		t.Fatal("foreign rules after owned hooks rejected", err)
	}
	good := listing["OUTPUT"]
	lines := strings.Split(strings.TrimSpace(good), "\n")
	listing["OUTPUT"] = strings.Join(append(append([]string{}, lines[:3]...), append([]string{"-A OUTPUT -j MT_TEST"}, lines[3:]...)...), "\n") + "\n"
	if _, err := ipFingerprint(c); err == nil {
		t.Fatal("foreign rule before ownerless hook accepted")
	}
	listing["OUTPUT"] = good
	listing["Z2R_DP_OUT"] += "-A Z2R_DP_OUT -j MARK --set-mark 0\n"
	if _, err := ipFingerprint(c); err == nil {
		t.Fatal("foreign rule in owned chain accepted")
	}
}
