/*
 * SPDX-FileCopyrightText: 2026 Daryl Denson
 * SPDX-License-Identifier: Apache-2.0
 */

package org.evolution.hilight

import android.content.Context
import android.graphics.Color
import android.hardware.lights.ColorSequence
import android.hardware.lights.Light
import android.hardware.lights.LightsManager
import android.hardware.lights.LightsRequest
import android.hardware.lights.MultiLightEffect
import android.os.Handler
import android.os.Looper
import android.util.Log

/** Plays a short sweep across the light bar's LEDs. */
class LightBarPreview(context: Context) {
    private val lightsManager = context.getSystemService(LightsManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var session: LightsManager.LightsSession? = null

    /** The LEDs that can play effects, left to right. Empty on phones without a light bar. */
    private val leds: List<Light> =
        lightsManager?.lights?.filter { it.hasAnimationControl() }?.sortedBy { it.ordinal }
            ?: emptyList()

    val isAvailable: Boolean
        get() = leds.isNotEmpty()

    fun play() {
        val manager = lightsManager ?: return
        if (!isAvailable) return
        // Delays must be whole frames, or the LEDs drift apart.
        val frame = leds.maxOf { it.minUpdatePeriodMillis }.coerceAtLeast(1)
        fun frames(ms: Long) = ((ms + frame - 1) / frame).coerceAtLeast(1) * frame
        val step = frames(STEP_MS)
        val last = leds.size - 1

        val builder = MultiLightEffect.Builder().setIterations(ITERATIONS)
        leds.forEachIndexed { i, led ->
            // Every LED's sequence has the same length, so the iterations stay in step:
            // wait for its turn, glow, fade, then wait for the rest of the sweep.
            val sequence = ColorSequence.Builder()
                .setInterpolationMode(ColorSequence.INTERPOLATION_MODE_LINEAR)
                .addControlPoint(0, Color.TRANSPARENT)
                .addControlPoint(frame + i * step, Color.TRANSPARENT)
                .addControlPoint(frames(RISE_MS), COLOR)
                .addControlPoint(frames(FALL_MS), Color.TRANSPARENT)
                .addControlPoint(frame + (last - i) * step, Color.TRANSPARENT)
                .build()
            builder.addLightSequence(led, sequence)
        }
        val effect = builder.build()

        stop()
        try {
            session = manager.openSession().also {
                it.requestLights(LightsRequest.Builder().setEffect(effect).build())
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "Couldn't play the preview", e)
            stop()
            return
        }
        // Closing the session hands the lights back to the system.
        handler.postDelayed(::stop, effect.totalDurationMillis + CLOSE_MARGIN_MS)
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        session?.close()
        session = null
    }

    private companion object {
        const val TAG = "HiLight"
        const val ITERATIONS = 2
        const val STEP_MS = 60L
        const val RISE_MS = 150L
        const val FALL_MS = 300L
        const val CLOSE_MARGIN_MS = 300L
        val COLOR = Color.rgb(0xE8, 0xF0, 0xFF)
    }
}
