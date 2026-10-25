package main

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func conntrackFixture() (string, []flow) {
	var text strings.Builder
	var flows []flow
	for n := 0; n < 2000; n++ {
		fmt.Fprintf(&text, "ipv4 2 tcp 6 120 src=192.0.2.1 dst=198.51.100.1 sport=%d dport=443 src=198.51.100.1 dst=192.0.2.1 sport=443 dport=%d mark=67108864\n", 20000+n, 20000+n)
		if n >= 1968 {
			flows = append(flows, flow{Host: "example.org", Local: fmt.Sprintf("192.0.2.1:%d", 20000+n), Remote: "198.51.100.1:443"})
		}
	}
	return text.String(), flows
}

func TestConntrackIndexPreservesOriginalTupleAndFirstMatch(t *testing.T) {
	text, flows := conntrackFixture()
	index := conntrackIndex(text, flows)
	if len(index) != len(flows) {
		t.Fatal(len(index))
	}
	for _, f := range flows {
		tuple, _ := proxyTuple(f)
		if value := index[tuple]; !value.valid || value.mark != 67108864 {
			t.Fatal(value)
		}
	}
	f := flows[0]
	reversed := flow{Local: f.Remote, Remote: f.Local}
	if _, ok := conntrackMark(text, reversed); ok {
		t.Fatal("reply tuple accepted as original")
	}
	tuple, _ := proxyTuple(f)
	invalid := fmt.Sprintf("src=%s dst=%s sport=%s dport=%s mark=garbage\n", tuple[0], tuple[1], tuple[2], tuple[3])
	if conntrackIndex(invalid+text, flows)[tuple].valid {
		t.Fatal("bad first mark overwritten by later tuple")
	}
}

func TestLivePacketEgressAvoidsRouteProcessesWithoutTrustingBadMarks(t *testing.T) {
	saved := runCommand
	defer func() { runCommand = saved }()
	calls := 0
	runCommand = func(_ string, args ...string) ([]byte, error) {
		calls++
		if !reflect.DeepEqual(args, []string{"-4", "route", "show", "table", "main", "default"}) {
			t.Fatal("unnecessary route process", args)
		}
		return []byte("default dev ppp0"), nil
	}
	f := flow{Host: "example.org", Local: "192.0.2.1:37024", Remote: "198.51.100.1:443"}
	event := "192.0.2.1\t37024\t198.51.100.1\t443\t1\tmark=67108864\tegress=ppp0\n"
	ct := "src=192.0.2.1 dst=198.51.100.1 sport=37024 dport=443 mark=67108864"
	proof, err := flowProof(testSettings(), []flow{f}, ct, event, 1)
	if err != nil || proof["route"] != "kernel_route_verified" || calls != 1 {
		t.Fatal(proof, err, calls)
	}
	for _, bad := range []string{strings.Replace(ct, "mark=67108864", "mark=0", 1), strings.Replace(ct, "mark=67108864", "mark=garbage", 1)} {
		if _, err := flowProof(testSettings(), []flow{f}, bad, event, 1); err == nil {
			t.Fatal("packet snapshot bypassed bad live conntrack mark")
		}
	}
	if _, err := flowProof(testSettings(), []flow{f}, ct, strings.Replace(event, "egress=ppp0", "egress=tun1", 1), 1); err == nil {
		t.Fatal("foreign egress accepted")
	}
}

func BenchmarkConntrackIndexed(b *testing.B) {
	text, flows := conntrackFixture()
	b.ReportAllocs()
	b.ResetTimer()
	for n := 0; n < b.N; n++ {
		conntrackIndex(text, flows)
	}
}

func BenchmarkConntrackRepeated(b *testing.B) {
	text, flows := conntrackFixture()
	b.ReportAllocs()
	b.ResetTimer()
	for n := 0; n < b.N; n++ {
		for _, f := range flows {
			conntrackMark(text, f)
		}
	}
}
