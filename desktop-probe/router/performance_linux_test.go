package main

import (
	"os"
	"testing"
	"time"
)

func TestHardwareFingerprintCost(t *testing.T) {
	if os.Getenv("ZATOR_PROBE_HARDWARE_PERF") != "1" {
		t.Skip("read-only hardware benchmark")
	}
	c, err := readSettings()
	if err != nil {
		t.Fatal(err)
	}
	if c.Backend != "iptables" {
		t.Skip("iptables benchmark")
	}
	started := time.Now()
	baseline, err := ipFingerprint(c)
	if err != nil {
		t.Fatal(err)
	}
	full := time.Since(started)
	started = time.Now()
	for n := 0; n < 10; n++ {
		snapshot, err := ipFingerprintWithChecks(c, false)
		if err != nil || snapshot != baseline {
			t.Fatal("transport changed", err)
		}
	}
	t.Logf("validated firewall: %s; repeated firewall snapshot: %s/op", full, time.Since(started)/10)
}
