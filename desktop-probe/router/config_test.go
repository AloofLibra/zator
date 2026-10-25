package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTCPPacketWindow(t *testing.T) {
	out, in, err := tcpPacketWindow("NFQWS2_TCP_PKT_OUT=20\nNFQWS2_TCP_PKT_IN='10'\n")
	if err != nil || out != 20 || in != 10 {
		t.Fatal(out, in, err)
	}
	for _, cfg := range []string{"", "NFQWS2_TCP_PKT_OUT=0\nNFQWS2_TCP_PKT_IN=0"} {
		out, in, err = tcpPacketWindow(cfg)
		if err != nil || out != 0 || in != 0 {
			t.Fatal(out, in, err)
		}
	}
	for _, value := range []string{"-1", "garbage", "65536"} {
		if _, _, err := tcpPacketWindow("NFQWS2_TCP_PKT_OUT=" + value); err == nil {
			t.Fatal(value)
		}
	}
}

func TestTCPPacketWindowCannotChangeUnderAnExistingSettingsSnapshot(t *testing.T) {
	c := testSettings()
	c.Backend = "iptables"
	c.ZapretRoot = t.TempDir()
	c.packetOut = 20
	c.packetIn = 10
	config := "FWTYPE=iptables\nDESYNC_MARK=0x40000000\nNFQWS2_TCP_PKT_OUT=20\nNFQWS2_TCP_PKT_IN=10\n"
	path := filepath.Join(c.ZapretRoot, "config")
	if err := os.WriteFile(path, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	if err := configCompatible(c); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Replace(config, "PKT_OUT=20", "PKT_OUT=21", 1)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := configCompatible(c); err == nil || !strings.HasPrefix(err.Error(), "CONFIG_CHANGED") {
		t.Fatal("stale packet window accepted", err)
	}
}

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

func TestPairedYouTubeConfig(t *testing.T) {
	c := testSettings()
	c.ZatorRoot = t.TempDir()
	c.ZapretRoot = t.TempDir()
	dir := filepath.Join(t.TempDir(), "nfq")
	for _, path := range []string{filepath.Join(c.ZatorRoot, "lua"), filepath.Join(c.ZatorRoot, "extra_strats/cache/orchestra"), dir} {
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
	}
	cfg, err := os.ReadFile("../../config.default")
	if err != nil {
		t.Fatal(err)
	}
	lua, err := os.ReadFile("../../orchestra/locked.lua")
	if err != nil {
		t.Fatal(err)
	}
	for path, body := range map[string][]byte{filepath.Join(c.ZapretRoot, "config"): cfg, filepath.Join(c.ZatorRoot, "lua/locked.lua"): lua, filepath.Join(c.ZatorRoot, "extra_strats/cache/orchestra/locked.tsv"): []byte("production\n")} {
		if err := os.WriteFile(path, body, 0644); err != nil {
			t.Fatal(err)
		}
	}
	args, err := prepareConfig(c, dir, 1, 3, 7)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, "\n")
	gv, yt := strings.Index(joined, "--lua-desync=circular_locked:key=2"), strings.Index(joined, "--lua-desync=circular_locked:key=1")
	if gv < 0 || yt <= gv || strings.Count(joined, "\n--new\n") != 2 || !strings.Contains(joined, "--hostlist-domains=googlevideo.com") {
		t.Fatal("wrong profile routing or separator", joined)
	}
	locks, _ := os.ReadFile(filepath.Join(dir, "locked.tsv"))
	if string(locks) != "1\ttls\t3\n2\ttls\t7\n" {
		t.Fatal(string(locks))
	}
	adapter, _ := os.ReadFile(filepath.Join(dir, "locked.lua"))
	if !strings.Contains(string(adapter), `.."\t"..tostring(profile)`) {
		t.Fatal("profile identity missing from private evidence")
	}
	if !strings.Contains(string(adapter), "tonumber(desync.fwmark)") || !strings.Contains(string(adapter), `egress="..tostring(desync.ifout`) {
		t.Fatal("packet-time mark/egress not recorded")
	}
	production, _ := os.ReadFile(filepath.Join(c.ZatorRoot, "extra_strats/cache/orchestra/locked.tsv"))
	if string(production) != "production\n" {
		t.Fatal("production lock changed")
	}
	if _, err = prepareConfig(c, dir, 1, 3, 999); err == nil {
		t.Fatal("unknown GV strategy accepted")
	}
	if _, err = prepareConfig(c, dir, 2, 3, 7); err == nil {
		t.Fatal("paired non-YT profile accepted")
	}
}

func testSettings() settings {
	return settings{Backend: "nft", Queue: 65534, ProxyUID: 65531, NfqUID: 65532, Port: 41081, Mark: 0x04000000, RawMark: 0x40000000, ZatorRoot: "/opt/zator", ZapretRoot: "/opt/zapret2"}
}

func TestResourceValidation(t *testing.T) {
	c := testSettings()
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*settings){func(c *settings) { c.Queue = 65535 }, func(c *settings) { c.ProxyUID = c.NfqUID }, func(c *settings) { c.NfqUID = 65533 }, func(c *settings) { c.Mark = 0x08000000 }, func(c *settings) { c.Mark = 0x04000001 }, func(c *settings) { c.ZatorRoot = "/tmp/a\";bad" }} {
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
	if !strings.Contains(rules, "meta l4proto tcp ct mark & 0x4000000 != 0 meta mark set meta mark | 0x4000000") || strings.Contains(rules, "ct mark set meta mark") {
		t.Fatal("conntrack fallback missing or foreign mark bits overwritten")
	}
	jump := strings.LastIndex(rules, "jump zator_dp_out")
	ret := strings.Index(rules, "postnat_hook meta nfproto ipv4 meta l4proto tcp meta mark & 0x4000000 != 0 return")
	if ret < 0 || jump < ret {
		t.Fatal("nft reverse insertion ordering")
	}
}
