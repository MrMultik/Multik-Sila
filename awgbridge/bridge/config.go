// Package bridge превращает серверы AmneziaWG в локальные SOCKS5-прокси.
//
// Зачем: всё в Multik Sila идёт через sing-box, а sing-box AmneziaWG не знает
// (как и Xray — в 3x-ui этот протокол тоже живёт не в Xray, а во встроенном в
// панель amneziawg-go). Та же беда была с xhttp и REALITY, и решена она так
// же: соединение с сервером держит отдельный движок и отдаёт на петле порт
// SOCKS5, в который sing-box ходит как в обычный outbound. Здесь движок —
// amneziawg-go на сетевом стеке в пространстве пользователя: сетевой адаптер
// не создаётся, права администратора не нужны, и на Android это работает
// внутри процесса приложения.
//
// Мост обязан быть SOCKS5 с UDP: через него идут и запросы DNS.
package bridge

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strconv"
	"strings"
)

// Server — один сервер AmneziaWG: содержимое клиентского .conf плюс адрес на
// петле, где слушает его порт SOCKS5.
type Server struct {
	Tag    string `json:"tag"`
	Listen string `json:"listen"`

	PrivateKey string   `json:"private_key"`
	Addresses  []string `json:"addresses"`
	DNS        []string `json:"dns"`
	MTU        int      `json:"mtu"`

	PublicKey    string   `json:"public_key"`
	PresharedKey string   `json:"preshared_key"`
	Endpoint     string   `json:"endpoint"`
	Keepalive    int      `json:"keepalive"`
	AllowedIPs   []string `json:"allowed_ips"`

	// Params — строки маскировки из секции [Interface] ровно как в .conf:
	// Jc, Jmin, S1, H1, I1, HeaderProtectionKey, RandomTrailers и так далее.
	// Регистр ключей не важен.
	Params map[string]string `json:"params"`
}

// Config — то, что приложение пишет мосту.
type Config struct {
	Servers []Server `json:"servers"`
	// Verbose включает подробный журнал amneziawg-go (рукопожатия).
	Verbose bool `json:"verbose"`
}

// DefaultMTU — рекомендация Amnezia для 3.1. В .conf от 3x-ui своё значение
// есть всегда; это запас на случай конфига, где его нет.
const DefaultMTU = 1280

// paramKeys: ключ .conf (в нижнем регистре) -> имя в UAPI. Значения идут как
// есть: числа, диапазоны («a-b») и описания пакетов amneziawg-go разбирает
// сам, и разойтись с его правилами здесь нечему.
var paramKeys = map[string]string{
	"jc": "jc", "jmin": "jmin", "jmax": "jmax",
	"s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
	"h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
	"i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
	"contentpaddingaddition": "content_padding_addition",
	"rekeyaftertime":         "rekey_after_time",
	"rekeytimeout":           "rekey_timeout",
	"rejectaftertime":        "reject_after_time",
	"keepalivetimeout":       "keepalive_timeout",
	"maxhandshakeattempts":   "max_handshake_attempts",
}

// switchKeys — строки вида «on/off».
var switchKeys = map[string]string{
	"randomtrailers": "random_trailers",
	"disablecookies": "disable_cookies",
}

func keyToHex(name, b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return "", fmt.Errorf("%s is not base64: %w", name, err)
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("%s must be 32 bytes, got %d", name, len(raw))
	}
	return hex.EncodeToString(raw), nil
}

func parseSwitch(v string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "on", "true", "1", "yes":
		return true, nil
	case "off", "false", "0", "no", "":
		return false, nil
	}
	return false, fmt.Errorf("expected on or off, got %q", v)
}

// resolveEndpoint отдаёт адрес сервера как ip:port — ничего другого
// amneziawg-go не принимает. Имя разрешается здесь, один раз, системным
// резолвером. Приложение под своим TUN передаёт сюда уже готовый адрес:
// иначе запрос имени ушёл бы в туннель, который ещё не поднят.
func resolveEndpoint(endpoint string) (string, error) {
	if ap, err := netip.ParseAddrPort(endpoint); err == nil {
		return ap.String(), nil
	}
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", fmt.Errorf("endpoint %q: %w", endpoint, err)
	}
	p, err := strconv.Atoi(port)
	if err != nil || p <= 0 || p > 65535 {
		return "", fmt.Errorf("endpoint %q: bad port", endpoint)
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return "", fmt.Errorf("endpoint %q: cannot resolve %s", endpoint, host)
	}
	// Сначала IPv4: туннель поверх IPv6 работает заметно реже.
	sort.SliceStable(ips, func(i, j int) bool { return ips[i].To4() != nil && ips[j].To4() == nil })
	addr, _ := netip.AddrFromSlice(ips[0])
	return netip.AddrPortFrom(addr.Unmap(), uint16(p)).String(), nil
}

