package org.gohezohservices.kwikparsel;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import java.util.UUID;

/** A local, user-requested alarm drill that does not create a server incident. */
public final class AdminAlarmTestReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        AdminAlarmStore.Credential credential = AdminAlarmStore.read(context);
        if (credential == null || !credential.registered) return;
        AdminAlarmNotification.show(context, UUID.randomUUID().toString(),
            "Kwik-Parsel alarm test", "Test only. No service incident occurred.");
    }
}
