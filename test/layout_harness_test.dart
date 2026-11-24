import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout_harness.dart';

/// The harness itself must catch overflows hidden inside delayed entrance
/// animations (they are invisible, so unpainted, in the first frame). This
/// blind spot once let the setup summary overflow ship to a real phone.
void main() {
  testWidgets('detects an overflow inside a delayed FadeInUp', (tester) async {
    final List<String> issues = await layoutIssues(
      tester,
      () => Scaffold(
        body: FadeInUp(
          delay: const Duration(milliseconds: 400),
          child: const Row(
            children: <Widget>[
              Text('Main Challenge'),
              Text('Time management and procrastination'),
            ],
          ),
        ),
      ),
      width: 320,
      height: 640,
      scale: 1.3,
    );
    expect(issues.any((i) => i.contains('overflowed')), isTrue);
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}
