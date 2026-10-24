package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestAutomaticWAN(t *testing.T) {
	for _, tc := range []struct {
		name, routes string
		want         []string
	}{
		{"dhcp", "default via 192.168.1.1 dev wan proto dhcp", []string{"wan"}},
		{"pppoe", "default dev pppoe-wan scope link", []string{"pppoe-wan"}},
		{"static-vlan", "default via 192.0.2.1 dev eth0.100 proto static metric 20", []string{"eth0.100"}},
		{"usb", "default via 192.0.2.1 dev wwan0 metric 5", []string{"wwan0"}},
		{"failover", "default dev wan metric 100\ndefault dev ppp0 metric 10", []string{"ppp0"}},
		{"equal-cost", "default dev eth1 metric 10\ndefault dev eth2 metric 10", []string{"eth1", "eth2"}},
		{"multipath", "default metric 10\n nexthop via 192.0.2.1 dev eth1 weight 1\n nexthop via 192.0.2.2 dev eth2 weight 1", []string{"eth1", "eth2"}},
		{"down-primary", "default dev eth1 metric 10 linkdown\ndefault dev eth2 metric 20", []string{"eth2"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := defaultWANs(tc.routes)
			if err != nil || !reflect.DeepEqual(got, tc.want) {
				t.Fatal(got, err)
			}
		})
	}
	for _, routes := range []string{"", "blackhole default", "default dev wan metric broken", "default dev wan;reboot", "default dev eth0 linkdown"} {
		if _, err := defaultWANs(routes); err == nil {
			t.Fatal("invalid uplink accepted", routes)
		}
	}
}

func TestLegacyWANSettingDoesNotPinConnectionType(t *testing.T) {
	c := testSettings()
	raw, _ := json.Marshal(c)
	var old map[string]any
	json.Unmarshal(raw, &old)
	old["wan"] = "pppoe-obsolete"
	raw, _ = json.Marshal(old)
	var parsed settings
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed != c || parsed.validate() != nil {
		t.Fatal(parsed, err)
	}
}
