package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"syscall"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// Выход в сеть для тестового сервера: то, что у настоящего сервера делает
// ядро (NAT), здесь делается в пространстве пользователя. Сетевой стек
// принимает соединения на ЛЮБОЙ адрес назначения и пересылает их обычными
// сокетами машины — так клиент через туннель видит настоящий интернет, и
// приложение можно проверять целиком, вместе с его проверкой связи.
//
// Устройство для amneziawg-go — по образцу его же tun/netstack (лицензия
// MIT), только стек здесь открыт: готовый пакет его прячет, а пересылке он
// нужен.

type natTun struct {
	ep       *channel.Endpoint
	stack    *stack.Stack
	events   chan tun.Event
	notify   *channel.NotificationHandle
	incoming chan *buffer.View
	mtu      int
}

// newNATTun создаёт устройство, которое пересылает весь TCP и UDP наружу.
// Соединения на innerAddr:80 уходят на локальный HTTP-сервер localHTTP — это
// «внутренний» адрес сервера, по которому удобно проверять сам туннель.
func newNATTun(mtu int, innerAddr, localHTTP string) (*natTun, error) {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	sack := tcpip.TCPSACKEnabled(true)
	s.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)

	t := &natTun{
		ep:       channel.New(1024, uint32(mtu), ""),
		stack:    s,
		events:   make(chan tun.Event, 10),
		incoming: make(chan *buffer.View),
		mtu:      mtu,
	}
	t.notify = t.ep.AddNotify(t)
	if err := s.CreateNIC(1, t.ep); err != nil {
		return nil, fmt.Errorf("CreateNIC: %v", err)
	}
	// Принимать пакеты на чужие адреса и отвечать от их имени — без этого
	// стек отбрасывал бы всё, что адресовано не ему самому.
	s.SetPromiscuousMode(1, true)
	s.SetSpoofing(1, true)
	s.AddRoute(tcpip.Route{Destination: header.IPv4EmptySubnet, NIC: 1})

	tcpForwarder := tcp.NewForwarder(s, 0, 2048, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		target := net.JoinHostPort(id.LocalAddress.String(), strconv.Itoa(int(id.LocalPort)))
		if id.LocalAddress.String() == innerAddr && id.LocalPort == 80 {
			target = localHTTP
		}
		remote, err := net.DialTimeout("tcp", target, 10*time.Second)
		if err != nil {
			r.Complete(true)
			return
		}
		var wq waiter.Queue
		ep, tcpErr := r.CreateEndpoint(&wq)
		if tcpErr != nil {
			remote.Close()
			r.Complete(true)
			return
		}
		r.Complete(false)
		local := gonet.NewTCPConn(&wq, ep)
		go func() {
			defer local.Close()
			defer remote.Close()
			go io.Copy(remote, local)
			io.Copy(local, remote)
		}()
	})
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpForwarder.HandlePacket)

	udpForwarder := udp.NewForwarder(s, func(r *udp.ForwarderRequest) bool {
		id := r.ID()
		target := net.JoinHostPort(id.LocalAddress.String(), strconv.Itoa(int(id.LocalPort)))
		remote, err := net.Dial("udp", target)
		if err != nil {
			return false
		}
		var wq waiter.Queue
		ep, udpErr := r.CreateEndpoint(&wq)
		if udpErr != nil {
			remote.Close()
			return false
		}
		local := gonet.NewUDPConn(&wq, ep)
		go relayUDP(local, remote)
		return true
	})
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpForwarder.HandlePacket)

	t.events <- tun.EventUp
	return t, nil
}

// relayUDP гоняет датаграммы в обе стороны, пока поток не замолчит на минуту.
func relayUDP(local, remote net.Conn) {
	defer local.Close()
	defer remote.Close()
	const idle = time.Minute
	go func() {
		buf := make([]byte, 65535)
		for {
			remote.SetReadDeadline(time.Now().Add(idle))
			n, err := remote.Read(buf)
			if err != nil {
				local.Close()
				return
			}
			local.Write(buf[:n])
		}
	}()
	buf := make([]byte, 65535)
	for {
		local.SetReadDeadline(time.Now().Add(idle))
		n, err := local.Read(buf)
		if err != nil {
			return
		}
		remote.Write(buf[:n])
	}
}

// prime выпускает из стека один холостой пакет — чтобы читающий поток движка
// забрал его со старым размером заполнения S4 (см. primeTransportPadding в
// пакете bridge).
func (t *natTun) prime() {
	local := tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{10, 9, 0, 1})}
	remote := tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{192, 0, 2, 1}), Port: 9}
	c, err := gonet.DialUDP(t.stack, &local, &remote, ipv4.ProtocolNumber)
	if err != nil {
		return
	}
	c.Write([]byte{0})
	c.Close()
}

func (t *natTun) Name() (string, error)    { return "nat", nil }
func (t *natTun) File() *os.File           { return nil }
func (t *natTun) Events() <-chan tun.Event { return t.events }
func (t *natTun) MTU() (int, error)        { return t.mtu, nil }
func (t *natTun) BatchSize() int           { return 1 }

// Read отдаёт движку пакет, который стек хочет отправить клиенту.
func (t *natTun) Read(buf [][]byte, sizes []int, offset int) (int, error) {
	view, ok := <-t.incoming
	if !ok {
		return 0, os.ErrClosed
	}
	n, err := view.Read(buf[0][offset:])
	if err != nil {
		return 0, err
	}
	sizes[0] = n
	return 1, nil
}

// Write принимает от движка расшифрованный пакет клиента и отдаёт его стеку.
func (t *natTun) Write(buf [][]byte, offset int) (int, error) {
	for _, b := range buf {
		packet := b[offset:]
		if len(packet) == 0 {
			continue
		}
		if packet[0]>>4 != 4 {
			return 0, syscall.EAFNOSUPPORT
		}
		pkb := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
		t.ep.InjectInbound(header.IPv4ProtocolNumber, pkb)
	}
	return len(buf), nil
}

func (t *natTun) WriteNotify() {
	pkt := t.ep.Read()
	if pkt == nil {
		return
	}
	view := pkt.ToView()
	pkt.DecRef()
	t.incoming <- view
}

func (t *natTun) Close() error {
	t.stack.RemoveNIC(1)
	t.stack.Close()
	t.ep.RemoveNotify(t.notify)
	t.ep.Close()
	close(t.events)
	close(t.incoming)
	return nil
}
