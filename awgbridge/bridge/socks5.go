package bridge

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// SOCKS5 в объёме, который нужен sing-box: без авторизации, CONNECT и
// UDP ASSOCIATE (RFC 1928). Своя реализация, а не библиотека, намеренно: на
// Android этот пакет собирается в один модуль с sing-box и Xray, и каждая
// лишняя зависимость там — повод для конфликта версий.

const (
	socksVersion = 5

	cmdConnect      = 1
	cmdUDPAssociate = 3

	atypIPv4   = 1
	atypDomain = 3
	atypIPv6   = 4

	repOK                  = 0
	repGeneralFailure      = 1
	repHostUnreachable     = 4
	repCommandNotSupported = 7
	repAddressNotSupported = 8
)

func (t *tunnel) serve() {
	for {
		c, err := t.listener.Accept()
		if err != nil {
			return
		}
		go t.handle(c)
	}
}

func (t *tunnel) handle(c net.Conn) {
	defer c.Close()
	// Срок только на само рукопожатие SOCKS: дальше соединение может молчать
	// сколько угодно.
	c.SetDeadline(time.Now().Add(30 * time.Second))
	br := bufio.NewReader(c)

	// Приветствие: версия, число методов, методы.
	head := make([]byte, 2)
	if _, err := io.ReadFull(br, head); err != nil || head[0] != socksVersion {
		return
	}
	methods := make([]byte, head[1])
	if _, err := io.ReadFull(br, methods); err != nil {
		return
	}
	noAuth := false
	for _, m := range methods {
		if m == 0 {
			noAuth = true
		}
	}
	if !noAuth {
		c.Write([]byte{socksVersion, 0xFF})
		return
	}
	if _, err := c.Write([]byte{socksVersion, 0}); err != nil {
		return
	}

	// Запрос: версия, команда, резерв, тип адреса, адрес, порт.
	req := make([]byte, 4)
	if _, err := io.ReadFull(br, req); err != nil || req[0] != socksVersion {
		return
	}
	host, port, err := readAddress(br, req[3])
	if err != nil {
		writeReply(c, repAddressNotSupported, nil)
		return
	}
	c.SetDeadline(time.Time{})

	switch req[1] {
	case cmdConnect:
		t.connect(c, br, host, port)
	case cmdUDPAssociate:
		t.udpAssociate(c, br)
	default:
		writeReply(c, repCommandNotSupported, nil)
	}
}

// readAddress читает адрес и порт в формате SOCKS5. Имя возвращается как
// есть: разрешать его должен DNS по ту сторону туннеля.
func readAddress(r io.Reader, atyp byte) (string, uint16, error) {
	var host string
	switch atyp {
	case atypIPv4:
		b := make([]byte, 4)
		if _, err := io.ReadFull(r, b); err != nil {
			return "", 0, err
		}
		host = netip.AddrFrom4([4]byte(b)).String()
	case atypIPv6:
		b := make([]byte, 16)
		if _, err := io.ReadFull(r, b); err != nil {
			return "", 0, err
		}
		host = netip.AddrFrom16([16]byte(b)).Unmap().String()
	case atypDomain:
		l := make([]byte, 1)
		if _, err := io.ReadFull(r, l); err != nil {
			return "", 0, err
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(r, b); err != nil {
			return "", 0, err
		}
		host = string(b)
	default:
		return "", 0, fmt.Errorf("address type %d", atyp)
	}
	p := make([]byte, 2)
	if _, err := io.ReadFull(r, p); err != nil {
		return "", 0, err
	}
	return host, binary.BigEndian.Uint16(p), nil
}

// appendAddress дописывает адрес и порт в формате SOCKS5.
func appendAddress(b []byte, addr netip.AddrPort) []byte {
	ip := addr.Addr().Unmap()
	if ip.Is4() {
		a := ip.As4()
		b = append(b, atypIPv4)
		b = append(b, a[:]...)
	} else {
		a := ip.As16()
		b = append(b, atypIPv6)
		b = append(b, a[:]...)
	}
	return binary.BigEndian.AppendUint16(b, addr.Port())
}

func writeReply(c net.Conn, rep byte, bound net.Addr) error {
	addr := netip.AddrPortFrom(netip.IPv4Unspecified(), 0)
	if bound != nil {
		if ap, err := netip.ParseAddrPort(bound.String()); err == nil {
			addr = ap
		}
	}
	_, err := c.Write(appendAddress([]byte{socksVersion, rep, 0}, addr))
	return err
}

func (t *tunnel) connect(c net.Conn, br *bufio.Reader, host string, port uint16) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	remote, err := t.tnet.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(int(port))))
	cancel()
	if err != nil {
		writeReply(c, repHostUnreachable, nil)
		return
	}
	defer remote.Close()
	if err := writeReply(c, repOK, nil); err != nil {
		return
	}

	// Два направления; каждое, дочитав, закрывает свою половину записи, чтобы
	// вторая сторона увидела конец потока, а не обрыв.
	done := make(chan struct{}, 2)
	go func() {
		// Из br, а не из c: часть данных клиента могла уже лежать в буфере.
		io.Copy(remote, br)
		closeWrite(remote)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(c, remote)
		closeWrite(c)
		done <- struct{}{}
	}()
	<-done
	<-done
}

func closeWrite(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
}

