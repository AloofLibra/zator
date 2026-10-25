package main

import "testing"

func TestDefaultSettings(t *testing.T) {
	for _, fw := range []string{"iptables", "nft", "nftables"} {
		c, err := defaultSettings("FWTYPE='" + fw + "'\n")
		if err != nil || c.validate() != nil || (fw == "iptables" && c.Backend != "iptables") || (fw != "iptables" && c.Backend != "nft") {
			t.Fatal(c, err)
		}
	}
	for _, cfg := range []string{"", "#FWTYPE=iptables", "FWTYPE=garbage"} {
		if _, err := defaultSettings(cfg); err == nil {
			t.Fatal(cfg)
		}
	}
	for _, row := range []string{`-A X --comment zator_desktop_probe -j NFQUEUE`, `-A X --comment "zator_desktop_probe" -j NFQUEUE`} {
		if !ownIPComment.MatchString(row) {
			t.Fatal(row)
		}
	}
	if ownIPComment.MatchString(`-A X --comment zator_desktop_probe_foreign -j NFQUEUE`) {
		t.Fatal("foreign comment accepted")
	}
}
