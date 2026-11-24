# Personal Digital Twin: weekly summary final verification

25 November 2026, Asia/Karachi. This update supersedes the weekly-summary verdict and automated counts in the historical session report below.

## Latest verdict

**Weekly Summary live generation, validation, display, caching and restart persistence have now passed through the actual Android emulator interface.** A real Gemini response completed in 3.157 seconds on the first HTTP attempt. It was accepted by the production validator and rendered as AI-generated text, separately from deterministic weekly statistics. No mock or local fallback is counted as that success.

Academic demonstration is ready using the verified saved AI summary and the clearly labeled local statistical summary. **Fresh online regeneration is still subject to intermittent Google HTTP 503 availability**; it is not guaranteed. A bounded repeat failed externally, but preserved the successful cached summary and local statistics.

## Investigation and root-cause limits

Daily and weekly use the same direct provider, native JSON schema and summary parser. Weekly uses the week analysis rather than the selected day, a larger output allowance (1100 versus 800 tokens), and a 75-second total deadline rather than 55 seconds. Neither sends raw historical daily documents: the context builder already calculates aggregates with units, dates and observation counts.

Two distinct failure classes were found:

1. **Confirmed external service failure:** prior and repeat live HTTP 503 responses from Google. Three attempts remain the maximum; no authentication/quota retries or unverified fallback model were introduced.
2. **Reproduced prompt/validation mismatch:** the validator rejects any digit in factual prose, including harmless date headings or “7 days,” while the old weekly prompt explicitly requested a summary for seven days ending a numeric date. The strengthened prompt now explicitly forbids copying dates/counts into qualitative prose and directs the model to use “this week.” Regression cases reproduce date-heading and fabricated-score rejection with specific safe categories.

The historical rejected response body was deliberately never retained. **Its exact offending field/text cannot be recovered or honestly identified retroactively.** The mismatch above is a reproducible failure path, not a claimed forensic recovery of that response. New diagnostics report only fixed categories such as `summary_numeric_headline` or `weekly_structure_highlights`, never response bodies, keys, user identifiers or arbitrary exception details. The new live response logged `PDT_WEEKLY validated`.

## Exact changes

- `lib/features/ai_assistant/domain/ai_prompts.dart`: weekly-only prompt distinguishes qualitative AI commentary from calculated facts; forbids date/count copying and numbered prose; describes missing observations as unknown. Weekly projection omits advice feedback, setup preferences, score associations and logging streak while preserving period bounds, source-grouped aggregates, units, observation counts, goals, trends, detected patterns, unavailable metrics and tracking/privacy warnings. Daily prompt behavior preserved.
- `lib/features/ai_assistant/domain/ai_response_validator.dart`: incomplete/wrongly typed weekly arrays fail safely rather than silently becoming a successful partial summary; explicit empty arrays remain supported. Numerical factual claims still fail. Added fixed field-specific rejection categories. No fabricated statistics are substituted or accepted to force a pass.
- `lib/features/ai_assistant/application/ai_assistant_controller.dart`: safe debug-only weekly validation outcome/category. Existing account guards, caching, persistence, deadlines and transport retries remain unchanged.
- `lib/features/ai_assistant/presentation/ai_assistant_screen.dart`: always shows **Local statistical weekly summary — not AI-generated**, exact date range, existing calculated facts and missing-data caveat. On error it explains AI commentary is unavailable. Any previously validated AI result remains separately labeled and dated.
- Kept the already-small five-field structured schema: headline, overview, highlights, improvements, nextSteps. No unnecessary schema redesign or model change. Model remains `gemini-3.5-flash-lite` with the existing central key.
- Added four tests covering numeric/date rejection categories, incomplete/empty structures, retained weekly context, and statistical fallback after service failure. Updated the previous malformed-array test to expect explicit typed failure instead of silent discard.

## Actual emulator verification

Existing Pixel_7/API 36 emulator and signed-in dedicated test account; normal app APK installed with `adb install -r`, no app data cleared. Test history remains the previously authorized synthetic fixture plus manual/focus entries, not real personal habits.

| Test | Actual result | Elapsed time | Attempts | Verdict |
| --- | --- | ---: | ---: | --- |
| Weekly generation | HTTP 200; validator accepted; real AI prose rendered | 3.157 s | 1 | Pass |
| Correct facts/date range | November 19–25; score 66/100, study 2h45m, manual focus 1h45m, sleep 7h26m, 7/7 logs; calculated facts separate from AI | No separate API call | 0 | Pass |
| Privacy/context | AI explains manual logs and automatic tracking OFF; discusses recorded study/sleep patterns | Included above | Included above | Pass |
| Restart persistence/cache | Same AI text and generation time reloaded after force-stop/relaunch; zero provider requests after restart | No API latency | 0 | Pass |
| Offline regeneration | Offline classification; cached valid AI and local statistics retained; connectivity restored | 0.040 s | No HTTP response | Pass negative test |
| Bounded real repeat | HTTP 503 on all attempts; safe local statistical fallback and cached AI retained | 10.639 s total | 3 | External failure; fallback passed |

