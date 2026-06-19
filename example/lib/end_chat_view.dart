import 'package:flutter/material.dart';
import 'package:sf_chat_helper/salesforce_chat_helper.dart';
import 'package:webview_flutter/webview_flutter.dart';

class EndChatView extends StatefulWidget {
  const EndChatView({super.key});

  @override
  State<EndChatView> createState() => _EndChatViewState();
}

class _EndChatViewState extends State<EndChatView> with WidgetsBindingObserver {
  late final WebViewController controller;
  late final SalesforceChatHelper chatHelper;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    controller = WebViewController();
    chatHelper = SalesforceChatHelper.builder()
        .setWebViewController(controller)
        .setSupportUrl(
          "https://bitkubexchange--uat.sandbox.my.site.com/en/support",
        )
        .setOnVisibilityChanged(() => setState(() {}))
        .setLoggingEnabled(true)
        .setCustomRequest(false)
        .setUatApexEndpoint(
          "https://bitkubexchange--uat.sandbox.my.salesforce-sites.com/publicapi/services/apexrest/update-session",
        )
        // .setCustomRequest(true)
        .build();

    ///custom load request
    // chatHelper.loadInitialRequest(
    //   "https://bitkubexchange--uat.sandbox.my.site.com/en/support",
    // );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    chatHelper.handleAppLifecycleState(state);
    super.didChangeAppLifecycleState(state);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        await chatHelper.closeAndClear();
        
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Demo EndChat'),
          actions: [
            TextButton(
              onPressed: () async {
                await chatHelper.manualEndChat();
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text(
                'End Chat',
                style: TextStyle(color: Colors.black),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Offstage(
                offstage: !chatHelper.isWebViewVisible,
                child: WebViewWidget(controller: controller),
              ),
              if (!chatHelper.isWebViewVisible)
                const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }
}
