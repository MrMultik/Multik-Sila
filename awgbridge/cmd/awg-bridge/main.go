// awg-bridge — мост AmneziaWG для настольной версии Multik Sila.
//
// Запускается приложением так же, как xray.exe для мостов xhttp и REALITY:
//
//	awg-bridge -c awg_bridge.json          поднять серверы и работать
//	awg-bridge -test -c awg_bridge.json    только проверить конфиг
//	awg-bridge -version
//
// Отказ из-за конкретного сервера печатается как «server <тег>: причина» с
// кодом выхода 1 — по тегу приложение выбрасывает этот сервер и пробует снова.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"

	"github.com/MrMultik/Multik-Sila/awgbridge/bridge"
)

const version = "1.0.0"

func main() {
	configPath := flag.String("c", "", "path to the bridge config (JSON)")
	test := flag.Bool("test", false, "check the config and exit")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("awg-bridge %s (amneziawg-go %s)\n", version, bridge.EngineVersion())
		return
	}
	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "no config: use -c <file>")
		os.Exit(2)
	}
	data, err := os.ReadFile(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var cfg bridge.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}

	if *test {
		if err := bridge.Check(cfg); err != nil {
			fail(err)
		}
		fmt.Println("Configuration OK.")
		return
	}

	logger := log.New(os.Stdout, "", log.Ltime)
	b, err := bridge.Start(cfg, logger.Printf)
	if err != nil {
		fail(err)
	}
	logger.Printf("awg-bridge %s started: servers %d", version, len(cfg.Servers))

	// Приложение останавливает мост снятием процесса; сигнал — для запуска
	// руками из консоли.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	<-stop
	b.Close()
}

func fail(err error) {
	var se *bridge.ServerError
	if errors.As(err, &se) {
		// Ровно этот вид строки разбирает приложение.
		fmt.Fprintf(os.Stderr, "server %s: %v\n", se.Tag, se.Err)
	} else {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(1)
}
