// Package silaxray — тонкая обёртка над Xray-core для мобильной сборки.
//
// Зачем она вообще нужна рядом с sing-box: sing-box не понимает транспорт
// xhttp. Это не пробел в настройках, а отсутствие кода — в его дереве нет ни
// одного упоминания xhttp/splithttp. В подписке пользователя на этом
// транспорте живут 5 серверов из 15, и без Xray они на Android просто
// пропадут из списка.
//
// Схема повторяет ту, что уже работает в Windows-версии: для каждого
// xhttp-сервера поднимается «мост» — экземпляр Xray с одним inbound SOCKS5 на
// локальном порту и одним outbound на нужный сервер. sing-box ходит в этот
// порт как в обычный socks-outbound. Разница только в том, что на Windows
// мост это отдельный процесс `xray.exe`, а здесь — объект внутри процесса
// приложения: на Android запускать сторонние исполняемые файлы нельзя.
//
// Мост обязан быть именно SOCKS5 с включённым UDP, а не HTTP-прокси: HTTP не
// переносит UDP, а браузеры сегодня регулярно пробуют HTTP/3 поверх QUIC.
// На Windows на этом уже обожглись — в логи сыпалось
// `router: UDP is not supported by outbound`.
//
// Интерфейс намеренно предельно узкий — строки, ошибки и указатель на
// структуру. gomobile умеет переносить через границу Java/Go только простые
// типы, и всё, что сложнее, пришлось бы описывать вручную.
package silaxray

import (
	"bytes"
	"fmt"
	"sync"

	core "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"

	// Регистрирует все протоколы и транспорты, включая xhttp. Без этого
	// импорта конфиг разберётся, но поднять его будет нечем: Xray собирает
	// реализации через глобальный реестр, наполняемый в init().
	_ "github.com/xtls/xray-core/main/distro/all"
)

// Instance — один работающий экземпляр Xray. Держится на стороне Kotlin,
// закрывается явно.
type Instance struct {
	mu      sync.Mutex
	server  *core.Instance
	running bool
}

// Start поднимает Xray по JSON-конфигу того же вида, что и настольная версия
// пишет в xray_bridge_*.json. Формат общий намеренно: генератор конфигов в
// Dart остаётся один на обе платформы, и расхождению взяться неоткуда.
func Start(configJSON string) (*Instance, error) {
	config, err := serial.LoadJSONConfig(bytes.NewReader([]byte(configJSON)))
	if err != nil {
		return nil, fmt.Errorf("разбор конфига Xray: %w", err)
	}
	server, err := core.New(config)
	if err != nil {
		return nil, fmt.Errorf("создание экземпляра Xray: %w", err)
	}
	if err := server.Start(); err != nil {
		// Закрываем сами: иначе при неудачном старте объект остаётся висеть
		// с уже занятыми сокетами, и следующая попытка упрётся в свой же порт.
		_ = server.Close()
		return nil, fmt.Errorf("запуск Xray: %w", err)
	}
	return &Instance{server: server, running: true}, nil
}

// Close останавливает экземпляр. Повторный вызов безопасен — на Android
// остановка приходит и от пользователя, и от системы, и порядок не
// гарантирован.
func (i *Instance) Close() error {
	i.mu.Lock()
	defer i.mu.Unlock()
	if !i.running {
		return nil
	}
	i.running = false
	return i.server.Close()
}

// IsRunning нужен стороне Kotlin, чтобы не считать мост живым по одному лишь
// наличию объекта. На Windows ровно на этом уже наступали: умерший мост
// навсегда оставался «поднятым» в словаре, и подстраховка при переключении
// сервера молча не срабатывала.
func (i *Instance) IsRunning() bool {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.running
}

// Version — версия вкомпилированного ядра. Экран «О программе» показывает
// версии обоих ядер, и брать их надо у самих ядер: на Windows уже ловили
// случай, когда установленная сборка Xray была новее «последнего релиза».
func Version() string {
	return core.Version()
}
