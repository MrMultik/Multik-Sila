package com.example.proxy_app_test

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Плитка в шторке быстрых настроек: включить и выключить VPN, не открывая
 * приложение (просьба пользователя 03.10.2026 — «у других приложений так
 * можно»).
 *
 * Включение — с последним конфигом, на котором туннель уже поднимался
 * (SilaVpnService хранит его, см. saveLastConfig): тот же профиль и сервер,
 * что в прошлый раз. Конфиг собирает Dart, а его без экрана не запустить.
 * Если такого конфига нет (ни разу не подключались) или Android отозвал
 * разрешение на VPN (включали другой клиент — спросить его заново может
 * только приложение), плитка открывает приложение.
 */
class SilaTileService : TileService() {

    companion object {
        /** Перерисовать плитку: состояние туннеля сменилось. */
        fun refresh(context: Context) {
            runCatching {
                requestListeningState(context, ComponentName(context, SilaTileService::class.java))
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        update(SilaVpnService.tunnelRunning)
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { toggle() } else toggle()
    }

    private fun toggle() {
        if (SilaVpnService.tunnelRunning) {
            startService(Intent(this, SilaVpnService::class.java).setAction(SilaVpnService.ACTION_STOP))
            update(false)
            return
        }
        if (VpnService.prepare(this) != null || !SilaVpnService.hasLastConfig(this)) {
            openApp()
            return
        }
        val intent = Intent(this, SilaVpnService::class.java).setAction(SilaVpnService.ACTION_START_LAST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        // Состояние «включено» придёт от службы (refresh), когда ядро поднимется.
    }

    private fun openApp() {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE)
            )
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(launch)
        }
    }

    private fun update(running: Boolean) {
        val tile = qsTile ?: return
        tile.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = getString(if (running) R.string.tile_on else R.string.tile_off)
        }
        tile.updateTile()
    }
}
