/*
 * SPDX-FileCopyrightText: 2026 Daryl Denson
 * SPDX-License-Identifier: Apache-2.0
 */

package org.evolution.hilight

import android.content.ContentResolver
import android.provider.Settings

/**
 * The HiLight settings, as stock Pixel Settings stores them: one Settings.Secure
 * int per trigger. The Google app reads [KEY_GEMINI]; NotificationAttentionHelper
 * reads [KEY_FAVORITE_CALLS]. HiLight counts as on while any trigger is on.
 * Turning it off saves each trigger in "<key>.previous" so turning it back on
 * restores the same choice.
 */
object HiLightSettings {
    const val KEY_GEMINI = "light_animation_feedback_enabled"
    const val KEY_FAVORITE_CALLS = "light_animation_favorite_calls_enabled"
    val TRIGGERS = listOf(KEY_GEMINI, KEY_FAVORITE_CALLS)

    private fun previous(key: String) = "$key.previous"

    fun isOn(cr: ContentResolver, key: String): Boolean =
        Settings.Secure.getInt(cr, key, 0) == 1

    fun set(cr: ContentResolver, key: String, on: Boolean) {
        Settings.Secure.putInt(cr, key, if (on) 1 else 0)
    }

    fun isEnabled(cr: ContentResolver): Boolean = TRIGGERS.any { isOn(cr, it) }

    fun setEnabled(cr: ContentResolver, enabled: Boolean) {
        if (enabled) {
            val saved = TRIGGERS.associateWith { Settings.Secure.getInt(cr, previous(it), 0) == 1 }
            // Nothing saved (first use, or everything was off): turn on every trigger.
            val restore = if (saved.values.any { it }) saved else TRIGGERS.associateWith { true }
            restore.forEach { (key, on) -> set(cr, key, on) }
        } else {
            TRIGGERS.forEach {
                Settings.Secure.putInt(cr, previous(it), if (isOn(cr, it)) 1 else 0)
                set(cr, it, false)
            }
        }
    }
}
