package org.gohezohservices.kwikparsel;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.IBinder;
import android.os.Looper;
import android.os.Handler;
import android.os.Bundle;
import android.os.PowerManager;

import org.json.JSONObject;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** Visible foreground tracking continues off duty until the rider stops sharing. */
public final class RiderLocationService extends Service implements LocationListener {
    public static final String ACTION_START = "org.gohezohservices.kwikparsel.START_TRACKING";
    public static final String ACTION_STOP = "org.gohezohservices.kwikparsel.STOP_TRACKING";
    public static final String ACTION_SET_DUTY = "org.gohezohservices.kwikparsel.SET_DUTY";
    public static final String EXTRA_DUTY = "onDuty";
    public static final String EXTRA_TOKEN = "trackingToken";
    private static final String CHANNEL = "rider_location";
    private static final String SUPABASE = "https://yejiqfocqmdxjeajoexd.supabase.co";
    private static final int NOTIFICATION_ID = 17;
    private final ExecutorService uploads = Executors.newSingleThreadExecutor();
    private final AtomicBoolean sending = new AtomicBoolean(false);
    private LocationManager locations;
    private volatile String trackingToken;
    private volatile long lastSentAt;
    private volatile Location lastSent;
    private volatile String pendingRequestId;
    private final Handler requestHandler = new Handler(Looper.getMainLooper());
    private final Runnable requestCheck = new Runnable() {
        @Override public void run() {
            if (active && !onDuty && trackingToken != null) uploads.execute(() -> {
                try {
                    pendingRequestId = pollRequest(trackingToken);
                    if (pendingRequestId != null) requestHandler.post(() -> startLocationUpdates());
                }
                catch (Exception ignored) { status = "Waiting for internet to check location requests"; }
            });
            if (active) requestHandler.postDelayed(this, 300000L);
        }
    };
    public static volatile boolean active = false;
    public static volatile boolean onDuty = false;
    public static volatile String status = "Offline";

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            String saved = getSharedPreferences("rider_location", MODE_PRIVATE).getString("token", null);
            if (saved == null) { stopSelf(); return START_NOT_STICKY; }
            intent = new Intent(this, RiderLocationService.class).setAction(ACTION_START)
                .putExtra(EXTRA_TOKEN, saved).putExtra(EXTRA_DUTY, false);
        }
        if (ACTION_STOP.equals(intent.getAction())) { stopTracking(); return START_NOT_STICKY; }
        if (ACTION_SET_DUTY.equals(intent.getAction())) {
            if (!active || trackingToken == null) return START_NOT_STICKY;
            boolean nextDuty = intent.getBooleanExtra(EXTRA_DUTY, false);
            onDuty = nextDuty;
            if (nextDuty) startLocationUpdates();
            else if (locations != null) locations.removeUpdates(this);
            pendingRequestId = null;
            requestHandler.removeCallbacks(requestCheck);
            requestHandler.post(requestCheck);
            lastSentAt = 0;
            status = nextDuty ? "On duty · getting phone GPS…" : "Off duty · checking for requests";
            if (!nextDuty) uploads.execute(() -> {
                try { postRpc("set_native_rider_duty", new JSONObject().put("p_token", trackingToken).put("p_on_duty", false)); }
                catch (Exception ignored) { status = "Off duty · waiting for internet"; }
            });
            return START_NOT_STICKY;
        }
        if (!ACTION_START.equals(intent.getAction())) return START_NOT_STICKY;
        String token = intent.getStringExtra(EXTRA_TOKEN);
        if (token == null || !token.matches("[0-9a-f]{64}")) { status = "Phone tracking could not start"; stopSelf(); return START_NOT_STICKY; }
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
                && checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            status = "Location permission is needed"; stopSelf(); return START_NOT_STICKY;
        }
        boolean wasActive = active;
        trackingToken = token;
        if (!wasActive) onDuty = intent.getBooleanExtra(EXTRA_DUTY, true);
        getSharedPreferences("rider_location", MODE_PRIVATE).edit().putString("token", token).apply();
        lastSentAt = 0;
        createChannel();
        Notification notification = notification();
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        else startForeground(NOTIFICATION_ID, notification);
        active = true;
        requestHandler.removeCallbacks(requestCheck);
        requestHandler.post(requestCheck);
        if (!onDuty) uploads.execute(() -> {
            try { postRpc("set_native_rider_duty", new JSONObject().put("p_token", trackingToken).put("p_on_duty", false)); }
            catch (Exception ignored) { /* The next fix retries reporting. */ }
        });
        status = "Connecting to phone GPS…";
        locations = (LocationManager) getSystemService(LOCATION_SERVICE);
        if (onDuty) startLocationUpdates();
        else status = "Off duty: waiting for a location request";
        return START_STICKY;
    }

    private void startLocationUpdates() {
        if (locations == null || (!onDuty && pendingRequestId == null)) return;
        try {
            locations.removeUpdates(this);
            boolean provider = false;
            if (locations.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, 10000L, 0f, this, Looper.getMainLooper());
                provider = true;
            }
            if (locations.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                locations.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 10000L, 0f, this, Looper.getMainLooper());
                provider = true;
            }
            if (!provider) status = "Turn on phone location to answer requests";
        } catch (SecurityException error) { status = "Location permission is needed"; }
    }

    @Override public void onLocationChanged(Location fix) {
        if (!active || trackingToken == null || !fix.hasAccuracy() || fix.getAccuracy() > 100f
                || System.currentTimeMillis() - fix.getTime() > 60000L) {
            if (active) status = "Waiting for accurate phone GPS…";
            return;
        }
        String requestId = pendingRequestId;
        if (!onDuty && requestId == null) return;
        long now = System.currentTimeMillis();
        if (onDuty && lastSent != null && now - lastSentAt < 60000L && lastSent.distanceTo(fix) < 50f) return;
        if (!sending.compareAndSet(false, true)) return;
        String token = trackingToken;
        uploads.execute(() -> {
            PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
            PowerManager.WakeLock wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "KwikParsel:RiderPositionUpload");
            wakeLock.acquire(25000L);
            try {
                JSONObject body = new JSONObject();
                body.put("p_token", token);
                body.put("p_latitude", fix.getLatitude());
                body.put("p_longitude", fix.getLongitude());
                body.put("p_accuracy_metres", (double) fix.getAccuracy());
                body.put("p_captured_at", java.time.Instant.ofEpochMilli(fix.getTime()).toString());
                boolean reportingDuty = onDuty;
                if (!reportingDuty) body.put("p_request_id", requestId);
                int result = postRpc(reportingDuty ? "report_native_rider_position" : "report_native_requested_position", body);
                if (result == 401 || result == 403) {
                    status = "Rider access ended. Sign in and go online again.";
                    stopTracking();
                } else if (result >= 200 && result < 300) {
                    if (!reportingDuty && requestId != null && requestId.equals(pendingRequestId)) {
                        pendingRequestId = null;
                        requestHandler.post(() -> { if (!onDuty && locations != null) locations.removeUpdates(this); });
                    }
                    lastSentAt = System.currentTimeMillis();
                    lastSent = new Location(fix);
                    status = (reportingDuty ? "On duty" : "Off-duty request answered") + " · GPS ±" + Math.round(fix.getAccuracy()) + " m";
                } else status = "Could not send location. Retrying…";
            } catch (Exception error) { status = "No connection. Retrying location…"; }
            finally { if (wakeLock.isHeld()) wakeLock.release(); sending.set(false); }
        });
    }

    @Override public void onProviderDisabled(String provider) { if (active) status = "Turn on phone location to stay online"; }
    @Override public void onProviderEnabled(String provider) { if (active) status = "Connecting to phone GPS…"; }
    @Override public void onStatusChanged(String provider, int status, Bundle extras) { }

    private int postRpc(String name, JSONObject body) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(SUPABASE + "/rest/v1/rpc/" + name).openConnection();
        connection.setConnectTimeout(10000);
        connection.setReadTimeout(10000);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("apikey", BuildConfig.SUPABASE_API_KEY);
        connection.setRequestProperty("Authorization", "Bearer " + BuildConfig.SUPABASE_API_KEY);
        try {
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body.toString().getBytes(StandardCharsets.UTF_8));
            }
            int code = connection.getResponseCode();
            InputStream response = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
            if (response != null) response.close();
            return code;
        } finally { connection.disconnect(); }
    }

    private String pollRequest(String token) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(SUPABASE + "/rest/v1/rpc/poll_native_rider_location_request").openConnection();
        connection.setConnectTimeout(10000); connection.setReadTimeout(10000);
        connection.setRequestMethod("POST"); connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("apikey", BuildConfig.SUPABASE_API_KEY);
        connection.setRequestProperty("Authorization", "Bearer " + BuildConfig.SUPABASE_API_KEY);
        try {
            try (OutputStream output = connection.getOutputStream()) {
                output.write(new JSONObject().put("p_token", token).toString().getBytes(StandardCharsets.UTF_8));
            }
            if (connection.getResponseCode() == 401 || connection.getResponseCode() == 403) {
                stopTracking(); return null;
            }
            if (connection.getResponseCode() != 200) return null;
            try (InputStream input = connection.getInputStream()) {
                String result = new String(input.readAllBytes(), StandardCharsets.UTF_8).trim();
                if (result.length() == 38 && result.startsWith("\"") && result.endsWith("\""))
                    return result.substring(1, 37);
                return null;
            }
        } finally { connection.disconnect(); }
    }

    private void stopTracking() {
        String token = trackingToken;
        getSharedPreferences("rider_location", MODE_PRIVATE).edit().remove("token").apply();
        trackingToken = null;
        pendingRequestId = null;
        requestHandler.removeCallbacks(requestCheck);
        active = false;
        onDuty = false;
        status = "Offline";
        if (locations != null) locations.removeUpdates(this);
        if (token != null) uploads.execute(() -> {
            try { postRpc("revoke_rider_tracking_token", new JSONObject().put("p_token", token)); }
            catch (Exception ignored) { /* The server expires a stale position and token. */ }
        });
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void createChannel() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "On-duty rider location", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Phone location is shared until you stop it, including while off duty.");
        manager.createNotificationChannel(channel);
    }

    private Notification notification() {
        PendingIntent open = PendingIntent.getActivity(this, 0,
            new Intent(this, MainActivity.class).setAction(Intent.ACTION_MAIN), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(this, 1,
            new Intent(this, RiderLocationService.class).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_tracking).setContentTitle("Kwik-Parsel location sharing")
            .setContentText("Phone GPS is shared with your company and active delivery customers")
            .setContentIntent(open).addAction(new Notification.Action.Builder(R.drawable.ic_tracking, "Stop sharing", stop).build())
            .setOngoing(true).build();
    }

    @Override public void onDestroy() {
        active = false;
        requestHandler.removeCallbacks(requestCheck);
        if (locations != null) locations.removeUpdates(this);
        uploads.shutdown();
        super.onDestroy();
    }
}
