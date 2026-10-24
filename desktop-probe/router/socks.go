package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type flow struct {
	Host    string `json:"host"`
	Local   string `json:"local"`
	Remote  string `json:"remote"`
	Started int64  `json:"started"`
}

func socksConnect(client net.Conn, resolver *net.Resolver, dial func(context.Context, string, string) (net.Conn, error)) (net.Conn, string, error) {
	_ = client.SetDeadline(time.Now().Add(15 * time.Second))
	var header [2]byte
	if _, err := io.ReadFull(client, header[:]); err != nil {
		return nil, "", err
	}
	if header[0] != 5 || header[1] == 0 {
		return nil, "", fmt.Errorf("SOCKS_VERSION")
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return nil, "", err
	}
	anonymous := false
	for _, method := range methods {
		anonymous = anonymous || method == 0
	}
	if !anonymous {
		_, _ = client.Write([]byte{5, 255})
		return nil, "", fmt.Errorf("SOCKS_AUTH")
	}
	if _, err := client.Write([]byte{5, 0}); err != nil {
		return nil, "", err
	}
	var req [4]byte
	if _, err := io.ReadFull(client, req[:]); err != nil {
		return nil, "", err
	}
	reject := func(code byte) (net.Conn, string, error) {
		_, _ = client.Write([]byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0})
		return nil, "", fmt.Errorf("SOCKS_REJECTED_%d", code)
	}
	if req[0] != 5 || req[1] != 1 || req[2] != 0 {
		return reject(7)
	}
	var host string
	switch req[3] {
	case 1:
		var ip [4]byte
		if _, err := io.ReadFull(client, ip[:]); err != nil {
			return nil, "", err
		}
		host = net.IP(ip[:]).String()
	case 3:
		var n [1]byte
		if _, err := io.ReadFull(client, n[:]); err != nil {
			return nil, "", err
		}
		if n[0] == 0 {
			return reject(8)
		}
		name := make([]byte, int(n[0]))
		if _, err := io.ReadFull(client, name); err != nil {
			return nil, "", err
		}
		host = string(name)
	default:
		return reject(8)
	}
	var port [2]byte
	if _, err := io.ReadFull(client, port[:]); err != nil {
		return nil, "", err
	}
	if binary.BigEndian.Uint16(port[:]) != 443 {
		return reject(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	ips, err := resolver.LookupIP(ctx, "ip4", host)
	if err != nil {
		return reject(4)
	}
	// Resolve on the router and deny all non-public destinations (including mapped IPv6).
	for _, ip := range ips {
		if !publicIPv4(ip) {
			continue
		}
		local := false
		addrs, e := net.InterfaceAddrs()
		if e != nil {
			return reject(4)
		}
		for _, addr := range addrs {
			if network, ok := addr.(*net.IPNet); ok && network.IP.Equal(ip) {
				local = true
				break
			}
		}
		if local {
			continue
		}
		upstream, err := dial(ctx, "tcp4", net.JoinHostPort(ip.String(), "443"))
		if err != nil {
			continue
		}
		if _, err = client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
			upstream.Close()
			return nil, "", err
		}
		_ = client.SetDeadline(time.Time{})
		return upstream, strings.ToLower(strings.TrimSuffix(host, ".")), nil
	}
	return reject(5)
}

func publicIPv4(ip net.IP) bool {
	ip = ip.To4()
	if ip == nil {
		return false
	}
	return ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && ip[0] != 0 && !(ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127) && !(ip[0] == 198 && (ip[1] == 18 || ip[1] == 19)) && !(ip[0] == 192 && ip[1] == 0 && ip[2] == 0)
}

func serveSOCKS(port int, flowPath string) error {
	listener, err := net.Listen("tcp4", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return err
	}
	defer listener.Close()
	var lock sync.Mutex
	slots := make(chan struct{}, 32)
	acceptPace := time.NewTicker(50 * time.Millisecond)
	defer acceptPace.Stop()
	for {
		<-acceptPace.C
		client, err := listener.Accept()
		if err != nil {
			return err
		}
		select {
		case slots <- struct{}{}:
		default:
			client.Close()
			continue
		}
		go func() {
			defer func() { <-slots; client.Close() }()
			upstream, host, err := socksConnect(client, net.DefaultResolver, (&net.Dialer{Timeout: 12 * time.Second}).DialContext)
			if err != nil {
				return
			}
			defer upstream.Close()
			lock.Lock()
			f, e := os.OpenFile(flowPath, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0600)
			if e == nil {
				e = json.NewEncoder(f).Encode(flow{Host: host, Local: upstream.LocalAddr().String(), Remote: upstream.RemoteAddr().String(), Started: time.Now().UnixMilli()})
				f.Close()
			}
			lock.Unlock()
			if e != nil {
				return
			}
			// Bound stalled flows and the maximum duration of a test session.
			deadline := time.Now().Add(3 * time.Minute)
			_ = client.SetDeadline(deadline)
			_ = upstream.SetDeadline(deadline)
			done := make(chan struct{}, 1)
			go func() {
				_, _ = io.Copy(upstream, client)
				if tcp, ok := upstream.(*net.TCPConn); ok {
					_ = tcp.CloseWrite()
				}
				done <- struct{}{}
			}()
			_, _ = io.Copy(client, upstream)
			client.Close()
			upstream.Close()
			<-done
		}()
	}
}