// uapi — сервер в виде одного запроса «set» для amneziawg-go: настройки
// устройства, затем узел.
func (s Server) uapi() (string, error) {
	dev, err := s.uapiDevice()
	if err != nil {
		return "", err
	}
	peer, err := s.uapiPeer()
	if err != nil {
		return "", err
	}
	return dev + peer, nil
}

// uapiDevice — настройки самого устройства: ключ и маскировка. Отдельно от
// узла они нужны мосту (см. primeTransportPadding).
func (s Server) uapiDevice() (string, error) {
	var b strings.Builder

	priv, err := keyToHex("PrivateKey", s.PrivateKey)
	if err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	b.WriteString("replace_peers=true\n")

	// Порядок фиксированный: один и тот же .conf всегда даёт один и тот же
	// запрос.
	keys := make([]string, 0, len(s.Params))
	for k := range s.Params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := strings.TrimSpace(s.Params[k])
		lk := strings.ToLower(strings.TrimSpace(k))
		switch {
		case lk == "headerprotectionkey":
			if v == "" {
				continue
			}
			h, err := keyToHex("HeaderProtectionKey", v)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(&b, "header_protection_key=%s\n", h)
		case switchKeys[lk] != "":
			on, err := parseSwitch(v)
			if err != nil {
				return "", fmt.Errorf("%s: %w", k, err)
			}
			fmt.Fprintf(&b, "%s=%t\n", switchKeys[lk], on)
		case paramKeys[lk] != "":
			if v == "" {
				continue
			}
			if strings.ContainsAny(v, "\r\n") {
				return "", fmt.Errorf("%s: line break in the value", k)
			}
			fmt.Fprintf(&b, "%s=%s\n", paramKeys[lk], v)
		default:
			// Ключ, которого эта сборка не знает. Честнее отказать, чем
			// поднять туннель наполовину настроенным: он молча не соединится,
			// и причину будет не найти.
			return "", fmt.Errorf("unknown parameter %q", k)
		}
	}
	return b.String(), nil
}

// uapiPeer — единственный узел: сервер, к которому подключаемся.
func (s Server) uapiPeer() (string, error) {
	var b strings.Builder

	pub, err := keyToHex("PublicKey", s.PublicKey)
	if err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "public_key=%s\n", pub)
	if strings.TrimSpace(s.PresharedKey) != "" {
		psk, err := keyToHex("PresharedKey", s.PresharedKey)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", psk)
	}
	endpoint, err := resolveEndpoint(strings.TrimSpace(s.Endpoint))
	if err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "endpoint=%s\n", endpoint)
	if s.Keepalive > 0 {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", s.Keepalive)
	}
	allowed := s.AllowedIPs
	if len(allowed) == 0 {
		allowed = []string{"0.0.0.0/0", "::/0"}
	}
	for _, a := range allowed {
		p, err := netip.ParsePrefix(strings.TrimSpace(a))
		if err != nil {
			return "", fmt.Errorf("AllowedIPs %q: %w", a, err)
		}
		fmt.Fprintf(&b, "allowed_ip=%s\n", p)
	}
	return b.String(), nil
}

// tunnelAddresses — собственные адреса клиента внутри туннеля.
func (s Server) tunnelAddresses() ([]netip.Addr, error) {
	var out []netip.Addr
	for _, a := range s.Addresses {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		if p, err := netip.ParsePrefix(a); err == nil {
			out = append(out, p.Addr())
			continue
		}
		addr, err := netip.ParseAddr(a)
		if err != nil {
			return nil, fmt.Errorf("Address %q: %w", a, err)
		}
		out = append(out, addr)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no Address in the config")
	}
	return out, nil
}

func (s Server) dnsServers() ([]netip.Addr, error) {
	var out []netip.Addr
	for _, d := range s.DNS {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		addr, err := netip.ParseAddr(d)
		if err != nil {
			return nil, fmt.Errorf("DNS %q: %w", d, err)
		}
		out = append(out, addr)
	}
	if len(out) == 0 {
		// Без резолвера CONNECT по имени было бы некого спросить.
		out = []netip.Addr{netip.MustParseAddr("1.1.1.1"), netip.MustParseAddr("8.8.8.8")}
	}
	return out, nil
}

func (s Server) mtu() int {
	if s.MTU > 0 {
		return s.MTU
	}
	return DefaultMTU
}
