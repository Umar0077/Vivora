# Personal Digital Twin: direct Gemini local testing

## Paste the key locally

File: `lib/core/config/gemini_config.dart`.
Replace `PASTE_YOUR_GEMINI_API_KEY_HERE` on line 4 with the key from Google AI Studio, keeping the quotes. Save, then fully restart the application (a hot reload is insufficient for a compiled constant).

The configuration file is included in Git with a placeholder, so a fresh checkout builds without creating any configuration file. Never commit a real key. The separate `gemini_config.example.dart` also contains placeholders only. Historical verification notes below describe the earlier, ignored-key local testing setup; the GitHub delivery uses the tracked placeholder.

Do not put the key in this document, logs, issues, screenshots, or conversation messages. Do not commit or publicly distribute any APK containing a real key. The latest user-authorized private testing APK contains the saved key; keep it local and private. See GEMINI_LIVE_REPORT.md for its location and remaining blockers.

## Transport and model

The application now uses `GeminiAiProvider` and the direct Google Gemini Developer API, with no Firebase AI Logic dependency.
Model: `gemini-3.5-flash-lite`.
Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent`.
Authentication: `x-goog-api-key` HTTP header; the key never appears in the URL.

Requests carry `systemInstruction`, user/model `contents`, and `generationConfig`. Structured requests set `responseMimeType: application/json` and `responseSchema`. Responses are read from candidate content parts; thinking parts, blocked output, truncation, missing text, and malformed JSON are rejected. Existing per-feature validators still check evidence, bounds, allowed metrics, and goal suggestions before display or persistence. HTTP error bodies and raw exceptions are never logged or returned to the UI.

Verified against Google's [model documentation](https://aistudio.google.com/docs/models/gemini-3.5-flash-lite), [generateContent reference](https://aistudio.google.com/api-reference/generate-content/generate-content), and [API-key header examples](https://aistudio.google.com/docs/get-started). Account-specific model access and quota require a live request after the key is saved.

## Shared feature wiring

All existing AI paths use the single provider wired in `AiAssistantModule`: chatbot and behavioral explanations, personalized recommendations and adaptive goal suggestions, daily and weekly summaries, study plans, and connection diagnostics. They all read the same local configuration.

Firebase Auth, Firestore storage/collection paths, App Check initialization for Firebase services, account-isolation checks, privacy controls, local rate limits, caching, and six-module functionality remain in place. Personal Digital Twin branding is preserved. Firebase App Check is not used to authenticate direct Gemini calls.

A blank or placeholder key produces a friendly not-configured state without contacting Google. Other modules and existing cached results remain usable.

## Pre-key verification

- Flutter analysis: passed, no issues (`gemini-analyze.log`).
- Full automated suite: all 309 tests passed (`gemini-tests-final.log`). The first run exposed an outdated UI wording expectation; it was corrected and the entire suite rerun successfully.
- Focused provider/controller tests: all 71 passed (`gemini-focused-tests.log`).
- Debug APK with placeholder configuration: built successfully (`gemini-debug-build.log`). Output: `build/app/outputs/flutter-apk/app-debug.apk`.
- Compiled Android branding/package check: Personal Digital Twin / com.example.vivora.
- Git check: local key file ignored by .gitignore and absent from tracked files; example contains only the placeholder.
- Existing Kotlin support warning remains non-blocking. No Firebase configuration or service upgrade was required for this migration.

At the initial pre-key checkpoint, no live API requests had been performed. See the live verification update below for subsequent results. Real authentication, model access, generated outputs, response times, and actual-account workflows are unverified until the user confirms the key is saved. Automated tests use simulated HTTP responses and must not be mistaken for live Gemini results.

## Live verification update

Live testing was performed. See [live results and device checklist](GEMINI_LIVE_REPORT.md). Authentication, chat, daily summaries and study plans succeeded, but server overload blocks full readiness. The saved key remains Git-ignored. A private debug APK now contains it, as explicitly authorized for local phone testing; it must not be distributed publicly.

## Original next-phase plan

Check live connectivity and model access, then execute chat, recommendations/goals, daily and weekly summaries, study plan generation, and structured validation while recording response times without printing credentials. Check for a connected Android device. Actual user-data workflows can only be claimed when tested with authenticated app data; synthetic context is not actual user productivity data.

Run analysis/tests again after any fixes. Use the placeholder build helper for any shareable APK. The explicitly authorized private testing APK uses the saved local key. Physical testing and any unavailable workflows must be reported separately.
