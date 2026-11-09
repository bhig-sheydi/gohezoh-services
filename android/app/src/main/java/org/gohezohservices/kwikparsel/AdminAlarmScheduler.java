package org.gohezohservices.kwikparsel;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;

import androidx.work.Constraints;
import androidx.work.BackoffPolicy;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;

import java.util.concurrent.TimeUnit;

/** Android schedules fallback background checks when FCM delivery is delayed. */
final class AdminAlarmScheduler {
    private static final String PERIODIC = "admin_alarm_periodic_v1";
    private static final String IMMEDIATE = "admin_alarm_immediate_v1";
    private static final String WATCHDOG_RETRY = "admin_alarm_watchdog_retry_v1";
    private static final int TEST_REQUEST_CODE = 7331;
    private static final int WATCHDOG_REQUEST_CODE = 7332;
    private static final long WATCHDOG_INTERVAL_MS = TimeUnit.MINUTES.toMillis(15);

    private AdminAlarmScheduler() { }

    static synchronized void enable(Context context) {
        Constraints network = new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build();
        PeriodicWorkRequest repeated = new PeriodicWorkRequest.Builder(
            AdminAlarmPollWorker.class, 15, TimeUnit.MINUTES)
            .setInitialDelay(15, TimeUnit.MINUTES)
            .setBackoffCriteria(BackoffPolicy.LINEAR, 75, TimeUnit.SECONDS)
            .setConstraints(network).build();
        WorkManager manager = WorkManager.getInstance(context);
        manager.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, repeated);
        manager.enqueueUniqueWork(IMMEDIATE, ExistingWorkPolicy.KEEP,
            new OneTimeWorkRequest.Builder(AdminAlarmPollWorker.class)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 75, TimeUnit.SECONDS)
                .setConstraints(network).build());
        ensureWatchdog(context);
    }

    static synchronized void disable(Context context) {
        WorkManager manager = WorkManager.getInstance(context);
        manager.cancelUniqueWork(PERIODIC);
        manager.cancelUniqueWork(IMMEDIATE);
        manager.cancelUniqueWork(WATCHDOG_RETRY);
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms != null) {
            alarms.cancel(testIntent(context));
            PendingIntent watchdog = watchdogIntent(context, false);
            if (watchdog != null) {
                alarms.cancel(watchdog);
                watchdog.cancel();
            }
        }
    }

    /** Re-arm on app launch or reboot without postponing an already scheduled alarm. */
    private static synchronized void ensureWatchdog(Context context) {
        if (watchdogIntent(context, false) == null) scheduleNextWatchdog(context);
    }

    /** AlarmManager calls can run during idle; the OS still chooses the exact time. */
    static synchronized void scheduleNextWatchdog(Context context) {
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(context);
        if (credential == null || !credential.registered) return;
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms == null) return;
        alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + WATCHDOG_INTERVAL_MS, watchdogIntent(context, true));
    }

    /** One delayed durable retry when the watchdog's brief receiver window expires. */
    static synchronized void enqueueWatchdogRetry(Context context) {
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(context);
        if (credential == null || !credential.registered) return;
        Constraints network = new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build();
        WorkManager.getInstance(context).enqueueUniqueWork(WATCHDOG_RETRY, ExistingWorkPolicy.KEEP,
            new OneTimeWorkRequest.Builder(AdminAlarmPollWorker.class)
                .setInitialDelay(75, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 75, TimeUnit.SECONDS)
                .setConstraints(network).build());
    }

    static void restoreAfterSystemEvent(Context context) {
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(context);
        if (credential != null && credential.registered) enable(context);
    }

    /** A response from an old request must not revoke a freshly registered phone. */
    static synchronized void revokeIfCurrent(Context context, AdminAlarmStore.Credential expected) {
        AdminAlarmStore.Credential current = AdminAlarmStore.read(context);
        if (current == null || !current.registered
            || !expected.deviceId.equals(current.deviceId)
            || !expected.secret.equals(current.secret)) return;
        AdminAlarmStore.clear(context);
        disable(context);
        AdminAlarmPollWorker.clearDeliveryState(context);
    }

    /** Schedules one local test so the user can lock the screen before it sounds. */
    static boolean scheduleLockScreenTest(Context context) {
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms == null) return false;
        alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + 10_000L, testIntent(context));
        return true;
    }

    private static PendingIntent testIntent(Context context) {
        Intent intent = new Intent(context, AdminAlarmTestReceiver.class);
        return PendingIntent.getBroadcast(context, TEST_REQUEST_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static PendingIntent watchdogIntent(Context context, boolean create) {
        Intent intent = new Intent(context, AdminAlarmWatchdogReceiver.class)
            .setAction(AdminAlarmWatchdogReceiver.ACTION_WATCHDOG);
        return PendingIntent.getBroadcast(context, WATCHDOG_REQUEST_CODE, intent,
            (create ? PendingIntent.FLAG_UPDATE_CURRENT : PendingIntent.FLAG_NO_CREATE)
                | PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_ONE_SHOT);
    }
}
