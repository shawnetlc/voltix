import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int minDurationMs;
  final int maxDurationMs;
  final double millisPerPixel;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.minDurationMs = 2200,
    this.maxDurationMs = 12000,
    this.millisPerPixel = 50,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final ScrollController _controller;
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _anim = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  void _checkOverflow() {
    if (!mounted || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max > 0) {
      final duration = Duration(
        milliseconds: (max * widget.millisPerPixel).toInt().clamp(
          widget.minDurationMs,
          widget.maxDurationMs,
        ),
      );
      _anim.duration = duration;
      _anim.addListener(_onTick);
      _anim.repeat(reverse: true);
    }
  }

  void _onTick() {
    if (_controller.hasClients) {
      _controller.jumpTo(_anim.value * _controller.position.maxScrollExtent);
    }
  }

  @override
  void dispose() {
    _anim.removeListener(_onTick);
    _anim.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, maxLines: 1, style: widget.style),
    );
  }
}
