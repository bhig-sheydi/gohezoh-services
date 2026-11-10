package org.gohezohservices.kwikparsel;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

/** Audible, visible rider assignment alarm. Always ends after at most one minute. */
public final class RiderRideAlarmService extends Service {
    static final String START = "ride_alarm_start";
    static final String STOP = "ride_alarm_stop";
    static final String JOB_ID = "job_id";
    private static final int NOTIFICATION_ID = 29;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private MediaPlayer player;
    private String jobId;
    private final Runnable timeout = this::stopAlarm;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || STOP.equals(intent.getAction())) {
            if (intent == null || jobId == null || jobId.equals(intent.getStringExtra(JOB_ID))) stopAlarm();
            return START_NOT_STICKY;
        }
        String incoming = intent.getStringExtra(JOB_ID);
        if (incoming == null || incoming.isBlank()) { stopAlarm(); return START_NOT_STICKY; }
        long remaining = 60_000L;
        if (incoming.equals(jobId)) return START_NOT_STICKY;
        stopSound();
        jobId = incoming;
        RidePushNotification.createChannel(this);
        Intent open = new Intent(this, MainActivity.class)
            .setData(Uri.parse("https://gohezoh-services.vercel.app/rider"))
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent tap = PendingIntent.getActivity(this, incoming.hashCode(), open,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(this, RidePushNotification.ALARM_CHANNEL)
            .setSmallIcon(R.drawable.ic_spike).setContentTitle("New ride: respond within one minute")
            .setContentText("Open the rider app and accept this pickup.")
            .setContentIntent(tap).setCategory(Notification.CATEGORY_ALARM)
            .setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE).build();
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            else startForeground(NOTIFICATION_ID, notification);
            player = MediaPlayer.create(this, R.raw.admin_alert);
            if (player != null) { player.setWakeMode(this, android.os.PowerManager.PARTIAL_WAKE_LOCK); player.setLooping(true); player.start(); }
        } catch (Exception failure) { stopAlarm(); return START_NOT_STICKY; }
        handler.removeCallbacks(timeout);
        handler.postDelayed(timeout, remaining);
        return START_NOT_STICKY;
    }

    private void stopSound() {
        handler.removeCallbacks(timeout);
        if (player != null) { try { player.stop(); } catch (Exception ignored) { } player.release(); player = null; }
    }
    private void stopAlarm() { stopSound(); jobId = null; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); }
    @Override public void onDestroy() { stopSound(); super.onDestroy(); }
}
