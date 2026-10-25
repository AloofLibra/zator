package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestIPTablesInstallationAndRollback(t *testing.T) {
	saved := runCommand
	defer func() { runCommand = saved }()
	for _, fault := range []bool{false, true} {
		log := []string{}
		created := map[string]bool{}
		count := 0
		runCommand = func(name string, args ...string) ([]byte, error) {
			line := strings.Join(args, " ")
			log = append(log, name+" "+line)
			if strings.HasPrefix(line, "-w 5 ") {
				return nil, fmt.Errorf("old Entware: bare -w only")
			}
			if strings.Contains(line, "-nL OUTPUT") {
				return []byte("Chain OUTPUT"), nil
			}
			if strings.Contains(line, " -S ") {
				return nil, fmt.Errorf("no own chain")
			}
			for i, arg := range args {
				if arg == "-N" {
					created[args[i+1]] = true
				}
				if arg == "-X" {
					delete(created, args[i+1])
				}
				if arg == "-A" {
					count++
					if fault && count == 3 {
						return nil, fmt.Errorf("injected")
					}
				}
			}
			return nil, nil
		}
		c := testSettings()
		c.Backend = "iptables"
		err := ipInstall(c)
		if fault && (err == nil || len(created) != 0) {
			t.Fatal("partial install not rolled back", err, created)
		}
		if !fault && err != nil {
			t.Fatal(err)
		}
		for _, line := range log {
			if strings.Contains(line, " -F ") && !strings.Contains(line, " -F Z2R_DP_") {
				t.Fatal("foreign chain flushed", line)
			}
			if strings.Contains(line, "65535") || strings.Contains(line, "62000") {
				t.Fatal("Supersweep resource reused", line)
			}
		}
		if !fault && !strings.Contains(strings.Join(log, "\n"), "--ctdir REPLY") {
			t.Fatal("reply identity missing")
		}
		if !fault && !strings.Contains(strings.Join(log, "\n"), "-I OUTPUT -p tcp -m connmark --mark 0x4000000/0x4000000 -j Z2R_DP_OUT") {
			t.Fatal("ownerless packets can escape test queue")
		}
	}
}
