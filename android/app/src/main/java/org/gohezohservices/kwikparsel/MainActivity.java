package org.gohezohservices.kwikparsel;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.provider.Settings;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Build;
import android.os.Message;
import android.webkit.ValueCallback;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.window.OnBackInvokedDispatcher;

import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONObject;

import java.util.Collections;
import java.util.concurrent.atomic.AtomicBoolean;
import com.google.firebase.messaging.FirebaseMessaging;

/** Trusted-site WebView. The native message bridge is available to the main frame only. */
public final class MainActivity extends Activity {
    private static final String HOME = "https://gohezoh-services.vercel.app";
    private static final int LOCATION_PERMISSION = 41;
    private static final int FILE_CHOOSER = 42;
    private static final int NOTIFICATION_PERMISSION = 43;
    private static final int CAMERA_PERMISSION = 44;
    private static final int ADMIN_NOTIFICATION_PERMISSION = 45;
    private static final int RIDE_NOTIFICATION_PERMISSION = 46;
    private WebView web;
    private String pendingTrackingToken;
    private String pendingPositionId;
    private ValueCallback<Uri[]> selectedFiles;
    private PermissionRequest pendingCameraRequest;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        web = new WebView(this);
        setContentView(web);
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, () -> {
                    if (web != null && web.canGoBack()) web.goBack();
                    else finish();
                });
        }
        AdminAlarmNotification.createChannel(this);
        RidePushNotification.createChannel(this);
        // Re-arm after a force-stop once the admin opens the app again.
        try { AdminAlarmScheduler.restoreAfterSystemEvent(this); }
        catch (RuntimeException ignored) { /* Opening the app must still work if Android delays alarms. */ }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            web.loadData("<h2>Update Android System WebView</h2><p>This app needs a newer Android System WebView for secure phone tracking.</p>", "text/html", "UTF-8");
            return;
        }
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (!request.isForMainFrame()) return false;
                if (allowed(request.getUrl())) return false;
                try { startActivity(new Intent(Intent.ACTION_VIEW, request.getUrl())); }
                catch (Exception ignored) { /* No external handler. */ }
                return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest request) {
                runOnUiThread(() -> {
                    if (web == null || web.getUrl() == null || !allowed(Uri.parse(web.getUrl()))
                        || !allowed(request.getOrigin())) { request.deny(); return; }
                    String[] resources = request.getResources();
                    if (resources.length != 1 || !PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resources[0])) {
                        request.deny(); return;
                    }
                    if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        request.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                    } else {
                        pendingCameraRequest = request;
                        requestPermissions(new String[]{Manifest.permission.CAMERA}, CAMERA_PERMISSION);
                    }
                });
            }
            @Override public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                if (!isUserGesture) return false;
                WebView popup = new WebView(MainActivity.this);
                popup.setWebViewClient(new WebViewClient() {
                    @Override public boolean shouldOverrideUrlLoading(WebView ignored, WebResourceRequest request) {
                        try { startActivity(new Intent(Intent.ACTION_VIEW, request.getUrl())); }
                        catch (Exception error) { /* No external handler. */ }
                        popup.destroy();
                        return true;
                    }
                });
                ((WebView.WebViewTransport) resultMsg.obj).setWebView(popup);
                resultMsg.sendToTarget();
                return true;
            }
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (selectedFiles != null) selectedFiles.onReceiveValue(null);
                selectedFiles = callback;
                try { startActivityForResult(params.createIntent(), FILE_CHOOSER); return true; }
                catch (Exception error) { selectedFiles = null; callback.onReceiveValue(null); return false; }
            }
        });
        WebViewCompat.addWebMessageListener(web, "KwikParselNative", Collections.singleton(HOME),
            (view, message, sourceOrigin, isMainFrame, replyProxy) -> {
                if (!isMainFrame || !allowed(sourceOrigin) || view.getUrl() == null || !allowed(Uri.parse(view.getUrl()))) return;
                runOnUiThread(() -> riderMessage(message.getData()));
            });
        WebViewCompat.addWebMessageListener(web, "GohezohLocation", Collections.singleton(HOME),
            (view, message, sourceOrigin, isMainFrame, replyProxy) -> {
                if (!isMainFrame || !allowed(sourceOrigin) || view.getUrl() == null || !allowed(Uri.parse(view.getUrl()))) return;
                runOnUiThread(() -> positionMessage(message.getData()));
            });
        web.loadUrl(initialUrl(getIntent()));
    }

    private boolean allowed(Uri uri) {
        return uri != null && "https".equals(uri.getScheme()) && "gohezoh-services.vercel.app".equals(uri.getHost())
            && (uri.getPort() == -1 || uri.getPort() == 443);
    }

    private String initialUrl(Intent intent) {
        Uri uri = intent == null ? null : intent.getData();
        return allowed(uri) ? uri.toString() : HOME + "/";
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (web != null && allowed(intent.getData())) web.loadUrl(initialUrl(intent));
    }

    private void riderMessage(String data) {
        String requestedType = "";
        try {
            JSONObject message = new JSONObject(data);
            requestedType = message.optString("type");
            switch (requestedType) {
                case "rider:status": sendRiderStatus(); break;
                case "admin:poll-status": adminPollStatus(); break;
                case "admin:enable-poll": enableAdminPoll(); break;
                case "admin:poll-registered": adminPollRegistered(); break;
                case "admin:disable-poll": disableAdminPoll(); break;
                case "admin:test-notification": testAdminNotification(); break;
                case "admin:open-notification-settings": openAdminNotificationSettings(); break;
                case "ride:status": sendRidePushStatus(); break;
                case "ride:register": enableRidePush(); break;
                case "ride:registered":
                    String rideUserId = message.optString("userId");
                    try { java.util.UUID.fromString(rideUserId); }
                    catch (Exception invalid) { break; }
                    getSharedPreferences("ride_push", MODE_PRIVATE).edit().putString("user_id", rideUserId).apply();
                    sendRidePushStatus();
                    break;
                case "ride:clear":
                    getSharedPreferences("ride_push", MODE_PRIVATE).edit().remove("user_id").apply();
                    sendRidePushStatus();
                    break;
                case "rider:background-settings":
                    showRiderLocationDisclosure(() -> startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + getPackageName()))));
                    break;
                case "rider:set-duty":
                    if (RiderLocationService.active) startService(new Intent(this, RiderLocationService.class)
                        .setAction(RiderLocationService.ACTION_SET_DUTY)
                        .putExtra(RiderLocationService.EXTRA_DUTY, message.optBoolean("onDuty", false)));
                    new Handler(Looper.getMainLooper()).postDelayed(this::sendRiderStatus, 300);
                    break;
                case "rider:stop":
                    if (RiderLocationService.active) startService(new Intent(this, RiderLocationService.class).setAction(RiderLocationService.ACTION_STOP));
                    else sendRiderStatus();
                    new Handler(Looper.getMainLooper()).postDelayed(this::sendRiderStatus, 300);
                    break;
                case "rider:start":
                    String token = message.optString("trackingToken");
                    if (!token.matches("[0-9a-f]{64}")) { sendRiderEvent(false, "Phone tracking could not start"); return; }
                    pendingTrackingToken = token;
                    showRiderLocationDisclosure(() -> {
                        if (hasLocationPermission()) startTracking();
                        else requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, LOCATION_PERMISSION);
                    });
                    break;
                default: break;
            }
        } catch (Exception error) {
            if (requestedType.startsWith("admin:"))
                sendAdminPollEvent("error", null, "Phone alerts could not be started.");
            else sendRiderEvent(false, "Phone tracking request was invalid");
        }
    }

    private boolean hasLocationPermission() {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            || checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private void sendRidePushStatus() {
        try {
            String registeredUser = getSharedPreferences("ride_push", MODE_PRIVATE).getString("user_id", "");
            sendEvent("kwik-parsel:ride-push", new JSONObject().put("type", "ride:status")
                .put("registeredUserId", registeredUser)
                .put("available", RidePushNotification.canPost(this)));
        } catch (Exception ignored) { /* Status can be requested again. */ }
    }

    private void enableRidePush() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, RIDE_NOTIFICATION_PERMISSION);
            return;
        }
        if (!RidePushNotification.canPost(this)) {
            sendRidePushStatus();
            return;
        }
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful()) { sendRidePushStatus(); return; }
            try {
                String deviceId = getSharedPreferences("ride_push", MODE_PRIVATE).getString("device_id", null);
                if (deviceId == null) {
                    deviceId = java.util.UUID.randomUUID().toString();
                    getSharedPreferences("ride_push", MODE_PRIVATE).edit().putString("device_id", deviceId).apply();
                }
                sendEvent("kwik-parsel:ride-push", new JSONObject().put("type", "ride:token")
                    .put("deviceId", deviceId).put("fcmToken", task.getResult()));
            } catch (Exception ignored) { sendRidePushStatus(); }
        });
    }

    private void adminPollStatus() {
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(this);
        if (!AdminAlarmNotification.canPost(this)) {
            sendAdminPollEvent("disabled", null, "Allow Android service notifications to hear alarms.");
        } else if (credential != null && credential.registered) {
            if (AdminAlarmNotification.hasSound(this))
                sendAdminPushState("enabled", null, "Phone service alarms are on.");
            else sendAdminPollEvent("error", null, "Service alarm sound is off in Android notification settings.");
        } else {
            sendAdminPollEvent("disabled", null, "Turn on phone service alarms in the Super Admin dashboard.");
        }
    }

    private void enableAdminPoll() {
        if (Build.VERSION.SDK_INT >= 33
            && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, ADMIN_NOTIFICATION_PERMISSION);
            return;
        }
        if (!AdminAlarmNotification.canPost(this)) {
            sendAdminPollEvent("disabled", null, "Enable service alarms in Android notification settings.");
            return;
        }
        if (!AdminAlarmNotification.hasSound(this)) {
            sendAdminPollEvent("error", null, "Turn on sound for Super Admin service alarms in Android notification settings.");
            return;
        }
        try {
            AdminAlarmStore.Credential credential = AdminAlarmStore.getOrCreate(this);
            sendAdminPollEvent("credentials", credential, "Registering this phone for service alarms.");
        } catch (Exception error) {
            sendAdminPollEvent("error", null, "Could not secure this phone's alarm credential.");
        }
    }

    private void adminPollRegistered() {
        if (!AdminAlarmNotification.canPost(this) || !AdminAlarmNotification.hasSound(this)
            || !AdminAlarmStore.markRegistered(this)) {
            sendAdminPollEvent("error", null, "Phone alarms could not start. Try again.");
            return;
        }
        AdminAlarmScheduler.enable(this);
        sendAdminPushState("enabled", null, "Phone service alarms are on.");
    }

    private void disableAdminPoll() {
        AdminAlarmStore.clear(this);
        AdminAlarmScheduler.disable(this);
        AdminAlarmPollWorker.clearDeliveryState(this);
        sendAdminPollEvent("disabled", null, "Phone service alarms are off on this device.");
    }

    private void testAdminNotification() {
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(this);
        if (credential == null || !credential.registered || !AdminAlarmNotification.canPost(this)
            || !AdminAlarmNotification.hasSound(this)) {
            sendAdminPollEvent("error", null, "Enable phone service alarms before testing.");
            return;
        }
        if (!AdminAlarmScheduler.scheduleLockScreenTest(this)) {
            sendAdminPollEvent("error", null, "Android could not schedule the alarm test.");
            return;
        }
        sendAdminPollEvent("enabled", null, "Test alarm scheduled. Lock the phone now; Android may delay the alert.");
    }

    private void openAdminNotificationSettings() {
        try {
            Intent settings = new Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName())
                .putExtra(Settings.EXTRA_CHANNEL_ID, AdminAlarmNotification.CHANNEL);
            startActivity(settings);
        } catch (Exception error) {
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName())));
        }
    }

    private void sendAdminPollEvent(String status, AdminAlarmStore.Credential credential, String message) {
        try {
            JSONObject detail = new JSONObject().put("type", "admin:poll-state")
                .put("status", status).put("message", message);
            detail.put("lastPollAttemptAt", AdminAlarmPollWorker.lastPollAttemptAt(this));
            detail.put("lastServerCheckAt", AdminAlarmPollWorker.lastServerCheckAt(this));
            detail.put("lastPollOutcome", AdminAlarmPollWorker.lastPollOutcome(this));
            if (credential != null) {
                detail.put("deviceId", credential.deviceId);
                detail.put("deviceSecret", credential.secret);
            }
            sendEvent("kwik-parsel:admin-push", detail);
        } catch (Exception ignored) { /* The web screen can request state again. */ }
    }

    private void sendAdminPushState(String status, AdminAlarmStore.Credential credential, String message) {
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful()) {
                sendAdminPollEvent("error", null, "Firebase phone alerts are unavailable.");
                return;
            }
            try {
                JSONObject detail = new JSONObject().put("type", "admin:poll-state")
                    .put("status", status).put("message", message)
                    .put("deviceId", AdminAlarmStore.read(this).deviceId)
                    .put("fcmToken", task.getResult());
                detail.put("lastPollAttemptAt", AdminAlarmPollWorker.lastPollAttemptAt(this));
                detail.put("lastServerCheckAt", AdminAlarmPollWorker.lastServerCheckAt(this));
                detail.put("lastPollOutcome", AdminAlarmPollWorker.lastPollOutcome(this));
                sendEvent("kwik-parsel:admin-push", detail);
            } catch (Exception ignored) { sendAdminPollEvent("error", null, "Phone alerts could not register."); }
        });
    }

    private void showRiderLocationDisclosure(Runnable continueAction) {
        if (getSharedPreferences("rider_location", MODE_PRIVATE).getBoolean("location_disclosure_v2", false)) {
            continueAction.run(); return;
        }
        new AlertDialog.Builder(this)
            .setTitle("Rider location sharing")
            .setMessage("Kwik-Parsel collects location data to enable rider dispatch, customer delivery tracking, company vehicle and rider safety, and authorized location requests even when the app is closed or not in use. While on duty, location is updated automatically. While off duty, the app checks for authorized requests about once an hour and reports a fresh position only when requested. The rider can manage this permission in Android settings. Continue to the Android permission request?")
            .setNegativeButton("Not now", (dialog, which) -> { pendingTrackingToken = null; sendRiderEvent(false, "Location permission is needed for rider tracking"); })
            .setPositiveButton("Continue", (dialog, which) -> {
                getSharedPreferences("rider_location", MODE_PRIVATE).edit().putBoolean("location_disclosure_v2", true).apply();
                continueAction.run();
            })
            .setCancelable(false).show();
    }

    private void startTracking() {
        if (pendingTrackingToken == null) return;
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION);
            return;
        }
        Intent intent = new Intent(this, RiderLocationService.class).setAction(RiderLocationService.ACTION_START)
            .putExtra(RiderLocationService.EXTRA_TOKEN, pendingTrackingToken);
        pendingTrackingToken = null;
        try { startForegroundService(intent); sendRiderEvent(true, "Connecting to phone GPS…"); }
        catch (Exception error) { sendRiderEvent(false, "Could not start phone GPS. Open the app and try again."); }
    }

    private void positionMessage(String data) {
        try {
            JSONObject message = new JSONObject(data);
            if (!"position:request".equals(message.optString("type"))) return;
            String id = message.optString("requestId");
            if (id.length() > 80 || id.isEmpty()) return;
            pendingPositionId = id;
            if (hasLocationPermission()) findPosition(id);
            else requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, LOCATION_PERMISSION);
        } catch (Exception ignored) { /* Malformed web request. */ }
    }

    private void findPosition(String id) {
        LocationManager manager = (LocationManager) getSystemService(LOCATION_SERVICE);
        boolean gps = manager.isProviderEnabled(LocationManager.GPS_PROVIDER);
        boolean network = manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
        if (!gps && !network) { sendPositionError(id, "unavailable"); return; }
        AtomicBoolean done = new AtomicBoolean(false);
        Handler handler = new Handler(Looper.getMainLooper());
        Location[] best = { null };
        LocationListener listener = new LocationListener() {
            @Override public void onLocationChanged(Location fix) {
                if (done.get() || !fix.hasAccuracy() || fix.getAccuracy() < 0 ||
                    Math.abs(System.currentTimeMillis() - fix.getTime()) > 60000) return;
                if (best[0] == null || fix.getAccuracy() < best[0].getAccuracy()) best[0] = fix;
                if (fix.getAccuracy() <= 100 && done.compareAndSet(false, true)) {
                    manager.removeUpdates(this);
                    sendPosition(id, fix);
                }
            }
            @Override public void onProviderDisabled(String provider) { }
            @Override public void onProviderEnabled(String provider) { }
            @Override public void onStatusChanged(String provider, int status, Bundle extras) { }
        };
        handler.postDelayed(() -> {
            if (done.compareAndSet(false, true)) {
                manager.removeUpdates(listener);
                if (best[0] == null) sendPositionError(id, "timeout");
                else sendPosition(id, best[0]);
            }
        }, 11000);
        try {
            if (gps && checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED)
                manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0L, 0f, listener, Looper.getMainLooper());
            if (network) manager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 0L, 0f, listener, Looper.getMainLooper());
        } catch (SecurityException error) {
            done.set(true); manager.removeUpdates(listener); sendPositionError(id, "permission_denied");
        } catch (IllegalArgumentException error) {
            done.set(true); manager.removeUpdates(listener); sendPositionError(id, "unavailable");
        }
    }

    private void sendPosition(String id, Location fix) {
        try {
            JSONObject result = new JSONObject();
            result.put("type", "gohezoh:position:result"); result.put("requestId", id);
            result.put("latitude", fix.getLatitude()); result.put("longitude", fix.getLongitude());
            result.put("accuracyMetres", (double) fix.getAccuracy()); result.put("capturedAt", fix.getTime());
            sendEvent("gohezoh:position", result);
        } catch (Exception error) { sendPositionError(id, "invalid"); }
    }

    private void sendPositionError(String id, String code) {
        try { sendEvent("gohezoh:position", new JSONObject().put("type", "gohezoh:position:result")
            .put("requestId", id).put("errorCode", code)); }
        catch (Exception ignored) { }
    }

    private void sendRiderStatus() { sendRiderEvent(RiderLocationService.active, RiderLocationService.status); }

    private void sendRiderEvent(boolean active, String message) {
        try { sendEvent("kwik-parsel:native", new JSONObject().put("type", "rider:status")
            .put("active", active).put("onDuty", RiderLocationService.onDuty).put("message", message)); }
        catch (Exception ignored) { }
    }

    private void sendEvent(String name, JSONObject detail) {
        if (web == null || web.getUrl() == null || !allowed(Uri.parse(web.getUrl()))) return;
        web.evaluateJavascript("window.dispatchEvent(new CustomEvent('" + name + "',{detail:" + detail.toString() + "}))", null);
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == CAMERA_PERMISSION) {
            if (pendingCameraRequest != null) {
                if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
                    pendingCameraRequest.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                else pendingCameraRequest.deny();
                pendingCameraRequest = null;
            }
            return;
        }
        if (requestCode == NOTIFICATION_PERMISSION) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) startTracking();
            else { pendingTrackingToken = null; sendRiderEvent(false, "Allow notifications to go online"); }
            return;
        }
        if (requestCode == ADMIN_NOTIFICATION_PERMISSION) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
                enableAdminPoll();
            else sendAdminPollEvent("disabled", null, "Android notification permission was denied.");
            return;
        }
        if (requestCode == RIDE_NOTIFICATION_PERMISSION) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
                enableRidePush();
            else sendRidePushStatus();
            return;
        }
        if (requestCode != LOCATION_PERMISSION) return;
        if (!hasLocationPermission()) {
            pendingTrackingToken = null;
            if (pendingPositionId != null) sendPositionError(pendingPositionId, "permission_denied");
            pendingPositionId = null;
            sendRiderEvent(false, "Allow phone location to go online");
            return;
        }
        if (pendingTrackingToken != null) startTracking();
        if (pendingPositionId != null) { findPosition(pendingPositionId); pendingPositionId = null; }
    }

    @Override protected void onResume() { super.onResume(); if (web != null) sendRiderStatus(); }

    @SuppressLint("GestureBackNavigation") // API 33+ uses OnBackInvokedDispatcher above.
    @Override public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack(); else super.onBackPressed();
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FILE_CHOOSER && selectedFiles != null) {
            selectedFiles.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, data));
            selectedFiles = null;
        }
    }
}
