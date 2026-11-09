package org.gohezohservices.kwikparsel;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import java.util.concurrent.atomic.AtomicBoolean;

/** Inexact idle wake-up supplements the network-constrained WorkManager schedule. */
public final class AdminAlarmWatchdogReceiver extends BroadcastReceiver {
    static final String ACTION_WATCHDOG = "org.gohezohservices.kwikparsel.ADMIN_ALARM_WATCHDOG";

    @Override public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        if (Intent.ACTION_BOOT_COMPLETED.equals(action)
            || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) {
            try { AdminAlarmScheduler.restoreAfterSystemEvent(context); }
            catch (RuntimeException ignored) { /* Existing WorkManager scheduling is a fallback. */ }
            return;
        }
        if (!ACTION_WATCHDOG.equals(action)) return;
        // Schedule first: an unexpected process stop must not end future checks.
        try { AdminAlarmScheduler.scheduleNextWatchdog(context); }
        catch (RuntimeException ignored) { /* WorkManager remains a fallback. */ }
        PendingResult pending = goAsync();
        AtomicBoolean finished = new AtomicBoolean(false);
        Handler main = new Handler(Looper.getMainLooper());
        Runnable deadline = () -> {
            if (finished.compareAndSet(false, true)) {
                try { AdminAlarmScheduler.enqueueWatchdogRetry(context); }
                catch (RuntimeException ignored) { /* The next watchdog is still scheduled. */ }
                pending.finish();
            }
        };
        main.postDelayed(deadline, 8_000L);
        Context app = context.getApplicationContext();
        try {
            new Thread(() -> {
                try { AdminAlarmPollWorker.pollFromWatchdog(app); }
                finally {
                    main.removeCallbacks(deadline);
                    if (finished.compareAndSet(false, true)) pending.finish();
                }
            }, "admin-alarm-watchdog").start();
        } catch (RuntimeException error) {
            deadline.run();
        }
    }
}
