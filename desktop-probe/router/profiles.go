package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var hostnamePattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$`)

func hostMatches(host, pattern string) bool {
	pattern = strings.TrimPrefix(strings.TrimSpace(strings.ToLower(pattern)), "*.")
	pattern = strings.TrimPrefix(pattern, ".")
	return hostnamePattern.MatchString(pattern) && (host == pattern || strings.HasSuffix(host, "."+pattern))
}

func resolveProfile(c settings, host string) (int, error) {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if len(host) > 253 || !strings.Contains(host, ".") || !hostnamePattern.MatchString(host) {
		return 0, fmt.Errorf("INVALID_HOSTNAME")
	}
	raw, err := os.ReadFile(filepath.Join(c.ZapretRoot, "config"))
	if err != nil {
		return 0, err
	}
	profile := 0
	matched := map[int]bool{}
	excluded := map[int]bool{}
	for _, line := range strings.Split(strings.ReplaceAll(string(raw), "\r", ""), "\n") {
		line = strings.TrimSpace(line)
		for p := 1; p <= 4; p++ {
			if line == fmt.Sprintf("#Z2R_AUTO_STANDARD_%d_BEGIN", p) {
				profile = p
			}
			if line == fmt.Sprintf("#Z2R_AUTO_STANDARD_%d_END", p) {
				profile = 0
			}
		}
		if profile == 0 {
			continue
		}
		for _, arg := range strings.Fields(line) {
			targets := []string{}
			exclude := false
			if strings.HasPrefix(arg, "--hostlist-domains=") {
				targets = strings.Split(strings.TrimPrefix(arg, "--hostlist-domains="), ",")
			}
			if strings.HasPrefix(arg, "--hostlist=") || strings.HasPrefix(arg, "--hostlist-exclude=") {
				pair := strings.SplitN(arg, "=", 2)
				exclude = pair[0] == "--hostlist-exclude"
				// Only deployed Zator lists are read; arbitrary config paths are not an API.
				path := filepath.Clean(pair[1])
				if !strings.HasPrefix(path, c.ZatorRoot+string(filepath.Separator)) {
					continue
				}
				list, e := os.ReadFile(path)
				if e != nil {
					continue
				}
				targets = strings.Split(string(list), "\n")
			}
			for _, target := range targets {
				target = strings.TrimSpace(strings.SplitN(target, "#", 2)[0])
				if hostMatches(host, target) {
					if exclude {
						excluded[profile] = true
					} else {
						matched[profile] = true
					}
				}
			}
		}
	}
	for _, p := range []int{2, 4, 1, 3} {
		if matched[p] && !excluded[p] {
			return p, nil
		}
	}
	return 0, fmt.Errorf("PROFILE_UNKNOWN: choose a profile explicitly")
}
