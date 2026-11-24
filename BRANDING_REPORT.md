# Personal Digital Twin branding update

Date: 24 November 2026.

## Scope and audit

This is a branding-only update. The user explicitly confirmed that the current Gemini integration must remain unchanged.

All app-authored, user-facing occurrences of the former product name found in the source audit have been replaced, including authentication, setup, dashboard, profile/settings/About, assistant labels and prompts, tracking guidance, notifications, errors, and documentation. Screens with no previous product-name text retain their existing descriptive titles.

Android, iOS, web, Windows, Linux, and macOS display metadata now use **Personal Digital Twin**. Both APKs' compiled manifests independently confirms this application label and the unchanged package ID.

Remaining old-name references are intentional compatibility identifiers: Dart imports/package name, Android package and native classes, Firebase project/configuration, method channels, saved preference keys, diagnostic/environment keys, internal executable/product names, historical development logs, and a regression-test input. Stored conversations and user-authored content are not rewritten.

## Logo and launch experience

The original logo asset was symbol-only: there was no embedded old-name text to remove. Its symbol and palette remain unchanged in the launcher icon and app. Flutter's splash now pairs it with the full name in the existing Plus Jakarta Sans typography, with wrapping and theme-aware contrast. Android's native launch backgrounds show the same original symbol in Light/Dark Mode. iOS launch assets and title were updated; its background and title use adaptive system colors.

A transparent horizontal wordmark is supplied in [assets/logo/personal_digital_twin_wordmark.png](assets/logo/personal_digital_twin_wordmark.png). The app uses real text with its original symbol so the name adapts to accessibility sizing and each theme.

Image-generation prompt: Create a professional transparent horizontal brand lockup using the supplied symbol-only logo. Preserve the symbol shapes, colors and rounded pastel square at left. Add only the exact name Personal Digital Twin at right, arranged as Personal / Digital Twin, in bold rounded geometric sans typography close to Plus Jakarta Sans. Preserve the blue-purple-teal harmony, allow generous spacing, and add no tagline or new icon.

## Compatibility

No branding changes were made to Firebase configuration, authentication, Firestore paths, existing accounts, or the Gemini provider/model/API integration. Existing internal identifiers were retained. All six modules retain their behavior; only branding strings and display presentation changed.

Old own-app activity entries resolve to the current display name by their unchanged package ID. Their raw stored name, package ID, duration and serialization remain unchanged; a regression test verifies this.

## Verification

| Check | Result |
| --- | --- |
| `flutter analyze` | Passed, no issues |
| `flutter test --reporter expanded` | Passed: all 292 existing tests |
| Focused branding tests | Passed: 2 additional tests (historical data preservation and About dialog layouts) |
| Branding visual preview | Passed; light/dark splash and login header inspected with the bundled font |
| `flutter build apk --debug` | Passed |
| `flutter build apk --release` | Passed |
| APK metadata, debug and release | Label Personal Digital Twin; package com.example.vivora |

No overflow or truncation was reported by the completed layout checks, and no branding inconsistency was found in the inspected previews. Device-specific launcher behavior still requires the manual check below.

Build outputs: [debug APK](build/app/outputs/flutter-apk/app-debug.apk) and [release APK](build/app/outputs/flutter-apk/app-release.apk).
Logs: `analyze-branding.log`, `test-branding.log`, `test-branding-specific.log`, `test-branding-preview.log`, `build-branding-debug.log`, and `build-branding-release.log`.

The build reports an existing Kotlin support deprecation warning; it does not prevent either APK from building. Dependency and architecture upgrades were outside this branding-only scope.

Light/dark splash and login-header screenshots are reproducible with:
`flutter test tool/branding_preview.dart`
They are written to `build/branding-preview/`. Automated layout checks cover widths 320–480, font scaling through 1.75, and both themes, including a focused check that opens the renamed About dialog.

## Remaining manual checks

- Install the APK on a physical Android device. Confirm launcher label/icon, cold launch in each theme, and notification display. Launchers may truncate long labels according to their own grid settings.
- Smoke-test sign-in with an existing account, saved data across all six modules, background reminders, and a live Gemini response. No connected physical device/live account verification was performed during this branding task.
- iOS/macOS native launch and display metadata require verification on Apple hardware; desktop/web builds were not requested or run.
- The existing release signing configuration uses the debug key. The produced release APK is suitable for local validation; store distribution still requires production signing.
