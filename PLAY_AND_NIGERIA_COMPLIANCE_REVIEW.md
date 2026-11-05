# Kwik-Parsel launch review — 5 November 2026

This is a code and policy gap review, not a legal certification or Google Play approval.

## Implemented in this change

- A company applicant must submit an 11-digit owner NIN and capture the owner's face with the device camera. The UI warns non-owners not to take the photo.
- The owner NIN and selfie are stored on the pending application and in a private Supabase bucket. Only the applicant and Super Admin can read the selfie. A database trigger blocks company approval without both items.
- An Android WebView camera permission handler only grants video capture to the trusted site. The app now targets API 36, subject to an Android build and device test.
- The selfie is a camera capture, **not** an automated biometric identity or liveness check. Super Admin must compare it with submitted identity evidence. A camera feed alone cannot prove ownership.

## Current submission status

1. **Privacy policy:** A public HTML policy now covers the app's main data flows and is linked within the web app. Its production URL and final legal wording still require review. [Play location policy](https://support.google.com/googleplay/android-developer/answer/9799150)
2. **Account deletion:** In-app and browser request paths now exist, with a Super Admin queue. Requests must actually be completed and associated data removed or lawfully retained; a request form alone is not completion. [Play account deletion](https://support.google.com/googleplay/android-developer/answer/13327111)
3. **Background location:** The Android manifest requests `ACCESS_BACKGROUND_LOCATION`; a separate native disclosure is now shown before rider location permission/settings. Play still requires its declaration and demonstration video. [Play background location](https://support.google.com/googleplay/android-developer/answer/9799150)
4. **Build verification:** Target API 36 is configured. Java is absent locally; a GitHub Actions Android build and physical-device camera/location test must pass. [Play target API rule](https://support.google.com/googleplay/android-developer/answer/11926878)
5. **Data Safety and store review:** The Play Console answers, permission declaration, screenshots, reviewer login and actual device behavior remain external checks. See `PLAY_CONSOLE_SUBMISSION.md`.

## Nigerian data-protection work before collecting owner identity at scale

- Document the lawful basis and give a clear privacy notice before taking NIN and face images. Limit access, retention and sharing; define a deletion and incident-response process. [Nigeria Data Protection Act 2023, sections 24–30 and 39–40](https://ndpc.gov.ng/wp-content/uploads/2024/03/Nigeria_Data_Protection_Act_2023.pdf)
- A draft impact assessment now covers identity and persistent rider-location processing. The company must decide whether registration as a data controller of major importance applies and have Nigerian counsel/DPO review the final policy and workflow. [NDPC implementation guidance](https://ndpc.gov.ng/wp-content/uploads/2025/03/NDP-ACT-GAID-2025-MARCH-20TH.pdf)
- Reapplication clears identity references. Super Admin now has a controlled action to remove unlinked verification files older than 30 days; it must be run and monitored. Retention for approved applications still needs a decision.
