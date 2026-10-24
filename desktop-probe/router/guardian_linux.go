package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func childOf(pid, parent int) bool {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) > 1 && f[0] == "PPid:" {
			return f[1] == strconv.Itoa(parent)
		}
	}
	return false
}

func adoptedChildren() ([]int, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	var children []int
	for _, entry := range entries {
		pid, e := strconv.Atoi(entry.Name())
		if e == nil && childOf(pid, os.Getpid()) {
			children = append(children, pid)
		}
	}
	return children, nil
}

func cleanupAdopted() error {
	for round := 0; round < 100; round++ {
		// Only kernel-proven children of this private subreaper may be signalled.
		children, err := adoptedChildren()
		if err != nil {
			return err
		}
		for _, pid := range children {
			var status syscall.WaitStatus
			if reaped, _ := syscall.Wait4(pid, &status, syscall.WNOHANG, nil); reaped == pid {
				continue
			}
			process, e := os.FindProcess(pid)
			if e != nil {
				continue
			}
			if childOf(pid, os.Getpid()) {
				signal := syscall.SIGTERM
				if round >= 50 {
					signal = syscall.SIGKILL
				}
				_ = process.Signal(signal)
			}
			_ = process.Release()
		}
		children, err = adoptedChildren()
		if err != nil {
			return err
		}
		if len(children) == 0 {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("OWNED_CHILD_CLEANUP_FAILED")
}

func guardSupervisor() error {
	// nfqws2's own setuid clears PDEATHSIG; a root subreaper must reap its orphans.
	if _, _, err := syscall.RawSyscall6(syscall.SYS_PRCTL, 36, 1, 0, 0, 0, 0); err != 0 {
		return fmt.Errorf("UNSUPPORTED_CAPABILITY: child subreaper")
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(self, "--serve")
	isolateChild(cmd, 0)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err = cmd.Start(); err != nil {
		return err
	}
	_ = cmd.Wait()
	return cleanupAdopted()
}
