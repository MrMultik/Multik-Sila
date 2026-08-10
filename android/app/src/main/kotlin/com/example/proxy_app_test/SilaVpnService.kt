package com.example.proxy_app_test

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import com.multiksila.libbox.CommandServer
import com.multiksila.libbox.CommandServerHandler
import com.multiksila.libbox.InterfaceUpdateListener
import com.multiksila.libbox.Libbox
import com.multiksila.libbox.LocalDNSTransport
import com.multiksila.libbox.NetworkInterfaceIterator
import com.multiksila.libbox.OverrideOptions
import com.multiksila.libbox.PlatformInterface
import com.multiksila.libbox.SetupOptions
import com.multiksila.libbox.StringIterator
import com.multiksila.libbox.SystemProxyStatus
import com.multiksila.libbox.TunOptions
import com.multiksila.libbox.WIFIState
import com.multiksila.silaxray.Silaxray
import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import com.multiksila.libbox.NetworkInterface as LibboxNetworkInterface
import com.multiksila.silaxray.Instance as XrayInstance

/**
 * Туннель Multik Sila на Android.
 *
 * Главное отличие от Windows-версии, из которого следует всё остальное: здесь
 * ядро НЕ отдельный процесс. На Windows приложение запускает `sing-box.exe` и
 * общается с ним через Clash API и файлы конфигов. На Android так нельзя:
 * интерфейс туннеля выдаёт система, в виде файлового дескриптора, и передать
 * его чужому процессу невозможно. Поэтому ядро вкомпилировано в приложение
 * библиотекой (`silacore.aar`), а этот класс — то, что она от нас требует:
 * реализация [PlatformInterface].
 *
 * Что при этом НЕ меняется и почему это ценно: конфиг ядра остаётся тем же
 * JSON, который генерирует общий дартовый код, а `with_clash_api` вкомпилирован
 * в библиотеку — значит статистика, список соединений и переключение серверов
 * работают через тот же localhost-адрес, что и на Windows, без единой правки.
 */
class SilaVpnService : VpnService(), PlatformInterface, CommandServerHandler {

    companion object {
        const val ACTION_START = "com.example.proxy_app_test.START"
        const val ACTION_STOP = "com.example.proxy_app_test.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_XRAY_BRIDGES = "xray_bridges"

        private const val NOTIFICATION_CHANNEL = "multik_sila_vpn"
        private const val NOTIFICATION_ID = 1

        /**
         * Живая служба. Нужна каналу в Dart: тот спрашивает состояние и
         * останавливает туннель, а держать ради этого привязку к службе —
         * лишняя ступень отказа в и без того длинной цепочке.
         */
        @Volatile
        var instance: SilaVpnService? = null
            private set

        /** Куда сообщать о смене состояния и об ошибках ядра. */
        @Volatile
        var statusListener: ((running: Boolean, error: String?) -> Unit)? = null
    }

    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null

    /**
     * Мосты Xray для xhttp-серверов, по одному на сервер, ключ — тег сервера.
     *
     * Ровно та же схема, что на Windows, и по той же причине: sing-box не
     * понимает транспорт xhttp вообще. Отличие только в том, что там это
     * отдельные процессы `xray.exe`, а здесь объекты внутри нашего процесса.
     */
    private val xrayBridges = mutableMapOf<String, XrayInstance>()

    private val running = AtomicBoolean(false)
    private var interfaceListener: InterfaceUpdateListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val connectivity: ConnectivityManager
        get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    // ------------------------------------------------------------------
    // Жизненный цикл службы
    // ------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        instance = this
        // Пути ядру задаём один раз за процесс. workingPath — куда ядро кладёт
        // свои рабочие файлы (кэш наборов правил, база), tempPath — временные.
        // Обе папки создаём сами: ядро на несуществующем пути молча деградирует.
        val working = File(filesDir, "core").apply { mkdirs() }
        val temp = File(cacheDir, "core").apply { mkdirs() }
        // Лог ядра — в файл рядом с журналом приложения.
        //
        // На Windows вывод ядра идёт в наш лог, потому что там оно отдельный
        // процесс и его stdout/stderr можно читать. Здесь ядро внутри
        // приложения, и его собственный лог по умолчанию не виден НИГДЕ: ни в
        // журнале приложения, ни в системном. Разбирать поломки в таком
        // состоянии невозможно — видно только, что «не работает».
        //
        // Именно на это и напоролись: туннель поднимался, пакеты в него шли,
        // наружу не выходило ничего, и ни одной строки о причине.
        //
        // Файл ОТДЕЛЬНЫЙ от `core_log.txt`. Туда пишет сам sing-box по ключу
        // `log.output` в конфиге, а путь к рабочему каталогу на Android — это и
        // есть `filesDir` (`getApplicationSupportDirectory` возвращает именно
        // его). Два независимых дескриптора на один файл пишут каждый со своим
        // смещением и затирают друг друга: журнал ядра получался рваным ровно
        // тогда, когда по нему надо было разбирать поломку. Сюда идут только
        // паники Go — то, чего в обычном логе не бывает вовсе.
        try {
            Libbox.redirectStderr(File(filesDir, "core_panic.txt").absolutePath)
        } catch (e: Exception) {
            android.util.Log.w("MultikSila", "не удалось перенаправить лог ядра: ${e.message}")
        }

