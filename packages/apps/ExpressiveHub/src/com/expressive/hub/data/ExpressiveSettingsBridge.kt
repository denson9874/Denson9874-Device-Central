package com.expressive.hub.data

import android.content.ContentResolver
import android.content.Context
import android.provider.Settings

/**
 * ExpressiveSettingsBridge
 * 
 * Bridges OS-level customization preferences between ExpressiveHub, Android SettingsProvider,
 * SystemUI, and Expressive Launcher in real-time.
 */
object ExpressiveSettingsBridge {

    // Settings Keys defined in frameworks/base Settings.Secure
    const val KEY_QS_TILE_STYLE = "expressive_qs_tile_style"              // 0=pill (28dp), 1=squircle (16dp), 2=classic
    const val KEY_BLUR_SCRIM_INTENSITY = "expressive_blur_scrim_intensity" // 0 to 100 (%)
    const val KEY_STATUS_BAR_SOLID_SCRIM = "expressive_status_bar_solid_scrim" // 0=disabled, 1=enabled
    const val KEY_STATUS_BAR_ICON_STYLE = "expressive_status_bar_icon_style" // 0=expressive, 1=stock, 2=minimal
    const val KEY_LOCK_CLOCK_TYPOGRAPHY = "expressive_lock_clock_typography" // 0=sans_flex, 1=ink_display, 2=retro
    const val KEY_HYBRID_GLANCE_MESSAGES = "expressive_hybrid_glance_messages" // 0=disabled, 1=enabled
    const val KEY_DRAWER_PRESENTATION_MODE = "expressive_drawer_presentation_mode" // 0=fullscreen, 1=bottom_sheet
    const val KEY_CORNER_RADIUS_PX = "expressive_corner_radius_px"       // dynamic dp tokens
    const val KEY_DYNAMIC_INK_INDIGO = "expressive_dynamic_ink_indigo"   // 0=standard M3, 1=expressive ink-indigo

    fun getInt(resolver: ContentResolver, key: String, default: Int): Int {
        return Settings.Secure.getInt(resolver, key, default)
    }

    fun putInt(resolver: ContentResolver, key: String, value: Int): Boolean {
        return Settings.Secure.putInt(resolver, key, value)
    }

    fun isSolidStatusBarScrimEnabled(context: Context): Boolean {
        return getInt(context.contentResolver, KEY_STATUS_BAR_SOLID_SCRIM, 0) == 1
    }

    fun setSolidStatusBarScrimEnabled(context: Context, enabled: Boolean): Boolean {
        return putInt(context.contentResolver, KEY_STATUS_BAR_SOLID_SCRIM, if (enabled) 1 else 0)
    }

    fun getBlurIntensity(context: Context): Int {
        return getInt(context.contentResolver, KEY_BLUR_SCRIM_INTENSITY, 80)
    }

    fun setBlurIntensity(context: Context, intensity: Int): Boolean {
        return putInt(context.contentResolver, KEY_BLUR_SCRIM_INTENSITY, intensity.coerceIn(0, 100))
    }

    fun getDrawerPresentationMode(context: Context): Int {
        return getInt(context.contentResolver, KEY_DRAWER_PRESENTATION_MODE, 0)
    }

    fun setDrawerPresentationMode(context: Context, mode: Int): Boolean {
        return putInt(context.contentResolver, KEY_DRAWER_PRESENTATION_MODE, mode)
    }

    fun isHybridGlanceMessagesEnabled(context: Context): Boolean {
        return getInt(context.contentResolver, KEY_HYBRID_GLANCE_MESSAGES, 1) == 1
    }

    fun setHybridGlanceMessagesEnabled(context: Context, enabled: Boolean): Boolean {
        return putInt(context.contentResolver, KEY_HYBRID_GLANCE_MESSAGES, if (enabled) 1 else 0)
    }
}
