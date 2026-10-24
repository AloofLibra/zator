package main

import "os/exec"

func secureState() error                   { return nil }
func managerLock() (func(), error)         { return func() {}, nil }
func fileLock(name string) (func(), error) { return func() {}, nil }
func routeMonitor() (func() (uint64, bool), func(), error) {
	return func() (uint64, bool) { return 0, false }, func() {}, nil
}
func firewallMonitor() (func() (uint64, bool), func(), error) { return routeMonitor() }
func guardSupervisor() error                                  { return nil }

func isolateChild(cmd *exec.Cmd, uid int) {}
func detachSupervisor(cmd *exec.Cmd)      {}