        Libbox.setup(SetupOptions().apply {
            basePath = filesDir.absolutePath
            workingPath = working.absolutePath
            tempPath = temp.absolutePath
            // Обходной путь для нативного стека Android — включён у всех
            // клиентов на libbox, без него на части прошивок ядро падает
            // на старте потока.
            fixAndroidStack = true
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
        }

        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            // Запуск без конфига — это перезапуск системой после того, как нас
            // выгрузили из памяти. Восстановить нечего: конфиг живёт на стороне
            // Dart, туда и уходит решение, поднимать ли туннель заново.
            statusListener?.invoke(false, "нет конфигурации")
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundNotification()
        try {
            startTunnel(config, intent.getStringArrayExtra(EXTRA_XRAY_BRIDGES))
        } catch (e: Exception) {
            statusListener?.invoke(false, e.message ?: e.toString())
            stopTunnel()
            return START_NOT_STICKY
        }
        // NOT_STICKY: система не должна поднимать туннель сама, без ведома
        // человека. Перезапуск после падения — решение приложения, а не
        // Android: молча включившийся VPN это последнее, чего от нас ждут.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopTunnel()
        instance = null
        super.onDestroy()
    }

    /** Система отзывает разрешение на VPN (например, включили другой клиент). */
    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    // ------------------------------------------------------------------
    // Запуск и остановка ядра
    // ------------------------------------------------------------------

    private fun startTunnel(config: String, bridges: Array<String>?) {
        // Мосты Xray поднимаются ДО ядра — все разом, как на Windows.
        // Причина та же: sing-box запекает порт socks-outbound'а в конфиг при
        // старте и не меняет его на лету, поэтому один общий порт с рестартом
        // при каждом переключении давал гонки и «connection refused».
        //
        // Старые гасим: набор серверов мог смениться вместе с профилем, а
        // оставленный мост держал бы свой порт занятым.
        closeBridges()
        bridges?.forEach { bridgeConfig -> startXrayBridge(bridgeConfig) }

        // Служба УЖЕ работает — значит это смена сервера или профиля, и ядро
        // надо перезагрузить, а не поднять второе. У библиотеки для этого
        // отдельный метод, `startOrReloadService`, и название у него честное.
        //
        // Первая версия создавала здесь новый CommandServer безусловно. Второй
        // экземпляр упирался в порты, занятые первым, и умирал — а снаружи
        // это выглядело как «сменил сервер, и подключение пропало совсем».
        val existing = commandServer
        if (existing != null) {
            existing.startOrReloadService(config, OverrideOptions())
            running.set(true)
            statusListener?.invoke(true, null)
            return
        }

        val server = CommandServer(this, this)
        server.start()
        commandServer = server
        // Пустой объект, а НЕ null. Библиотека разыменовывает эти настройки
        // без проверки:
        //
        //   StartOrReloadService(configContent string, options *OverrideOptions)
        //       ... daemon.OverrideOptions{AutoRedirect: options.AutoRedirect}
        //
        // и на null роняет весь процесс приложения в SIGABRT, а Android потом
        // трижды перезапускает службу по кругу. Внутренние списки пустыми быть
        // могут — их разбор nil переживает (`iteratorToArray` проверяет), а вот
        // сам объект обязан существовать.
        //
        // Переопределять здесь нечего: какие программы пускать в туннель, а
        // какие мимо, решает конфиг ядра, и берётся это из общих настроек
        // приложения — см. openTun.
        server.startOrReloadService(config, OverrideOptions())
        running.set(true)
        statusListener?.invoke(true, null)
    }

