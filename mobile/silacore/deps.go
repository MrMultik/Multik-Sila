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
package silacore

import (
	_ "github.com/sagernet/sing-box/experimental/libbox"
)
