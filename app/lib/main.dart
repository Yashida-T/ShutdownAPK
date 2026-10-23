import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// -------------------- APPEARANCE (same palette as the desktop app) --------------------

const kBg = Color(0xFF151922);
const kCard = Color(0xFF202938);
const kText = Color(0xFFF8FAFC);
const kMuted = Color(0xFFA6B0C0);
const kBlue = Color(0xFF3B82F6);
const kRed = Color(0xFFB91C1C);
const kErr = Color(0xFFEF4444);
const kGreen = Color(0xFF22C55E);
const kGray = Color(0xFF374151);
const kPort = 5000;

void main() => runApp(const ShutdownApp());

class ShutdownApp extends StatelessWidget {
  const ShutdownApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shutdown Scheduler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kBlue),
      ),
      home: const Root(),
    );
  }
}

// -------------------- HELPERS --------------------

String _two(int n) => n.toString().padLeft(2, '0');

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _fmtClock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${_two(h)}:${_two(d.minute)} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

String _fmtDate(DateTime d) => '${_two(d.day)} ${_months[d.month - 1]} ${d.year}';

String _fmtRemaining(int? s) {
  if (s == null) return '--:--:--';
  return '${_two(s ~/ 3600)}:${_two(s % 3600 ~/ 60)}:${_two(s % 60)}';
}

const _labels = {'shutdown': 'Shutdown', 'sleep': 'Sleep', 'logout': 'Log out'};
String _label(String? a) => _labels[a] ?? 'Shutdown';

String _afterText(String a) => switch (a) {
      'sleep' => 'Sleep after',
      'logout' => 'Log out after',
      _ => 'Shut down after',
    };

String _confirmAt(String a, String when) => switch (a) {
      'sleep' => 'Put the PC to sleep at $when?',
      'logout' => 'Log out of the PC at $when?',
      _ => 'Shut down the PC at $when?',
    };

String get _phoneLabel => Platform.isIOS ? 'iPhone' : 'Android phone';

// -------------------- PC CLIENT --------------------

class NotPaired implements Exception {
  const NotPaired();
}

class ApiError implements Exception {
  ApiError(this.message);
  final String message;
  @override
  String toString() => message;
}

class FoundPc {
  FoundPc(this.name, this.ip);
  final String name;
  final String ip;
}

class PcClient {
  PcClient(this.host, {this.token});
  final String host;
  String? token;

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, dynamic>? body, int timeout = 6}) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('http://$host:$kPort$path');
      final req = method == 'POST' ? await http.postUrl(uri) : await http.getUrl(uri);
      req.headers.set('X-Token', token ?? '');
      if (method == 'POST') {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body ?? {})));
      }
      final res = await req.close().timeout(Duration(seconds: timeout));
      final text =
          await res.transform(utf8.decoder).join().timeout(Duration(seconds: timeout));
      Map<String, dynamic> data = {};
      if (text.isNotEmpty) {
        try {
          final d = jsonDecode(text);
          if (d is Map<String, dynamic>) data = d;
        } catch (_) {}
      }
      if (res.statusCode == 401) throw const NotPaired();
      if (res.statusCode >= 400) {
        throw ApiError((data['error'] ?? 'Request failed').toString());
      }
      return data;
    } finally {
      http.close(force: true);
    }
  }

  Future<Map<String, dynamic>> hello() => _send('GET', '/api/hello', timeout: 4);
  Future<Map<String, dynamic>> status() => _send('GET', '/api/status');
  Future<Map<String, dynamic>> pair(String name) =>
      _send('POST', '/api/pair', body: {'name': name}, timeout: 90);
  Future<Map<String, dynamic>> schedule(String action, int seconds) =>
      _send('POST', '/api/schedule', body: {'action': action, 'seconds': seconds});
  Future<Map<String, dynamic>> cancel() => _send('POST', '/api/cancel');
}

