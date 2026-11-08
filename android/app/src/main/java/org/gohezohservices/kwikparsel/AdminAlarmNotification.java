package org.gohezohservices.kwikparsel;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;

/** One high-priority notification per new admin incident, using a sound bundled in the APK. */
final class AdminAlarmNotification {
    static final String CHANNEL = "admin_service_alarm_v2";

    private AdminAlarmNotification() { }

    static void createChannel(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL,
            "Super Admin service alarms", NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("Service spikes and low profit-margin warnings.");
        channel.enableVibration(true);
        channel.setVibrationPattern(new long[]{0, 300, 150, 400});
        // Name-based resource URI remains stable when Android changes numeric resource IDs on upgrade.
        Uri sound = Uri.parse("android.resource://" + context.getPackageName() + "/raw/admin_alert");
        channel.setSound(sound, new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
        manager.createNotificationChannel(channel);
    }

    static boolean canPost(Context context) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) return false;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = manager.getNotificationChannel(CHANNEL);
        return manager.areNotificationsEnabled() && channel != null
            && channel.getImportance() >= NotificationManager.IMPORTANCE_DEFAULT;
    }

    static boolean show(Context context, String alertId, String title, String body) {
        createChannel(context);
        if (!canPost(context)) return false;
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
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .build();
        try {
            context.getSystemService(NotificationManager.class).notify(alertId.hashCode(), notification);
            return true;
        } catch (SecurityException error) {
            return false;
        }
    }
}
