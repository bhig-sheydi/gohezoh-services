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

/** Runs only after the rider taps Go online. Android keeps its notification visible while tracking. */
public final class RiderLocationService extends Service implements LocationListener {
    public static final String ACTION_START = "org.gohezohservices.kwikparsel.START_TRACKING";
    public static final String ACTION_STOP = "org.gohezohservices.kwikparsel.STOP_TRACKING";
    public static final String EXTRA_TOKEN = "trackingToken";
    private static final String CHANNEL = "rider_location";
    private static final String SUPABASE = "https://yejiqfocqmdxjeajoexd.supabase.co";
    private static final int NOTIFICATION_ID = 17;
    private final ExecutorService uploads = Executors.newSingleThreadExecutor();
    private final AtomicBoolean sending = new AtomicBoolean(false);
    private LocationManager locations;
    private volatile String trackingToken;
    private long lastSentAt;
    private Location lastSent;
    public static volatile boolean active = false;
    public static volatile String status = "Offline";

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }
        if (ACTION_STOP.equals(intent.getAction())) { stopTracking(); return START_NOT_STICKY; }
        if (!ACTION_START.equals(intent.getAction())) return START_NOT_STICKY;
        String token = intent.getStringExtra(EXTRA_TOKEN);
        if (token == null || !token.matches("[0-9a-f]{64}")) { status = "Phone tracking could not start"; stopSelf(); return START_NOT_STICKY; }
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
                && checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            status = "Location permission is needed"; stopSelf(); return START_NOT_STICKY;
        }
        trackingToken = token;
        createChannel();
        Notification notification = notification();
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        else startForeground(NOTIFICATION_ID, notification);
        active = true;
        status = "Connecting to phone GPS…";
        locations = (LocationManager) getSystemService(LOCATION_SERVICE);
        try {
            boolean provider = false;
            if (locations.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, 10000L, 25f, this, Looper.getMainLooper());
                provider = true;
            }
            if (locations.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                locations.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 10000L, 25f, this, Looper.getMainLooper());
                provider = true;
            }
            if (!provider) { status = "Turn on phone location to go online"; stopTracking(); }
        } catch (SecurityException error) { status = "Location permission is needed"; stopTracking(); }
        return START_NOT_STICKY;
    }

    @Override public void onLocationChanged(Location fix) {
        if (!active || trackingToken == null || !fix.hasAccuracy() || fix.getAccuracy() > 100f
                || System.currentTimeMillis() - fix.getTime() > 60000L) {
            if (active) status = "Waiting for accurate phone GPS…";
            return;
        }
        long now = System.currentTimeMillis();
        if (lastSent != null && now - lastSentAt < 60000L && lastSent.distanceTo(fix) < 50f) return;
        if (!sending.compareAndSet(false, true)) return;
        lastSentAt = now;
        lastSent = new Location(fix);
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
                int result = postRpc("report_native_rider_position", body);
                if (result == 401 || result == 403) {
                    status = "Rider access ended. Sign in and go online again.";
                    stopTracking();
                } else if (result >= 200 && result < 300) {
                    status = "Online · phone GPS ±" + Math.round(fix.getAccuracy()) + " m";
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

    private void stopTracking() {
        String token = trackingToken;
        trackingToken = null;
        active = false;
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
        channel.setDescription("Phone location is shared while you are on duty. Tap Stop to end tracking.");
        manager.createNotificationChannel(channel);
    }

    private Notification notification() {
        PendingIntent open = PendingIntent.getActivity(this, 0,
            new Intent(this, MainActivity.class).setAction(Intent.ACTION_MAIN), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(this, 1,
            new Intent(this, RiderLocationService.class).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_tracking).setContentTitle("Kwik-Parsel rider on duty")
            .setContentText("Phone GPS is sharing your location for nearby deliveries")
            .setContentIntent(open).addAction(new Notification.Action.Builder(R.drawable.ic_tracking, "Go offline", stop).build())
            .setOngoing(true).build();
    }

    @Override public void onDestroy() {
        active = false;
        if (locations != null) locations.removeUpdates(this);
        uploads.shutdown();
        super.onDestroy();
    }
}
