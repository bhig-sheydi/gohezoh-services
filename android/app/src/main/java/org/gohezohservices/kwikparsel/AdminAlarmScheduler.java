package org.gohezohservices.kwikparsel;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;

import androidx.work.Constraints;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;

import java.util.concurrent.TimeUnit;

/** Android schedules background checks; no always-running foreground service or Firebase. */
final class AdminAlarmScheduler {
    private static final String PERIODIC = "admin_alarm_periodic_v1";
    private static final String IMMEDIATE = "admin_alarm_immediate_v1";
    private static final int TEST_REQUEST_CODE = 7331;

    private AdminAlarmScheduler() { }

    static void enable(Context context) {
        Constraints network = new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build();
        PeriodicWorkRequest repeated = new PeriodicWorkRequest.Builder(
            AdminAlarmPollWorker.class, 15, TimeUnit.MINUTES)
            .setConstraints(network).build();
        WorkManager manager = WorkManager.getInstance(context);
        manager.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, repeated);
        manager.enqueueUniqueWork(IMMEDIATE, ExistingWorkPolicy.KEEP,
            new OneTimeWorkRequest.Builder(AdminAlarmPollWorker.class).setConstraints(network).build());
    }

    static void disable(Context context) {
        WorkManager manager = WorkManager.getInstance(context);
        manager.cancelUniqueWork(PERIODIC);
        manager.cancelUniqueWork(IMMEDIATE);
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms != null) alarms.cancel(testIntent(context));
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
}
