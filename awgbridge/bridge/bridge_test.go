package bridge

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/net/proxy"
)

// Стенд: «сервер» AmneziaWG и мост-клиент в одном процессе, оба на стеке в
// пространстве пользователя, между ними настоящий UDP по петле. На стороне
// сервера внутри туннеля слушают HTTP и UDP-эхо — до них и надо достучаться
// через SOCKS5 моста.

const (
	serverTunnelIP = "10.9.0.1"
	clientTunnelIP = "10.9.0.2"
	echoPort       = 5353
)

func newKey(t *testing.T) (priv, pub string) {
	t.Helper()
	var k [32]byte
	if _, err := rand.Read(k[:]); err != nil {
		t.Fatal(err)
	}
	k[0] &= 248
	k[31] = (k[31] & 127) | 64
	p, err := curve25519.X25519(k[:], curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(k[:]), base64.StdEncoding.EncodeToString(p)
}

func randomKey(t *testing.T) string {
	t.Helper()
	var k [32]byte
	if _, err := rand.Read(k[:]); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(k[:])
}

func freeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

// paramLines — строки маскировки для стороны сервера. Имена UAPI берутся из
// тех же таблиц, что и у моста, но сам запрос собран отдельно: сервер здесь
// играет роль чужой реализации.
func paramLines(t *testing.T, params map[string]string) string {
	t.Helper()
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		lk, v := strings.ToLower(k), params[k]
		switch {
		case lk == "headerprotectionkey":
			h, err := keyToHex(k, v)
			if err != nil {
				t.Fatal(err)
			}
			fmt.Fprintf(&b, "header_protection_key=%s\n", h)
		case switchKeys[lk] != "":
			fmt.Fprintf(&b, "%s=%t\n", switchKeys[lk], v == "on")
		default:
			fmt.Fprintf(&b, "%s=%s\n", paramKeys[lk], v)
		}
	}
	return b.String()
}

// serverVerbose — подробный журнал стороны сервера, когда нужно разобрать,
// что происходит между сторонами.
var serverVerbose func(format string, args ...any)

type rig struct {
	port                 int
	serverPub, clientKey string
}

// startServer поднимает сторону сервера с параметрами маскировки params.
func startServer(t *testing.T, params map[string]string) rig {
	t.Helper()
	serverPriv, serverPub := newKey(t)
	clientPriv, clientPub := newKey(t)
	port := freeUDPPort(t)

	tunDev, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr(serverTunnelIP)}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	logger := &device.Logger{Verbosef: device.DiscardLogf, Errorf: t.Logf}
	if serverVerbose != nil {
		logger.Verbosef, logger.Errorf = serverVerbose, serverVerbose
	}
	dev := device.NewDevice(tunDev, conn.NewStdNetBind(), logger)
	t.Cleanup(dev.Close)

	privHex, _ := keyToHex("server key", serverPriv)
	pubHex, _ := keyToHex("client key", clientPub)
	if err := dev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\n%s", privHex, port, paramLines(t, params))); err != nil {
		t.Fatalf("server config: %v", err)
	}
	// Та же особенность движка, что и у клиента (см. primeTransportPadding):
	// без холостого пакета первый ответ сервера ушёл бы без заполнения S4.
	if c, err := tnet.DialUDPAddrPort(
		netip.AddrPortFrom(netip.MustParseAddr(serverTunnelIP), 0),
		netip.MustParseAddrPort("192.0.2.1:9")); err == nil {
		c.Write([]byte{0})
		c.Close()
		time.Sleep(20 * time.Millisecond)
	}
	if err := dev.IpcSet(fmt.Sprintf("public_key=%s\nallowed_ip=%s/32\n", pubHex, clientTunnelIP)); err != nil {
		t.Fatalf("server peer: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}

	// HTTP внутри туннеля.
	ln, err := tnet.ListenTCP(&net.TCPAddr{Port: 80})
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, "hello through awg")
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	// UDP-эхо внутри туннеля.
	echo, err := tnet.ListenUDPAddrPort(netip.AddrPortFrom(netip.MustParseAddr(serverTunnelIP), echoPort))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { echo.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := echo.ReadFrom(buf)
			if err != nil {
				return
			}
			echo.WriteTo(append([]byte("echo:"), buf[:n]...), from)
		}
	}()

	return rig{port: port, serverPub: serverPub, clientKey: clientPriv}
}

