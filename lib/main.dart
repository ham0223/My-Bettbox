import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/clipboard_ext.dart';
import 'package:bett_box/plugins/tile.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/state.dart';
import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import 'application.dart';
import 'clash/core.dart';
import 'clash/lib.dart';
import 'common/common.dart';
import 'common/external_control.dart';
import 'common/network_matcher.dart';
import 'models/models.dart';

ReceivePort? _serviceReceiverPort;
ReceivePort? _messageReceiverPort;

Future<void> main(List<String> args) async {
  globalState.isService = false;
  WidgetsFlutterBinding.ensureInitialized();

  if (system.isDesktop &&
      (args.contains('--exit') || args.contains('--restart'))) {
    final command = args.contains('--exit') ? 'exit' : 'restart';
    await _sendControlCommand(command);
    exit(0);
  }

  if (system.isMacOS) {
    final acquire = await singleInstanceLock.acquire();
    if (!acquire) {
      commonPrint.log(
        'SingleInstanceLock: another instance detected or lock failed, exiting',
      );
      await _sendControlCommand('show');
      await Future.delayed(const Duration(milliseconds: 100));
      exit(0);
    }
  }

  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;

  final version = await system.version;
  await Future.wait([globalState.initApp(version), clashCore.preload()]);

  try {
    await uiManager.initializeUI();
  } catch (e) {
    commonPrint.log('Failed to initialize UI: $e');
  }

  await _runApp();
}