    private fun stopTunnel() {
        if (!running.compareAndSet(true, false) && commandServer == null) return
        try {
            commandServer?.closeService()
        } catch (_: Exception) {
        }
        try {
            commandServer?.close()
        } catch (_: Exception) {
        }
        commandServer = null

        // Мосты гасим ПОСЛЕ ядра: пока ядро живо, оно может держать через них
        // соединения, и обратный порядок дал бы шквал ошибок в лог на ровном
        // месте.
        closeBridges()

        try {
            tunDescriptor?.close()
        } catch (_: Exception) {
        }
        tunDescriptor = null

        stopDefaultInterfaceMonitorInternal()
        statusListener?.invoke(false, null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeBridges() {
        xrayBridges.values.forEach { bridge ->
            try {
                bridge.close()
            } catch (_: Exception) {
            }
        }
        xrayBridges.clear()
    }

    private fun startXrayBridge(bridgeConfig: String) {
        // Тег вытаскиваем из самого конфига, чтобы не заводить второй канал
        // передачи и не рассинхронизировать его с содержимым.
        val tag = Regex("\"tag\"\\s*:\\s*\"([^\"]+)\"").find(bridgeConfig)?.groupValues?.get(1)
            ?: bridgeConfig.hashCode().toString()
        try {
            xrayBridges[tag] = Silaxray.start(bridgeConfig)
        } catch (e: Exception) {
            // Мост не поднялся — это потеря одного сервера, а не всего
            // туннеля. Молчать нельзя: на Windows именно из-за проглоченной
            // ошибки моста «сервер недоступен» ничего не объяснял.
            statusListener?.invoke(running.get(), "мост Xray $tag: ${e.message}")
        }
    }

    // ------------------------------------------------------------------
    // PlatformInterface — то, что библиотека требует от платформы
    // ------------------------------------------------------------------

    /**
     * Главный метод: Android выдаёт интерфейс туннеля, мы отдаём ядру его
     * файловый дескриптор.
     */
    override fun openTun(options: TunOptions): Int {
        val builder = Builder()
            .setSession("Multik Sila")
            .setMtu(options.mtu)

        var hasInet4 = false
        var hasInet6 = false
        var iterator = options.inet4Address
        while (iterator.hasNext()) {
            val prefix = iterator.next()
            builder.addAddress(prefix.address(), prefix.prefix())
            hasInet4 = true
        }
        iterator = options.inet6Address
        while (iterator.hasNext()) {
            val prefix = iterator.next()
            builder.addAddress(prefix.address(), prefix.prefix())
            hasInet6 = true
        }

        if (options.autoRoute) {
            // Маршруты задаёт ядро, а не мы: список приходит уже с учётом
            // выбранного режима (весь трафик или обход РФ), и дублировать
            // эту логику здесь значило бы завести второй источник правды.
            // .value, а не .value(): библиотека отдаёт адрес в обёртке
            // StringBox с методом getValue(), и Kotlin видит его свойством.
            builder.addDnsServer(options.dnsServerAddress.value)

            var routes = options.inet4RouteAddress
            if (routes.hasNext()) {
                while (routes.hasNext()) {
                    val prefix = routes.next()
                    builder.addRoute(prefix.address(), prefix.prefix())
                }
            } else if (hasInet4) {
                builder.addRoute("0.0.0.0", 0)
            }

            // Маршрут по семейству адресов добавляем, ТОЛЬКО если у туннеля в
            // этом семействе есть адрес.
            //
            // Иначе получалась чёрная дыра: с выключенным перехватом IPv6 у
            // адаптера IPv6-адреса нет, а маршрут `::/0` в туннель мы всё равно
            // прописывали. Пакеты приложений уходили в интерфейс, которому
            // отвечать нечем, — и вместо мгновенного отказа (по которому Happy
            // Eyeballs за миллисекунды откатывается на IPv4) приложение ждало
            // таймаута. Снаружи: часть сайтов и приложений «не открывается»,
            // хотя туннель исправен.
            routes = options.inet6RouteAddress
            if (routes.hasNext()) {
                while (routes.hasNext()) {
                    val prefix = routes.next()
                    builder.addRoute(prefix.address(), prefix.prefix())
                }
            } else if (hasInet6) {
                builder.addRoute("::", 0)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                var excluded = options.inet4RouteExcludeAddress
                while (excluded.hasNext()) {
                    val prefix = excluded.next()
                    builder.excludeRoute(android.net.IpPrefix(
                        java.net.InetAddress.getByName(prefix.address()), prefix.prefix()))
                }
                excluded = options.inet6RouteExcludeAddress
                while (excluded.hasNext()) {
                    val prefix = excluded.next()
                    builder.excludeRoute(android.net.IpPrefix(
                        java.net.InetAddress.getByName(prefix.address()), prefix.prefix()))
                }
            }
        }

        // Правила «эта программа мимо VPN» — андроидный аналог правил по пути
        // к .exe на Windows. Себя из туннеля исключаем ВСЕГДА: иначе запросы
        // приложения к панели подписки и проверка обновлений пошли бы через
        // собственный туннель, а на старте его ещё нет.
        var packages = options.includePackage
        var hasInclude = false
        while (packages.hasNext()) {
            hasInclude = true
            runCatching { builder.addAllowedApplication(packages.next()) }
        }
        if (!hasInclude) {
            packages = options.excludePackage
            while (packages.hasNext()) {
                runCatching { builder.addDisallowedApplication(packages.next()) }
            }
            runCatching { builder.addDisallowedApplication(packageName) }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList(),
                )
            )
        }

        val descriptor = builder.establish()
            ?: throw IllegalStateException("Android не выдал интерфейс VPN — разрешение отозвано?")
        tunDescriptor = descriptor
        return descriptor.fd
    }

