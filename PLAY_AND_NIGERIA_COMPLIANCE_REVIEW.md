# Kwik-Parsel launch review — 5 November 2026

This is a code and policy gap review, not a legal certification or Google Play approval.

## Implemented in this change

- A company applicant must submit an 11-digit owner NIN and capture the owner's face with the device camera. The UI warns non-owners not to take the photo.
- The owner NIN and selfie are stored on the pending application and in a private Supabase bucket. Only the applicant and Super Admin can read the selfie. A database trigger blocks company approval without both items.
- An Android WebView camera permission handler only grants video capture to the trusted site. The app now targets API 36, subject to an Android build and device test.
- The selfie is a camera capture, **not** an automated biometric identity or liveness check. Super Admin must compare it with submitted identity evidence. A camera feed alone cannot prove ownership.

## Blocks a Google Play submission

1. **Privacy policy:** There is no public, comprehensive policy in the app or site covering NIN, face photos, payments, precise/background location, recipients, retention, deletion, and third parties. Play requires a live URL and in-app link. [Play location policy](https://support.google.com/googleplay/android-developer/answer/9799150)
2. **Account deletion:** Signup is available, but no discoverable in-app and external account-deletion request flow was found. Both are required. [Play account deletion](https://support.google.com/googleplay/android-developer/answer/13327111)
3. **Background location declaration:** The Android manifest requests `ACCESS_BACKGROUND_LOCATION`. The rider terms page exists, but the native flow did not show a separate prominent disclosure before the Android permission request. Play requires a declaration, demonstration video, privacy policy and prominent disclosure. [Play background location](https://support.google.com/googleplay/android-developer/answer/9799150)
4. **Build verification:** Target API was raised from 35 to 36 because Play requires 36 for new submissions after 31 August 2026. Java is absent in this workspace, so the Android build and on-device camera/background-location behavior still need verification. [Play target API rule](https://support.google.com/googleplay/android-developer/answer/11926878)
5. **Data Safety and store review:** The Play Console Data Safety answers, permission declaration, screenshots, and valid reviewer login cannot be verified from this repository. These must match actual production behavior.

## Nigerian data-protection work before collecting owner identity at scale

- Document the lawful basis and give a clear privacy notice before taking NIN and face images. Limit access, retention and sharing; define a deletion and incident-response process. [Nigeria Data Protection Act 2023, sections 24–30 and 39–40](https://ndpc.gov.ng/wp-content/uploads/2024/03/Nigeria_Data_Protection_Act_2023.pdf)
- Perform a data privacy impact assessment for the combined identity and persistent rider-location processing, assess whether registration as a data controller of major importance applies, and get Nigerian counsel to review the final policy and workflow. [NDPC implementation guidance](https://ndpc.gov.ng/wp-content/uploads/2025/03/NDP-ACT-GAID-2025-MARCH-20TH.pdf)
- Decide how long rejected, revoked and abandoned applications retain NIN and face images. Reapplication now clears their application references, but old private storage objects still require a controlled cleanup process.
