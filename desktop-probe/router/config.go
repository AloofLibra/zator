package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var strategyPattern = regexp.MustCompile(`:strategy=([0-9]+)(?:\s|:|$)`)

func defaultSettings(config string) (settings, error) {
	c := settings{Queue: 65534, ProxyUID: 65531, NfqUID: 65532, Port: 41081, Mark: 0x04000000, RawMark: 0x40000000, ZatorRoot: "/opt/zator", ZapretRoot: "/opt/zapret2"}
	switch configValue(config, "FWTYPE") {
	case "iptables":
		c.Backend = "iptables"
	case "nft", "nftables":
		c.Backend = "nft"
	default:
		return c, fmt.Errorf("CONFIG_UNSUPPORTED: firewall backend")
	}
	return c, c.validate()
}

func configValue(config, key string) string {
	for _, line := range strings.Split(config, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, key+"=") {
			return strings.Trim(strings.TrimSpace(strings.SplitN(strings.TrimPrefix(line, key+"="), "#", 2)[0]), "\"'")
		}
	}
	return ""
}

func tcpPacketWindow(config string) (int, int, error) {
	limits := [2]int{}
	for i, key := range []string{"NFQWS2_TCP_PKT_OUT", "NFQWS2_TCP_PKT_IN"} {
		value := configValue(config, key)
		if value == "" {
			continue
		}
		n, err := strconv.ParseUint(value, 10, 16)
		if err != nil {
			return 0, 0, fmt.Errorf("CONFIG_UNSUPPORTED: %s", key)
		}
		limits[i] = int(n)
	}
	return limits[0], limits[1], nil
}

func configCompatible(c settings) error {
	raw, err := readLimited(filepath.Join(c.ZapretRoot, "config"), 1024*1024)
	if err != nil {
		return err
	}
	cfg := string(raw)
	if c.Backend == "iptables" {
		out, in, err := tcpPacketWindow(cfg)
		if err != nil {
			return err
		}
		if out != c.packetOut || in != c.packetIn {
			return fmt.Errorf("CONFIG_CHANGED: TCP packet window")
		}
	}
	fw := configValue(cfg, "FWTYPE")
	if (c.Backend == "nft" && fw != "nftables" && fw != "nft") || (c.Backend == "iptables" && fw != "iptables") || configValue(cfg, "POSTNAT") == "0" {
		return fmt.Errorf("CONFIG_UNSUPPORTED: firewall backend or pre-NAT layout")
	}
	mark, err := strconv.ParseUint(configValue(cfg, "DESYNC_MARK"), 0, 32)
	if err != nil || uint32(mark) != c.RawMark {
		return fmt.Errorf("MARK_COLLISION")
	}
	for _, key := range []string{"DESYNC_MARK_POSTNAT", "CLIENT_SCOPE_MARK_MASK", "FILTER_MARK"} {
		value := configValue(cfg, key)
		if value == "" {
			continue
		}
		bits, e := strconv.ParseUint(value, 0, 32)
		if e != nil || uint32(bits)&c.Mark != 0 {
			return fmt.Errorf("MARK_COLLISION")
		}
		if c.Backend == "nft" && key == "DESYNC_MARK_POSTNAT" && bits != 0x20000000 {
			return fmt.Errorf("CONFIG_UNSUPPORTED: custom post-NAT mark")
		}
	}
	return nil
}