// startClient поднимает мост к стенду с параметрами params.
func startClient(t *testing.T, r rig, params map[string]string) net.Addr {
	t.Helper()
	b, err := Start(Config{Servers: []Server{{
		Tag:        "srv_0",
		Listen:     "127.0.0.1:0",
		PrivateKey: r.clientKey,
		Addresses:  []string{clientTunnelIP + "/32"},
		MTU:        1280,
		PublicKey:  r.serverPub,
		Endpoint:   fmt.Sprintf("127.0.0.1:%d", r.port),
		Params:     params,
	}}}, t.Logf)
	if err != nil {
		t.Fatalf("bridge: %v", err)
	}
	t.Cleanup(b.Close)
	return b.Addr("srv_0")
}

// httpThroughSocks делает GET к HTTP-серверу внутри туннеля через SOCKS5.
func httpThroughSocks(socks net.Addr, timeout time.Duration) (string, error) {
	dialer, err := proxy.SOCKS5("tcp", socks.String(), nil, &net.Dialer{Timeout: timeout})
	if err != nil {
		return "", err
	}
	type result struct {
		body string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		c, err := dialer.Dial("tcp", serverTunnelIP+":80")
		if err != nil {
			ch <- result{err: err}
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(timeout))
		fmt.Fprintf(c, "GET / HTTP/1.0\r\nHost: test\r\n\r\n")
		resp, err := http.ReadResponse(bufio.NewReader(c), nil)
		if err != nil {
			ch <- result{err: err}
			return
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		ch <- result{body: string(body), err: err}
	}()
	select {
	case r := <-ch:
		return r.body, r.err
	case <-time.After(timeout):
		return "", errors.New("timed out")
	}
}

// udpThroughSocks отправляет датаграмму на UDP-эхо внутри туннеля через
// UDP ASSOCIATE и возвращает ответ.
func udpThroughSocks(socks net.Addr, payload string, timeout time.Duration) (string, error) {
	ctl, err := net.DialTimeout("tcp", socks.String(), timeout)
	if err != nil {
		return "", err
	}
	defer ctl.Close()
	ctl.SetDeadline(time.Now().Add(timeout))
	if _, err := ctl.Write([]byte{5, 1, 0}); err != nil {
		return "", err
	}
	greet := make([]byte, 2)
	if _, err := io.ReadFull(ctl, greet); err != nil || greet[1] != 0 {
		return "", fmt.Errorf("greeting: %v %v", greet, err)
	}
	if _, err := ctl.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return "", err
	}
	reply := make([]byte, 10)
	if _, err := io.ReadFull(ctl, reply); err != nil || reply[1] != 0 || reply[3] != 1 {
		return "", fmt.Errorf("associate reply: %v %v", reply, err)
	}
	relay := &net.UDPAddr{IP: net.IP(reply[4:8]), Port: int(binary.BigEndian.Uint16(reply[8:10]))}

	u, err := net.DialUDP("udp", nil, relay)
	if err != nil {
		return "", err
	}
	defer u.Close()
	u.SetDeadline(time.Now().Add(timeout))
	ip := netip.MustParseAddr(serverTunnelIP).As4()
	pkt := append([]byte{0, 0, 0, 1}, ip[:]...)
	pkt = binary.BigEndian.AppendUint16(pkt, echoPort)
	pkt = append(pkt, payload...)
	if _, err := u.Write(pkt); err != nil {
		return "", err
	}
	buf := make([]byte, 2048)
	n, err := u.Read(buf)
	if err != nil {
		return "", err
	}
	if n < 10 || buf[3] != 1 {
		return "", fmt.Errorf("short or non-IPv4 reply: %v", buf[:n])
	}
	if got := netip.AddrFrom4([4]byte(buf[4:8])).String(); got != serverTunnelIP {
		return "", fmt.Errorf("reply from %s", got)
	}
	return string(buf[10:n]), nil
}

