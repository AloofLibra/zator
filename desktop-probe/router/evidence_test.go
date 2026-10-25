package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestFlowEvidence(t *testing.T) {
	f := flow{Host: "www.youtube.com", Local: "192.0.2.1:37024", Remote: "93.184.216.34:443"}
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
		if reflect.DeepEqual(args, []string{"-4", "route", "show", "table", "main", "default"}) {
			return []byte("default dev pppoe-wan"), nil
		}
		return []byte("93.184.216.34 dev work src 192.0.2.1"), nil
	}
	if _, err := flowProof(testSettings(), []flow{f}, snapshot, event, 7); err == nil {
		t.Fatal("VPN accepted")
	}
	queries := 0
	runCommand = func(name string, args ...string) ([]byte, error) {
		if reflect.DeepEqual(args, []string{"-4", "route", "show", "table", "main", "default"}) {
			return []byte("default dev pppoe-wan"), nil
		}
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
	if proof["unavailable_reason"] != "STRATEGY_INVOCATION_NOT_FOUND" || proof["matched_flows"] != 1 {
		t.Fatal("missing evidence cannot be diagnosed", proof)
	}
	missing, err := flowProof(testSettings(), []flow{f}, "", event, 7)
	if err != nil || missing["unavailable_reason"] != "CONNTRACK_NOT_FOUND" {
		t.Fatal(missing, err)
	}
	other.Host = "i.ytimg.com"
	proof, err = flowProof(testSettings(), []flow{other, f}, snapshot, event, 7)
	if err != nil || !reflect.DeepEqual(proof["verified_hosts"], []string{f.Host}) {
		t.Fatal("expired auxiliary flow invalidated document", proof, err)
	}
	auxiliary := strings.ReplaceAll(snapshot, "sport=37024", "sport=37025")
	proof, err = flowProof(testSettings(), []flow{f, other}, snapshot+"\n"+auxiliary, event, 7)
	if err != nil || !reflect.DeepEqual(proof["verified_hosts"], []string{f.Host}) {
		t.Fatal("auxiliary flow without Lua was trusted or invalidated document", proof, err)
	}
	if _, err = flowProof(testSettings(), []flow{f}, strings.ReplaceAll(snapshot, "mark=67138866", "mark=0"), event, 7); err == nil {
		t.Fatal("known unmarked flow accepted")
	}
	media := f
	media.Host = "video.googlevideo.com"
	pairedEvent := strings.TrimSpace(event) + "\t1\n"
	proof, err = flowProof(testSettings(), []flow{f}, snapshot, pairedEvent, 7, 8)
	if err != nil || proof["connection_match"] != "verified" {
		t.Fatal("YT pair evidence rejected", proof, err)
	}
	proof, err = flowProof(testSettings(), []flow{media}, snapshot, pairedEvent, 7, 8)
	if err != nil || proof["connection_match"] == "verified" {
		t.Fatal("YT strategy was accepted for GV", proof, err)
	}
	pairedEvent = strings.Replace(pairedEvent, "\t7\t1", "\t8\t2", 1)
	proof, err = flowProof(testSettings(), []flow{media}, snapshot, pairedEvent, 7, 8)
	if err != nil || proof["connection_match"] != "verified" {
		t.Fatal("independent GV evidence rejected", proof, err)
	}
	proof, err = flowProof(testSettings(), []flow{media}, snapshot, strings.Replace(pairedEvent, "\t8\t2", "\t8\t1", 1), 7, 8)
	if err != nil || proof["connection_match"] == "verified" {
		t.Fatal("correct number under wrong profile was accepted", proof, err)
	}
	marked := strings.TrimSpace(event) + "\tmark=604009778\tegress=pppoe-wan\n"
	proof, err = flowProof(testSettings(), []flow{f}, "", marked, 7)
	if err != nil || proof["connection_match"] != "verified" || proof["packet_snapshot_flows"] != 1 {
		t.Fatal("expired flow lost its packet-time proof", proof, err)
	}
	for _, unproven := range []string{event, strings.ReplaceAll(marked, "\tegress=pppoe-wan", ""), strings.ReplaceAll(marked, "\t7\tmark", "\t8\tmark")} {
		proof, err = flowProof(testSettings(), []flow{f}, "", unproven, 7)
		if err != nil || proof["connection_match"] == "verified" {
			t.Fatal("incomplete/wrong historical evidence accepted", proof, err)
		}
	}
	for _, unsafe := range []string{strings.ReplaceAll(marked, "604009778", "0"), strings.ReplaceAll(marked, "604009778", "1140850688"), strings.ReplaceAll(marked, "pppoe-wan", "work")} {
		if _, err = flowProof(testSettings(), []flow{f}, "", unsafe, 7); err == nil {
			t.Fatal("bad recorded mark/egress accepted", unsafe)
		}
	}
	auxEvent := strings.ReplaceAll(marked, "\t37024\t", "\t37025\t")
	proof, err = flowProof(testSettings(), []flow{f, other}, auxiliary, marked+auxEvent, 7)
	if err != nil || proof["packet_snapshot_flows"] != 1 || !reflect.DeepEqual(proof["verified_hosts"], []string{f.Host, other.Host}) {
		t.Fatal("closed document could not be combined with live auxiliary flow", proof, err)
	}
	pairedMarked := strings.TrimSpace(event) + "\t2\tmark=604009778\tegress=pppoe-wan\n"
	proof, err = flowProof(testSettings(), []flow{media}, "", pairedMarked, 9, 7)
	if err != nil || proof["packet_snapshot_flows"] != 1 || proof["connection_match"] != "verified" {
		t.Fatal("closed GV flow lost its independent profile proof", proof, err)
	}
	proof, err = flowProof(testSettings(), []flow{media}, "", strings.Replace(pairedMarked, "\t7\t2\t", "\t7\t1\t", 1), 9, 7)
	if err != nil || proof["connection_match"] == "verified" {
		t.Fatal("historical mark bypassed profile identity", proof, err)
	}
}

