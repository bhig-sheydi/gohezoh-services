package org.gohezohservices.kwikparsel;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Build;
import android.os.Message;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;

import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONObject;

import java.util.Collections;
import java.util.concurrent.atomic.AtomicBoolean;

/** Trusted-site WebView. The native message bridge is available to the main frame only. */
public final class MainActivity extends Activity {
    private static final String HOME = "https://gohezoh-services.vercel.app";
    private static final int LOCATION_PERMISSION = 41;
    private static final int FILE_CHOOSER = 42;
    private static final int NOTIFICATION_PERMISSION = 43;
    private WebView web;
    private String pendingTrackingToken;
    private String pendingPositionId;
    private ValueCallback<Uri[]> selectedFiles;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        web = new WebView(this);
        setContentView(web);
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
        try {
            JSONObject message = new JSONObject(data);
            switch (message.optString("type")) {
                case "rider:status": sendRiderStatus(); break;
                case "rider:stop":
                    if (RiderLocationService.active) startService(new Intent(this, RiderLocationService.class).setAction(RiderLocationService.ACTION_STOP));
                    else sendRiderStatus();
                    new Handler(Looper.getMainLooper()).postDelayed(this::sendRiderStatus, 300);
                    break;
                case "rider:start":
                    String token = message.optString("trackingToken");
                    if (!token.matches("[0-9a-f]{64}")) { sendRiderEvent(false, "Phone tracking could not start"); return; }
                    pendingTrackingToken = token;
                    if (hasLocationPermission()) startTracking();
                    else requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, LOCATION_PERMISSION);
                    break;
                default: break;
            }
        } catch (Exception error) { sendRiderEvent(false, "Phone tracking request was invalid"); }
    }

    private boolean hasLocationPermission() {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            || checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
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
        String provider = manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ? LocationManager.GPS_PROVIDER
            : manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ? LocationManager.NETWORK_PROVIDER : null;
        if (provider == null) { sendPositionError(id, "unavailable"); return; }
        AtomicBoolean done = new AtomicBoolean(false);
        Handler handler = new Handler(Looper.getMainLooper());
        LocationListener listener = new LocationListener() {
            @Override public void onLocationChanged(Location fix) {
                if (!done.compareAndSet(false, true)) return;
                manager.removeUpdates(this);
                try {
                    JSONObject result = new JSONObject();
                    result.put("type", "gohezoh:position:result"); result.put("requestId", id);
                    result.put("latitude", fix.getLatitude()); result.put("longitude", fix.getLongitude());
                    result.put("accuracyMetres", (double) fix.getAccuracy()); result.put("capturedAt", fix.getTime());
                    sendEvent("gohezoh:position", result);
                } catch (Exception error) { sendPositionError(id, "invalid"); }
            }
            @Override public void onProviderDisabled(String provider) { }
            @Override public void onProviderEnabled(String provider) { }
            @Override public void onStatusChanged(String provider, int status, Bundle extras) { }
        };
        handler.postDelayed(() -> {
            if (done.compareAndSet(false, true)) { manager.removeUpdates(listener); sendPositionError(id, "timeout"); }
        }, 15000);
        try { manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper()); }
        catch (SecurityException error) { done.set(true); sendPositionError(id, "permission_denied"); }
    }

    private void sendPositionError(String id, String code) {
        try { sendEvent("gohezoh:position", new JSONObject().put("type", "gohezoh:position:result")
            .put("requestId", id).put("errorCode", code)); }
        catch (Exception ignored) { }
    }

    private void sendRiderStatus() { sendRiderEvent(RiderLocationService.active, RiderLocationService.status); }

    private void sendRiderEvent(boolean active, String message) {
        try { sendEvent("kwik-parsel:native", new JSONObject().put("type", "rider:status")
            .put("active", active).put("message", message)); }
        catch (Exception ignored) { }
    }

    private void sendEvent(String name, JSONObject detail) {
        if (web == null || web.getUrl() == null || !allowed(Uri.parse(web.getUrl()))) return;
        web.evaluateJavascript("window.dispatchEvent(new CustomEvent('" + name + "',{detail:" + detail.toString() + "}))", null);
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == NOTIFICATION_PERMISSION) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) startTracking();
            else { pendingTrackingToken = null; sendRiderEvent(false, "Allow notifications to go online"); }
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