The local summary is never relabeled AI-generated, never replaces the AI cache with fabricated prose, and uses the existing analysis service. Observation counts and missing-data messages prevent absent records from becoming zeros. Existing no-data guards prevent empty-history requests; automated coverage remains separate from live verification.

## Final verification/build

- `flutter analyze`: **no issues**, 7.2 seconds.
- `flutter test`: **327 passed, 0 failed**, 5m57s in the final run.
- Relevant Android application unit tests: **39 passed, 0 failed, 0 errors**, Gradle BUILD SUCCESSFUL (26 seconds).
- Total: **366 application automated tests passed**. An initial run exposed the obsolete malformed-array expectation; it was corrected and the entire suite rerun successfully.
- Debug build: passed, Gradle 27.8 seconds; final normal application target `lib/main.dart`, existing configured real key. Installed and smoke-tested on the emulator. Only test-file formatting/expectation changes followed the successful app build; no later application source changes.
- Private APK SHA-256 matches the built app: `A0872917D3006B460381196A6B91024CEF7373BB8A9D0C9F26D60019D09DFD14`.

Final private APK:
`C:\Users\aliah\OneDrive\Desktop\Ibrahims FYP\vivora\build\private-testing\personal-digital-twin-private-debug.apk`

Key and build output remain Git-ignored; key is not distributed in source or reports. APK contains the real key only for the authorized private local test. Nothing committed or publicly distributed.

## Evidence and remaining issues

Evidence directory: `C:\Users\aliah\OneDrive\Desktop\Ibrahims FYP\vivora\build\emulator-testing`.

New files: `weekly_fix_live-result.json/.png/.xml/.log`, `weekly_fix_persisted.*`, `weekly_fix_persistence.json`, `weekly_local_offline-result.json`, `weekly_fix_repeat-result.json`, `weekly-final-analyze.log`, `weekly-final-tests.log`, `weekly-final-android.log`, `weekly-build.log`.

Google's intermittent 503 remains an external availability issue. The historical rejection's exact payload remains unknowable; the current prompt and strict validation passed live. The previously documented paused Home live-capture presentation limitation and untested notification/second-account workflows were outside this exclusively weekly-summary task. No hardware tests repeated, no other modules redesigned, no Firebase configuration/rules or branding changed.

For the demonstration: install the private APK without clearing data; use the dedicated account; open Assistant → Summaries → Weekly. Show the successful cached AI summary and separately labeled statistics. Generate again only with connectivity; if Google returns 503, explain the local/cached view accurately. Do not publish the keyed APK.

---

# Historical emulator session report (superseded where noted above)
# Personal Digital Twin: final emulator test report

25 November 2026, Asia/Karachi. Test window approximately 24 November 22:39 to 25 November 01:10, including sign-in/build time.

## Final verdict

**Not fully ready for an all-features academic demonstration.** Real Gemini chat, recommendations, daily summaries, adaptive goals, study plans and behavioral explanations passed through the application interface. Weekly summary did not pass: repeated HTTP 503 responses, plus one HTTP 200 response rejected by validation. HTTP success alone is not counted as feature success.

Four reproduced application defects were fixed. Final analysis and all **362 application tests passed**. The normal private debug APK was rebuilt and installed without clearing data. Firebase configuration, rules, package identifiers and API key remain unchanged.

## Environment and test data

- Existing Pixel_7 Google Play AVD; Android 16/API 36, x86_64, 2 GB RAM; emulator-5554. No new image downloaded.
- App com.example.vivora, version 1.0.0 (1), minimum SDK 24, target SDK 36.
- User signed in directly and authorized sample data in a dedicated test account. Completed the six-step profile setup as Emulator Test Student.
- Seven marked synthetic daily logs for November 18–24 were added only where missing. Firestore server reads verified all seven. November 25 was entered through the actual manual logging screen.
- Synthetic inputs used real Firebase repositories, behavior/scoring services and Gemini requests. They are not real personal habits or physical sensor accuracy evidence. No production records were manufactured or overwritten.

## Actual live AI results

Configured model: `gemini-3.5-flash-lite`, direct Gemini Developer API, existing centralized local key. Successful calls establish authentication and model accessibility during this session. All rows below used the actual application interface; no mock or locally generated fallback is counted.

Times are provider elapsed time including retries, except diagnostics (UI-observed). Attempts are HTTP attempts within the named action.

