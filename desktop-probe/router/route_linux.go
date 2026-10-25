package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
)

func routeEventChangesTransport(m syscall.NetlinkMessage) (bool, error) {
	if m.Header.Type != syscall.RTM_NEWLINK {
		return true, nil
	}
	if len(m.Data) < syscall.SizeofIfInfomsg {
		return false, fmt.Errorf("short link event")
	}
	if binary.NativeEndian.Uint32(m.Data[12:16]) != 0 {
		return true, nil
	}
	attrs, err := syscall.ParseNetlinkRouteAttr(&m)
	if err != nil {
		return false, err
	}
	wireless := false
	for _, attr := range attrs {
		switch attr.Attr.Type {
		case syscall.IFLA_WIRELESS:
			wireless = true
		case syscall.IFLA_IFNAME:
		default:
			return true, nil
		}
	}
	// Keenetic Wi-Fi drivers multicast association/RSSI events without changing link state.
	return !wireless, nil
}

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
				if protocol == syscall.NETLINK_ROUTE {
					messages, e := syscall.ParseNetlinkMessage(buf[:n])
					if e != nil {
						healthy.Store(false)
						return
					}
					changed := false
					for _, message := range messages {
						relevant, e := routeEventChangesTransport(message)
						if e != nil {
							healthy.Store(false)
							return
						}
						changed = changed || relevant
					}
					if !changed {
						continue
					}
				}
				generation.Add(1)
			}
		}
	}()
	return func() (uint64, bool) { return generation.Load(), healthy.Load() }, func() { healthy.Store(false); _ = f.Close() }, nil
}
