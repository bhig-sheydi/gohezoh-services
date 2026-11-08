package org.gohezohservices.kwikparsel;

import android.content.Context;

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
    }
}
