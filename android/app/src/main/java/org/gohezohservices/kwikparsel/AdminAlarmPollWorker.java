package org.gohezohservices.kwikparsel;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;

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
import java.util.concurrent.locks.ReentrantLock;

/** Short authenticated polling job; Android can execute it with the screen off. */
public final class AdminAlarmPollWorker extends Worker {
    private static final String URL = "https://yejiqfocqmdxjeajoexd.supabase.co/functions/v1/admin-alarm-poll";
    private static final String PREFS = "admin_alarm_delivery_v1";
    private static final int MAX_RESPONSE_BYTES = 65536;
    private static final int MAX_ALERTS = 20;
    private static final int MAX_SEEN = 128;
    private static final long MIN_SERVER_POLL_GAP_MS = 60_000L;
    private static final ReentrantLock POLL_LOCK = new ReentrantLock();

    public AdminAlarmPollWorker(@NonNull Context context, @NonNull WorkerParameters parameters) {
        super(context, parameters);
    }

    @NonNull @Override public Result doWork() {
        return poll(getApplicationContext(), getRunAttemptCount(), false);
    }

    /** The idle watchdog shares the same parser, de-duplication and credentials as WorkManager. */
    static void pollFromWatchdog(Context context) {
        poll(context, 2, true);
    }

    private static Result poll(Context context, int attempt, boolean shortTimeout) {
        // Never queue behind another in-process poll; the other poll will deliver the alerts.
        if (!POLL_LOCK.tryLock()) return shortTimeout ? Result.success() : retryBounded(attempt);
        try { return pollLocked(context, attempt, shortTimeout); }
        finally { POLL_LOCK.unlock(); }
    }

    private static Result pollLocked(Context context, int attempt, boolean shortTimeout) {
        SharedPreferences diagnostics = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        diagnostics.edit().putLong("last_poll_attempt_at", System.currentTimeMillis()).apply();
        // An upgraded app may run background work before its activity is opened.
        AdminAlarmNotification.createChannel(context);
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(context);
        if (credential == null || !credential.registered) {
            saveOutcome(context, "Phone alerts not registered");
            return Result.success();
        }
        if (!AdminAlarmNotification.canPost(context)) {
            saveOutcome(context, "Android notifications disabled");
            return Result.success();
        }
        long elapsed = SystemClock.elapsedRealtime();
        long previous = diagnostics.getLong("last_server_poll_elapsed", 0L);
        if (previous > 0 && elapsed >= previous && elapsed - previous < MIN_SERVER_POLL_GAP_MS) {
            saveOutcome(context, "Recently checked; duplicate skipped");
            return shortTimeout ? Result.success() : retryBounded(attempt);
        }
        try {
            Set<String> ack = loadIds(context, "ack_ids");
            JSONObject request = new JSONObject()
                .put("device_id", credential.deviceId)
                .put("device_secret", credential.secret)
                .put("ack_ids", new JSONArray(ack));
            HttpURLConnection connection = (HttpURLConnection) new URL(URL).openConnection();
            try {
                connection.setRequestMethod("POST");
                // goAsync() receivers have a short execution window; leave time to finish().
                connection.setConnectTimeout(shortTimeout ? 2500 : 8000);
                connection.setReadTimeout(shortTimeout ? 4000 : 10000);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setRequestProperty("Accept", "application/json");
                connection.setRequestProperty("apikey", BuildConfig.SUPABASE_API_KEY);
                byte[] bytes = request.toString().getBytes(StandardCharsets.UTF_8);
                connection.setFixedLengthStreamingMode(bytes.length);
                try (OutputStream output = connection.getOutputStream()) { output.write(bytes); }
                int status = connection.getResponseCode();
                if (status == 401 || status == 403) {
                    AdminAlarmScheduler.revokeIfCurrent(context, credential);
                    return Result.success();
                }
                if (status == 429)
                    diagnostics.edit().putLong("last_server_poll_elapsed", SystemClock.elapsedRealtime()).apply();
                if (status == 429) { saveOutcome(context, "Server rate limit"); return transientFailure(context, attempt, shortTimeout); }
                if (status >= 500) { saveOutcome(context, "Server unavailable"); return transientFailure(context, attempt, shortTimeout); }
                if (status != 200) { saveOutcome(context, "Server returned " + status); return Result.success(); }
                JSONObject response;
                try (InputStream input = connection.getInputStream()) {
                    response = new JSONObject(new String(readBounded(input), StandardCharsets.UTF_8));
                }
                JSONArray alerts = response.optJSONArray("alerts");
                if (alerts == null || alerts.length() > MAX_ALERTS) {
                    saveOutcome(context, "Invalid server response");
                    return transientFailure(context, attempt, shortTimeout);
                }
                // Opt-out clears the credential and delivery cache under this monitor.
                // Keep notification and deduplication writes together so a late poll
                // cannot restore old IDs or sound after opt-out has completed.
                synchronized (AdminAlarmStore.class) {
                    AdminAlarmStore.Credential active = AdminAlarmStore.read(context);
                    if (active == null || !active.registered
                        || !credential.deviceId.equals(active.deviceId)
                        || !credential.secret.equals(active.secret)) return Result.success();
                    // ACK only after a successful response; failures keep IDs for later.
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
                }
                diagnostics.edit().putLong("last_server_poll_elapsed", SystemClock.elapsedRealtime()).apply();
                diagnostics.edit().putLong("last_server_check_at", System.currentTimeMillis())
                    .putString("last_poll_outcome", "Checked").apply();
                return Result.success();
            } finally {
                connection.disconnect();
            }
        } catch (Exception error) {
            saveOutcome(context, "Connection unavailable");
            return transientFailure(context, attempt, shortTimeout);
        }
    }

    private static Result transientFailure(Context context, int attempt, boolean shortTimeout) {
        if (!shortTimeout) return retryBounded(attempt);
        try { AdminAlarmScheduler.enqueueWatchdogRetry(context); }
        catch (RuntimeException ignored) { /* The next watchdog and WorkManager remain scheduled. */ }
        return Result.success();
    }

    private static Result retryBounded(int attempt) {
        return attempt < 2 ? Result.retry() : Result.success();
    }

    private static void saveOutcome(Context context, String outcome) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("last_poll_outcome", outcome).apply();
    }

    static long lastServerCheckAt(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("last_server_check_at", 0L);
    }

    static long lastPollAttemptAt(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("last_poll_attempt_at", 0L);
    }

    static String lastPollOutcome(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("last_poll_outcome", "Waiting for first check");
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
