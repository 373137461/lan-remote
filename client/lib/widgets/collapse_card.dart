import 'package:flutter/material.dart';

/// 可折叠卡片
/// - header：始终可见的摘要行
/// - body：折叠/展开内容，高度平滑动画
class CollapseCard extends StatelessWidget {
  final Widget header;
  final Widget body;
  final bool expanded;
  final VoidCallback onToggle;
  final EdgeInsets bodyPadding;

  const CollapseCard({
    super.key,
    required this.header,
    required this.body,
    required this.expanded,
    required this.onToggle,
    this.bodyPadding = const EdgeInsets.fromLTRB(14, 0, 14, 14),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(child: header),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    child: const Icon(Icons.expand_more, color: Colors.white38, size: 20),
                  ),
                ],
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeInOut,
              child: expanded
                  ? Padding(padding: bodyPadding, child: body)
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),
        ],
      ),
    );
  }
}
