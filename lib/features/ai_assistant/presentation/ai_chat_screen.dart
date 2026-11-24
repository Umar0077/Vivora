import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/vivora_palette.dart';
import '../../../core/widgets/app_bar_title.dart';
import '../application/ai_assistant_controller.dart';
import '../domain/ai_models.dart';
import 'widgets/ai_widgets.dart';

/// Chat with Personal Digital Twin AI. Answers use the student's recorded data for today and
/// the last 7 days; only the last few messages are sent as conversation
/// history.
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key, required this.controller});

  final AiAssistantController controller;

  static const List<String> suggestedQuestions = <String>[
    'How productive was I this week?',
    'How much time did I spend studying?',
    'Which habits should I work on?',
    'How can I reduce distractions?',
    'Am I improving compared with last week?',
    'Can you suggest a study plan?',
  ];

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;

  AiAssistantController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    _input.addListener(() => setState(() {}));
    unawaited(c.open());
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(jump: true));
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    final int count = c.chat.length + (c.chatSending ? 1 : 0);
    if (count != _lastCount) {
      _lastCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    }
  }

  void _toBottom({bool jump = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final double end = _scroll.position.maxScrollExtent;
    if (jump || MediaQuery.of(context).disableAnimations) {
      _scroll.jumpTo(end);
    } else {
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _send([String? text]) async {
    final String q = (text ?? _input.text).trim();
    if (q.isEmpty || c.chatSending || c.chatClearing) return;
    _input.clear();
    await c.sendChat(q);
  }

  Future<void> _confirmClear() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Clear chat history?'),
        content: const Text(
          'All messages with Personal Digital Twin AI will be deleted from your account. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.palette.danger,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await c.clearChat();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not clear the chat. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final List<ChatMessage> messages = c.chat;
        final VivoraPalette p = context.palette;
        return Scaffold(
          backgroundColor: p.background,
          appBar: AppBar(
            title: const AppBarTitle('Ask Personal Digital Twin AI'),
            actions: <Widget>[
              if (messages.isNotEmpty)
                IconButton(
                  tooltip: 'Clear chat',
                  onPressed: c.chatSending || c.chatClearing
                      ? null
                      : _confirmClear,
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: messages.isEmpty && !c.chatSending
                      ? _EmptyChat(onAsk: _send)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(
                            Space.lg,
                            Space.md,
                            Space.lg,
                            Space.md,
                          ),
                          itemCount: messages.length + (c.chatSending ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i == messages.length) {
                              return const _TypingBubble();
                            }
                            return _Bubble(message: messages[i]);
                          },
                        ),
                ),
                if (c.chatError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.lg,
                      0,
                      Space.lg,
                      Space.sm,
                    ),
                    child: AiErrorBanner(
                      failure: c.chatError!,
                      onRetry: c.canRetryChat ? c.retryChat : null,
                    ),
                  ),
                _InputBar(
                  controller: _input,
                  sending: c.chatSending || c.chatClearing,
                  onSend: _send,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onAsk});
  final void Function(String) onAsk;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    return ListView(
      padding: const EdgeInsets.all(Space.xl),
      children: <Widget>[
        Icon(Icons.forum_rounded, size: 40, color: context.brand),
        const SizedBox(height: Space.md),
        Text(
          'Ask about your productivity',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: Space.sm),
        Text(
          'Personal Digital Twin AI sends your question, recent chat and a compact activity summary to Google Gemini. Free-tier inputs and replies may be used to improve Google products. Do not enter sensitive or confidential information.',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.textSecondary),
        ),
        const SizedBox(height: Space.xl),
        Text(
          'Try asking',
          style: TextStyle(color: p.textSecondary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: Space.sm),
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: <Widget>[
            for (final String q in AiChatScreen.suggestedQuestions)
              ActionChip(label: Text(q), onPressed: () => onAsk(q)),
          ],
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    final bool mine = message.role == ChatRole.user;
    final Color bg = mine
        ? Theme.of(context).colorScheme.primaryContainer
        : p.surface;
    final Color fg = mine
        ? Theme.of(context).colorScheme.onPrimaryContainer
        : p.textPrimary;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: Space.md),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: bg,
            border: mine ? null : Border.all(color: p.border),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(Radii.md),
              topRight: const Radius.circular(Radii.md),
              bottomLeft: Radius.circular(mine ? Radii.md : 4),
              bottomRight: Radius.circular(mine ? 4 : Radii.md),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.xs),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 14,
                        color: context.brand,
                      ),
                      const SizedBox(width: Space.xs),
                      Flexible(
                        child: Text(
                          'Personal Digital Twin AI',
                          style: TextStyle(
                            color: p.textSecondary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              SelectableText(
                message.text,
                style: TextStyle(color: fg, height: 1.4),
              ),
              const SizedBox(height: Space.xs),
              Text(
                formatWhen(context, message.createdAt),
                style: TextStyle(
                  color: mine ? fg.withValues(alpha: 0.8) : p.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.md),
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: context.palette.surface,
          border: Border.all(color: context.palette.border),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Semantics(
          liveRegion: true,
          label: 'Personal Digital Twin AI is answering',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Space.sm),
              Flexible(
                child: Text(
                  'Thinking…',
                  style: TextStyle(color: context.palette.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final Future<void> Function([String?]) onSend;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    final bool canSend = !sending && controller.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.sm,
        Space.sm,
        Space.sm,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              maxLength: AiAssistantController.maxQuestionChars,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Ask a question',
                hintMaxLines: 3,
                counterText: '',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          IconButton.filled(
            tooltip: 'Send',
            onPressed: canSend ? () => onSend() : null,
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}
