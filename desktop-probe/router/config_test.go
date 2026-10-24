package main

import (
	"os"
	"strings"
	"testing"
)

func TestShippedProfiles(t *testing.T) {
	raw, err := os.ReadFile("../../config.default")
	if err != nil {
		t.Fatal(err)
	}
	for profile := 1; profile <= 4; profile++ {
		args, numbers, err := profilePlan(string(raw), profile)
		if err != nil {
			t.Fatal(profile, err)
		}
		if len(numbers) < 2 {
			t.Fatal("missing strategies", profile)
		}
		if strings.Count(strings.Join(args, "\n"), "--new\n") != 1 {
			t.Fatal("empty shadow profile", profile)
		}
		for _, arg := range args {
			if strings.Contains(arg, "--hostlist") || strings.Contains(arg, "--lua-init") {
				t.Fatal("production filter/init leaked", arg)
			}
		}
	}
	if _, _, err := profilePlan(string(raw), 5); err == nil {
		t.Fatal("UDP accepted")
	}
	if _, _, err := profilePlan("NFQWS2_OPT=\"\n--new\n\"", 1); err == nil {
		t.Fatal("broken config accepted")
	}
}

func testSettings() settings {
	return settings{Backend: "nft", Queue: 65534, ProxyUID: 65531, NfqUID: 65532, Port: 41081, Mark: 0x04000000, RawMark: 0x40000000, WAN: "pppoe-wan", ZatorRoot: "/opt/zator", ZapretRoot: "/opt/zapret2"}
}

func TestResourceValidation(t *testing.T) {
	c := testSettings()
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*settings){func(c *settings) { c.Queue = 65535 }, func(c *settings) { c.ProxyUID = c.NfqUID }, func(c *settings) { c.NfqUID = 65533 }, func(c *settings) { c.Mark = 0x08000000 }, func(c *settings) { c.Mark = 0x04000001 }, func(c *settings) { c.WAN = "wan;reboot" }, func(c *settings) { c.ZatorRoot = "/tmp/a\";bad" }} {
		bad := c
		change(&bad)
		if bad.validate() == nil {
			t.Fatal("unsafe settings", bad)
		}
	}
}

func TestStaticTransport(t *testing.T) {
	rules := transportRules(testSettings())
	for _, want := range []string{"meta skuid 65531 tcp dport 443", "meta skuid 65532", "ct direction reply ct mark", "queue num 65534 bypass", "jump zator_dp_out", "jump zator_dp_in"} {
		if !strings.Contains(rules, want) {
			t.Fatal(want)
		}
	}
	if strings.Contains(rules, "65535") || strings.Contains(rules, "62000") || strings.Contains(rules, "flush") {
		t.Fatal("production/Supersweep interference")
	}
	jump := strings.LastIndex(rules, "jump zator_dp_out")
	ret := strings.Index(rules, "postnat_hook meta nfproto ipv4 meta l4proto tcp meta mark & 0x4000000 != 0 return")
	if ret < 0 || jump < ret {
		t.Fatal("nft reverse insertion ordering")
	}
}
