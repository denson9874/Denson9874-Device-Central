/*
 * SPDX-FileCopyrightText: 2026 Daryl Denson
 * SPDX-License-Identifier: Apache-2.0
 */

package org.evolution.hilight

import android.database.ContentObserver
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.SwitchPreferenceCompat
import com.android.settingslib.widget.MainSwitchPreference

class HiLightFragment : PreferenceFragmentCompat() {

    private lateinit var mainSwitch: MainSwitchPreference
    private lateinit var triggers: Map<String, SwitchPreferenceCompat>
    private lateinit var preview: LightBarPreview

    private val resolver get() = requireContext().contentResolver

    // Another app (or Pixel's own code) may change the settings while this screen is open.
    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = refresh()
    }

    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        setPreferencesFromResource(R.xml.hilight_settings, rootKey)
        preview = LightBarPreview(requireContext())

        mainSwitch = findPreference("hilight_main_switch")!!
        mainSwitch.addOnSwitchChangeListener { _, isChecked ->
            if (isChecked != HiLightSettings.isEnabled(resolver)) {
                HiLightSettings.setEnabled(resolver, isChecked)
            }
            refresh()
        }

        triggers = mapOf(
            HiLightSettings.KEY_GEMINI to findPreference<SwitchPreferenceCompat>("hilight_gemini")!!,
            HiLightSettings.KEY_FAVORITE_CALLS to
                findPreference<SwitchPreferenceCompat>("hilight_favorite_calls")!!,
        )
        triggers.forEach { (key, pref) ->
            pref.setOnPreferenceChangeListener { _, newValue ->
                HiLightSettings.set(resolver, key, newValue as Boolean)
                refresh()
                true
            }
        }

        findPreference<Preference>("hilight_preview")!!.apply {
            isVisible = preview.isAvailable
            setOnPreferenceClickListener {
                preview.play()
                true
            }
        }
    }

    override fun onResume() {
        super.onResume()
        HiLightSettings.TRIGGERS.forEach {
            resolver.registerContentObserver(Settings.Secure.getUriFor(it), false, observer)
        }
        refresh()
    }

    override fun onPause() {
        super.onPause()
        resolver.unregisterContentObserver(observer)
        preview.stop()
    }

    private fun refresh() {
        val enabled = HiLightSettings.isEnabled(resolver)
        mainSwitch.isChecked = enabled
        triggers.forEach { (key, pref) ->
            pref.isChecked = HiLightSettings.isOn(resolver, key)
            pref.isEnabled = enabled
        }
    }
}