| Feature / expectation | Actual result | Time | Attempts | Status |
| --- | --- | ---: | ---: | --- |
| Diagnostics: authenticate and validate verification response | Successful diagnostic displayed | 14.772 s UI-observed | Not instrumented | Pass |
| Chat: today's productivity | Correct recorded facts and period | 9.677 s | 3: 503,503,200 | Pass |
| Chat: biggest distractions | Explained missing app evidence without inventing apps | 6.332 s | 2: 503,200 | Pass |
| Chat: improve focus | Real focus advice displayed | 20.742 s | 2: 503,200 | Pass |
| Chat: tomorrow's routine | Real routine displayed | 10.185 s | 1: 200 | Pass |
| Behavioral explanations | Explained actual detected patterns from test history | 3.189 s | 1: 200 | Pass |
| Recommendations | Validated prioritized study/focus/sleep cards and recorded supporting evidence | 5.492 s | 2: 503,200 | Pass on final retry |
| Independent adaptive goals | Worked while recommendation generation had failed | 1.466 s | 1: 200 | Pass |
| Goals after precision fix | Correct recorded mean of 2h45m displayed | 3.851 s | 2: 503,200 | Pass |
| Daily summary | Valid JSON, qualitative prose, deterministic facts, manual-data/privacy explanation | 8.416 s | 3: 503,503,200 | Pass |
| Weekly instrumented retry | Exhausted service retries | 11.323 s | 3: 503 | Fail/external blocker |
| Weekly final request | HTTP 200 but content rejected by validation | 1.803 s | 1: 200 | Fail, not a successful summary |
| Weekly validation retry | Exhausted service retries | 8.714 s | 3: 503 | Fail/external blocker |
| Study plan | Valid 3h/day, three 60-minute sessions, 15-minute breaks, flexible priorities, morning preference | 1.880 s | 1: 200 | Pass |
| Offline chat | Offline error, preserved conversation, usable UI | 0.103 s | No HTTP response | Pass negative test |

Earlier recommendations failed after 11.484 s and three HTTP 503 responses. Earlier uninstrumented daily/weekly actions showed temporary-service errors. They are not successful generations.

### Actions, validation and persistence

- Successful cards were accepted by production validators. Invalid weekly content was withheld. Its response body was not logged; the precise offending field is unestablished. Google availability alone is therefore not asserted as the cause of every weekly failure.
- Native JSON schema generation, bounded retries and validation remain intact. No unverified fallback model was introduced and no validation was weakened.
- Recommendations: Helpful, Not helpful, Done and Dismiss exercised. Completed advice moved to Recent advice. Separate server-only audit of every feedback field was not performed.
- Goal Cancel left target unchanged; Apply saved 7.5-hour sleep target, reflected in profile. No automatic goal changes occurred.
- Accepted study plan persisted after process restart, including Plan accepted state. Daily summary persisted with correct stale-data warning after new records. Focus history persisted. Conversation history was inspected after tab navigation and restart.
- Insufficient history showed an appropriate empty state before fixture creation.
- Live negative coverage: HTTP 503 recovery/exhaustion, rejected output and offline error. HTTP 429, timeout, malformed/empty output, cancellation, repeated-request guards and account isolation have automated coverage, not intentionally induced live failures or a second-account emulator test.
- Weekly summary still needs a validated successful render. Avoid excessive retries while Google is returning 503.

## Six-module regression

| Module | Result |
| --- | --- |
| 1. User management/personalization | Login, six-step setup, profile, appearance, goal confirmation and authenticated session across updates passed. No second-account live test. |
| 2. Activity monitoring/data collection | Manual log saved; sub-minute focus session correctly discarded; longer session saved one minute; pause/resume and restart history passed. Tracking checks below. |
| 3. Behavior/habit analysis | Actual engine processed seven-day fixtures, manual provenance, patterns, evidence levels and partial coverage. Midnight cache defect fixed and tested. |
| 4. Productivity scoring | November 24 score 74 agrees with 73.75 calculation and inspected components. November 25 partial score 63 excludes missing weights, with 65% coverage. |
| 5. Analytics/reports | Dashboard, weekly/monthly reports, historical detail and charts inspected. Date coverage and recorded statistics checked. |
| 6. AI assistance | Validated live results for requested categories except weekly summary. Partial pass, not unconditional readiness. |

## Tracking controls and privacy

- Settings switch visible; OFF persisted after updates/restarts. No Sync Now needed.
- Usage Access granted through Android's app-specific UI. Physical Activity stayed denied and displayed Not allowed correctly. No physical sensor accuracy claim.
- ON: native successful-sync timestamp advanced approximately 604 seconds across two foreground intervals, consistent with five-minute updates.
- OFF: native timestamp unchanged over 845.725 seconds (over 14 minutes); historical reports/logs remained available.
- Resuming ON produced real collection and Saved to cloud. Stored local intervals were `[1795546773068,1795548673752]` and `[1795550573948,null]`, excluding approximately 31.7 minutes OFF. Usage increased from about 25 to 26 minutes, not by the disabled period, with explicit partial-coverage notice.
- Restored tracking OFF and appearance System default. AI output respected OFF and manual/previous-record provenance.
- After restart while paused, Home's live-capture panel can show No data yet/Never until collection resumes; historical data remains in reports and AI facts. This is a presentation limitation, not deleted history.

