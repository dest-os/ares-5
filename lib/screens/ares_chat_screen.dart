import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/settings_service.dart';
import '../services/llm_service.dart';
import '../services/ares_service.dart';
import 'settings_screen.dart';

class _Msg {
  final String rol;
  final String metin;
  _Msg({required this.rol, required this.metin});
  Map<String, dynamic> toJson() => {'rol': rol, 'metin': metin};
  factory _Msg.fromJson(Map<String, dynamic> j) =>
      _Msg(rol: '${j['rol'] ?? 'sen'}', metin: '${j['metin'] ?? ''}');
}

class _Konu {
  String id;
  String baslik;
  List<_Msg> mesajlar;
  _Konu({required this.id, required this.baslik, List<_Msg>? mesajlar})
      : mesajlar = mesajlar ?? [];
  Map<String, dynamic> toJson() => {
        'id': id,
        'baslik': baslik,
        'mesajlar': mesajlar.map((m) => m.toJson()).toList(),
      };
  factory _Konu.fromJson(Map<String, dynamic> j) => _Konu(
        id: '${j['id']}',
        baslik: '${j['baslik'] ?? 'Sohbet'}',
        mesajlar: ((j['mesajlar'] as List?) ?? [])
            .map((e) => _Msg.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// Sadece arka plan gorseli + tamamen seffaf dokunma alanlari.
/// Ek yazi / ikon cizilmez; gorseldeki + mic gonder cark kullanilir.
class AresChatScreen extends StatefulWidget {
  final SettingsService settings;
  final AresService? ares;
  const AresChatScreen({super.key, required this.settings, this.ares});

  @override
  State<AresChatScreen> createState() => _AresChatScreenState();
}

class _AresChatScreenState extends State<AresChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _tts = FlutterTts();
  late final LlmService _llm;

  List<_Konu> _konular = [];
  String? _aktifId;
  final List<String> _ekler = [];
  bool _busy = false;
  bool _mic = false;
  bool _sesli = true;

  _Konu get _aktif {
    if (_konular.isEmpty) {
      final k =
          _Konu(id: '${DateTime.now().millisecondsSinceEpoch}', baslik: 'Yeni');
      _konular.add(k);
      _aktifId = k.id;
    }
    return _konular.firstWhere((k) => k.id == _aktifId,
        orElse: () => _konular.first);
  }

  @override
  void initState() {
    super.initState();
    _llm = LlmService(widget.settings);
    _tts.setLanguage('tr-TR');
    _tts.setSpeechRate(0.5);
    // Klavye acilinca mesajlari alta kaydir (input gorunsun)
    _focus.addListener(() {
      if (_focus.hasFocus) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _toEnd();
        });
      }
    });
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    _focus.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('ares_chat_konular');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      setState(() {
        _konular = list
            .map((e) => _Konu.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (_konular.isNotEmpty) _aktifId = _konular.first.id;
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ares_chat_konular',
        jsonEncode(_konular.map((k) => k.toJson()).toList()));
  }

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (r == null || r.files.isEmpty) return;
      setState(() {
        for (final f in r.files) {
          _ekler.add(f.name);
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Dosya: $e')));
      }
    }
  }

  Future<void> _micTap() async {
    if (widget.ares == null || !widget.settings.geminiHazir) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Mikrofon icin Gemini anahtari gerekli')));
      }
      return;
    }
    setState(() => _mic = true);
    try {
      await widget.ares!.uyandirVeDinle();
      final m = widget.ares!.sonSoylenen;
      if (m.isNotEmpty) setState(() => _ctrl.text = m);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _mic = false);
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty && _ekler.isEmpty) return;
    if (_busy) return;
    final full = _ekler.isEmpty ? text : '$text\n[Ek: ${_ekler.join(", ")}]';
    setState(() {
      _busy = true;
      _aktif.mesajlar.add(_Msg(rol: 'sen', metin: full));
      if (_aktif.baslik == 'Yeni' && text.isNotEmpty) {
        _aktif.baslik = text.length > 28 ? '${text.substring(0, 28)}...' : text;
      }
      _ctrl.clear();
      _ekler.clear();
    });
    _focus.unfocus();
    await _save();
    _toEnd();

    try {
      await widget.settings.yukle();
      final yanit = await _llm.akilliYanit(full);
      if (!mounted) return;
      setState(() => _aktif.mesajlar.add(_Msg(rol: 'ares', metin: yanit)));
      await _save();
      _toEnd();
      if (_sesli && yanit.isNotEmpty) await _tts.speak(yanit);
    } catch (e) {
      if (!mounted) return;
      setState(() => _aktif.mesajlar.add(_Msg(rol: 'ares', metin: 'Hata: $e')));
      await _save();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent + 40);
      }
    });
  }

  void _geri() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _settingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xE00A1520),
      builder: (ctx) {
        final s = widget.settings;
        final ops = [
          if (s.geminiHazir) ApiProvider.gemini,
          if (s.nvidiaHazir) ApiProvider.nvidia,
          if (s.openaiHazir) ApiProvider.openai,
          if (s.grokHazir) ApiProvider.grok,
          if (s.claudeHazir) ApiProvider.claude,
          if (s.customHazir) ApiProvider.custom,
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Beyin sec',
                    style: TextStyle(
                        color: Color(0xFF00BFFF),
                        fontWeight: FontWeight.bold)),
              ),
              ...ops.map((id) => ListTile(
                    leading: Icon(
                      s.birincilApi == id
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: const Color(0xFF00BFFF),
                    ),
                    title: Text(ApiProvider.etiket(id),
                        style: const TextStyle(color: Colors.white)),
                    onTap: () async {
                      s.birincilApi = id;
                      await s.kaydet();
                      if (ctx.mounted) Navigator.pop(ctx);
                      setState(() {});
                    },
                  )),
              ListTile(
                leading: const Icon(Icons.settings, color: Color(0xFF00BFFF)),
                title: const Text('Tum ayarlar',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          SettingsScreen(settings: widget.settings),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Tamamen seffaf dokunma alani — ikon/yazi yok.
  Widget _zone({
    required double left,
    required double top,
    required double width,
    required double height,
    required VoidCallback onTap,
  }) {
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: const ColoredBox(color: Color(0x00000000)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final fullW = size.width;
    final fullH = size.height;
    final keyboard = mq.viewInsets.bottom;
    final topSafe = mq.padding.top;

    return Scaffold(
      backgroundColor: Colors.black,
      // Klavye acilinca body otomatik kuculmesin; biz sohbet katmanini
      // klavyenin ustune oturtuyoruz (yatay tablet: 2400x1600).
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Arka plan — tam ekran sabit (klavye acilsa da gorsel bozulmaz)
          Image.asset(
            'assets/images/ares_chat_bg.png',
            fit: BoxFit.cover,
            width: fullW,
            height: fullH,
            errorBuilder: (_, __, ___) =>
                Container(color: const Color(0xFF02050A)),
          ),

          // ===== SOHBET KATMANI: klavyenin ustundeki alan =====
          // keyboard > 0 iken alt kenar klavyenin ustune cekilir;
          // ust bar + mesajlar + yazma cubugu hep bu alanin icinde kalir.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: keyboard,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;

                // Oranlar bu "klavye ustu" yuksekligine gore
                final topBarH = h * 0.09;
                final bottomBarH = h * 0.11;
                final bottomBarTop = h * 0.88;

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // ===== UST SEFFAF ZONLAR =====
                    _zone(
                      left: w * 0.015,
                      top: topSafe + h * 0.012,
                      width: w * 0.08,
                      height: topBarH * 0.7,
                      onTap: _geri,
                    ),
                    _zone(
                      left: w * 0.70,
                      top: topSafe + h * 0.012,
                      width: w * 0.07,
                      height: topBarH * 0.7,
                      onTap: () => setState(() => _sesli = !_sesli),
                    ),
                    _zone(
                      left: w * 0.78,
                      top: topSafe + h * 0.012,
                      width: w * 0.07,
                      height: topBarH * 0.7,
                      onTap: _settingsSheet,
                    ),
                    _zone(
                      left: w * 0.88,
                      top: topSafe + h * 0.012,
                      width: w * 0.09,
                      height: topBarH * 0.7,
                      onTap: _geri,
                    ),

                    // ===== MESAJ ALANI =====
                    Positioned(
                      left: w * 0.30,
                      right: w * 0.035,
                      top: topSafe + topBarH,
                      bottom: h - bottomBarTop,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                        itemCount:
                            _aktif.mesajlar.length + (_busy ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (_busy && i == _aktif.mesajlar.length) {
                            return const Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: EdgeInsets.all(10),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF00BFFF),
                                  ),
                                ),
                              ),
                            );
                          }
                          final m = _aktif.mesajlar[i];
                          final me = m.rol == 'sen';
                          return Align(
                            alignment: me
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(vertical: 3),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              constraints:
                                  BoxConstraints(maxWidth: w * 0.40),
                              decoration: BoxDecoration(
                                color: me
                                    ? const Color(0xFF00BFFF)
                                        .withOpacity(0.30)
                                    : Colors.black.withOpacity(0.45),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFF00BFFF)
                                      .withOpacity(0.35),
                                ),
                              ),
                              child: Text(
                                m.metin,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    height: 1.3),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    // ===== ALT ZONLAR: + / mic / gonder =====
                    _zone(
                      left: w * 0.30,
                      top: bottomBarTop,
                      width: w * 0.08,
                      height: bottomBarH * 0.85,
                      onTap: _pick,
                    ),
                    _zone(
                      left: w * 0.825,
                      top: bottomBarTop,
                      width: w * 0.065,
                      height: bottomBarH * 0.85,
                      onTap: _mic ? () {} : _micTap,
                    ),
                    _zone(
                      left: w * 0.89,
                      top: bottomBarTop,
                      width: w * 0.08,
                      height: bottomBarH * 0.85,
                      onTap: _busy ? () {} : _send,
                    ),

                    // ===== YAZI ALANI =====
                    Positioned(
                      left: w * 0.38,
                      right: w * 0.20,
                      top: bottomBarTop + bottomBarH * 0.12,
                      height: bottomBarH * 0.70,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (!_focus.hasFocus) {
                            _focus.requestFocus();
                          }
                        },
                        child: TextField(
                          controller: _ctrl,
                          focusNode: _focus,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            height: 1.2,
                          ),
                          cursorColor: const Color(0xFF00BFFF),
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 10),
                            filled: false,
                          ),
                        ),
                      ),
                    ),

                    // Ek dosya chip'leri
                    if (_ekler.isNotEmpty)
                      Positioned(
                        left: w * 0.38,
                        right: w * 0.20,
                        top: bottomBarTop - 26,
                        height: 24,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: _ekler
                              .map(
                                (e) => Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Chip(
                                    label: Text(e,
                                        style: const TextStyle(
                                            fontSize: 10)),
                                    onDeleted: () =>
                                        setState(() => _ekler.remove(e)),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: Colors.black54,
                                    labelStyle: const TextStyle(
                                        color: Colors.white),
                                    deleteIconColor: Colors.white54,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
