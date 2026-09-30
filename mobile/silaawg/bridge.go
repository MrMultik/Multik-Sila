// Package silaawg — мост AmneziaWG для мобильной сборки.
//
// Тот же мост, что на Windows работает отдельной программой `awg-bridge.exe`
// (код общий — модуль awgbridge в корне репозитория), только здесь он живёт
// внутри процесса приложения: запускать сторонние исполняемые файлы на Android
// нельзя. Схема та же, что у silaxray: серверы AmneziaWG превращаются в порты
// SOCKS5 на петле, и sing-box ходит в них как в обычные socks-outbound.
//
// Сокеты моста в туннель не попадают: приложение целиком исключено из
// собственного VPN (`addDisallowedApplication` в SilaVpnService), так что
// петли «туннель в туннеле» здесь быть не может.
//
// Интерфейс узкий по той же причине, что у silaxray: gomobile переносит
// через границу Java/Go только простые типы.
package silaawg

import (
	"encoding/json"
	"fmt"
	"sync"

	"github.com/MrMultik/Multik-Sila/awgbridge/bridge"
)

// Instance — работающий мост со всеми своими серверами. Держится на стороне
// Kotlin, закрывается явно.
type Instance struct {
	mu sync.Mutex
	b  *bridge.Bridge
}

func parse(configJSON string) (bridge.Config, error) {
	var cfg bridge.Config
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return cfg, fmt.Errorf("разбор конфига моста AmneziaWG: %w", err)
	}
	return cfg, nil
}

// Start поднимает мост по JSON-конфигу того же вида, что настольная версия
// пишет в awg_bridge.json: генератор конфигов в Dart один на обе платформы.
//
// Отказ из-за конкретного сервера приходит как «server <тег>: причина» — по
// тегу служба выбрасывает этот сервер и пробует снова, остальные работают.
func Start(configJSON string) (*Instance, error) {
	cfg, err := parse(configJSON)
	if err != nil {
		return nil, err
	}
	b, err := bridge.Start(cfg, nil)
	if err != nil {
		return nil, err
	}
	return &Instance{b: b}, nil
}

// Close останавливает мост. Повторный вызов безвреден.
func (i *Instance) Close() {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.b != nil {
		i.b.Close()
		i.b = nil
	}
}

// Version — версия движка AmneziaWG, с которой собрано ядро (для экрана
// «О программе»).
func Version() string {
	return bridge.EngineVersion()
}
