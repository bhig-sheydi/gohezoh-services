package org.gohezohservices.kwikparsel;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;

/** A distinct, audible Android channel for super-admin service incidents. */
final class AdminSpikeNotification {
    static final String CHANNEL = "admin_spike_alarm_v1";

    private AdminSpikeNotification() { }

    static void createChannel(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL,
            "Super Admin spike alarms", NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("Alerts when delivery systems or database traffic spike.");
        channel.enableVibration(true);
        channel.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
            new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT).build());
        manager.createNotificationChannel(channel);
    }

    static void show(Context context, String alertId, String title, String body) {
        createChannel(context);
        Intent open = new Intent(context, MainActivity.class)
            .setData(Uri.parse("https://gohezoh-services.vercel.app/"))
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent tap = PendingIntent.getActivity(context, 0, open,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_spike)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(new Notification.BigTextStyle().bigText(body))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build();
        context.getSystemService(NotificationManager.class).notify(alertId.hashCode(), notification);
    }
}