## Bugs fixed

| Reproduced defect/root cause | Source | Retest |
| --- | --- | --- |
| Goal mean rounded to tenths before minute formatting | `lib/features/ai_assistant/domain/ai_response_validator.dart` | Exact-mean serialization regression; regenerated live card displays 2h45m |
| Good Morning hardcoded at night | `lib/features/dashboard/presentation/widgets/greeting_header.dart` | Hour-based greeting implemented; rebuilt home checked. Evening branch not independently time-simulated |
| Paused permission labels reused prompt guards and falsely implied permission granted | `lib/features/activity_monitoring/presentation/widgets/tracking_status_card.dart` | Widget regression and emulator Not allowed state passed |
| Insights cached yesterday after midnight while Reports used today | `lib/features/insights/services/insights_service.dart` | Two rollover regressions, cached load and incoming capture, passed; current-day facts checked after rebuild |

Debug-only provider metadata records format/status/attempt/elapsed time without credentials, headers, bodies or user IDs. Local fixture/evidence tooling is opt-in and excluded from the normal main entry point.

## Branding, stability and Firebase

Personal Digital Twin visible on inspected onboarding/login, setup, home, settings, assistant, reports and profile. Longer headings/cards fit inspected screenshots in system/light and dark appearance. Branding/responsive automated tests passed. Internal IDs preserved. Live notification delivery/artwork, every registration variant and About screen were not newly verified.

Captured sanitized logs had no matching FATAL EXCEPTION, Unhandled Exception, RenderFlex overflow or Firestore PERMISSION_DENIED. This is scoped to captured intervals.

Firebase authentication and server-backed profile/history retrieval worked. Goal, focus, plan and summary restart persistence worked; this is not an independent server-only audit of every locally cached AI document. No configuration/security-rule changes or data clearing occurred.

## Automated verification and final APK

- `flutter pub get`: passed.
- `flutter analyze`: no issues, 11.9 seconds.
- `flutter test`: **323 passed, 0 failed**, approximately 4m17s.
- `android/gradlew.bat -p android :app:testDebugUnitTest`: **39 passed, 0 failed, 0 errors**, BUILD SUCCESSFUL. Count only app-owned XML results; unrelated plugin artifacts excluded.
- Combined: **362 passed, 0 failed**.
- `flutter build apk --debug -t lib/main.dart`: passed, Gradle 24.6 seconds. Existing nonfatal toolchain deprecation warnings remain.
- Normal APK installed with `adb install -r`, no data reset. Private copy hash matches latest built APK.

Private testing APK:
`C:\Users\aliah\OneDrive\Desktop\Ibrahims FYP\vivora\build\private-testing\personal-digital-twin-private-debug.apk`

Contains the existing real key as explicitly authorized for private local testing. Configuration and APK are Git-ignored; configuration is untracked. Nothing committed or publicly distributed. Not a production distribution build.

## Evidence

`C:\Users\aliah\OneDrive\Desktop\Ibrahims FYP\vivora\build\emulator-testing`

PNG/XML screenshots, sanitized logs, per-action timing/result JSON, tracking snapshots/intervals, fixture server confirmation and final build/test logs. Key examples: recommendations_final_ui, weekly_final_ui, weekly_validation_retry_ui, goals_precision_final, daily_persisted_final, plan_acceptance_persisted, focus_persisted_restart, chat_persisted_restart, tracking_resumed_final, tracking_restored_off.

## Exact remaining steps and readiness answers

1. Weekly summary is NOT successfully verified. When service capacity recovers, use Assistant → Summaries → Weekly → Generate weekly summary. Require validated rendered prose, correct date range/facts and cache persistence. If rejected again, investigate a safe validation category without logging private content or weakening factual validation.
2. For private phone review, install the APK over the existing app without clearing data; sign in to the dedicated test account; inspect saved chat, accepted plan, daily summary, sample goal and focus history. Do not publish the keyed APK.
3. Notification delivery and second-account live isolation remain unverified workflows. Physical usage/sensor accuracy, battery restrictions and Xiaomi behavior were deliberately not repeated, per request.

All six modules have tested usable paths, but not all required AI workflows pass. Firebase works for observed operations; tracking controls pass; inspected branding passes. Four defects fixed; weekly-summary failure and paused live-panel presentation limitation remain. Full academic readiness is **not declared** until weekly summary is successfully validated.