// Read config as data: an installed config is shell code and must not be evaluated.
func profilePlan(config string, profile int) ([]string, []int, error) {
	if profile < 1 || profile > 4 {
		return nil, nil, fmt.Errorf("PROFILE_UNKNOWN")
	}
	var blobs, common, plan []string
	numbers := []int{}
	commonNumbers := []int{}
	active, template, block, separator := false, false, false, false
	begin := fmt.Sprintf("#Z2R_AUTO_STANDARD_%d_BEGIN", profile)
	end := fmt.Sprintf("#Z2R_AUTO_STANDARD_%d_END", profile)
	for _, line := range strings.Split(strings.ReplaceAll(config, "\r", ""), "\n") {
		line = strings.TrimSpace(line)
		if line == `NFQWS2_OPT="` {
			active = true
			continue
		}
		if line == `"` {
			active = false
		}
		if !active {
			continue
		}
		if strings.HasPrefix(line, "--blob=") {
			blobs = append(blobs, line)
		}
		if line == "--template=z2r_tcp_tls_common" {
			template = true
		}
		if template {
			if strings.HasPrefix(line, "--") {
				common = append(common, splitDesync(line)...)
				for _, match := range strategyPattern.FindAllStringSubmatch(line, -1) {
					n, _ := strconv.Atoi(match[1])
					if !contains(commonNumbers, n) {
						commonNumbers = append(commonNumbers, n)
					}
				}
			}
			if line == "--new" {
				template = false
				separator = true
			}
			continue
		}
		if line == begin {
			block = true
			continue
		}
		if line == end {
			block = false
		}
		if !block {
			continue
		}
		if strings.HasPrefix(line, "--import=") {
			if line != "--import=z2r_tcp_tls_common" {
				return nil, nil, fmt.Errorf("CONFIG_UNSUPPORTED")
			}
			for _, n := range commonNumbers {
				if !contains(numbers, n) {
					numbers = append(numbers, n)
				}
			}
		}
		if strings.HasPrefix(line, "--import=") || (strings.HasPrefix(line, "--lua-desync=") && strategyPattern.MatchString(line)) || line == "--in-range=x" || line == "--payload=tls_client_hello,discord_ip_discovery" {
			plan = append(plan, splitDesync(line)...)
			for _, match := range strategyPattern.FindAllStringSubmatch(line, -1) {
				n, _ := strconv.Atoi(match[1])
				if !contains(numbers, n) {
					numbers = append(numbers, n)
				}
			}
		}
	}
	if !separator || len(plan) == 0 || len(numbers) == 0 {
		return nil, nil, fmt.Errorf("CONFIG_UNSUPPORTED")
	}
	for n := 1; n <= len(numbers); n++ {
		if !contains(numbers, n) {
			return nil, nil, fmt.Errorf("CONFIG_UNSUPPORTED: strategy numbering has gaps")
		}
	}
	args := append(blobs, common...)
	args = append(args, "--filter-tcp=443", "--filter-l7=tls", "--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello", "--out-range=-s34228", "--in-range=-s32768", fmt.Sprintf("--lua-desync=circular_locked:key=%d", profile))
	return append(args, plan...), numbers, nil
}

func contains(numbers []int, n int) bool {
	for _, v := range numbers {
		if v == n {
			return true
		}
	}
	return false
}
func splitDesync(line string) []string {
	parts := strings.Split(line, " --lua-desync=")
	for i := 1; i < len(parts); i++ {
		parts[i] = "--lua-desync=" + parts[i]
	}
	return parts
}

