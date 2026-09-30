// awg-testserver — сервер AmneziaWG 3.1 для проверки моста и приложения без
// настоящего сервера. НЕ для работы: один клиент, ключи на один запуск,
// никакой защиты.
//
// Поднимает сторону сервера, выпускает клиента в сеть этой машины (см.
// nat.go) и печатает клиентский .conf в том виде, в каком его выдаёт 3x-ui.
// По адресу http://10.9.0.1/ внутри туннеля отвечает сам — так видно, что
// запрос прошёл именно через туннель. С флагом -v20 — набор параметров
// AmneziaWG 2.0 (без строк 3.x).
//
//	awg-testserver -endpoint 127.0.0.1:51999 > client.conf
//
// Из эмулятора Android хост виден как 10.0.2.2: -endpoint 10.0.2.2:51999.
package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"golang.org/x/crypto/curve25519"
)

const (
	serverIP = "10.9.0.1"
	clientIP = "10.9.0.2"
	mtu      = 1264
)

func newKey() (priv, pub []byte) {
	priv = make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		panic(err)
	}
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		panic(err)
	}
	return priv, pub
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func die(what string, err error) {
	fmt.Fprintln(os.Stderr, what, err)
	os.Exit(1)
}

func main() {
	endpoint := flag.String("endpoint", "127.0.0.1:51999", "address the client should connect to (host:port)")
	v20 := flag.Bool("v20", false, "AmneziaWG 2.0 parameters only")
	flag.Parse()

	_, portText, err := net.SplitHostPort(*endpoint)
	if err != nil {
		fmt.Fprintln(os.Stderr, "endpoint:", err)
		os.Exit(2)
	}

	// Занятый порт движок пишет в журнал и работает дальше «вхолостую» — а
	// клиент при этом молча попадает к тому, кто порт держит (например, к
	// прошлому запуску с другими ключами). Проверяем сами и сразу.
	if probe, err := net.ListenPacket("udp", ":"+portText); err != nil {
		die("UDP port is busy:", err)
	} else {
		probe.Close()
	}

	serverPriv, serverPub := newKey()
	clientPriv, clientPub := newKey()
	headerKey := make([]byte, 32)
	rand.Read(headerKey)

	// Пары «строка .conf» / «строка UAPI» — в одном месте, чтобы сервер и
	// выданный клиенту конфиг не могли разойтись.
	type param struct{ conf, uapi, value string }
	params := []param{
		{"Jc", "jc", "4"}, {"Jmin", "jmin", "10"}, {"Jmax", "jmax", "50"},
		{"S1", "s1", "30"}, {"S2", "s2", "45"}, {"S3", "s3", "20"}, {"S4", "s4", "16"},
		{"H1", "h1", "100000-200000"}, {"H2", "h2", "300000-400000"},
		{"H3", "h3", "500000-600000"}, {"H4", "h4", "700000-800000"},
		{"I1", "i1", "<r 148>"},
	}
	var confExtra, uapiExtra strings.Builder
	if !*v20 {
		params = append(params,
			param{"ContentPaddingAddition", "content_padding_addition", "0-32"},
			param{"RekeyAfterTime", "rekey_after_time", "100-140"})
		fmt.Fprintf(&confExtra, "HeaderProtectionKey = %s\n", b64(headerKey))
		fmt.Fprintf(&uapiExtra, "header_protection_key=%s\n", hex.EncodeToString(headerKey))
		confExtra.WriteString("RandomTrailers = on\n")
		uapiExtra.WriteString("random_trailers=true\n")
	}

	var uapi, conf strings.Builder
	fmt.Fprintf(&uapi, "private_key=%s\nlisten_port=%s\n", hex.EncodeToString(serverPriv), portText)
	fmt.Fprintf(&conf, "[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = 1.1.1.1\nMTU = %d\n", b64(clientPriv), clientIP, mtu)
	for _, p := range params {
		fmt.Fprintf(&uapi, "%s=%s\n", p.uapi, p.value)
		fmt.Fprintf(&conf, "%s = %s\n", p.conf, p.value)
	}
	uapi.WriteString(uapiExtra.String())
	conf.WriteString(confExtra.String())
	fmt.Fprintf(&conf, "\n# awg-testserver - client\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s\nPersistentKeepalive = 25",
		b64(serverPub), *endpoint)

	// Собственный ответ сервера: обычный HTTP на петле машины, куда пересылка
	// отправляет всё, что клиент шлёт на 10.9.0.1:80.
	inner, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		die("inner http:", err)
	}
	go http.Serve(inner, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/generate_204" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		io.WriteString(w, "hello through awg")
	}))

	tunDev, err := newNATTun(mtu, serverIP, inner.Addr().String())
	if err != nil {
		die("network stack:", err)
	}
	logger := &device.Logger{
		Verbosef: device.DiscardLogf,
		Errorf:   func(f string, a ...any) { fmt.Fprintf(os.Stderr, "server: "+f+"\n", a...) },
	}
	dev := device.NewDevice(tunDev, conn.NewStdNetBind(), logger)
	if err := dev.IpcSet(uapi.String()); err != nil {
		die("server config:", err)
	}
	// Первый пакет после настройки движок шлёт без заполнения S4 (см.
	// primeTransportPadding в пакете bridge) — снимаем холостым пакетом, пока
	// узла ещё нет.
	tunDev.prime()
	time.Sleep(20 * time.Millisecond)
	if err := dev.IpcSet(fmt.Sprintf("public_key=%s\nallowed_ip=%s/32\n", hex.EncodeToString(clientPub), clientIP)); err != nil {
		die("server peer:", err)
	}
	if err := dev.Up(); err != nil {
		die("bring up:", err)
	}

	// Конфиг клиента — единственное, что идёт в stdout.
	fmt.Println(conf.String())
	fmt.Fprintf(os.Stderr, "awg-testserver: listening on UDP %s; the client gets this machine's network, and http://%s/ answers from the server itself\n", portText, serverIP)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	<-stop
	dev.Close()
}
