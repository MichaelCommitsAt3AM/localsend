import 'package:flutter/material.dart';
import 'package:localsend_app/provider/app_update_provider.dart';
import 'package:localsend_app/widget/updater/app_update_banner.dart';
import 'package:refena_flutter/refena_flutter.dart';

class AppUpdateBannerWatcher extends StatelessWidget {
  final Widget child;

  const AppUpdateBannerWatcher({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final isVisible = context.watch(appUpdateProvider).isBannerVisible;

    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            child: isVisible ? const AppUpdateBanner() : const SizedBox.shrink(),
          ),
        ),
        Expanded(
          child: isVisible
              ? MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: child,
                )
              : child,
        ),
      ],
    );
  }
}
