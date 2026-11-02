package org.gohezohservices.kwikparsel;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

/** Restarts only tracking explicitly enabled by the rider, when Android permits it. */
public final class RiderBootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        String token = context.getSharedPreferences("rider_location", Context.MODE_PRIVATE).getString("token", null);
        if (token == null || !token.matches("[0-9a-f]{64}")) return;
        if (Build.VERSION.SDK_INT >= 29 && context.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                != PackageManager.PERMISSION_GRANTED) return;
        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
                && context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) return;
        try {
            context.startForegroundService(new Intent(context, RiderLocationService.class)
                .setAction(RiderLocationService.ACTION_START)
                .putExtra(RiderLocationService.EXTRA_TOKEN, token)
                .putExtra(RiderLocationService.EXTRA_DUTY, false));
        } catch (RuntimeException ignored) { /* Android may block background starts; rider must reopen the app. */ }
    }
}
