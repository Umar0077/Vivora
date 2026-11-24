# Personal Digital Twin: Gemini optimization and private testing

24 November 2026 (Asia/Karachi)

## Readiness

**Not fully ready for reliable AI delivery.** Authentication and model access work, and every required feature except weekly summaries has produced a validated real response during this investigation. Repeated runs remain inconsistent because Google returns HTTP 503 high-demand errors. No mocked or locally generated fallback answer is counted as a live success.

## Final real API run

Model: gemini-3.5-flash-lite. Direct Developer API generateContent with x-goog-api-key header, native responseSchema and minimal thinking. Durations include retries/backoff.

| Feature | Final validated outcome | Elapsed |
| --- | --- | --- |
| connection | Passed | 1.680 s |
| chatbot | Passed | 1.887 s |
| behavior_explanation | Failed: server | 10.184 s |
| recommendations | Failed: server | 9.710 s |
| adaptive_goals | Passed | 1.590 s |
| daily_summary | Passed | 16.113 s |
| weekly_summary | Failed: server | 7.816 s |
| study_plan | Passed | 2.443 s |

Earlier optimized runs produced validated recommendations in 1.934 s and behavioral explanations in 6.237 s (another run recovered after 503 in 17.558 s). Their final-run failures demonstrate inconsistent availability, not stable readiness. Study-plan latency improved from the earlier 20.756 s to 2.443 s in the final run; this is an observed sample, not a latency guarantee. Weekly summaries have not been successfully verified.

Final live harness: **6 of 10 checks passed**; behavior explanation, recommendations, weekly summary and complete cache reopening failed. The complete-cache check requires all generated artifacts and therefore could not pass without a weekly summary. Real invalid-key rejection passed. An earlier real-chat reopening check confirmed no additional API call; full persistence/race/account-isolation coverage also passes offline tests.

The harness sends **synthetic productivity records**, processed through the actual behavior engine, context builder, controller, provider and validators. Metrics retain provenance, units and recorded-day coverage; behavioral patterns and study preferences are included. It uses in-memory storage. Real account productivity data, Firebase login and Firestore round trips have **not** been exercised on a phone. These must not be confused with successful live Google requests.

## Changes and investigation

- Compact generation context removes redundant totals/ranges, limits patterns and top apps, and omits unrelated fields for goals/plans. Coverage, warnings, averages, goals and source labels remain. Typical generation prompts are approximately 2,600–2,700 characters. Original evidence objects and cache fingerprints are unchanged.
- Recommendations request at most three focused recommendations. Adaptive goals have their own request, button, loading/error state and existing evidence/bounds validation. Recommendation failure no longer blocks goals. Existing confirmation is still required before changing a goal.
- Concurrent recommendation/goal completion and late responses after account switching are regression-tested. Tests initially hit the intentional reservation guard; they now start the second request after reservation completes and verify both completion orders, without weakening the limiter.
- Connection diagnostics use dedicated system instructions instead of the chatbot's scope restrictions, avoiding false diagnostic-token mismatches.
- Each transport attempt is limited to 20 seconds. Transient 500/502/503/504 responses and stalled attempts can retry twice, with one- and two-second backoff. Overall deadlines remain bounded: chat/diagnostics 40 s, recommendations/goals 65 s, daily summary/study plan 55 s, weekly summary 75 s. A timeout closes the transport and prevents late retries. Invalid credentials and quota errors are not retried.
- Structured JSON, truncation/safety checks and semantic feature validators remain enabled. No schema-validation failure was substituted with fabricated content.
- Google explicitly returned high-demand errors. The modest prompt sizes, accepted native schemas and successful requests do not support a malformed request/authentication explanation. Minimal thinking is explicitly set as supported by [Google documentation](https://aistudio.google.com/docs/thinking).
- A real full-request probe of gemini-3.6-flash failed weekly summaries and study plans with 503s, then recommendations with quotaExceeded. It was **not enabled as an automatic fallback**. Earlier probes of other models also failed availability/quota checks. No unverified fallback is configured.

## Regression and build results

- Flutter analysis: no issues.
- Flutter suite: **319 passed, 0 failed**.
- Android app JVM tests: **39 passed, 0 failures/errors**.
- Combined offline regression total: **358 passed, 0 failed**. These are separate from the live harness results above.
- Debug APK: built successfully with the saved real key, explicitly authorized for private phone testing. Compiled-artifact inspection confirmed the saved key is included without displaying it.
- Private APK: build/private-testing/personal-digital-twin-private-debug.apk (185,556,110 bytes).
- The local key remains Git-ignored and untracked; build outputs are ignored. Nothing was committed or uploaded. Keep this keyed APK private; do not publish or share it. The existing placeholder-build helper remains available for preparing a key-free artifact.
- Existing Kotlin/Gradle deprecation warnings remain non-blocking.
- No Android device is attached, so instrumentation tests and actual phone workflows were not run.
- This optimization touched AI code/tests/tooling only. No Firebase configuration, package ID, authentication implementation, Firestore paths, user data, automatic tracking logic, six-module implementation or Personal Digital Twin branding was changed by this work. Offline regression coverage passed; live device behavior remains to be checked.

Evidence: build/gemini-live-results.json, build/gemini-live-before-attempt-timeout.json, build/gemini-alternate-results.json, gemini-final-tests.log, gemini-final-android-tests.log, gemini-final-analyze.log and gemini-private-build.log. These contain no API key.

## Physical phone checklist

1. Install the private APK as an update; do not uninstall or clear app data. With USB debugging authorized: adb install -r build/private-testing/personal-digital-twin-private-debug.apk. If signing incompatibility prevents an update, stop rather than uninstalling saved data.
2. Open Personal Digital Twin; check Light/Dark Mode, splash, headers and longer-name layout. Sign in with the existing account and verify profile, settings, historical records and saved goals.
3. Verify all six areas: activity tracking/sync, productivity logging/scoring, behavior insights, goals/focus, reports/reminders, and AI assistant. Compare dashboard/report values to existing data.
4. Grant necessary usage/activity/notification permissions. Check automatic tracking ON/OFF, foreground/background transitions, synchronization, focus timer and reminder delivery.
5. Run AI connection diagnostics. Ask about a known actual study/focus value and a follow-up. Verify period, source and coverage; missing activity must not be described as zero.
6. Generate recommendations and mark one helpful/dismissed. Independently request adaptive goals, including after a recommendation error. Verify realistic targets; cancel confirmation first, then apply only a deliberately chosen goal.
7. Generate daily, yesterday and weekly summaries. Compare deterministic statistics with the reports. Weekly generation remains a release blocker until it produces valid real output.
8. Generate a study plan, inspect preferred study time, session arithmetic, breaks and gradual daily target. Merely viewing the plan must not change the goal.
9. Reopen/restart and verify cached chat, advice, goals, summaries and plan remain. In airplane mode verify clear offline behavior and preserved cached results. Restore network and retry once.
10. Sign out and use a second account; verify no previous user's data, cached content or late response appears. Recheck the original account's saved data afterwards.
11. Record actual device response times and any Google overload/quota error. Recommendations/behavior explanations need repeated successful runs; weekly summary needs its first successful live verification before claiming full readiness.
