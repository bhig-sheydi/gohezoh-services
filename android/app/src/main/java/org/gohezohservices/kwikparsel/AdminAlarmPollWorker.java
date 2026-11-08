package org.gohezohservices.kwikparsel;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.UUID;

/** Short authenticated polling job; Android can execute it with the screen off. */
public final class AdminAlarmPollWorker extends Worker {
    private static final String URL = "https://yejiqfocqmdxjeajoexd.supabase.co/functions/v1/admin-alarm-poll";
    private static final String PREFS = "admin_alarm_delivery_v1";
    private static final int MAX_RESPONSE_BYTES = 65536;
    private static final int MAX_ALERTS = 20;
    private static final int MAX_SEEN = 128;

    public AdminAlarmPollWorker(@NonNull Context context, @NonNull WorkerParameters parameters) {
        super(context, parameters);
    }

    @NonNull @Override public Result doWork() {
        Context context = getApplicationContext();
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(context);
        if (credential == null || !credential.registered || !AdminAlarmNotification.canPost(context)) return Result.success();
        try {
            Set<String> ack = loadIds(context, "ack_ids");
            JSONObject request = new JSONObject()
                .put("device_id", credential.deviceId)
                .put("device_secret", credential.secret)
                .put("ack_ids", new JSONArray(ack));
            HttpURLConnection connection = (HttpURLConnection) new URL(URL).openConnection();
            try {
                connection.setRequestMethod("POST");
                connection.setConnectTimeout(8000);
                connection.setReadTimeout(10000);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setRequestProperty("Accept", "application/json");
                connection.setRequestProperty("apikey", BuildConfig.SUPABASE_API_KEY);
                byte[] bytes = request.toString().getBytes(StandardCharsets.UTF_8);
                connection.setFixedLengthStreamingMode(bytes.length);
                try (OutputStream output = connection.getOutputStream()) { output.write(bytes); }
                int status = connection.getResponseCode();
                if (status == 401 || status == 403) {
                    AdminAlarmStore.clear(context);
                    AdminAlarmScheduler.disable(context);
                    clearDeliveryState(context);
                    return Result.success();
                }
                if (status == 429 || status >= 500) return retryBounded();
                if (status != 200) return Result.success();
                JSONObject response;
                try (InputStream input = connection.getInputStream()) {
                    response = new JSONObject(new String(readBounded(input), StandardCharsets.UTF_8));
                }
                JSONArray alerts = response.optJSONArray("alerts");
                if (alerts == null || alerts.length() > MAX_ALERTS) return Result.success();
                // ACK only after a successful response; network failures keep IDs for the next check.
                Set<String> pending = loadIds(context, "ack_ids");
                pending.removeAll(ack);
                Set<String> seen = loadIds(context, "seen_ids");
                for (int i = 0; i < alerts.length(); i++) {
                    JSONObject alert = alerts.optJSONObject(i);
                    if (alert == null) continue;
                    String id = alert.optString("id", "");
                    try { UUID.fromString(id); } catch (IllegalArgumentException invalid) { continue; }
                    if (seen.contains(id)) { pending.add(id); continue; }
                    String type = alert.optString("type", "");
                    if (!"spike".equals(type) && !"margin".equals(type)) continue;
                    String title = alert.optString("title", "Kwik-Parsel service alert");
                    String body = alert.optString("body", "Open the Super Admin dashboard for details.");
                    if (title.isEmpty() || title.length() > 100 || body.isEmpty() || body.length() > 300) continue;
                    if (!AdminAlarmNotification.show(context, id, title, body)) return Result.success();
                    seen.add(id);
                    pending.add(id);
                    saveIds(context, "seen_ids", seen, MAX_SEEN);
                    saveIds(context, "ack_ids", pending, MAX_SEEN);
                }
                saveIds(context, "ack_ids", pending, MAX_SEEN);
                return Result.success();
            } finally {
                connection.disconnect();
            }
        } catch (Exception error) {
            return retryBounded();
        }
    }

    private Result retryBounded() {
        return getRunAttemptCount() < 2 ? Result.retry() : Result.success();
    }

    private static byte[] readBounded(InputStream input) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] chunk = new byte[4096];
        int size;
        while ((size = input.read(chunk)) != -1) {
            if (out.size() + size > MAX_RESPONSE_BYTES) throw new IllegalStateException("Oversized alarm response");
            out.write(chunk, 0, size);
        }
        return out.toByteArray();
    }

    private static synchronized Set<String> loadIds(Context context, String name) {
        Set<String> ids = new LinkedHashSet<>();
        String raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(name, "[]");
        try {
            JSONArray values = new JSONArray(raw);
            for (int i = 0; i < values.length() && i < MAX_SEEN; i++) {
                String id = values.optString(i, "");
                try { UUID.fromString(id); ids.add(id); } catch (IllegalArgumentException ignored) { }
            }
        } catch (Exception ignored) { /* A corrupt local cache is safe to discard. */ }
        return ids;
    }

    private static synchronized void saveIds(Context context, String name, Set<String> ids, int max) {
        while (ids.size() > max) ids.remove(ids.iterator().next());
        SharedPreferences stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        stored.edit().putString(name, new JSONArray(ids).toString()).commit();
    }

    static void clearDeliveryState(Context context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply();
    }
}
