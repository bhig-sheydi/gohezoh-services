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

/** Actionable ride alerts have their own audible channel and never use the admin channel. */
final class RidePushNotification {
    static final String CHANNEL = "ride_alerts_v1";
    static final String ALARM_CHANNEL = "rider_assignment_alarm_v1";
    private RidePushNotification() { }

    static void createChannel(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "Ride alerts", NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("New company invitations, rider assignments and customer matches.");
        channel.enableVibration(true);
        channel.setVibrationPattern(new long[]{0, 450, 200, 550});
        channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
        Uri sound = Uri.parse("android.resource://" + context.getPackageName() + "/raw/admin_alert");
        channel.setSound(sound, new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
        manager.createNotificationChannel(channel);
        NotificationChannel alarm = new NotificationChannel(ALARM_CHANNEL, "Rider assignment alarm", NotificationManager.IMPORTANCE_HIGH);
        alarm.setDescription("Visible one-minute alarm for a newly assigned ride.");
        alarm.setSound(null, null);
        alarm.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
        manager.createNotificationChannel(alarm);
    }

    static boolean canPost(Context context) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) return false;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = manager.getNotificationChannel(CHANNEL);
        return manager.areNotificationsEnabled() && channel != null
            && channel.getImportance() >= NotificationManager.IMPORTANCE_DEFAULT;
    }

    static boolean canRing(Context context) {
        if (!canPost(context)) return false;
        NotificationChannel channel = context.getSystemService(NotificationManager.class).getNotificationChannel(CHANNEL);
        return channel != null && channel.getSound() != null;
    }

    static void show(Context context, String eventId, String type) {
        createChannel(context);
        if (!canPost(context)) return;
        String title, body, path;
        switch (type) {
            case "company_invitation":
                title = "New delivery request"; body = "Open your company dashboard to respond now."; path = "/"; break;
            case "company_reassignment_offer":
                title = "Paid pickup needs a rider"; body = "Open your company dashboard to accept this fixed-price job within one minute."; path = "/"; break;
            case "rider_assignment":
                title = "New ride assigned"; body = "Open your rider dashboard for pickup details."; path = "/rider"; break;
            case "independent_offer":
                title = "New delivery offer"; body = "Open your rider dashboard to accept or decline this delivery."; path = "/rider"; break;
            case "customer_match":
                title = "A rider is available"; body = "Open your deliveries to choose a company."; path = "/"; break;
            case "rider_missed":
                title = "Paid pickup lost"; body = "Your rider did not respond. The job and its pending payout were removed from your company."; path = "/"; break;
            default: return;
        }
        Intent open = new Intent(context, MainActivity.class)
            .setData(Uri.parse("https://gohezoh-services.vercel.app" + path))
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent tap = PendingIntent.getActivity(context, eventId.hashCode(), open,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_spike).setContentTitle(title).setContentText(body)
            .setContentIntent(tap).setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).build();
        try { context.getSystemService(NotificationManager.class).notify(eventId.hashCode(), notification); }
        catch (SecurityException ignored) { /* Notification permission changed during delivery. */ }
    }
}
