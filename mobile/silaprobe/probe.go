// Package silaprobe — пробный экземпляр sing-box для замера задержки на
// Android без поднятого VPN.
//
// На Windows режим «сквозной путь» поднимает отдельный процесс sing-box на
// служебных портах и шлёт через каждый сервер настоящий запрос (Clash API
// `delay`). На Android процессов нет, и до этой правки «сквозной путь» без
// подключения тихо подменялся временем рукопожатия, а с подключением шёл
// через ядро туннеля — цифры «менялись от подключения» (пользователь,
// 07.10.2026: «сделать обыкновенный замер без подключения»).
//
// Здесь — тот же sing-box, что в libbox, но без туннеля и без платформенного
// слоя: только Clash API и исходящие. Конфиг собирает Dart, как для
// пробного процесса на Windows.
package silaprobe

import (
	"context"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

// Probe — работающий пробный экземпляр.
type Probe struct {
	instance *box.Box
	cancel   context.CancelFunc
}

// Start поднимает пробный sing-box из готового JSON.
func Start(configJSON string) (*Probe, error) {
	ctx, cancel := context.WithCancel(context.Background())
	ctx = include.Context(ctx)
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		cancel()
		return nil, err
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		cancel()
		return nil, err
	}
	if err = instance.Start(); err != nil {
		instance.Close()
		cancel()
		return nil, err
	}
	return &Probe{instance: instance, cancel: cancel}, nil
}

// Close останавливает экземпляр и освобождает его порты.
func (p *Probe) Close() error {
	err := p.instance.Close()
	p.cancel()
	return err
}