// params31 — набор AmneziaWG 3.1 того же вида, что выдаёт 3x-ui.
func params31(t *testing.T) map[string]string {
	return map[string]string{
		"Jc": "4", "Jmin": "10", "Jmax": "50",
		"S1": "30", "S2": "45", "S3": "20", "S4": "16",
		"H1": "100000-200000", "H2": "300000-400000", "H3": "500000-600000", "H4": "700000-800000",
		"I1":                     "<r 32>",
		"HeaderProtectionKey":    randomKey(t),
		"ContentPaddingAddition": "0-32",
		"RandomTrailers":         "on",
	}
}

func copyParams(p map[string]string) map[string]string {
	out := make(map[string]string, len(p))
	for k, v := range p {
		out[k] = v
	}
	return out
}

func TestTCPAndUDPThroughAmneziaWG31(t *testing.T) {
	params := params31(t)
	socks := startClient(t, startServer(t, params), params)

	started := time.Now()
	body, err := httpThroughSocks(socks, 10*time.Second)
	if err != nil {
		t.Fatalf("TCP through the bridge: %v", err)
	}
	if body != "hello through awg" {
		t.Fatalf("TCP through the bridge: got %q", body)
	}
	// Первый же запрос, вместе с рукопожатием, обязан пройти быстро. Без
	// primeTransportPadding он занимал 2 с: первый пакет уходил без
	// заполнения S4, сервер его отбрасывал, и TCP повторял SYN.
	if took := time.Since(started); took > 900*time.Millisecond {
		t.Fatalf("the first request took %v: the first packet was lost", took)
	}

	got, err := udpThroughSocks(socks, "ping", 10*time.Second)
	if err != nil {
		t.Fatalf("UDP through the bridge: %v", err)
	}
	if got != "echo:ping" {
		t.Fatalf("UDP through the bridge: got %q", got)
	}
}

