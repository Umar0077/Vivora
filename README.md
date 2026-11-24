# Personal Digital Twin

Personal Digital Twin helps students understand their activity, recognize behavior patterns, track productivity, manage goals, review reports, and get contextual AI assistance.

The app supports Light and Dark Mode. Its original blue, teal, purple, and green symbol is preserved; the interface and launch experience use the Personal Digital Twin name.

## Development

Run `flutter pub get`, then `flutter run` with the existing Firebase configuration.

Verify changes with:

```sh
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

The Dart package name, Android application ID, Firebase project, storage paths, and platform channels retain their existing internal identifiers for compatibility. The public product name is Personal Digital Twin.

For local AI testing, replace the placeholder on line 4 of the included `lib/core/config/gemini_config.dart` with your Google AI Studio key. This configuration file is tracked: never commit your real key. Fully restart the app after saving. Do not share or commit builds containing a real key. No ENV file, Dart define, Firebase AI Logic, or backend is needed for Gemini.

See [current Gemini testing setup](GEMINI_TESTING.md), [historical AI integration handover](AI_DELIVERY_REPORT.md) and [branding verification](BRANDING_REPORT.md).
