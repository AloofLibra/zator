package main

import (
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
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

func invoked(snapshot string, f flow, strategy int, profile ...int) bool {
	source, port, err := net.SplitHostPort(f.Local)
	if err != nil {
		return false
	}
	target, dport, err := net.SplitHostPort(f.Remote)
	if err != nil {
		return false
	}
	row := strings.Join([]string{source, port, target, dport, strconv.Itoa(strategy)}, "\t")
	if len(profile) != 0 {
		row += "\t" + strconv.Itoa(profile[0])
	}
	for _, line := range strings.Split(snapshot, "\n") {
		if line == row {
			return true
		}
	}
	return false
}

func flowProof(c settings, flows []flow, conntrack, events string, strategy int, gvStrategy ...int) (response, error) {
	proof := response{"connection_match": "unavailable", "strategy_invocation": "unavailable", "route": "unavailable", "observed_flows": len(flows), "unavailable_reason": "NO_PROXY_FLOW"}
	if len(flows) == 0 {
		return proof, nil
	}
	wans, err := discoverWANs()
	if err != nil {
		return nil, err
	}
	egress := ""
	matchedFlows, invokedFlows, routedFlows := 0, 0, 0
	verifiedHosts := []string{}
	seenHosts := map[string]bool{}
	checkedRoutes := map[string]bool{}
	for _, f := range flows {
		wanted := strategy
		var profile []int
		if len(gvStrategy) != 0 {
			profile = []int{1}
			if hostMatches(f.Host, "googlevideo.com") {
				wanted = gvStrategy[0]
				profile[0] = 2
			}
		}
		mark, matched := conntrackMark(conntrack, f)
		if !matched {
			continue
		}
		if mark&c.Mark == 0 || mark&c.RawMark != 0 {
			return nil, fmt.Errorf("FLOW_MARK_MISMATCH")
		}
		matchedFlows++
		executed := invoked(events, f, wanted, profile...)
		if executed {
			invokedFlows++
		}
		target, _, err := net.SplitHostPort(f.Remote)
		if err != nil {
			return proof, err
		}
		key := target + "/" + strconv.FormatUint(uint64(mark), 10)
		if checkedRoutes[key] {
			routedFlows++
			if executed && !seenHosts[f.Host] {
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
		routedFlows++
		if !executed {
			continue
		}
		if !seenHosts[f.Host] {
			verifiedHosts = append(verifiedHosts, f.Host)
			seenHosts[f.Host] = true
		}
	}
	proof["matched_flows"], proof["invoked_flows"], proof["routed_flows"] = matchedFlows, invokedFlows, routedFlows
	if len(verifiedHosts) == 0 {
		switch {
		case matchedFlows == 0:
			proof["unavailable_reason"] = "CONNTRACK_NOT_FOUND"
		case invokedFlows == 0:
			proof["unavailable_reason"] = "STRATEGY_INVOCATION_NOT_FOUND"
		default:
			proof["unavailable_reason"] = "ROUTE_NOT_PROVEN"
		}
		return proof, nil
	}
	proof["connection_match"], proof["strategy_invocation"], proof["route"] = "verified", "verified", "kernel_route_verified"
	proof["egress_interface"], proof["wan_interfaces"], proof["verified_hosts"] = egress, wans, verifiedHosts
	delete(proof, "unavailable_reason")
	return proof, nil
}

func settledTelemetry(read func() (response, error)) (response, error) {
	for attempt := 0; ; attempt++ {
		out, err := read()
		if err != nil {
			return out, err
		}
		out["telemetry_reads"] = attempt + 1
		proof, ok := out["proof"].(response)
		complete := proof["connection_match"] == "verified" && proof["strategy_invocation"] == "verified" && proof["route"] == "kernel_route_verified"
		if !ok || complete || attempt == 2 {
			return out, nil
		}
		// Conntrack and Lua publish separately; never retry an explicit transport error.
		time.Sleep(100 * time.Millisecond)
	}
}
