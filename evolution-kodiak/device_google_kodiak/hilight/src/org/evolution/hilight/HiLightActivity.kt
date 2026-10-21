/*
 * SPDX-FileCopyrightText: 2026 Daryl Denson
 * SPDX-License-Identifier: Apache-2.0
 */

package org.evolution.hilight

import android.os.Bundle
import com.android.settingslib.collapsingtoolbar.CollapsingToolbarBaseActivity
import com.android.settingslib.collapsingtoolbar.R as ToolbarR

class HiLightActivity : CollapsingToolbarBaseActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            supportFragmentManager
                .beginTransaction()
                .replace(ToolbarR.id.content_frame, HiLightFragment())
                .commit()
        }
    }
}
