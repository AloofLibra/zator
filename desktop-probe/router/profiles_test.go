package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProfileResolutionUsesInstalledLists(t *testing.T) {
	c := testSettings()
	c.ZatorRoot = t.TempDir()
	c.ZapretRoot = c.ZatorRoot
	list := filepath.Join(c.ZatorRoot, "rkn.txt")
	if err := os.WriteFile(list, []byte("example.org\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := "#Z2R_AUTO_STANDARD_2_BEGIN\n--hostlist-domains=googlevideo.com\n#Z2R_AUTO_STANDARD_2_END\n#Z2R_AUTO_STANDARD_3_BEGIN\n--hostlist=" + list + "\n#Z2R_AUTO_STANDARD_3_END\n"
	if err := os.WriteFile(filepath.Join(c.ZapretRoot, "config"), []byte(cfg), 0600); err != nil {
		t.Fatal(err)
	}
	for host, want := range map[string]int{"r1.googlevideo.com": 2, "cdn.example.org": 3} {
		got, err := resolveProfile(c, host)
		if err != nil || got != want {
			t.Fatal(host, got, err)
		}
	}
	for _, host := range []string{"notgooglevideo.com", "googlevideo.com.evil.org", "missing.example", "a;reboot"} {
		if _, err := resolveProfile(c, host); err == nil {
			t.Fatal("guessed/unsafe profile", host)
		}
	}
}