// Тот же порт принимает и HTTP-прокси: им меряет задержку приложение.
func TestHTTPProxyOnTheSamePort(t *testing.T) {
	params := params31(t)
	socks := startClient(t, startServer(t, params), params)

	// Обычный http: запрос с полным адресом пересылается серверу.
	proxyURL, _ := url.Parse("http://" + socks.String())
	client := &http.Client{
		Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
		Timeout:   10 * time.Second,
	}
	resp, err := client.Get("http://" + serverTunnelIP + "/")
	if err != nil {
		t.Fatalf("plain request through the HTTP proxy: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "hello through awg" {
		t.Fatalf("plain request: got %q", body)
	}

	// CONNECT — так через прокси ходит https.
	c, err := net.DialTimeout("tcp", socks.String(), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	fmt.Fprintf(c, "CONNECT %s:80 HTTP/1.1\r\nHost: %s:80\r\n\r\n", serverTunnelIP, serverTunnelIP)
	br := bufio.NewReader(c)
	status, err := br.ReadString('\n')
	if err != nil || !strings.Contains(status, " 200 ") {
		t.Fatalf("CONNECT: %q, %v", status, err)
	}
	for line := status; strings.TrimSpace(line) != ""; {
		if line, err = br.ReadString('\n'); err != nil {
			t.Fatal(err)
		}
	}
	fmt.Fprintf(c, "GET / HTTP/1.0\r\nHost: test\r\n\r\n")
	inner, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatalf("through CONNECT: %v", err)
	}
	body, _ = io.ReadAll(inner.Body)
	inner.Body.Close()
	if string(body) != "hello through awg" {
		t.Fatalf("through CONNECT: got %q", body)
	}
}

// Конфиг 2.0 (без строк 3.1) — такой пользователь делает для роутера, и мост
// обязан принимать его тоже.
func TestAmneziaWG20ConfigWorks(t *testing.T) {
	params := map[string]string{
		"Jc": "5", "Jmin": "10", "Jmax": "50",
		"S1": "30", "S2": "45", "S3": "20", "S4": "8",
		"H1": "1100000000-1200000000", "H2": "1300000000-1400000000",
		"H3": "1500000000-1600000000", "H4": "1700000000-1800000000",
		"I1": "<r 64>",
	}
	socks := startClient(t, startServer(t, params), params)
	body, err := httpThroughSocks(socks, 10*time.Second)
	if err != nil || body != "hello through awg" {
		t.Fatalf("got %q, %v", body, err)
	}
}

// Контроль: параметры маскировки действительно доходят до движка. С чужим
// ключом защиты заголовков и с чужим H1 туннель подняться не должен — если бы
// мост их молча терял, эти случаи проходили бы так же, как правильный.
func TestWrongObfuscationDoesNotConnect(t *testing.T) {
	for name, spoil := range map[string]func(map[string]string){
		"another header protection key": func(p map[string]string) { p["HeaderProtectionKey"] = randomKey(t) },
		"another H1":                    func(p map[string]string) { p["H1"] = "900000-950000" },
	} {
		t.Run(name, func(t *testing.T) {
			params := params31(t)
			r := startServer(t, params)
			wrong := copyParams(params)
			spoil(wrong)
			socks := startClient(t, r, wrong)
			if body, err := httpThroughSocks(socks, 4*time.Second); err == nil {
				t.Fatalf("connected with wrong parameters: %q", body)
			}
		})
	}
}

func TestUAPI(t *testing.T) {
	priv, pub := newKey(t)
	hp := randomKey(t)
	hpHex, _ := keyToHex("hp", hp)
	s := Server{
		Tag: "srv_3", PrivateKey: priv, PublicKey: pub,
		Endpoint: "203.0.113.7:51820", Keepalive: 25,
		Params: map[string]string{
			"Jc": "4", "H1": "100-200", "I1": "<r 32>",
			"HeaderProtectionKey": hp, "ContentPaddingAddition": "0-32",
			"RekeyAfterTime": "100-140", "RandomTrailers": "on", "DisableCookies": "off",
			"S3": "", // пустое значение — строки нет вовсе
		},
	}
	conf, err := s.uapi()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"jc=4\n", "h1=100-200\n", "i1=<r 32>\n",
		"header_protection_key=" + hpHex + "\n",
		"content_padding_addition=0-32\n", "rekey_after_time=100-140\n",
		"random_trailers=true\n", "disable_cookies=false\n",
		"endpoint=203.0.113.7:51820\n", "persistent_keepalive_interval=25\n",
		"allowed_ip=0.0.0.0/0\n", "allowed_ip=::/0\n",
	} {
		if !strings.Contains(conf, want) {
			t.Errorf("no %q in:\n%s", want, conf)
		}
	}
	if strings.Contains(conf, "s3=") {
		t.Errorf("empty S3 must not produce a line:\n%s", conf)
	}
	// Настройки устройства обязаны идти раньше настроек узла.
	if strings.Index(conf, "jc=") > strings.Index(conf, "public_key=") {
		t.Errorf("device keys after peer keys:\n%s", conf)
	}
}

func TestBadConfigNamesTheServer(t *testing.T) {
	priv, pub := newKey(t)
	good := Server{Tag: "srv_0", Listen: "127.0.0.1:0", PrivateKey: priv, PublicKey: pub,
		Addresses: []string{"10.0.0.2/32"}, Endpoint: "203.0.113.7:51820"}

	for name, breakIt := range map[string]func(*Server){
		"key that is not base64": func(s *Server) { s.PublicKey = "not a key" },
		"unknown parameter":      func(s *Server) { s.Params = map[string]string{"Jx": "1"} },
		"no address":             func(s *Server) { s.Addresses = nil },
		"overlapping header ranges": func(s *Server) {
			s.Params = map[string]string{"H1": "100-200", "H2": "150-300", "H3": "400-500", "H4": "600-700"}
		},
	} {
		t.Run(name, func(t *testing.T) {
			bad := good
			bad.Tag = "srv_7"
			breakIt(&bad)
			err := Check(Config{Servers: []Server{good, bad}})
			var se *ServerError
			if !errors.As(err, &se) || se.Tag != "srv_7" {
				t.Fatalf("want an error naming srv_7, got %v", err)
			}
			if !strings.HasPrefix(err.Error(), "server srv_7: ") {
				t.Fatalf("error text: %q", err.Error())
			}
		})
	}

	if err := Check(Config{Servers: []Server{good}}); err != nil {
		t.Fatalf("good config rejected: %v", err)
	}
}
