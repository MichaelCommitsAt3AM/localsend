import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/provider/app_update_provider.dart';
import 'package:localsend_app/widget/updater/app_update_banner.dart';
import 'package:refena_flutter/refena_flutter.dart';

class AppUpdateBannerWatcher extends StatelessWidget {
  final Widget child;

  const AppUpdateBannerWatcher({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final isVisible = context.watch(appUpdateProvider).isBannerVisible;

    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            child: isVisible
                ? AnnotatedRegion<SystemUiOverlayStyle>(
                    value: SystemUiOverlayStyle(
                      statusBarColor: Colors.transparent,
                      statusBarIconBrightness: theme.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
                      statusBarBrightness: theme.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
                      systemStatusBarContrastEnforced: false,
                    ),
                    child: Material(
                      color: theme.colorScheme.primaryContainer,
                      child: const SafeArea(bottom: false, child: AppUpdateBanner()),
                    ),
                  )
                : const SizedBox.shrink(),
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
      ),
    );
  }
}
