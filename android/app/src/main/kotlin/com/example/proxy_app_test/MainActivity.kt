package com.example.proxy_app_test

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import com.multiksila.libbox.Libbox
import com.multiksila.silaxray.Silaxray
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper

/**
 * Мост между дартовым кодом и туннелем.
 *
 * Разделение обязанностей намеренно жёсткое: Dart решает ЧТО запускать
 * (разбирает подписку, собирает JSON-конфиг, выбирает сервер), Kotlin — КАК
 * (служба, разрешение системы, уведомление). Благодаря этому вся содержательная
 * логика остаётся общей с Windows-версией: конфиг генерируется тем же кодом,
 * а статистика и переключение серверов идут через Clash API на localhost, как
 * и там.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "multik_sila/vpn"
        private const val EVENTS = "multik_sila/vpn_status"
        private const val REQUEST_PREPARE = 24601
    }

    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * Ожидающий вызов `prepare`. Android спрашивает разрешение на VPN
     * собственным диалогом и отвечает через onActivityResult, то есть ответ
     * приходит асинхронно и в другом месте — результат надо кому-то отдать.
     */
    private var pendingPrepare: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                    SilaVpnService.statusListener = { running, error ->
                        // Строго в главный поток: события приходят из потоков
                        // ядра, а канал Flutter принимает только оттуда.
                        main.post {
                            events?.success(mapOf("running" to running, "error" to error))
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    SilaVpnService.statusListener = null
                    events = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Разрешение на VPN. Android показывает свой диалог один раз
                // и запоминает ответ, поэтому спрашивать заранее при каждом
                // запуске не нужно — но проверять надо всегда: разрешение
                // отзывается включением другого клиента VPN.
                "prepare" -> {
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        pendingPrepare = result
                        startActivityForResult(intent, REQUEST_PREPARE)
                    }
                }

                "start" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("no_config", "конфигурация не передана", null)
                        return@setMethodCallHandler
                    }
                    // Мосты Xray для xhttp-серверов: список готовых конфигов,
                    // по одному на сервер. Собирает их тот же дартовый код,
                    // что пишет xray_bridge_*.json на Windows.
                    val bridges = call.argument<List<String>>("bridges")?.toTypedArray()
                    val intent = Intent(this, SilaVpnService::class.java)
                        .setAction(SilaVpnService.ACTION_START)
                        .putExtra(SilaVpnService.EXTRA_CONFIG, config)
                        .putExtra(SilaVpnService.EXTRA_XRAY_BRIDGES, bridges)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }

                "stop" -> {
                    startService(
                        Intent(this, SilaVpnService::class.java).setAction(SilaVpnService.ACTION_STOP)
                    )
                    result.success(true)
                }

                "isRunning" -> result.success(SilaVpnService.instance != null)

                // Версии обоих ядер спрашиваем у самих ядер, а не помним
                // числом в коде: на Windows уже ловили случай, когда
                // установленная сборка Xray оказалась новее «последнего
                // релиза», и версия по памяти врала.
                "coreVersions" -> result.success(
                    mapOf(
                        "singbox" to runCatching { Libbox.version() }.getOrDefault(""),
                        "xray" to runCatching { Silaxray.version() }.getOrDefault(""),
                    )
                )

                // Список установленных программ — для правил «эта программа
                // мимо VPN». На Windows тут был путь к .exe, здесь имя пакета.
                // «Системное» здесь — НЕ признак того, что показывать не надо.
                //
                // Отбор по FLAG_SYSTEM казался очевидным: человек ищет свой
                // мессенджер, а не полторы сотни служб Android. Но флаг стоит у
                // всего предустановленного, а на телефонах, продаваемых в
                // России, предустановлен как раз мессенджер — и правило для него
                // задать было бы нельзя. Проверено на эмуляторе: с этим отбором
                // экран пуст ЦЕЛИКОМ, включая Chrome.
                //
                // Правильный признак — есть ли у приложения значок в меню, то
                // есть может ли человек его запустить. Ровно то, что он и ищет в
                // списке. Служебные пакеты без значка отсеиваются сами.
                "installedApps" -> {
                    val apps = packageManager.getInstalledApplications(0)
                        .filter { it.packageName != packageName }
                        .filter { packageManager.getLaunchIntentForPackage(it.packageName) != null }
                        .map {
                            mapOf(
                                "package" to it.packageName,
                                "name" to packageManager.getApplicationLabel(it).toString(),
                                "system" to ((it.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0),
                            )
                        }
                        .sortedBy { it["name"] as String }
                    result.success(apps)
                }

                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PREPARE) {
            // Отказ — это ответ, а не ошибка: человек имеет право не пускать
            // приложение в сеть, и Dart обязан показать это внятно, а не
            // молча оставить выключенный щит.
            pendingPrepare?.success(resultCode == Activity.RESULT_OK)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
