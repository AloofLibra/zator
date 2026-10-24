package main

import (
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
}
