package main

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestSOCKSRejectsUDPAndIPv6(t *testing.T) {
	for _, req := range [][]byte{{5, 3, 0, 1}, {5, 1, 0, 4}, {5, 1, 1, 1}} {
		client, server := net.Pipe()
		done := make(chan error, 1)
		go func() {
			defer server.Close()
			_, _, err := socksConnect(server, net.DefaultResolver, (&net.Dialer{}).DialContext)
			done <- err
		}()
		_ = client.SetDeadline(time.Now().Add(time.Second))
		_, _ = client.Write([]byte{5, 1, 0})
		var answer [2]byte
		if _, err := io.ReadFull(client, answer[:]); err != nil {
			t.Fatal(err)
		}
		if answer != [2]byte{5, 0} {
			t.Fatal(answer)
		}
		_, _ = client.Write(req)
		reply := make([]byte, 10)
		if _, err := io.ReadFull(client, reply); err != nil {
			t.Fatal(err)
		}
		client.Close()
		if reply[1] == 0 || <-done == nil {
			t.Fatal("unsupported accepted")
		}
	}
}

func TestSOCKSIPv4Connect(t *testing.T) {
	client, server := net.Pipe()
	upstream, remote := net.Pipe()
	defer remote.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		conn, _, err := socksConnect(server, net.DefaultResolver, func(ctx context.Context, network, address string) (net.Conn, error) {
			if network != "tcp4" || address != "93.184.216.34:443" {
				t.Errorf("bad destination %s %s", network, address)
			}
			return upstream, nil
		})
		if conn != nil {
			conn.Close()
		}
		done <- err
	}()
	_ = client.SetDeadline(time.Now().Add(time.Second))
	_, _ = client.Write([]byte{5, 1, 0})
	reply := make([]byte, 2)
	_, _ = io.ReadFull(client, reply)
	_, _ = client.Write([]byte{5, 1, 0, 1, 93, 184, 216, 34, 1, 187})
	reply = make([]byte, 10)
	if _, err := io.ReadFull(client, reply); err != nil {
		t.Fatal(err)
	}
	client.Close()
	if reply[1] != 0 {
		t.Fatal(reply)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestPublicIPv4(t *testing.T) {
	for _, ip := range []string{"127.0.0.1", "192.168.10.1", "10.0.0.1", "169.254.1.1", "100.64.0.1", "198.18.0.1", "::1", "2001:db8::1", "0.1.2.3", "224.0.0.1"} {
		if publicIPv4(net.ParseIP(ip)) {
			t.Fatal(ip)
		}
	}
	if !publicIPv4(net.ParseIP("93.184.216.34")) {
		t.Fatal("public rejected")
	}
}