Future<void> _sendControlCommand(String command) async {
  for (int i = 0; i < 5; i++) {
    try {
      await ExternalControl.sendCommand(command);
      commonPrint.log('Sent $command command to running instance');
      return;
    } catch (e) {
      if (i == 4) {
        commonPrint.log('Failed to send $command command: $e');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}

Future<void> _runApp() async {
  try {
    await RustLib.init();
  } catch (e) {
    commonPrint.log('Failed to initialize code_forge RustLib: $e');
  }

  if (system.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      commonPrint.log('Failed to set high refresh rate: $e');
    }
  }
  await android?.init();

  await window?.init();
  if (system.isWindows) {
    clipboardExt.init();
  }
  HttpOverrides.global = BettboxHttpOverrides();
  runApp(ProviderScope(child: const Application()));
}

@pragma('vm:entry-point')
Future<void> _service(List<String> flags) async {
  globalState.isService = true;
  WidgetsFlutterBinding.ensureInitialized();
  await globalState.init();

  {
    final quickStart = flags.contains('quick');
    final bootStart = flags.contains('boot');
    final clashLibHandler = ClashLibHandler();
    final smartAutoStopLock = Lock();

    // smartResume() on the native side kicks off the actual rebind/restart
    // work in a fire-and-forget coroutine and returns immediately, so a
    // successful call here does NOT mean the tunnel is actually back up yet.
    // If the native bindService() call stalls or times out (observed in
    // practice after the device has been idle/Doze for a while - low
    // probability, but real), nothing else would normally re-attempt it until
    // some unrelated later network event happens to trigger another check.
    // This verifies the resume actually took effect within a bounded window
    // and retries a few times if not, instead of leaving the VPN silently
    // down. Runs outside smartAutoStopLock so it never blocks a real,
    // subsequent network-change decision.
    //
    // Declared before checkSmartAutoStop() below because Dart local
    // functions (unlike top-level ones) can't be referenced before their
    // declaration in the same scope.
    bool _smartResumeVerifyRunning = false;
    void _verifySmartResume(String networks) {
      if (_smartResumeVerifyRunning) return;
      _smartResumeVerifyRunning = true;
      Future(() async {
        try {
          for (int attempt = 0; attempt < 6; attempt++) {
            await Future.delayed(const Duration(seconds: 2));
            final stillSmartStopped = await vpn?.isSmartStopped() ?? false;
            final isRunning = await vpn?.getStatus() ?? false;
            if (!stillSmartStopped && isRunning) return;

            // Make sure the decision to resume still holds before retrying -
            // if the user moved back onto a "should stop" network meanwhile,
            // don't fight that.
            final candidateIps =
                await vpn?.getLocalIpAddresses() ?? const <String>[];
            final candidateGateways =
                await vpn?.getLocalGateways() ?? const <String>[];
            final shouldStopNow =
                candidateIps.any(
                  (ip) => NetworkMatcher.matchAny(ip, networks),
                ) ||
                candidateGateways.any(
                  (gw) => NetworkMatcher.matchAnyGateway(gw, networks),
                );
            if (shouldStopNow) return;

            commonPrint.log(
              'Smart resume has not taken effect yet, retrying (attempt ${attempt + 1})',
            );
            await vpn?.setSmartStopped(false);
            await vpn?.smartResume(clashLibHandler.getAndroidVpnOptions());
          }
        } finally {
          _smartResumeVerifyRunning = false;
        }
      });
    }

    Future<void> checkSmartAutoStop() async {
      try {
        final vpnProps = globalState.config.vpnProps;
        if (!vpnProps.smartAutoStop) return;
        final networks = vpnProps.smartAutoStopNetworks;
        if (networks.isEmpty) return;

        await smartAutoStopLock.synchronized(() async {
          final isSmartStopped = await vpn?.isSmartStopped() ?? false;
          final candidateIps =
              await vpn?.getLocalIpAddresses() ?? const <String>[];
          final candidateGateways =
              await vpn?.getLocalGateways() ?? const <String>[];
          if (candidateIps.isEmpty && candidateGateways.isEmpty) return;

          final shouldStop =
              candidateIps.any(
                (ip) => NetworkMatcher.matchAny(ip, networks),
              ) ||
              candidateGateways.any(
                (gw) => NetworkMatcher.matchAnyGateway(gw, networks),
              );

          if (shouldStop && !isSmartStopped) {
            final isRunning = await vpn?.getStatus() ?? false;
            if (isRunning) {
              await vpn?.setSmartStopped(true);
              await vpn?.smartStop();
            }
          } else if (!shouldStop && isSmartStopped) {
            await vpn?.setSmartStopped(false);
            await vpn?.smartResume(clashLibHandler.getAndroidVpnOptions());
            _verifySmartResume(networks);
          }
        });
      } catch (e) {
        commonPrint.log('Smart auto stop check failed: $e');
      }
    }

    // Debounced version for network change events
    // Shorter delay (500ms) for faster response
    int _networkChangeCheckSequence = 0;
    void _debouncedCheckSmartAutoStop() {
      final currentSequence = ++_networkChangeCheckSequence;
      Future.delayed(const Duration(milliseconds: 600), () async {
        if (currentSequence != _networkChangeCheckSequence) {
          return;
        }
        await checkSmartAutoStop();
      });
    }

    // Runs an initial smart-auto-stop evaluation right after the VPN starts,
    // retrying every second for up to 8 seconds. This is needed because a
    // fresh start has no *network change* event to trigger
    // _debouncedCheckSmartAutoStop - without this, a start that happens while
    // already sitting on a "should stop" network (e.g. tapping the tile at
    // home) would never be evaluated until some later, unrelated network
    // transition occurred. Previously this was only scheduled inside the
    // boot/quick-start flow below, so a manual/tile start (no boot/quick
    // flag, e.g. after reboot with autoRun off, or a normal tap) skipped it
    // entirely.
    //
    // Guarded against overlap: if a tile tap and the boot/quick flow happen to
    // race (e.g. user taps the tile right as autoRun is kicking in), only one
    // 8-second polling loop runs; the second call is a no-op. checkSmartAutoStop
    // itself is still safe to call concurrently (serialized by
    // smartAutoStopLock), this guard just avoids doubling up the polling work.
    bool _initialSmartAutoStopCheckRunning = false;
    void _scheduleInitialSmartAutoStopCheck() {
      if (_initialSmartAutoStopCheckRunning) return;
      Future(() async {
        final vpnProps = globalState.config.vpnProps;
        if (!vpnProps.smartAutoStop) return;
        final networks = vpnProps.smartAutoStopNetworks;
        if (networks.isEmpty) return;
        _initialSmartAutoStopCheckRunning = true;
        try {
          for (int attempt = 0; attempt < 8; attempt++) {
            await Future.delayed(const Duration(seconds: 1));
            // Re-read on every attempt: bail out early if the user disabled
            // smart auto-stop, or if it no longer has any networks configured,
            // while this loop was still running.
            final props = globalState.config.vpnProps;
            if (!props.smartAutoStop || props.smartAutoStopNetworks.isEmpty) {
              return;
            }
            await checkSmartAutoStop();
            final isSmartStopped = await vpn?.isSmartStopped() ?? false;
            final isRunning = await vpn?.getStatus() ?? false;
            if (!isRunning) return;
            if (isSmartStopped) return;
          }
        } finally {
          _initialSmartAutoStopCheckRunning = false;
        }
      });
    }

    tile?.addListener(
      _TileListenerWithService(
        onStart: () async {
          await app.tip(appLocalizations.startVpn);
          await globalState.handleStart();
          _scheduleInitialSmartAutoStopCheck();
        },
        onStop: () async {
          await app.tip(appLocalizations.stopVpn);
          clashLibHandler.stopListener();
          await vpn?.stop();
        },
        onReconnectIpc: () {
          commonPrint.log(
            'Service: reconnectIpc requested, re-establishing IPC',
          );
          _handleMainIpc(clashLibHandler);
        },
      ),
    );

    vpn?.addListener(
      _VpnListenerWithService(
        onDnsChanged: (String dns) {
          clashLibHandler.updateDns(dns);
        },
        onNetworkChanged: _debouncedCheckSmartAutoStop,
      ),
    );

    if (!quickStart && !bootStart) {
      _handleMainIpc(clashLibHandler);
      return;
    }

    if (bootStart && !globalState.config.appSetting.autoRun) {
      commonPrint.log(
        'Silent boot detected, but autoRun is disabled. Staying idle.',
      );
      _handleMainIpc(clashLibHandler);
      return;
    }

    commonPrint.log('Executing ${bootStart ? "boot" : "quick"} start sequence');
    await ClashCore.initGeo();
    app.tip(appLocalizations.startVpn);
    final homeDirPath = await appPath.homeDirPath;
    final version = await system.version;
    final clashConfig = globalState.config.patchClashConfig.copyWith.tun(
      enable: false,
    );

    Future(() async {
      try {
        final params = await globalState.getSetupParams(
          pathConfig: clashConfig,
        );
        final profileId = globalState.config.currentProfileId;
        if (profileId == null) {
          return;
        }
        final res = await clashLibHandler.quickStart(
          InitParams(homeDir: homeDirPath, version: version),
          params,
          globalState.getCoreState(),
        );
        debugPrint(res);
        if (res.isNotEmpty) {
          commonPrint.log('QuickStart failed with error: $res');
          await vpn?.stop();
          return;
        }
        await vpn?.start(clashLibHandler.getAndroidVpnOptions());
        // Combined with onAvailable/onLost callbacks for immediate response
        // on later real network transitions.
        _scheduleInitialSmartAutoStopCheck();

        if (globalState.config.vpnProps.networkSpeedNotification) {
          final profile = globalState.config.profiles
              .where((e) => e.id == profileId)
              .firstOrNull;
          final profileName = profile?.label ?? 'Bettbox';
          await vpn?.updateNotificationSpeed(profileName, '↑0B/s ↓0B/s');
        }

        if (globalState.config.appSetting.openLogs) {
          await clashLibHandler.invokeAction(
            '{"id": "quickStartLog", "method": "startLog"}',
          );
        } else {
          await clashLibHandler.invokeAction(
            '{"id": "quickStopLog", "method": "stopLog"}',
          );
        }

        clashLibHandler.startListener();
      } catch (e) {
        commonPrint.log('Fatal error during service background start: $e');
        await vpn?.stop();
      }
    });
  }
}

void _handleMainIpc(ClashLibHandler clashLibHandler) {
  final sendPort = IsolateNameServer.lookupPortByName(mainIsolate);
  if (sendPort == null) {
    commonPrint.log('Service: mainIsolate sendPort not found, IPC unavailable');
    return;
  }

  _serviceReceiverPort?.close();
  _messageReceiverPort?.close();

  _serviceReceiverPort = ReceivePort();
  _serviceReceiverPort!.listen((message) async {
    final res = await clashLibHandler.invokeAction(message);
    _safeSend(sendPort, res);
  });
  _safeSend(sendPort, _serviceReceiverPort!.sendPort);

  _messageReceiverPort = ReceivePort();
  clashLibHandler.attachMessagePort(_messageReceiverPort!.sendPort.nativePort);
  _messageReceiverPort!.listen((message) {
    _safeSend(sendPort, message);
  });

  clashLibHandler.startListener();
}

void _safeSend(SendPort sendPort, dynamic message) {
  try {
    sendPort.send(message);
  } catch (e) {
    commonPrint.log('Service: IPC send failed: $e');
    final retryPort = IsolateNameServer.lookupPortByName(mainIsolate);
    if (retryPort != null) {
      try {
        retryPort.send(message);
      } catch (_) {}
    }
  }
}

@immutable
class _TileListenerWithService with TileListener {
  final Function() _onStart;
  final Function() _onStop;
  final Function() _onReconnectIpc;

  const _TileListenerWithService({
    required Function() onStart,
    required Function() onStop,
    required Function() onReconnectIpc,
  }) : _onStart = onStart,
       _onStop = onStop,
       _onReconnectIpc = onReconnectIpc;

  @override
  void onStart() => _onStart();

  @override
  void onStop() => _onStop();

  @override
  void onReconnectIpc() => _onReconnectIpc();
}

@immutable
class _VpnListenerWithService with VpnListener {
  final Function(String dns) _onDnsChanged;
  final Function() _onNetworkChanged;

  const _VpnListenerWithService({
    required Function(String dns) onDnsChanged,
    required Function() onNetworkChanged,
  })  : _onDnsChanged = onDnsChanged,
        _onNetworkChanged = onNetworkChanged;

  @override
  void onDnsChanged(String dns) {
    super.onDnsChanged(dns);
    _onDnsChanged(dns);
  }

  @override
  void onNetworkChanged() {
    super.onNetworkChanged();
    _onNetworkChanged();
  }
}
