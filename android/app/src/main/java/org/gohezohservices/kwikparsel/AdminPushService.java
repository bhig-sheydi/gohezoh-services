package org.gohezohservices.kwikparsel;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;
import java.util.UUID;

/** Data-only FCM payload: Android uses the bundled siren even with the WebView closed. */
public final class AdminPushService extends FirebaseMessagingService {
    @Override public void onNewToken(String token) {
        // A refreshed token is registered when the admin next opens Service health.
    }

    @Override public void onMessageReceived(RemoteMessage message) {
        Map<String, String> data = message.getData();
        String id = data.get("event_id");
        String type = data.get("type");
        try { UUID.fromString(id); } catch (Exception invalid) { return; }
        if ("company_invitation".equals(type) || "rider_assignment".equals(type) || "customer_match".equals(type)) {
            String registeredUser = getSharedPreferences("ride_push", MODE_PRIVATE).getString("user_id", "");
            if (registeredUser.equals(data.get("user_id"))) RidePushNotification.show(this, id, type);
            return;
        }
        if (!"spike".equals(type) && !"margin".equals(type)) return;
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(this);
        if (credential == null || !credential.registered) return;
        if (!AdminAlarmNotification.canPost(this)) return;
        String title = "spike".equals(type) ? "Kwik-Parsel service spike" : "Kwik-Parsel margin alert";
        String body = "Open Service health to review this alert.";
        AdminAlarmNotification.show(this, id, title, body);
    }
}
