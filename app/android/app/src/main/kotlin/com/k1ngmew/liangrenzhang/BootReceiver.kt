package com.k1ngmew.liangrenzhang

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the alert connection after a reboot or an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                try {
                    AlertService.start(context)
                } catch (e: Exception) {
                    // some ROMs block background starts; the app restarts it when opened
                }
            }
        }
    }
}