func prepareConfig(c settings, dir string, profile, strategy int, gvStrategy ...int) ([]string, error) {
	raw, err := os.ReadFile(filepath.Join(c.ZapretRoot, "config"))
	if err != nil {
		return nil, err
	}
	plan, numbers, err := profilePlan(string(raw), profile)
	if err != nil {
		return nil, err
	}
	if strategy != 0 && !contains(numbers, strategy) {
		return nil, fmt.Errorf("STRATEGY_UNKNOWN")
	}
	locks := fmt.Sprintf("%d\ttls\t%d\n", profile, strategy)
	evidenceProfile := ""
	if len(gvStrategy) != 0 {
		if profile != 1 || len(gvStrategy) != 1 {
			return nil, fmt.Errorf("PROFILE_UNKNOWN")
		}
		gvPlan, gvNumbers, e := profilePlan(string(raw), 2)
		if e != nil {
			return nil, e
		}
		if gvStrategy[0] < 0 || (gvStrategy[0] != 0 && !contains(gvNumbers, gvStrategy[0])) {
			return nil, fmt.Errorf("STRATEGY_UNKNOWN")
		}
		plan, err = youtubePairPlan(plan, gvPlan)
		if err != nil {
			return nil, err
		}
		locks += fmt.Sprintf("2\ttls\t%d\n", gvStrategy[0])
		evidenceProfile = `.."\t"..tostring(profile)`
	}
	raw, err = os.ReadFile(filepath.Join(c.ZatorRoot, "lua", "locked.lua"))
	if err != nil {
		return nil, err
	}
	lua := strings.Replace(string(raw), `local LOCKED_PATH = "/opt/zator/extra_strats/cache/orchestra/locked.tsv"`, fmt.Sprintf("local LOCKED_PATH = %q", dir+"/locked.tsv"), 1)
	lua = strings.Replace(lua, `local LOCKED_MANUAL_PATH = "/opt/zator/extra_strats/cache/orchestra/locked.manual.tsv"`, fmt.Sprintf("local LOCKED_MANUAL_PATH = %q", dir+"/locked.manual.tsv"), 1)
	if strings.Contains(lua, `local LOCKED_PATH = "/opt/zator/`) || !strings.Contains(lua, fmt.Sprintf("local LOCKED_PATH = %q", dir+"/locked.tsv")) {
		return nil, fmt.Errorf("LOCK_ADAPTER_UNSUPPORTED")
	}
	if strings.Count(lua, "if locked == 0 then") != 1 || strings.Count(lua, "verdict = blob_override_execute(desync, verdict, instance, base_profile)") != 1 {
		return nil, fmt.Errorf("LOCK_ADAPTER_UNSUPPORTED")
	}
	lua = strings.Replace(lua, "if locked == 0 then", "if locked == 0 then\n    zator_probe_record(desync, 0, base_profile)", 1)
	lua = strings.Replace(lua, "verdict = blob_override_execute(desync, verdict, instance, base_profile)", "verdict = blob_override_execute(desync, verdict, instance, base_profile)\n      zator_probe_record(desync, hrec.nstrategy, base_profile)", 1)
	lua += fmt.Sprintf(`
-- Keep the original packet mark even when conntrack has expired before telemetry.
local probe_seen = {}
local probe_count = 0
function zator_probe_record(desync, strategy, profile)
  local dis = desync and desync.dis
  if not dis or not dis.ip or not dis.tcp or dis.tcp.th_dport ~= 443 then return end
  local row = ntop(dis.ip.ip_src).."\t"..dis.tcp.th_sport.."\t"..ntop(dis.ip.ip_dst).."\t"..dis.tcp.th_dport.."\t"..strategy%s
  local mark = tonumber(desync.fwmark)
  if mark then
    if mark < 0 then mark = mark + 4294967296 end
    row = row.."\tmark="..string.format("%%.0f", mark).."\tegress="..tostring(desync.ifout or "")
  end
  if probe_seen[row] or probe_count >= 1024 then return end
  local f = assert(io.open(%q, "a"))
  assert(f:write(row.."\n"))
  assert(f:close())
  probe_seen[row] = true
  probe_count = probe_count + 1
end
`, evidenceProfile, filepath.Dir(dir)+"/evidence/invocations.tsv")
	for name, body := range map[string][]byte{"locked.lua": []byte(lua), "locked.tsv": []byte(locks), "locked.manual.tsv": {}} {
		if err = os.WriteFile(filepath.Join(dir, name), body, 0644); err != nil {
			return nil, err
		}
		if err = os.Chmod(filepath.Join(dir, name), 0644); err != nil {
			return nil, err
		}
	}
	for _, name := range []string{"blob_override.tsv", "mode_override.tsv", "sni_override.tsv", "clonesize.tsv"} {
		body, readErr := os.ReadFile(filepath.Join(c.ZatorRoot, "extra_strats/cache/orchestra", name))
		if readErr != nil && !os.IsNotExist(readErr) {
			return nil, readErr
		}
		if err = os.WriteFile(filepath.Join(dir, name), body, 0644); err != nil {
			return nil, err
		}
		if err = os.Chmod(filepath.Join(dir, name), 0644); err != nil {
			return nil, err
		}
	}
	args := []string{fmt.Sprintf("--qnum=%d", c.Queue), fmt.Sprintf("--uid=%d:%d", c.NfqUID, c.NfqUID), fmt.Sprintf("--fwmark=0x%x", c.RawMark)}
	for _, name := range []string{"zapret-lib.lua", "zapret-antidpi.lua", "zapret-auto.lua"} {
		args = append(args, "--lua-init=@"+filepath.Join(c.ZapretRoot, "lua", name))
	}
	args = append(args, "--lua-init=@"+dir+"/locked.lua", "--lua-init=@"+filepath.Join(c.ZatorRoot, "lua/fake-adapt.lua"))
	return append(args, plan...), nil
}

func youtubePairPlan(yt, gv []string) ([]string, error) {
	start := func(args []string) int {
		for i, arg := range args {
			if arg == "--filter-tcp=443" {
				return i
			}
		}
		return -1
	}
	y, g := start(yt), start(gv)
	if y < 0 || g < 0 || strings.Join(yt[:y], "\n") != strings.Join(gv[:g], "\n") {
		return nil, fmt.Errorf("CONFIG_UNSUPPORTED: incompatible YouTube templates")
	}
	args := append([]string{}, yt[:y]...)
	// The specific media profile must precede the page/assets fallback.
	args = append(args, "--hostlist-domains=googlevideo.com")
	args = append(args, gv[g:]...)
	args = append(args, "--new")
	return append(args, yt[y:]...), nil
}
