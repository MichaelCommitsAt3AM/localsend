import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One editable value keeps paste, selection, backspace and accessibility intact.
/// The boxes and separator are presentation only; the value contains digits.
class PairingCodeInput extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? errorText;
  final bool enabled;
  final VoidCallback onSubmitted;

  const PairingCodeInput({
    super.key,
    required this.controller,
    required this.label,
    required this.onSubmitted,
    this.errorText,
    this.enabled = true,
  });

  @override
  State<PairingCodeInput> createState() => _PairingCodeInputState();
}

class _PairingCodeInputState extends State<PairingCodeInput> {
  final _focus = FocusNode(debugLabel: 'Pairing code');
  final _contextMenu = ContextMenuController();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {});

  bool _isActive(int index, TextEditingValue value) => _focus.hasFocus && widget.enabled && value.selection.baseOffset.clamp(0, 7) == index;

  void _selectDigit(int index) {
    if (!widget.enabled) return;
    _contextMenu.remove();
    _focus.requestFocus();
    final length = widget.controller.text.length;
    widget.controller.selection = index < length
        ? TextSelection(baseOffset: index, extentOffset: index + 1)
        : TextSelection.collapsed(offset: length);
  }

  void _showPasteMenu(Offset position) {
    if (!widget.enabled) return;
    _focus.requestFocus();
    _contextMenu.show(
      context: context,
      contextMenuBuilder: (_) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: position),
        buttonItems: [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () async {
              _contextMenu.remove();
              final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
              if (!mounted || !widget.enabled) return;
              final digits = (clipboard?.text ?? '').replaceAll(RegExp(r'[^0-9]'), '');
              if (digits.isEmpty) return;
              final code = digits.length > 8 ? digits.substring(0, 8) : digits;
              widget.controller.value = TextEditingValue(
                text: code,
                selection: TextSelection.collapsed(offset: code.length),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _contextMenu.remove();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cellWidth = (constraints.maxWidth - 60) / 8;
                final height = (cellWidth * 1.2).clamp(52.0, 72.0).toDouble();
                return SizedBox(
                  height: height,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0,
                          alwaysIncludeSemantics: true,
                          child: TextField(
                            controller: widget.controller,
                            focusNode: _focus,
                            enabled: widget.enabled,
                            autofocus: widget.enabled,
                            keyboardType: const TextInputType.numberWithOptions(decimal: false, signed: false),
                            textDirection: TextDirection.ltr,
                            textInputAction: TextInputAction.done,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            maxLength: 8,
                            showCursor: false,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: InputDecoration(labelText: widget.label, counterText: ''),
                            onSubmitted: (_) => widget.onSubmitted(),
                          ),
                        ),
                      ),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: widget.controller,
                        builder: (context, value, _) => ExcludeSemantics(
                          child: Row(
                            textDirection: TextDirection.ltr,
                            children: [
                              for (var index = 0; index < 8; index++) ...[
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => _selectDigit(index),
                                    onLongPressStart: (details) => _showPasteMenu(details.globalPosition),
                                    onSecondaryTapDown: (details) => _showPasteMenu(details.globalPosition),
                                    child: AnimatedContainer(
                                      key: ValueKey('pairing-code-digit-$index'),
                                      duration: const Duration(milliseconds: 120),
                                      height: height,
                                      decoration: BoxDecoration(
                                        color: colors.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: widget.errorText != null
                                              ? colors.error
                                              : _isActive(index, value)
                                              ? colors.primary
                                              : colors.outlineVariant,
                                          width: _isActive(index, value) ? 2 : 1,
                                        ),
                                      ),
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.all(4),
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                index < value.text.length ? value.text[index] : '',
                                                style: theme.textTheme.headlineSmall?.copyWith(
                                                  fontWeight: FontWeight.w500,
                                                  color: widget.enabled ? colors.onSurface : colors.onSurface.withValues(alpha: 0.38),
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (_isActive(index, value))
                                            IgnorePointer(
                                              child: Align(
                                                alignment: index < value.text.length ? const Alignment(0.75, 0) : Alignment.center,
                                                child: SizedBox(
                                                  key: const ValueKey('pairing-code-caret'),
                                                  width: 2,
                                                  height: 26,
                                                  child: ColoredBox(color: colors.primary),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (index == 3)
                                  SizedBox(
                                    width: 24,
                                    child: Center(child: Text('-', style: theme.textTheme.titleLarge)),
                                  )
                                else if (index < 7)
                                  const SizedBox(width: 6),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        if (widget.errorText != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(widget.errorText!, style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
          ),
        ],
      ],
    );
  }
}
