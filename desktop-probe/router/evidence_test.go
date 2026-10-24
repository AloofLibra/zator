package main

import (
	"testing"
)

func TestFlowEvidence(t *testing.T) {
	f := flow{Local: "192.0.2.1:37024", Remote: "93.184.216.34:443"}
	snapshot := "ipv4 2 tcp 6 113 TIME_WAIT src=192.0.2.1 dst=93.184.216.34 sport=37024 dport=443 packets=15 src=93.184.216.34 dst=192.0.2.1 sport=443 dport=37024 mark=67138866"
	if mark, ok := conntrackMark(snapshot, f); !ok || mark != 67138866 {
		t.Fatal("tuple not matched", mark, ok)
	}
	other := f
	other.Local = "192.0.2.1:37025"
	if _, ok := conntrackMark(snapshot, other); ok {
		t.Fatal("unrelated flow matched")
	}
	event := "192.0.2.1\t37024\t93.184.216.34\t443\t7\n"
	if !invoked(event, f, 7) || invoked(event, f, 8) || invoked(event, other, 7) {
		t.Fatal("strategy identity lost")
	}
	original := runCommand
	defer func() { runCommand = original }()
	runCommand = func(name string, args ...string) ([]byte, error) {
		return []byte("93.184.216.34 dev work src 192.0.2.1"), nil
	}
	if _, err := flowProof(testSettings(), []flow{f}, snapshot, event, 7); err == nil {
		t.Fatal("VPN accepted")
	}
	queries := 0
	runCommand = func(name string, args ...string) ([]byte, error) {
		queries++
		return []byte("93.184.216.34 dev pppoe-wan src 192.0.2.1"), nil
	}
	proof, err := flowProof(testSettings(), []flow{f}, snapshot, event, 7)
	if err != nil || proof["connection_match"] != "verified" {
		t.Fatal(proof, err)
	}
	queries = 0
	if _, err = flowProof(testSettings(), []flow{f, f}, snapshot, event, 7); err != nil || queries != 1 {
		t.Fatal("route fork repeated for one destination", queries, err)
	}
	proof, err = flowProof(testSettings(), []flow{f}, snapshot, "", 7)
	if err != nil || proof["connection_match"] == "verified" {
		t.Fatal("missing Lua evidence accepted")
	}
}
