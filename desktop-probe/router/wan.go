package main

import (
	"fmt"
	"strconv"
	"strings"
)

// Use kernel uplinks, not connection-type names: PPP, DHCP, static and failover share this contract.
func defaultWANs(snapshot string) ([]string, error) {
	bestMetric := ^uint64(0)
	var devices []string
	var routes []string
	for _, line := range strings.Split(snapshot, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "nexthop ") && len(routes) > 0 {
			routes[len(routes)-1] += " " + strings.TrimSpace(line)
		} else {
			routes = append(routes, line)
		}
	}
	for _, line := range routes {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != "default" || strings.Contains(" "+line+" ", " linkdown ") {
			continue
		}
		metric := uint64(0)
		var routeDevices []string
		for i := 1; i+1 < len(fields); i++ {
			switch fields[i] {
			case "metric":
				value, err := strconv.ParseUint(fields[i+1], 10, 32)
				if err != nil {
					return nil, fmt.Errorf("WAN_UNAVAILABLE: invalid default route metric")
				}
				metric = value
			case "dev":
				if !ifacePattern.MatchString(fields[i+1]) {
					return nil, fmt.Errorf("WAN_UNAVAILABLE: invalid uplink interface")
				}
				routeDevices = append(routeDevices, fields[i+1])
			}
		}
		if len(routeDevices) == 0 {
			continue
		}
		if metric < bestMetric {
			devices = nil
			bestMetric = metric
		}
		if metric == bestMetric {
			for _, device := range routeDevices {
				found := false
				for _, existing := range devices {
					if existing == device {
						found = true
					}
				}
				if !found {
					devices = append(devices, device)
				}
			}
		}
	}
	if len(devices) == 0 {
		return nil, fmt.Errorf("WAN_UNAVAILABLE: no active IPv4 default route in main table")
	}
	return devices, nil
}

func discoverWANs() ([]string, error) {
	out, err := runCommand("ip", "-4", "route", "show", "table", "main", "default")
	if err != nil {
		return nil, fmt.Errorf("WAN_UNAVAILABLE: cannot read IPv4 default route")
	}
	return defaultWANs(string(out))
}
