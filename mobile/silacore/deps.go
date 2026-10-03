// Package silacore существует ради одной строки импорта ниже.
//
// gomobile собирает `github.com/sagernet/sing-box/experimental/libbox` —
// пакет из ЗАВИСИМОСТИ, а не из нашего модуля. Без явного импорта Go считает
// его никем не используемым: `go mod tidy` вычищает из go.mod модули, нужные
// только ему, и сборка падает на «no required module provides package».
//
// Пустой импорт делает зависимость настоящей, и весь граф модулей — включая
// то, что подтягивается тегами сборки (quic, gvisor, utls) — остаётся на
// месте.
//
// То же с `github.com/sagernet/gomobile/bind`: его ищет gobind в НАШЕМ
// модуле, а импортирует только код, который gobind генерирует сам. При
// обновлении ядер (02.10.2026) `go mod tidy` его вычистил, и сборка упала на
// «unable to import bind: no Go package in github.com/sagernet/gomobile/bind».
package silacore

import (
	_ "github.com/sagernet/gomobile/bind"
	_ "github.com/sagernet/sing-box/experimental/libbox"
)
