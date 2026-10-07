package com.expressive.hub

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.SeekBarPreference
import androidx.preference.SwitchPreferenceCompat
import com.expressive.hub.data.ExpressiveSettingsBridge

class ExpressiveHubActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.title = getString(R.string.expressive_hub_title)

        if (savedInstanceState == null) {
            supportFragmentManager
                .beginTransaction()
                .replace(android.R.id.content, ExpressiveHubPreferenceFragment())
                .commit()
        }
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    class ExpressiveHubPreferenceFragment : PreferenceFragmentCompat() {

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            setPreferencesFromResource(R.xml.expressive_hub_preferences, rootKey)

            // Setup Quick Settings Style
            val qsStylePref = findPreference<ListPreference>(ExpressiveSettingsBridge.KEY_QS_TILE_STYLE)
            qsStylePref?.setOnPreferenceChangeListener { _, newValue ->
                val intVal = (newValue as String).toIntOrNull() ?: 0
                ExpressiveSettingsBridge.putInt(requireContext().contentResolver, ExpressiveSettingsBridge.KEY_QS_TILE_STYLE, intVal)
                true
            }

            // Setup Blur Scrim Slider
            val blurPref = findPreference<SeekBarPreference>(ExpressiveSettingsBridge.KEY_BLUR_SCRIM_INTENSITY)
            blurPref?.setOnPreferenceChangeListener { _, newValue ->
                ExpressiveSettingsBridge.setBlurIntensity(requireContext(), newValue as Int)
                true
            }

            // Setup Solid Status Bar Scrim
            val statusBarScrimPref = findPreference<SwitchPreferenceCompat>(ExpressiveSettingsBridge.KEY_STATUS_BAR_SOLID_SCRIM)
            statusBarScrimPref?.setOnPreferenceChangeListener { _, newValue ->
                ExpressiveSettingsBridge.setSolidStatusBarScrimEnabled(requireContext(), newValue as Boolean)
                true
            }

            // Setup Drawer Presentation Mode (Fullscreen vs Bottom Sheet)
            val drawerModePref = findPreference<ListPreference>(ExpressiveSettingsBridge.KEY_DRAWER_PRESENTATION_MODE)
            drawerModePref?.setOnPreferenceChangeListener { _, newValue ->
                val intVal = (newValue as String).toIntOrNull() ?: 0
                ExpressiveSettingsBridge.setDrawerPresentationMode(requireContext(), intVal)
                true
            }

            // Setup Hybrid Glance Messages
            val glanceMessagesPref = findPreference<SwitchPreferenceCompat>(ExpressiveSettingsBridge.KEY_HYBRID_GLANCE_MESSAGES)
            glanceMessagesPref?.setOnPreferenceChangeListener { _, newValue ->
                ExpressiveSettingsBridge.setHybridGlanceMessagesEnabled(requireContext(), newValue as Boolean)
                true
            }
        }
    }
}
