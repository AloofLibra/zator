package main

import (
	"encoding/binary"
	"syscall"
	"testing"
)

func linkEvent(change uint32, kinds ...uint16) syscall.NetlinkMessage {
	data := make([]byte, syscall.SizeofIfInfomsg)
	binary.NativeEndian.PutUint32(data[12:16], change)
	for _, kind := range kinds {
		attr := make([]byte, 8)
		binary.NativeEndian.PutUint16(attr, 8)
		binary.NativeEndian.PutUint16(attr[2:], kind)
		data = append(data, attr...)
	}
	return syscall.NetlinkMessage{Header: syscall.NlMsghdr{Type: syscall.RTM_NEWLINK}, Data: data}
}

func TestRouteWirelessNotifications(t *testing.T) {
	for _, m := range []syscall.NetlinkMessage{linkEvent(0, syscall.IFLA_IFNAME, syscall.IFLA_WIRELESS), linkEvent(0, syscall.IFLA_WIRELESS)} {
		if changed, err := routeEventChangesTransport(m); err != nil || changed {
			t.Fatal("wireless telemetry changed generation", changed, err)
		}
	}
	for _, m := range []syscall.NetlinkMessage{
		linkEvent(syscall.IFF_UP, syscall.IFLA_IFNAME, syscall.IFLA_WIRELESS),
		linkEvent(0, syscall.IFLA_IFNAME, syscall.IFLA_WIRELESS, syscall.IFLA_MTU),
		linkEvent(0, syscall.IFLA_IFNAME, syscall.IFLA_OPERSTATE),
		linkEvent(0, syscall.IFLA_IFNAME),
		{Header: syscall.NlMsghdr{Type: syscall.RTM_DELLINK}},
		{Header: syscall.NlMsghdr{Type: syscall.RTM_NEWROUTE}},
		{Header: syscall.NlMsghdr{Type: syscall.RTM_DELROUTE}},
		{Header: syscall.NlMsghdr{Type: syscall.RTM_NEWADDR}},
		{Header: syscall.NlMsghdr{Type: syscall.RTM_NEWRULE}},
	} {
		if changed, err := routeEventChangesTransport(m); err != nil || !changed {
			t.Fatal("real change ignored", m, changed, err)
		}
	}
	for _, data := range [][]byte{nil, make([]byte, 15), append(make([]byte, 16), 1, 0, 1, 0)} {
		if _, err := routeEventChangesTransport(syscall.NetlinkMessage{Header: syscall.NlMsghdr{Type: syscall.RTM_NEWLINK}, Data: data}); err == nil {
			t.Fatal("malformed event accepted")
		}
	}
}
