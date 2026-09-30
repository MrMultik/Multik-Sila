package bridge

import (
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
)

// ServerError — отказ, у которого есть виновник. Один общий конфиг на все
// серверы означает, что без имени виновника отказ одного выглядел бы как
// отказ всех (ровно на этом уже обжигались с общим конфигом Xray): приложение
// по тегу выбрасывает сервер и поднимает остальные.
type ServerError struct {
	Tag string
	Err error
}

func (e *ServerError) Error() string { return fmt.Sprintf("server %s: %v", e.Tag, e.Err) }
func (e *ServerError) Unwrap() error { return e.Err }

// Logf — куда мост пишет. Формат как у Printf, перевод строки не нужен.
type Logf func(format string, args ...any)

// Bridge — работающие туннели со своими портами SOCKS5.
type Bridge struct {
	mu      sync.Mutex
	tunnels []*tunnel
}

// tunnel — один сервер: устройство AmneziaWG, его сетевой стек и слушатель.
type tunnel struct {
	tag      string
	dev      *device.Device
	tnet     *netstack.Net
	listener net.Listener
	// Собственные адреса в туннеле: к ним привязываются UDP-сокеты стека.
	local4, local6 netip.Addr
	logf           Logf
}

// newDevice собирает устройство на стеке в пространстве пользователя и
// применяет к нему конфиг. Сокетов не открывает и в сеть не выходит — этим
// же пользуется Check.
func newDevice(s Server, verbose bool, logf Logf) (*tunnel, error) {
	devConf, err := s.uapiDevice()
	if err != nil {
		return nil, err
	}
	peerConf, err := s.uapiPeer()
	if err != nil {
		return nil, err
	}
	addrs, err := s.tunnelAddresses()
	if err != nil {
		return nil, err
	}
	dns, err := s.dnsServers()
	if err != nil {
		return nil, err
	}

	tunDev, tnet, err := netstack.CreateNetTUN(addrs, dns, s.mtu())
	if err != nil {
		return nil, fmt.Errorf("network stack: %w", err)
	}

	logger := &device.Logger{Verbosef: device.DiscardLogf, Errorf: device.DiscardLogf}
	if logf != nil {
		prefix := "[" + s.Tag + "] "
		logger.Errorf = func(format string, args ...any) { logf(prefix+format, args...) }
		if verbose {
			logger.Verbosef = logger.Errorf
		}
	}
	// NewStdNetBind, а не NewDefaultBind: на Windows умолчание — кольцевые
	// буферы RIO, и обычные сокеты здесь предсказуемее.
	dev := device.NewDevice(tunDev, conn.NewStdNetBind(), logger)
	t := &tunnel{tag: s.Tag, dev: dev, tnet: tnet, logf: logf}
	for _, a := range addrs {
		if a.Is4() && !t.local4.IsValid() {
			t.local4 = a
		}
		if a.Is6() && !a.Is4In6() && !t.local6.IsValid() {
			t.local6 = a
		}
	}

	// Сначала устройство, потом узел — между ними primeTransportPadding.
	if err := dev.IpcSet(devConf); err != nil {
		dev.Close()
		return nil, fmt.Errorf("config rejected: %w", err)
	}
	t.primeTransportPadding()
	if err := dev.IpcSet(peerConf); err != nil {
		dev.Close()
		return nil, fmt.Errorf("config rejected: %w", err)
	}
	return t, nil
}

// primeTransportPadding снимает задержку первого запроса через туннель.
//
// Поток amneziawg-go, читающий пакеты из стека, берёт размер заполнения S4
// ДО того, как встанет ждать пакета, а ждать он встаёт при создании
// устройства — то есть раньше, чем применён конфиг. Поэтому самый первый
// пакет уходит со старым значением, нулём: на 16 байт (или сколько задано в
// S4) короче, чем ждёт сервер. Сервер его не узнаёт и отбрасывает, TCP
// повторяет SYN через секунду. Снято трассой на стенде: первый пакет данных
// 96 байт, все следующие 112, первый запрос — 2 с вместо 2 мс.
//
// Лечится одним холостым пакетом, пока узла ещё нет: читающий поток
// забирает его со старым значением, не находит, кому отправить, и на
// следующем круге берёт уже настоящее S4. В сеть при этом не уходит ничего.
func (t *tunnel) primeTransportPadding() {
	local, remote := t.local4, netip.MustParseAddr("192.0.2.1") // TEST-NET-1
	if !local.IsValid() {
		local, remote = t.local6, netip.MustParseAddr("2001:db8::1")
	}
	if !local.IsValid() {
		return
	}
	c, err := t.tnet.DialUDPAddrPort(netip.AddrPortFrom(local, 0), netip.AddrPortFrom(remote, 9))
	if err != nil {
		return
	}
	c.Write([]byte{0})
	c.Close()
	// Дать читающему потоку забрать пакет до того, как появится узел: иначе
	// холостой пакет ушёл бы серверу и зря начал рукопожатие.
	time.Sleep(20 * time.Millisecond)
}

// Check проверяет конфиг так же, как Start, но ничего не слушает.
// Возвращает первую ошибку; если она про конкретный сервер — *ServerError.
func Check(cfg Config) error {
	for _, s := range cfg.Servers {
		t, err := newDevice(s, false, nil)
		if err != nil {
			return &ServerError{Tag: s.Tag, Err: err}
		}
		t.dev.Close()
	}
	return nil
}

// Start поднимает все серверы конфига. При отказе любого закрывает уже
// поднятые и возвращает *ServerError с его тегом.
func Start(cfg Config, logf Logf) (*Bridge, error) {
	b := &Bridge{}
	for _, s := range cfg.Servers {
		t, err := newDevice(s, cfg.Verbose, logf)
		if err == nil {
			err = t.up(s.Listen)
		}
		if err != nil {
			b.Close()
			return nil, &ServerError{Tag: s.Tag, Err: err}
		}
		b.tunnels = append(b.tunnels, t)
	}
	return b, nil
}

func (t *tunnel) up(listen string) error {
	if err := t.dev.Up(); err != nil {
		t.dev.Close()
		return fmt.Errorf("bring up: %w", err)
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		t.dev.Close()
		return fmt.Errorf("listen %s: %w", listen, err)
	}
	t.listener = ln
	go t.serve()
	return nil
}

// Addr — адрес, на котором слушает SOCKS5 сервера с этим тегом (нужно тестам
// и тем, кто задаёт порт 0).
func (b *Bridge) Addr(tag string) net.Addr {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, t := range b.tunnels {
		if t.tag == tag && t.listener != nil {
			return t.listener.Addr()
		}
	}
	return nil
}

// Close останавливает всё. Повторный вызов безвреден.
func (b *Bridge) Close() {
	b.mu.Lock()
	tunnels := b.tunnels
	b.tunnels = nil
	b.mu.Unlock()
	for _, t := range tunnels {
		if t.listener != nil {
			t.listener.Close()
		}
		t.dev.Close()
	}
}
