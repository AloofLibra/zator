package main

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

func conntrackMark(snapshot string, f flow) (uint32, bool) {
	source, port, err := net.SplitHostPort(f.Local)
	if err != nil {
		return 0, false
	}
	target, dport, err := net.SplitHostPort(f.Remote)
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(snapshot, "\n") {
		fields := strings.Fields(line)
		tuple := map[string]string{}
		mark := ""
		for _, field := range fields {
			pair := strings.SplitN(field, "=", 2)
			if len(pair) != 2 {
				continue
			}
			if pair[0] == "mark" {
				mark = pair[1]
			}
			if _, seen := tuple[pair[0]]; !seen {
				tuple[pair[0]] = pair[1]
			}
		}
		if tuple["src"] == source && tuple["dst"] == target && tuple["sport"] == port && tuple["dport"] == dport {
			value, err := strconv.ParseUint(mark, 10, 32)
			return uint32(value), err == nil
		}
	}
	return 0, false
}

func invoked(snapshot string, f flow, strategy int) bool {
	source, port, err := net.SplitHostPort(f.Local)
	if err != nil {
		return false
	}
	target, dport, err := net.SplitHostPort(f.Remote)
	if err != nil {
		return false
	}
	row := strings.Join([]string{source, port, target, dport, strconv.Itoa(strategy)}, "\t")
	for _, line := range strings.Split(snapshot, "\n") {
		if line == row {
			return true
		}
	}
	return false
}

func flowProof(c settings, flows []flow, conntrack, events string, strategy int) (response, error) {
	proof := response{"connection_match": "unavailable", "strategy_invocation": "unavailable", "route": "unavailable"}
	if len(flows) == 0 {
		return proof, nil
	}
	wans, err := discoverWANs()
	if err != nil {
		return nil, err
	}
	egress := ""
	verifiedHosts := []string{}
	seenHosts := map[string]bool{}
	checkedRoutes := map[string]bool{}
	for _, f := range flows {
		mark, matched := conntrackMark(conntrack, f)
		if !matched {
			continue
		}
		if mark&c.Mark == 0 || mark&c.RawMark != 0 {
			return nil, fmt.Errorf("FLOW_MARK_MISMATCH")
		}
		target, _, err := net.SplitHostPort(f.Remote)
		if err != nil {
			return proof, err
		}
		key := target + "/" + strconv.FormatUint(uint64(mark), 10)
		if checkedRoutes[key] {
			if invoked(events, f, strategy) && !seenHosts[f.Host] {
				verifiedHosts = append(verifiedHosts, f.Host)
				seenHosts[f.Host] = true
			}
			continue
		}
		route, err := runCommand("ip", "-4", "route", "get", target, "mark", strconv.FormatUint(uint64(mark), 10))
		if err != nil {
			continue
		}
		fields := strings.Fields(string(route))
		wan := false
		for i := 0; i+1 < len(fields); i++ {
			if fields[i] == "dev" {
				for _, allowed := range wans {
					if fields[i+1] == allowed {
						wan = true
						egress = allowed
					}
				}
				break
			}
		}
		if !wan {
			return nil, fmt.Errorf("ROUTE_MISMATCH: flow does not use active default uplink (%s)", strings.Join(wans, ","))
		}
		checkedRoutes[key] = true
		if !invoked(events, f, strategy) {
			continue
		}
		if !seenHosts[f.Host] {
			verifiedHosts = append(verifiedHosts, f.Host)
			seenHosts[f.Host] = true
		}
	}
	if len(verifiedHosts) == 0 {
		return proof, nil
	}
	return response{"connection_match": "verified", "strategy_invocation": "verified", "route": "kernel_route_verified", "egress_interface": egress, "wan_interfaces": wans, "verified_hosts": verifiedHosts}, nil
}
