package org.gohezohservices.kwikparsel;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

/** Foreground FCM delivery; Android posts the notification itself in background. */
public final class AdminSpikeMessagingService extends FirebaseMessagingService {
    @Override public void onMessageReceived(RemoteMessage message) {
        String alertId = message.getData().get("alert_id");
        if (alertId == null || !alertId.matches("[0-9a-fA-F-]{36}")) return;
        RemoteMessage.Notification payload = message.getNotification();
        String title = payload != null && payload.getTitle() != null
            ? payload.getTitle() : "Kwik-Parsel service spike";
        String body = payload != null && payload.getBody() != null
            ? payload.getBody() : "Open the Super Admin dashboard for details.";
        AdminSpikeNotification.show(this, alertId, title, body);
    }
}