/// Looks for PCs running pc_server.py on the phone's Wi-Fi network (/24 sweep).
Future<List<FoundPc>> scanNetwork() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  final wifi = interfaces.where((i) {
    final n = i.name.toLowerCase();
    return n.startsWith('wlan') || n.startsWith('en') || n.startsWith('wl');
  }).toList();
  final prefixes = <String>{};
  for (final i in (wifi.isNotEmpty ? wifi : interfaces)) {
    for (final a in i.addresses) {
      final p = a.address.split('.');
      if (p.length == 4 && !a.isLoopback) prefixes.add('${p[0]}.${p[1]}.${p[2]}');
    }
  }

  Future<FoundPc?> probe(String ip) async {
    final http = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await http.getUrl(Uri.parse('http://$ip:$kPort/api/hello'));
      final res = await req.close().timeout(const Duration(seconds: 2));
      final body = await res.transform(utf8.decoder).join();
      final d = jsonDecode(body);
      if (d is Map && d['app'] == 'shutdown-scheduler') {
        return FoundPc(d['name'].toString(), ip);
      }
    } catch (_) {
    } finally {
      http.close(force: true);
    }
    return null;
  }

  final ips = [
    for (final p in prefixes)
      for (var n = 1; n < 255; n++) '$p.$n',
  ];
  final found = <FoundPc>[];
  for (var i = 0; i < ips.length; i += 64) {
    final results = await Future.wait(ips.skip(i).take(64).map(probe));
    found.addAll(results.whereType<FoundPc>());
  }
  return found;
}