    /**
     * Да, защиту сокетов берём на себя.
     *
     * Это android-аналог самой дорогой ошибки Windows-версии: там
     * `auto_route` заворачивал в туннель трафик ВСЕХ процессов, включая наш
     * собственный `xray.exe`, и его коннект до прокси-сервера уходил обратно
     * в тот же туннель — замкнутый круг, наружу ничего не выходило. Здесь ту
     * же роль играет [protect]: сокет ядра, помеченный им, идёт мимо туннеля.
     */
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        // Результат НЕ проверяем, и это не небрежность.
        //
        // `protect` возвращает false штатно: например, когда сокет создаётся
        // раньше, чем система выдала интерфейс VPN, — а на старте ядро именно
        // так и делает. Первая версия бросала здесь исключение, то есть
        // обрывала соединение на ровном месте. Наружу это выглядело ровно как
        // «подключился, щит залит, сервер пингуется, а не грузится ничего»:
        // туннель поднят, и каждое исходящее соединение ядра умирает при
        // рождении.
        //
        // Ошибку глотать всё же нельзя молча — но и валить из-за неё связь
        // нельзя тем более: сокет, который не удалось вывести из туннеля,
        // в худшем случае уйдёт в него и не соединится, а брошенное
        // исключение гарантированно убивает соединение, которое могло бы
        // работать.
        if (!protect(fd)) {
            android.util.Log.w("MultikSila", "protect(fd=$fd) вернул false")
        }
    }

    /**
     * С Android 10 читать /proc/net чужих процессов нельзя — ядру приходится
     * спрашивать владельца соединения у системы, через [findConnectionOwner].
     */
    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): com.multiksila.libbox.ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("определение владельца соединения требует Android 10")
        }
        val uid = connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == -1) throw IllegalStateException("владелец соединения не найден")

        val owner = com.multiksila.libbox.ConnectionOwner()
        owner.userId = uid
        val names = packageManager.getPackagesForUid(uid)
        if (names != null && names.isNotEmpty()) {
            owner.userName = names[0]
            owner.setAndroidPackageNames(names.toIterator())
        }
        return owner
    }

    /// Монитор сети, по которому ядро выбирает канал наружу.
    ///
    /// Следим за сетью БЕЗ УЧЁТА VPN, и это принципиально.
    ///
    /// Первая версия подписывалась на сеть по умолчанию
    /// (`registerDefaultNetworkCallback`). Но как только наш туннель поднят,
    /// сетью по умолчанию для системы становится он сам — и ядро получало
    /// в качестве канала наружу СОБСТВЕННЫЙ туннель. В его логе это выглядит
    /// так:
    ///
    ///   INFO  network: updated default interface tun0
    ///   ERROR connection: open connection to ... using outbound/vless[srv_0]:
    ///         no available network interface
    ///
    /// Снаружи — «подключился, сервер пингуется, не грузится ничего». Причём
    /// первые секунды работает: до подъёма туннеля по умолчанию ещё физическая
    /// сеть, и замер задержки успевает пройти. Потом всё встаёт.
    ///
    /// `NET_CAPABILITY_NOT_VPN` есть у любой сети, кроме VPN, — запрос с ним
    /// туннель не выберет никогда.
    /// Сети-кандидаты, которые сейчас видны. Ключ — сама сеть.
    ///
    /// Список, а не одна «последняя пришедшая»: на телефоне одновременно живут
    /// и Wi-Fi, и мобильная сеть, `onAvailable` приходит по обеим, и та, что
    /// пришла второй, затирала первую. Ядро получало канал наружу, которым
    /// система на самом деле не пользуется, — и часть соединений уходила в
    /// никуда, пока остальные (уже установленные) продолжали работать. Снаружи
    /// это и выглядит как «подключился, но часть сайтов и приложений не
    /// открывается».
    private val candidateNetworks = linkedSetOf<Network>()

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = listener
        candidateNetworks.clear()
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(candidateNetworks) { candidateNetworks.add(network) }
                reportBest()
            }

            override fun onLinkPropertiesChanged(network: Network, props: LinkProperties) {
                synchronized(candidateNetworks) { candidateNetworks.add(network) }
                reportBest()
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                synchronized(candidateNetworks) { candidateNetworks.add(network) }
                reportBest()
            }

            // Обязательно. Раньше обработчика не было вовсе: при уходе Wi-Fi
            // ядро продолжало считать каналом наружу исчезнувший интерфейс, и
            // новые соединения умирали молча, пока приложение показывало
            // «подключено». Переход Wi-Fi <-> мобильная сеть на телефоне
            // происходит по нескольку раз в день, так что это не край.
            override fun onLost(network: Network) {
                synchronized(candidateNetworks) { candidateNetworks.remove(network) }
                reportBest()
            }
        }
        networkCallback = callback
        // registerBestMatchingNetworkCallback сам держит ЛУЧШУЮ подходящую сеть
        // и присылает смену — ровно то, что нужно, но появился только в
        // Android 12. Ниже — свой выбор из списка кандидатов.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            connectivity.registerBestMatchingNetworkCallback(
                request, callback, android.os.Handler(android.os.Looper.getMainLooper()))
        } else {
            connectivity.registerNetworkCallback(request, callback)
        }
    }

    /**
     * Сообщает ядру ту сеть, которой система пользуется на самом деле.
     *
     * Порядок предпочтения повторяет системный: Ethernet, потом Wi-Fi, потом
     * мобильная. Внутри одного вида — та, что пришла позже (переподключение к
     * другой точке доступа).
     */
    private fun reportBest() {
        val listener = interfaceListener ?: return
        val candidates = synchronized(candidateNetworks) { candidateNetworks.toList() }
        var bestRank = -1
        var bestName: String? = null
        var bestIndex = 0
        var bestExpensive = false
        for (network in candidates) {
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            val name = connectivity.getLinkProperties(network)?.interfaceName ?: continue
            // Индекс интерфейса — то, по чему ядро его и находит
            // (`InterfaceFinder().ByIndex`). Нуля среди настоящих индексов не
            // бывает, и раньше он подставлялся как «не смогли определить»:
            // ядро писало `find updated interface` в лог, который на Android
            // никто не видел, и оставалось со СТАРЫМ интерфейсом. Лучше не
            // сообщать ничего, чем сообщить заведомо ненаходимое.
            val index = runCatching {
                java.net.NetworkInterface.getByName(name)?.index ?: 0
            }.getOrDefault(0)
            if (index <= 0) continue
            val rank = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 2
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 1
                else -> 0
            }
            if (rank >= bestRank) {
                bestRank = rank
                bestName = name
                bestIndex = index
                bestExpensive = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }
        }
        if (bestName == null) {
            // Индекс -1 — это «канала наружу нет», ядро понимает его отдельно и
            // сбрасывает выбранный интерфейс. Без такого сообщения оно держится
            // за последний известный и пытается ходить через него.
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        listener.updateDefaultInterface(bestName, bestIndex, bestExpensive, false)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        stopDefaultInterfaceMonitorInternal()
    }

    private fun stopDefaultInterfaceMonitorInternal() {
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        networkCallback = null
        interfaceListener = null
        synchronized(candidateNetworks) { candidateNetworks.clear() }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val list = java.net.NetworkInterface.getNetworkInterfaces().toList().map { nif ->
            LibboxNetworkInterface().apply {
                name = nif.name
                index = nif.index
                mtu = runCatching { nif.mtu }.getOrDefault(1500)
                addresses = nif.interfaceAddresses
                    .mapNotNull { address ->
                        // У локальных IPv6-адресов Android дописывает зону —
                        // имя интерфейса после знака процента
                        // (`fe80::...%dummy0`). Ядро разбирает адрес как
                        // префикс, а зоны в префиксе стандартом не
                        // предусмотрены, и Go роняет ВЕСЬ процесс:
                        //
                        //   panic: netip.ParsePrefix("fe80::...%dummy0/64"):
                        //          IPv6 zones cannot be present in a prefix
                        //
                        // Зону отрезаем. Потерять нечего: она указывает на тот
                        // самый интерфейс, который мы сейчас и описываем.
                        val host = address.address.hostAddress ?: return@mapNotNull null
                        "${host.substringBefore('%')}/${address.networkPrefixLength}"
                    }
                    .toIterator()
                flags = 0
                if (nif.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                if (nif.isUp) flags = flags or OsConstants.IFF_UP
            }
        }
        return object : NetworkInterfaceIterator {
            private var position = 0
            override fun hasNext(): Boolean = position < list.size
            override fun next(): LibboxNetworkInterface = list[position++]
        }
    }

    // Расширение сети iOS — не наш случай, но метод интерфейса общий.
    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun readWIFIState(): WIFIState? = null

    /**
     * Системные корневые сертификаты ядру не отдаём: доверять оно должно ровно
     * тому, что записано в конфиге. Отдать сюда весь системный список значило
     * бы молча расширить доверие на всё, что установлено в системе.
     */
    override fun systemCertificates(): StringIterator = emptyList<String>().toIterator()

    override fun clearDNSCache() {
        // Своего кэша DNS у нас нет — им занимается само ядро.
    }

    override fun sendNotification(notification: com.multiksila.libbox.Notification) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(
            notification.identifier.hashCode(),
            Notification.Builder(this, NOTIFICATION_CHANNEL)
                .setContentTitle(notification.title)
                .setContentText(notification.body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .build()
        )
    }

    /** DNS резолвим средствами ядра, платформенный транспорт не подставляем. */
    override fun localDNSTransport(): LocalDNSTransport? = null

    // ------------------------------------------------------------------
    // CommandServerHandler — обратные вызовы от служебного канала ядра
    // ------------------------------------------------------------------

    override fun serviceReload() {
        // Перезагрузка конфига идёт со стороны Dart полным перезапуском:
        // конфиг там и генерируется, и держать его вторую копию здесь значило
        // бы завести источник расхождения.
        stopTunnel()
    }

    override fun serviceStop() = stopTunnel()

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        // На Android системного прокси в windows-смысле нет: весь трафик и так
        // идёт через интерфейс туннеля, подменять ничего не нужно. Отсюда же
        // вся ветка WinINET из десктопной версии здесь просто отсутствует.
        available = false
        enabled = false
    }

    override fun setSystemProxyEnabled(enabled: Boolean) {
        // См. выше — нечего включать.
    }

    override fun writeDebugMessage(message: String) {
        statusListener?.invoke(running.get(), null)
        android.util.Log.d("MultikSila", message)
    }

    // ------------------------------------------------------------------
    // Уведомление
    // ------------------------------------------------------------------

    private fun startForegroundNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "Multik Sila",
                    // LOW, а не DEFAULT: уведомление постоянное и обязано быть
                    // тихим. Звук при каждом подключении — верный способ
                    // заставить человека отключить уведомления совсем, а без
                    // них он лишится и кнопки «Отключить».
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }

        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, SilaVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setContentTitle("Multik Sila")
            .setContentText("Защита включена")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(
                // Тип значка указан явно: у Action.Builder два конструктора,
                // со значком-ресурсом (int) и со значком-объектом (Icon), и
                // голый null между ними неоднозначен.
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?, "Отключить", stop
                ).build()
            )
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}

/** Список строк в том виде, в каком его ждёт библиотека. */
private fun Collection<String>.toIterator(): StringIterator {
    val items = toList()
    return object : StringIterator {
        private var position = 0
        override fun len(): Int = items.size
        override fun hasNext(): Boolean = position < items.size
        override fun next(): String = items[position++]
    }
}

private fun Array<String>.toIterator(): StringIterator = toList().toIterator()

private fun StringIterator.toList(): List<String> {
    val result = mutableListOf<String>()
    while (hasNext()) result.add(next())
    return result
}
