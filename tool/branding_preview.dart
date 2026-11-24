// Run with: flutter test tool/branding_preview.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vivora/core/theme/app_theme.dart';
import 'package:vivora/features/splash/presentation/splash_screen.dart';
import 'package:vivora/features/auth/presentation/widgets/auth_header.dart';

void main() {
  testWidgets('render branding previews with the bundled font', (tester) async {
    final loader = FontLoader('PlusJakartaSans')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans.ttf'));
    await loader.load();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final dark in [false, true]) {
      for (final splash in [true, false]) {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
            home: RepaintBoundary(
              key: key,
              child: splash
                  ? const SplashScreen()
                  : const Scaffold(
                      body: SafeArea(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(24),
                          child: AuthHeader(),
                        ),
                      ),
                    ),
            ),
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/logo/logo.png'),
            key.currentContext!,
          ),
        );
        await tester.pump(const Duration(milliseconds: 1800));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/branding-preview/${splash ? 'splash' : 'auth'}-${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      }
    }
  });
}