// udpAssociate — UDP через туннель. Клиент шлёт датаграммы на наш сокет на
// петле, каждая с заголовком SOCKS5 (куда она на самом деле); мы отправляем
// полезную часть из стека туннеля и возвращаем ответы с таким же заголовком.
// Живёт, пока открыто управляющее TCP-соединение.
func (t *tunnel) udpAssociate(c net.Conn, br *bufio.Reader) {
	local, _ := c.LocalAddr().(*net.TCPAddr)
	if local == nil {
		writeReply(c, repGeneralFailure, nil)
		return
	}
	relay, err := net.ListenUDP("udp", &net.UDPAddr{IP: local.IP})
	if err != nil {
		writeReply(c, repGeneralFailure, nil)
		return
	}
	a := &association{t: t, relay: relay}
	defer a.close()
	if err := writeReply(c, repOK, relay.LocalAddr()); err != nil {
		return
	}
	go a.fromClient()
	// Управляющее соединение больше ничего не несёт; его закрытие — сигнал
	// конца ассоциации.
	io.Copy(io.Discard, br)
}

type association struct {
	t     *tunnel
	relay *net.UDPConn
	// Откуда клиент прислал последнюю датаграмму — туда и уходят ответы.
	client atomic.Pointer[net.UDPAddr]

	mu     sync.Mutex
	closed bool
	// По сокету стека на семейство адресов: сокет, привязанный к IPv4, в
	// IPv6 не отправит.
	out4, out6 net.PacketConn
	// Имена из заголовков: sing-box обычно шлёт уже адрес, но SOCKS5
	// разрешает и имя.
	names map[string]netip.Addr
}

func (a *association) close() {
	a.mu.Lock()
	a.closed = true
	out4, out6 := a.out4, a.out6
	a.mu.Unlock()
	a.relay.Close()
	if out4 != nil {
		out4.Close()
	}
	if out6 != nil {
		out6.Close()
	}
}

func (a *association) fromClient() {
	buf := make([]byte, 65535)
	for {
		n, from, err := a.relay.ReadFromUDP(buf)
		if err != nil {
			return
		}
		// Заголовок: два байта резерва, номер фрагмента, адрес, порт.
		if n < 4 || buf[2] != 0 {
			continue // фрагментацию не поддерживаем — как и почти все
		}
		r := &sliceReader{b: buf[3:n]}
		atyp, _ := r.ReadByte()
		host, port, err := readAddress(r, atyp)
		if err != nil {
			continue
		}
		dst, err := a.resolve(host)
		if err != nil {
			continue
		}
		out, err := a.outFor(dst)
		if err != nil {
			continue
		}
		a.client.Store(from)
		out.WriteTo(r.rest(), net.UDPAddrFromAddrPort(netip.AddrPortFrom(dst, port)))
	}
}

func (a *association) resolve(host string) (netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap(), nil
	}
	a.mu.Lock()
	ip, ok := a.names[host]
	a.mu.Unlock()
	if ok {
		return ip, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	addrs, err := a.t.tnet.LookupContextHost(ctx, host)
	if err != nil {
		return netip.Addr{}, err
	}
	for _, s := range addrs {
		ip, err := netip.ParseAddr(s)
		if err != nil {
			continue
		}
		ip = ip.Unmap()
		// Только то семейство, с которого мы вообще можем отправить.
		if (ip.Is4() && !a.t.local4.IsValid()) || (ip.Is6() && !a.t.local6.IsValid()) {
			continue
		}
		a.mu.Lock()
		if a.names == nil {
			a.names = make(map[string]netip.Addr)
		}
		a.names[host] = ip
		a.mu.Unlock()
		return ip, nil
	}
	return netip.Addr{}, errors.New("no usable address")
}

// outFor отдаёт сокет стека туннеля нужного семейства, создавая его при
// первом обращении и запуская чтение ответов.
func (a *association) outFor(dst netip.Addr) (net.PacketConn, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return nil, net.ErrClosed
	}
	slot, local := &a.out4, a.t.local4
	if dst.Is6() {
		slot, local = &a.out6, a.t.local6
	}
	if *slot != nil {
		return *slot, nil
	}
	if !local.IsValid() {
		return nil, errors.New("no tunnel address of this family")
	}
	out, err := a.t.tnet.ListenUDPAddrPort(netip.AddrPortFrom(local, 0))
	if err != nil {
		return nil, err
	}
	*slot = out
	go a.toClient(out)
	return out, nil
}

func (a *association) toClient(out net.PacketConn) {
	buf := make([]byte, 65535)
	for {
		n, from, err := out.ReadFrom(buf)
		if err != nil {
			return
		}
		client := a.client.Load()
		src, err := netip.ParseAddrPort(from.String())
		if client == nil || err != nil {
			continue
		}
		pkt := appendAddress(make([]byte, 0, n+22), src)
		// Перед адресом — три байта: резерв и номер фрагмента.
		pkt = append([]byte{0, 0, 0}, pkt...)
		pkt = append(pkt, buf[:n]...)
		a.relay.WriteToUDP(pkt, client)
	}
}

// sliceReader — чтение из куска датаграммы теми же функциями, что и из потока.
type sliceReader struct {
	b []byte
}

func (r *sliceReader) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}

func (r *sliceReader) ReadByte() (byte, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	c := r.b[0]
	r.b = r.b[1:]
	return c, nil
}

func (r *sliceReader) rest() []byte { return r.b }
