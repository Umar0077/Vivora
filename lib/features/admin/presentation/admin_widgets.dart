import 'package:flutter/material.dart';
import '../data/admin_models.dart';

String adminDay(DateTime? d) => d == null
    ? 'Not recorded'
    : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String adminHours(double? h) =>
    h == null ? 'Not recorded' : '${h.toStringAsFixed(1)} h';

class AdminPanel extends StatelessWidget {
  const AdminPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(subtitle!),
            ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class AdminMessage extends StatelessWidget {
  const AdminMessage(this.text, {super.key, this.retry, this.error = false});
  final String text;
  final VoidCallback? retry;
  final bool error;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(error ? Icons.cloud_off_outlined : Icons.info_outline, size: 32),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center),
        if (retry != null)
          TextButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
      ],
    ),
  );
}

class AdminLoading extends StatelessWidget {
  const AdminLoading({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading administrator data',
    child: Column(
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 16),
        for (var i = 0; i < 3; i++)
          Card(
            child: SizedBox(
              height: 80,
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 12,
                    width: 160,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class AdminMetricGrid extends StatelessWidget {
  const AdminMetricGrid(this.metrics, {super.key});
  final List<(String, String, IconData)> metrics;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final cols = c.maxWidth >= 900
          ? 4
          : c.maxWidth >= 440
          ? 2
          : 1;
      final width = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final m in metrics)
            SizedBox(
              width: width,
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(m.$3, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        m.$2,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(m.$1),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Only callers' explicitly selected fields are rendered. Raw documents and
/// unknown fields (which could contain secrets) are never dumped to the UI.
class AdminFields extends StatelessWidget {
  const AdminFields(this.fields, {super.key});
  final Map<String, Object?> fields;
  static String display(Object? value) {
    if (value == null) return 'Not recorded';
    if (value is bool) return value ? 'Yes' : 'No';
    if (value is num) {
      return value.isFinite && value >= 0 ? '$value' : 'Not recorded';
    }
    return adminText(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final e in fields.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.key, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 3),
              SelectableText(display(e.value)),
            ],
          ),
        ),
    ],
  );
}