func TestBusyBoxRouteEvidence(t *testing.T) {
	original := runCommand
	defer func() { runCommand = original }()
	runCommand = func(_ string, args ...string) ([]byte, error) {
		if reflect.DeepEqual(args, []string{"-4", "route", "show", "table", "main", "default"}) {
			return []byte("default dev ppp0"), nil
		}
		return nil, errors.New("ip: need at least destination address")
	}
	f := flow{Host: "example.org", Local: "192.0.2.1:37024", Remote: "93.184.216.34:443"}
	snapshot := "src=192.0.2.1 dst=93.184.216.34 sport=37024 dport=443 mark=67108864"
	event := "192.0.2.1\t37024\t93.184.216.34\t443\t7\tmark=67108864"
	proof, err := flowProof(testSettings(), []flow{f}, snapshot, event+"\tegress=ppp0\n", 7)
	if err != nil || proof["route"] != "kernel_route_verified" {
		t.Fatal(proof, err)
	}
	if _, err = flowProof(testSettings(), []flow{f}, snapshot, event+"\tegress=tun1\n", 7); err == nil {
		t.Fatal("VPN accepted")
	}
	for _, unproven := range []string{event + "\n", strings.Replace(event, "\t7\t", "\t8\t", 1) + "\tegress=ppp0\n"} {
		proof, err = flowProof(testSettings(), []flow{f}, snapshot, unproven, 7)
		if err != nil || proof["route"] == "kernel_route_verified" {
			t.Fatal(proof, err)
		}
	}
}

func TestSettledTelemetry(t *testing.T) {
	reads := 0
	out, err := settledTelemetry(func() (response, error) {
		reads++
		state := "unavailable"
		if reads == 2 {
			state = "verified"
		}
		route := "unavailable"
		if state == "verified" {
			route = "kernel_route_verified"
		}
		return response{"proof": response{"connection_match": state, "strategy_invocation": state, "route": route}}, nil
	})
	if err != nil || reads != 2 || out["telemetry_reads"] != 2 || out["proof"].(response)["connection_match"] != "verified" {
		t.Fatal(out, err, reads)
	}
	reads = 0
	out, err = settledTelemetry(func() (response, error) {
		reads++
		return response{"proof": response{"connection_match": "unavailable"}}, nil
	})
	if err != nil || reads != 3 || out["proof"].(response)["connection_match"] != "unavailable" {
		t.Fatal("missing evidence was fabricated or retry unbounded", out, err, reads)
	}
	reads = 0
	breach := errors.New("FLOW_MARK_MISMATCH")
	_, err = settledTelemetry(func() (response, error) { reads++; return nil, breach })
	if err != breach || reads != 1 {
		t.Fatal("transport violation retried", err, reads)
	}
}