// -------------------- ROOT: connection handling --------------------

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  SharedPreferences? prefs;
  PcClient? client;
  String pcName = '';
  String? notice;
  bool starting = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    prefs = await SharedPreferences.getInstance();
    final last = prefs!.getString('lastHost');
    if (last != null && last.isNotEmpty) {
      await _connect(last, (_) {});
    }
    if (mounted) setState(() => starting = false);
  }

  Map<String, String> _tokens() {
    try {
      final raw = jsonDecode(prefs!.getString('tokens') ?? '{}') as Map;
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  /// Returns null on success, or an error message.
  Future<String?> _connect(String hostInput, void Function(String) progress) async {
    final host = hostInput.trim();
    if (host.isEmpty) return 'Enter your PC name or IP address.';
    final c = PcClient(host);

    progress('Contacting $host...');
    Map<String, dynamic> hello;
    try {
      hello = await c.hello();
    } catch (_) {
      return 'Could not reach "$host". Check that pc_server.py is running on the PC '
          'and that both devices are on the same Wi-Fi.';
    }
    if (hello['app'] != 'shutdown-scheduler') {
      return '"$host" is not running Shutdown Scheduler.';
    }
    final name = hello['name'].toString();

    final tokens = _tokens();
    c.token = tokens[name];
    try {
      await c.status();
    } on NotPaired {
      progress('Approve this phone on "$name" (a prompt is showing on the PC)...');
      try {
        final r = await c.pair(_phoneLabel);
        c.token = r['token'].toString();
        tokens[name] = c.token!;
        await prefs!.setString('tokens', jsonEncode(tokens));
      } on ApiError catch (e) {
        return e.message;
      } catch (_) {
        return 'Pairing timed out. Try again and click Yes on the PC.';
      }
    } catch (_) {
      return 'The PC did not respond. Try again.';
    }

    await prefs!.setString('lastHost', host);
    if (mounted) {
      setState(() {
        client = c;
        pcName = name;
        notice = null;
      });
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (starting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final c = client;
    if (c == null) {
      return ConnectScreen(
        initialHost: prefs?.getString('lastHost') ?? '',
        notice: notice,
        onConnect: _connect,
      );
    }
    return SchedulerScreen(
      key: ValueKey(c.host),
      client: c,
      pcName: pcName,
      onDisconnect: () => setState(() {
        client = null;
        notice = null;
      }),
      onLost: (msg) => setState(() {
        client = null;
        notice = msg;
      }),
    );
  }
}

// -------------------- CONNECT SCREEN --------------------

Widget _card(Widget child) => Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(18)),
      child: child,
    );

Widget _btn(String text, Color color, VoidCallback? onTap) => SizedBox(
      width: double.infinity,
      height: 44,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Text(text,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    required this.initialHost,
    required this.onConnect,
    this.notice,
  });
  final String initialHost;
  final String? notice;
  final Future<String?> Function(String, void Function(String)) onConnect;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController ctrl = TextEditingController(text: widget.initialHost);
  List<FoundPc> found = [];
  bool scanning = false, connecting = false;
  String? status, error;

  @override
  void initState() {
    super.initState();
    error = widget.notice;
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  Future<void> _go(String host) async {
    if (connecting) return;
    setState(() {
      connecting = true;
      error = null;
      status = 'Contacting $host...';
    });
    final err = await widget.onConnect(host, (m) {
      if (mounted) setState(() => status = m);
    });
    if (!mounted) return;
    setState(() {
      connecting = false;
      status = null;
      error = err;
    });
  }

  Future<void> _scan() async {
    if (scanning || connecting) return;
    setState(() {
      scanning = true;
      found = [];
      error = null;
    });
    List<FoundPc> res = [];
    try {
      res = await scanNetwork();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      scanning = false;
      found = res;
      if (res.isEmpty) {
        error = 'No PCs found on this Wi-Fi. Make sure pc_server.py is running on the PC, '
            'or type its name / IP address above.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
              children: [
                const Text('◷  Shutdown Scheduler',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kText)),
                const SizedBox(height: 12),
                _card(Column(children: [
                  const Text('Connect to your PC', style: TextStyle(color: kMuted)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    enabled: !connecting,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _go,
                    decoration: InputDecoration(
                      hintText: 'PC name or IP (e.g. DESKTOP-ABC or 192.168.0.12)',
                      filled: true,
                      fillColor: kBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _btn('Connect', kBlue, connecting ? null : () => _go(ctrl.text)),
                  const SizedBox(height: 10),
                  _btn(scanning ? 'Scanning...' : 'Scan Network', kGray,
                      (scanning || connecting) ? null : _scan),
                ])),
                if (found.isNotEmpty)
                  _card(Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('PCs found', style: TextStyle(color: kMuted)),
                      const SizedBox(height: 6),
                      for (final pc in found)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.computer, color: kBlue),
                          title: Text(pc.name),
                          subtitle: Text(pc.ip, style: const TextStyle(color: kMuted)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: connecting
                              ? null
                              : () {
                                  ctrl.text = pc.ip;
                                  _go(pc.ip);
                                },
                        ),
                    ],
                  )),
                if (connecting || scanning)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(status!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: kMuted, fontSize: 12)),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: kErr, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------- SCHEDULER SCREEN --------------------

class SchedulerScreen extends StatefulWidget {
  const SchedulerScreen({
    super.key,
    required this.client,
    required this.pcName,
    required this.onDisconnect,
    required this.onLost,
  });
  final PcClient client;
  final String pcName;
  final VoidCallback onDisconnect;
  final void Function(String) onLost;

  @override
  State<SchedulerScreen> createState() => _SchedulerScreenState();
}

class _SchedulerScreenState extends State<SchedulerScreen> {
  String mode = 'Specific Time';
  String action = 'shutdown';

  late int hour12;
  late int minute;
  late String ampm;
  int durH = 1;
  int durM = 0;

  DateTime? endsAt;
  String? scheduleText;
  String? activeAction;

  String statusText = 'System ready';
  Color statusColor = kMuted;
  bool busy = false;
  bool refreshing = false;
  int failures = 0;
  Timer? ticker, poller;

  @override
  void initState() {
    super.initState();
    final d = DateTime.now().add(const Duration(minutes: 5));
    hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    minute = d.minute;
    ampm = d.hour >= 12 ? 'PM' : 'AM';
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (endsAt != null && mounted) setState(() {});
    });
    poller = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    ticker?.cancel();
    poller?.cancel();
    super.dispose();
  }

  int? get remaining =>
      endsAt == null ? null : max(0, endsAt!.difference(DateTime.now()).inSeconds);

  void _setStatus(String text, Color color) {
    if (!mounted) return;
    setState(() {
      statusText = text;
      statusColor = color;
    });
  }

  void _applyStatus(Map<String, dynamic> st) {
    if (!mounted) return;
    setState(() {
      final r = st['remaining'];
      if (r == null) {
        endsAt = null;
        scheduleText = null;
        activeAction = null;
      } else {
        endsAt = DateTime.now().add(Duration(seconds: (r as num).toInt()));
        scheduleText = st['target_text']?.toString();
        activeAction = st['action']?.toString();
      }
    });
  }

  Future<void> _refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final st = await widget.client.status();
      failures = 0;
      _applyStatus(st);
    } on NotPaired {
      if (mounted) {
        widget.onLost('This phone is no longer approved on ${widget.pcName}. Connect again.');
      }
    } catch (_) {
      failures++;
      if (failures >= 2 && mounted) {
        widget.onLost('Lost connection to ${widget.pcName}. It may have shut down, '
            'gone to sleep, or left the network.');
      }
    } finally {
      refreshing = false;
    }
  }

  Future<bool> _confirm(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Confirm', style: TextStyle(fontSize: 18)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel', style: TextStyle(color: kMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _schedule() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final st = await widget.client.status();
      final pcNow = DateTime.parse('${st['now']}Z'); // PC clock, treated as plain wall time
      DateTime target;
      if (mode == 'Specific Time') {
        var h = hour12;
        if (ampm == 'PM' && h != 12) {
          h += 12;
        } else if (ampm == 'AM' && h == 12) {
          h = 0;
        }
        target = DateTime.utc(pcNow.year, pcNow.month, pcNow.day, h, minute);
        if (!target.isAfter(pcNow)) target = target.add(const Duration(days: 1));
      } else {
        if (durH == 0 && durM == 0) {
          _setStatus('Enter a duration greater than zero.', kErr);
          return;
        }
        target = pcNow.add(Duration(hours: durH, minutes: durM));
      }
      final when = '${_fmtClock(target)} on ${_fmtDate(target)}';
      if (!mounted || !await _confirm(_confirmAt(action, when))) return;
      final seconds = max(1, target.difference(pcNow).inSeconds);
      final r = await widget.client.schedule(action, seconds);
      _applyStatus(r);
      _setStatus('${_label(action)} scheduled successfully.', kGreen);
    } on NotPaired {
      widget.onLost('This phone is no longer approved on ${widget.pcName}. Connect again.');
    } catch (e) {
      _setStatus('Scheduling failed: $e', kErr);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _doNow(String act) async {
    if (busy) return;
    final msg = act == 'sleep' ? 'Put the PC to sleep now?' : 'Log out of the PC now?';
    if (!await _confirm(msg)) return;
    setState(() => busy = true);
    try {
      final r = await widget.client.schedule(act, 0);
      _applyStatus(r);
      _setStatus(act == 'sleep' ? 'Putting the PC to sleep...' : 'Logging out...', kGreen);
    } on NotPaired {
      widget.onLost('This phone is no longer approved on ${widget.pcName}. Connect again.');
    } catch (e) {
      _setStatus('Failed: $e', kErr);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cancel() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final r = await widget.client.cancel();
      _applyStatus({'remaining': null});
      if (r['cancelled'] == true) {
        _setStatus('Schedule cancelled.', kGreen);
      } else {
        _setStatus('Nothing was scheduled.', kMuted);
      }
    } on NotPaired {
      widget.onLost('This phone is no longer approved on ${widget.pcName}. Connect again.');
    } catch (e) {
      _setStatus('Cancel failed: $e', kErr);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------- UI ----------

  Widget _pick<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
    double width = 78,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: kBlue, borderRadius: BorderRadius.circular(10)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: kCard,
          iconEnabledColor: Colors.white,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          items: [
            for (final i in items) DropdownMenuItem<T>(value: i, child: Text(label(i))),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _specificCard() {
    return _card(Column(children: [
      Text('Set ${_label(action).toLowerCase()} time', style: const TextStyle(color: kMuted)),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _pick<int>(
          value: hour12,
          items: List.generate(12, (i) => i + 1),
          label: _two,
          onChanged: (v) => setState(() => hour12 = v),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text(':', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        _pick<int>(
          value: minute,
          items: List.generate(60, (i) => i),
          label: _two,
          onChanged: (v) => setState(() => minute = v),
        ),
        const SizedBox(width: 8),
        _pick<String>(
          value: ampm,
          items: const ['AM', 'PM'],
          label: (s) => s,
          onChanged: (v) => setState(() => ampm = v),
        ),
      ]),
    ]));
  }

  Widget _durationCard() {
    return _card(Column(children: [
      Text(_afterText(action), style: const TextStyle(color: kMuted)),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _pick<int>(
          value: durH,
          items: List.generate(25, (i) => i),
          label: (v) => '$v',
          width: 84,
          onChanged: (v) => setState(() => durH = v),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('hours'),
        ),
        _pick<int>(
          value: durM,
          items: List.generate(60, (i) => i),
          label: (v) => '$v',
          width: 84,
          onChanged: (v) => setState(() => durM = v),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 8),
          child: Text('min'),
        ),
      ]),
      const SizedBox(height: 8),
      const Text('Choose 0–24 hours and 0–59 minutes.',
          style: TextStyle(fontSize: 10, color: kMuted)),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final r = remaining;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
              children: [
                const Text('◷  Shutdown Scheduler',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kText)),
                const SizedBox(height: 8),

                // What we're connected to
                _card(Row(children: [
                  const Icon(Icons.circle, size: 12, color: kGreen),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Connected to ${widget.pcName}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(widget.client.host,
                            style: const TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  TextButton(onPressed: widget.onDisconnect, child: const Text('Change')),
                ])),

                // Mode + action selectors
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'Specific Time', label: Text('Specific Time')),
                      ButtonSegment(value: 'Countdown', label: Text('Countdown')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => setState(() => mode = s.first),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'shutdown', label: Text('Shutdown')),
                      ButtonSegment(value: 'sleep', label: Text('Sleep')),
                      ButtonSegment(value: 'logout', label: Text('Log out')),
                    ],
                    selected: {action},
                    onSelectionChanged: (s) => setState(() => action = s.first),
                  ),
                ),

                // Picker for the chosen mode
                mode == 'Specific Time' ? _specificCard() : _durationCard(),

                // Time remaining
                _card(Column(children: [
                  const Text('TIME REMAINING',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: kMuted)),
                  const SizedBox(height: 2),
                  Text(_fmtRemaining(r),
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.bold, color: Color(0xFF60A5FA))),
                  const SizedBox(height: 2),
                  Text(
                    scheduleText == null
                        ? 'Nothing scheduled'
                        : '${_label(activeAction)}: $scheduleText',
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                ])),

                const SizedBox(height: 4),
                _btn('Schedule ${_label(action)}', kBlue, busy ? null : _schedule),
                const SizedBox(height: 10),
                _btn('Cancel Schedule', kRed, busy ? null : _cancel),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _btn('Sleep Now', kGray, busy ? null : () => _doNow('sleep'))),
                  const SizedBox(width: 10),
                  Expanded(child: _btn('Log Out Now', kGray, busy ? null : () => _doNow('logout'))),
                ]),
                const SizedBox(height: 12),
                Text(statusText,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: statusColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
