/*
 * Copyright (C) 2026 The ExpressiveOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.expressiveos.wallpapers;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.WallpaperManager;
import android.content.res.Configuration;
import android.graphics.Outline;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.widget.GridLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Lightweight WallpaperPicker entry point exposing the four bespoke ExpressiveOS wallpapers
 * alongside PixelWallpapers2026 without overriding Google's partner wallpaper pack.
 */
public final class ExpressiveWallpaperPickerActivity extends Activity {

    private static final class WallpaperItem {
        final int titleRes;
        final int subtitleRes;
        final int drawableRes;
        final int thumbRes;

        WallpaperItem(int titleRes, int subtitleRes, int drawableRes, int thumbRes) {
            this.titleRes = titleRes;
            this.subtitleRes = subtitleRes;
            this.drawableRes = drawableRes;
            this.thumbRes = thumbRes;
        }
    }

    private static final WallpaperItem[] ITEMS = new WallpaperItem[] {
            new WallpaperItem(R.string.bloom_title, R.string.bloom_subtitle,
                    R.drawable.expressiveos_bloom, R.drawable.expressiveos_bloom_thumbnail),
            new WallpaperItem(R.string.dusk_title, R.string.dusk_subtitle,
                    R.drawable.expressiveos_dusk, R.drawable.expressiveos_dusk_thumbnail),
            new WallpaperItem(R.string.dawn_title, R.string.dawn_subtitle,
                    R.drawable.expressiveos_dawn, R.drawable.expressiveos_dawn_thumbnail),
            new WallpaperItem(R.string.mint_title, R.string.mint_subtitle,
                    R.drawable.expressiveos_mint, R.drawable.expressiveos_mint_thumbnail),
    };

    private final ExecutorService mExecutor = Executors.newSingleThreadExecutor();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (getActionBar() != null) {
            getActionBar().setDisplayHomeAsUpEnabled(true);
            getActionBar().setTitle(R.string.category_expressiveos);
        }

        final boolean isNight = (getResources().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        final int bgColor = getColor(isNight
                ? android.R.color.system_surface_dark
                : android.R.color.system_surface_container_light);
        final int cardColor = getColor(isNight
                ? android.R.color.system_surface_container_high_dark
                : android.R.color.system_surface_container_lowest_light);
        final int titleColor = getColor(isNight
                ? android.R.color.system_on_surface_dark
                : android.R.color.system_on_surface_light);
        final int subtitleColor = getColor(isNight
                ? android.R.color.system_on_surface_variant_dark
                : android.R.color.system_on_surface_variant_light);

        final ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(bgColor);
        scroll.setFillViewport(true);

        final int pad = dp(16);
        final GridLayout grid = new GridLayout(this);
        grid.setColumnCount(2);
        grid.setPadding(pad, pad, pad, pad);

        final int cardRadius = dp(24);
        final int thumbRadius = dp(20);
        final int gap = dp(12);

        for (int i = 0; i < ITEMS.length; i++) {
            final WallpaperItem item = ITEMS[i];
            final LinearLayout card = new LinearLayout(this);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setClickable(true);
            card.setFocusable(true);
            card.setPadding(dp(12), dp(12), dp(12), dp(14));
            card.setContentDescription(getString(item.titleRes) + ", " + getString(item.subtitleRes));

            final GradientDrawable cardBg = new GradientDrawable();
            cardBg.setCornerRadius(cardRadius);
            cardBg.setColor(cardColor);
            card.setBackground(cardBg);

            final ImageView preview = new ImageView(this);
            preview.setImageResource(item.thumbRes);
            preview.setScaleType(ImageView.ScaleType.CENTER_CROP);
            preview.setClipToOutline(true);
            preview.setOutlineProvider(new ViewOutlineProvider() {
                @Override
                public void getOutline(View view, Outline outline) {
                    outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), thumbRadius);
                }
            });
            final LinearLayout.LayoutParams imgLp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(220));
            card.addView(preview, imgLp);

            final TextView title = new TextView(this);
            title.setText(item.titleRes);
            title.setTextColor(titleColor);
            title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            final LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            titleLp.topMargin = dp(12);
            card.addView(title, titleLp);

            final TextView subtitle = new TextView(this);
            subtitle.setText(item.subtitleRes);
            subtitle.setTextColor(subtitleColor);
            subtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
            final LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            subLp.topMargin = dp(2);
            card.addView(subtitle, subLp);

            card.setOnClickListener(v -> showApplyDialog(item));

            final GridLayout.LayoutParams cardLp = new GridLayout.LayoutParams(
                    GridLayout.spec(i / 2), GridLayout.spec(i % 2, 1f));
            cardLp.width = 0;
            cardLp.height = ViewGroup.LayoutParams.WRAP_CONTENT;
            cardLp.setMargins(i % 2 == 0 ? 0 : gap / 2, 0, i % 2 == 0 ? gap / 2 : 0, gap);
            cardLp.setGravity(Gravity.FILL_HORIZONTAL);
            grid.addView(card, cardLp);
        }

        scroll.addView(grid, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(scroll);
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        if (item.getItemId() == android.R.id.home) {
            finish();
            return true;
        }
        return super.onOptionsItemSelected(item);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        mExecutor.shutdownNow();
    }

    private void showApplyDialog(WallpaperItem item) {
        final CharSequence[] options = new CharSequence[] {
                getString(R.string.set_wallpaper_home),
                getString(R.string.set_wallpaper_lock),
                getString(R.string.set_wallpaper_both),
        };
        new AlertDialog.Builder(this)
                .setTitle(getString(item.titleRes) + " — " + getString(R.string.set_wallpaper_dialog_title))
                .setItems(options, (dialog, which) -> {
                    final int flags = switch (which) {
                        case 0 -> WallpaperManager.FLAG_SYSTEM;
                        case 1 -> WallpaperManager.FLAG_LOCK;
                        default -> WallpaperManager.FLAG_SYSTEM | WallpaperManager.FLAG_LOCK;
                    };
                    applyWallpaper(item.drawableRes, flags);
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    private void applyWallpaper(int drawableRes, int flags) {
        mExecutor.execute(() -> {
            boolean ok = false;
            try {
                WallpaperManager.getInstance(getApplicationContext()).setResource(drawableRes, flags);
                ok = true;
            } catch (IOException ignored) {
                ok = false;
            }
            final boolean result = ok;
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                Toast.makeText(
                        this,
                        result ? R.string.set_wallpaper_done : R.string.set_wallpaper_failed,
                        Toast.LENGTH_SHORT).show();
                if (result) {
                    setResult(RESULT_OK);
                    finish();
                }
            });
        });
    }

    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }
}
