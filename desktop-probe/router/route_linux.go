package main

import (
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
)

// Netlink remembers transient route changes even when the final snapshot matches.
func routeMonitor() (func() (uint64, bool), func(), error) {
	return netlinkMonitor(syscall.NETLINK_ROUTE, 0xd1)
}
func firewallMonitor() (func() (uint64, bool), func(), error) {
	return netlinkMonitor(syscall.NETLINK_NETFILTER, 1<<6) // NFNLGRP_NFTABLES
}
func netlinkMonitor(protocol, groups int) (func() (uint64, bool), func(), error) {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, protocol)
	if err != nil {
		return nil, nil, fmt.Errorf("UNSUPPORTED_CAPABILITY: route notifications")
	}
	// RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV4_ROUTE | RTMGRP_IPV4_RULE.
	if err = syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: uint32(groups)}); err != nil {
		syscall.Close(fd)
		return nil, nil, fmt.Errorf("UNSUPPORTED_CAPABILITY: netlink notifications")
	}
	f := os.NewFile(uintptr(fd), "zator-route-monitor")
	var generation atomic.Uint64
	var healthy atomic.Bool
	healthy.Store(true)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := f.Read(buf)
			if err != nil {
				healthy.Store(false)
				return
			}
			if n > 0 {
				generation.Add(1)
			}
		}
	}()
	return func() (uint64, bool) { return generation.Load(), healthy.Load() }, func() { healthy.Store(false); _ = f.Close() }, nil
}
