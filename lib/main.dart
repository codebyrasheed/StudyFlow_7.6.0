import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Directory;
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

// ───────────────────────── helpers ─────────────────────────
const kExam = Color(0xFFFF6B8A);
const kAssign = Color(0xFF5CB8FF);
const kHabit = Color(0xFF4ADE80);
const kAccent = Color(0xFF8B5CF6);

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
String newId() => DateTime.now().microsecondsSinceEpoch.toString();
Color typeColor(String t) => t == 'Exam' ? kExam : kAssign;
bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color onSurf(BuildContext c) => Theme.of(c).colorScheme.onSurface;

String rel(DateTime d) {
  final diff = dateOnly(d).difference(dateOnly(DateTime.now())).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 0) return 'in $diff days';
  return '${-diff} days ago';
}

int streak(Habit h) {
  var d = DateTime.now();
  if (!h.days.contains(dayKey(d))) d = d.subtract(const Duration(days: 1));
  var n = 0;
  while (h.days.contains(dayKey(d))) {
    n++;
    d = d.subtract(const Duration(days: 1));
  }
  return n;
}

// ───────────────────────── models ─────────────────────────
class Assignment {
  String id, title, subject, type;
  DateTime date;
  bool done;
  Assignment({
    required this.id,
    required this.title,
    required this.subject,
    required this.type,
    required this.date,
    this.done = false,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subject': subject,
        'type': type,
        'date': date.millisecondsSinceEpoch,
        'done': done,
      };
  factory Assignment.fromJson(Map<String, dynamic> j) => Assignment(
        id: j['id'],
        title: j['title'],
        subject: j['subject'] ?? '',
        type: j['type'] ?? 'Assignment',
        date: DateTime.fromMillisecondsSinceEpoch(j['date']),
        done: j['done'] ?? false,
      );
}

class Habit {
  String id, name, emoji;
  String? created;
  int target;
  Map<String, int> progress;
  List<String> days;
  Habit({
    required this.id,
    required this.name,
    required this.emoji,
    List<String>? days,
    this.created,
    this.target = 1,
    Map<String, int>? progress,
  })  : days = days ?? [],
        progress = progress ?? {};
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'emoji': emoji, 'days': days, 'created': created, 'target': target, 'progress': progress};
  factory Habit.fromJson(Map<String, dynamic> j) {
    final d = List<String>.from(j['days'] ?? []);
    final earliest = d.isEmpty ? null : (List<String>.from(d)..sort()).first;
    return Habit(
      id: j['id'],
      name: j['name'],
      emoji: j['emoji'] ?? '✨',
      days: d,
      created: j['created'] ?? earliest,
      target: j['target'] ?? 1,
      progress: Map<String, int>.from(j['progress'] ?? {}),
    );
  }
}

// ───────────────────────── store ─────────────────────────
class Store extends ChangeNotifier {
  List<Assignment> assignments = [];
  List<Habit> habits = [];
  ThemeMode mode = ThemeMode.dark;
  Map<String, String> attendance = {};
  int thGreen = 85, thYellow = 75;
  List<Notif> inbox = [];
  List<Notif> plan = [];
  Map<String, bool> nOn = {'habit': true, 'assignment': true, 'exam': true, 'attendance': true};
  Map<String, int> nTime = {'habit': 1200, 'assignment': 540, 'exam': 480, 'attendance': 510};
  bool permAsked = false;
  List<QuickLink> links = [];
  Map<String, int> pomoCfg = {'focus': 25, 'short': 5, 'cycles': 4};
  bool pomoSound = true;
  String? pomoSoundPath, pomoSoundName;
  String pomoDate = '';
  int pomoCycles = 0, pomoBreaks = 0, pomoFocusSec = 0;
  SharedPreferences? _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    try {
      final a = _p!.getString('assignments');
      final h = _p!.getString('habits');
      if (a != null) {
        assignments = (jsonDecode(a) as List)
            .map((e) => Assignment.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      if (h != null) {
        habits = (jsonDecode(h) as List)
            .map((e) => Habit.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      mode = _p!.getString('mode') == 'light' ? ThemeMode.light : ThemeMode.dark;
      final att = _p!.getString('attendance');
      if (att != null) {
        attendance = Map<String, String>.from(jsonDecode(att) as Map);
      }
      thGreen = _p!.getInt('thGreen') ?? 85;
      thYellow = _p!.getInt('thYellow') ?? 75;
      final ib = _p!.getString('inbox');
      if (ib != null) {
        inbox = (jsonDecode(ib) as List)
            .map((e) => Notif.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final pl = _p!.getString('plan');
      if (pl != null) {
        plan = (jsonDecode(pl) as List)
            .map((e) => Notif.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final no = _p!.getString('nOn');
      if (no != null) nOn = {...nOn, ...Map<String, bool>.from(jsonDecode(no) as Map)};
      final nt = _p!.getString('nTime');
      if (nt != null) nTime = {...nTime, ...Map<String, int>.from(jsonDecode(nt) as Map)};
      permAsked = _p!.getBool('permAsked') ?? false;
      for (final h in habits) {
        h.created ??= dayKey(DateTime.now());
      }
      final ql = _p!.getString('links');
      if (ql != null) {
        links = (jsonDecode(ql) as List)
            .map((e) => QuickLink.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final pc = _p!.getString('pomoCfg');
      if (pc != null) {
        final m = Map<String, int>.from(jsonDecode(pc) as Map);
        pomoCfg = {
          'focus': (m['focus'] ?? 25).clamp(1, 180).toInt(),
          'short': (m['short'] ?? 5).clamp(1, 60).toInt(),
          'cycles': (m['cycles'] ?? 4).clamp(1, 12).toInt(),
        };
      }
      pomoSound = _p!.getBool('pomoSound') ?? true;
      pomoSoundPath = _p!.getString('pomoSoundPath');
      pomoSoundName = _p!.getString('pomoSoundName');
      final pd = _p!.getString('pomoDay');
      if (pd != null) {
        final m = Map<String, dynamic>.from(jsonDecode(pd) as Map);
        pomoDate = m['date'] ?? '';
        pomoCycles = m['cycles'] ?? 0;
        pomoBreaks = m['breaks'] ?? 0;
        pomoFocusSec = m['focusSec'] ?? 0;
      }
      rollPomoDay();
    } catch (_) {}
  }

  void _save() {
    _p?.setString('assignments', jsonEncode(assignments.map((e) => e.toJson()).toList()));
    _p?.setString('habits', jsonEncode(habits.map((e) => e.toJson()).toList()));
    _p?.setString('mode', mode == ThemeMode.light ? 'light' : 'dark');
    _p?.setString('attendance', jsonEncode(attendance));
    _p?.setInt('thGreen', thGreen);
    _p?.setInt('thYellow', thYellow);
    _p?.setString('nOn', jsonEncode(nOn));
    _p?.setString('nTime', jsonEncode(nTime));
    _p?.setString('links', jsonEncode(links.map((e) => e.toJson()).toList()));
    notifyListeners();
    notifier.requestSync();
  }

  List<Assignment> get sorted =>
      [...assignments]..sort((a, b) => a.date.compareTo(b.date));

  List<Assignment> get upcoming {
    final t = dateOnly(DateTime.now());
    return sorted.where((a) => !a.done && !dateOnly(a.date).isBefore(t)).toList();
  }

  void setAttendance(DateTime d, String? status) {
    final k = dayKey(d);
    if (status == null) {
      attendance.remove(k);
    } else {
      attendance[k] = status;
    }
    _save();
  }

  void setThresholds(int green, int yellow) {
    thGreen = green;
    thYellow = yellow;
    _save();
  }

  int get unread => inbox.where((n) => !n.read).length;

  /// Persists the notification inbox and plan without triggering a re-sync.
  void saveNotifs() {
    _p?.setString('inbox', jsonEncode(inbox.map((e) => e.toJson()).toList()));
    _p?.setString('plan', jsonEncode(plan.map((e) => e.toJson()).toList()));
    _p?.setBool('permAsked', permAsked);
    notifyListeners();
  }

  void markRead(String key) {
    for (final n in inbox) {
      if (n.key == key) n.read = true;
    }
    saveNotifs();
  }

  void markAllRead() {
    for (final n in inbox) {
      n.read = true;
    }
    saveNotifs();
  }

  void deleteNotif(String key) {
    inbox.removeWhere((n) => n.key == key);
    saveNotifs();
  }

  void setNotifOn(String cat, bool v) {
    nOn[cat] = v;
    _save();
  }

  void setNotifTime(String cat, int minutes) {
    nTime[cat] = minutes;
    _save();
  }

  void toggleMode() {
    mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    _save();
  }

  void addAssignment(Assignment a) {
    assignments.add(a);
    _save();
  }

  void updateAssignment(Assignment a) => _save();

  void deleteAssignment(String id) {
    assignments.removeWhere((a) => a.id == id);
    _save();
  }

  void addHabit(Habit h) {
    habits.add(h);
    _save();
  }

  /// Today's Pomodoro counters reset when the local calendar date changes.
  void rollPomoDay() {
    final t = dayKey(DateTime.now());
    if (pomoDate != t) {
      pomoDate = t;
      pomoCycles = 0;
      pomoBreaks = 0;
      pomoFocusSec = 0;
    }
  }

  void savePomo() {
    _p?.setString('pomoCfg', jsonEncode(pomoCfg));
    _p?.setBool('pomoSound', pomoSound);
    if (pomoSoundPath == null) {
      _p?.remove('pomoSoundPath');
      _p?.remove('pomoSoundName');
    } else {
      _p?.setString('pomoSoundPath', pomoSoundPath!);
      _p?.setString('pomoSoundName', pomoSoundName ?? 'Custom sound');
    }
    _p?.setString(
        'pomoDay',
        jsonEncode({
          'date': pomoDate,
          'cycles': pomoCycles,
          'breaks': pomoBreaks,
          'focusSec': pomoFocusSec,
        }));
    notifyListeners();
  }

  void setPomo(String key, int v) {
    pomoCfg[key] = v;
    savePomo();
  }

  void resetPomoConfig() {
    pomoCfg = {'focus': 25, 'short': 5, 'cycles': 4};
    savePomo();
  }

  void setPomoSound(String path, String name) {
    pomoSoundPath = path;
    pomoSoundName = name;
    savePomo();
  }

  void clearPomoSound() {
    pomoSoundPath = null;
    pomoSoundName = null;
    savePomo();
  }

  void togglePomoSound() {
    pomoSound = !pomoSound;
    savePomo();
  }

  void addPomoFocus(int seconds) {
    rollPomoDay();
    pomoCycles++;
    pomoFocusSec += seconds;
    savePomo();
  }

  void addPomoBreak() {
    rollPomoDay();
    pomoBreaks++;
    savePomo();
  }

  void addLink(QuickLink l) {
    links.add(l);
    _save();
  }

  void updateLink(QuickLink l) => _save();

  void deleteLink(String id) {
    links.removeWhere((l) => l.id == id);
    _save();
  }

  void updateHabit(Habit h) => _save();

  void reorderHabits(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final h = habits.removeAt(oldIndex);
    habits.insert(newIndex, h);
    _save();
  }

  void deleteHabit(String id) {
    habits.removeWhere((h) => h.id == id);
    _save();
  }

  /// Tap cycle: each tap adds progress; reaching the daily target completes the
  /// day; tapping a completed day resets it. A target of 1 behaves exactly as before.
  void toggleHabit(Habit h, DateTime day) {
    final k = dayKey(day);
    if (h.days.contains(k)) {
      h.days.remove(k);
      h.progress.remove(k);
    } else {
      final c = (h.progress[k] ?? 0) + 1;
      if (c >= h.target) {
        h.progress.remove(k);
        h.days.add(k);
      } else {
        h.progress[k] = c;
      }
    }
    _save();
  }
}

final store = Store();

// ───────────────────────── app ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const StudyFlowApp());
  WidgetsBinding.instance.addObserver(_LifecycleSync());
  notifier.init();
}

class _LifecycleSync with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      pomodoro.onResume();
      notifier.refreshPermission().then((_) => notifier.requestSync());
    } else if (state == AppLifecycleState.paused) {
      pomodoro.onBackground();
    }
  }
}

ThemeData buildTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: kAccent, brightness: b),
      dialogBackgroundColor: b == Brightness.dark ? const Color(0xFF1B1636) : Colors.white,
    );

class StudyFlowApp extends StatelessWidget {
  const StudyFlowApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => MaterialApp(
        navigatorKey: navKey,
        title: 'StudyFlow',
        debugShowCheckedModeBanner: false,
        themeMode: store.mode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const Shell(),
      ),
    );
  }
}

// ───────────────────────── glass widgets ─────────────────────────
class Glass extends StatefulWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final double? opacity;
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.onTap,
    this.opacity,
  });

  @override
  State<Glass> createState() => _GlassState();
}

class _GlassState extends State<Glass> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    final o = widget.opacity ?? (d ? 0.10 : 0.65);
    final r = BorderRadius.circular(widget.radius);
    final box = RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: widget.padding,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white.withOpacity(o), Colors.white.withOpacity(o * 0.45)],
              ),
              borderRadius: r,
              border: Border.all(color: Colors.white.withOpacity(d ? 0.16 : 0.85)),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
    if (widget.onTap == null) return box;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: box,
      ),
    );
  }
}

class Orb extends StatelessWidget {
  final Color color;
  final double size;
  const Orb(this.color, this.size, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withOpacity(0)]),
        ),
      );
}

class Background extends StatelessWidget {
  const Background({super.key});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    return Stack(fit: StackFit.expand, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: d
                ? const [Color(0xFF0A0A18), Color(0xFF15102E), Color(0xFF0B1426)]
                : const [Color(0xFFEDE9FE), Color(0xFFE0ECFF), Color(0xFFFCE7F3)],
          ),
        ),
      ),
      Positioned(top: -90, left: -80, child: Orb(kAccent.withOpacity(d ? 0.55 : 0.40), 320)),
      Positioned(top: 260, right: -140, child: Orb(const Color(0xFF22D3EE).withOpacity(d ? 0.35 : 0.30), 360)),
      Positioned(bottom: -120, left: -60, child: Orb(const Color(0xFFEC4899).withOpacity(d ? 0.35 : 0.28), 340)),
    ]);
  }
}

class GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  const GlassIconBtn(this.icon, this.onTap, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Glass(
        radius: 16,
        padding: const EdgeInsets.all(11),
        onTap: onTap,
        child: Icon(icon, size: 22, color: color ?? onSurf(context)),
      );
}

class PageHeader extends StatelessWidget {
  final String title, subtitle;
  final Widget? action;
  const PageHeader({super.key, required this.title, required this.subtitle, this.action});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 13.5, color: on.withOpacity(0.6))),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        if (action != null) ...[action!, const SizedBox(width: 8)],
        const NotificationBell(),
        const SizedBox(width: 8),
        GlassIconBtn(
          isDark(context) ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          store.toggleMode,
        ),
      ]),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 20, 12),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: onSurf(context))),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

class EmptyCard extends StatelessWidget {
  final String emoji, text;
  const EmptyCard(this.emoji, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Glass(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
          child: SizedBox(
            width: double.infinity,
            child: Column(children: [
              Text(emoji, style: const TextStyle(fontSize: 34)),
              const SizedBox(height: 8),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: onSurf(context).withOpacity(0.65))),
            ]),
          ),
        ),
      );
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  const Pill(this.text, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      );
}

Future<bool> confirmDelete(BuildContext c, String what) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (x) => AlertDialog(
      title: const Text('Delete?'),
      content: Text('Delete "$what"? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(x, true), child: const Text('Delete')),
      ],
    ),
  );
  return r ?? false;
}

InputDecoration deco(BuildContext c, String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: onSurf(c).withOpacity(0.07),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );

// ───────────────────────── shell ─────────────────────────
final navIndex = ValueNotifier<int>(0);

class Shell extends StatelessWidget {
  const Shell({super.key});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    const pages = [DashboardPage(), AssignmentsPage(), CalendarPage(), AttendancePage()];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (d ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      child: Stack(children: [
        const Positioned.fill(child: Background()),
        Scaffold(
          extendBody: true,
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: ValueListenableBuilder<int>(
              valueListenable: navIndex,
              builder: (c, idx, _) => AnimatedPage(index: idx, pages: pages),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ValueListenableBuilder<int>(
                valueListenable: navIndex,
                builder: (c, idx, _) =>
                    NavBar(idx: idx, onTap: (i) => navIndex.value = i),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class NavBar extends StatelessWidget {
  final int idx;
  final ValueChanged<int> onTap;
  const NavBar({super.key, required this.idx, required this.onTap});
  @override
  Widget build(BuildContext context) {
    const icons = [
      Icons.dashboard_rounded,
      Icons.assignment_rounded,
      Icons.calendar_month_rounded,
      Icons.how_to_reg_rounded,
    ];
    const labels = ['Dashboard', 'Assignments', 'Calendar', 'Attendance'];
    final on = onSurf(context);
    return Glass(
      radius: 28,
      padding: const EdgeInsets.all(6),
      opacity: isDark(context) ? 0.12 : 0.75,
      child: Row(
        children: List.generate(4, (i) {
          final sel = i == idx;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: sel ? kAccent.withOpacity(0.28) : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedScale(
                    scale: sel ? 1.15 : 1,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutBack,
                    child: Icon(icons[i], color: sel ? kAccent : on.withOpacity(0.55)),
                  ),
                  const SizedBox(height: 2),
                  Text(labels[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? kAccent : on.withOpacity(0.55),
                      )),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ───────────────────────── dashboard ─────────────────────────
class StatCard extends StatelessWidget {
  final String value, label;
  final Color color;
  const StatCard(this.value, this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Glass(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        child: SizedBox(
          width: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.65))),
          ]),
        ),
      );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final today = DateTime.now();
        final up = store.upcoming;
        final exams = up.where((a) => a.type == 'Exam').length;
        return RevealList(
          page: 'dash',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Dashboard',
              subtitle: DateFormat('EEEE, d MMMM').format(today),
              action: GlassIconBtn(
                Icons.grid_view_rounded,
                () => openScreen(c, const ToolsHubPage()),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: HabitsTodayCard(),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Expanded(child: StatCard('$exams', 'Upcoming exams', kExam)),
                const SizedBox(width: 10),
                Expanded(child: StatCard('${up.length - exams}', 'Assignments due', kAssign)),
              ]),
            ),
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: AttendanceSummary(),
            ),
            const SizedBox(height: 6),
            SectionTitle(
              'My Habits',
              trailing: GlassIconBtn(Icons.add_rounded, () => showHabitSheet(c)),
            ),
            if (store.habits.isEmpty)
              const EmptyCard('🌱', 'No habits yet.\nTap + to start tracking one.')
            else
              const HabitReorderList(),
            const SectionTitle('Coming up'),
            if (up.isEmpty)
              const EmptyCard('🎉', 'Nothing due. Enjoy the free time!')
            else
              ...up.take(3).map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
          ],
        );
      },
    );
  }
}

class HabitTile extends StatelessWidget {
  final Habit h;
  const HabitTile({super.key, required this.h});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final today = dateOnly(DateTime.now());
    final done = h.days.contains(dayKey(today));
    final cnt = h.progress[dayKey(today)] ?? 0;
    final partial = !done && cnt > 0;
    final s = streak(h);
    final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.all(14),
        onTap: () => showHabitDetails(context, h),
        child: Row(children: [
          Expanded(
            child: AnimatedOpacity(
              opacity: done ? 0.6 : 1,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: Row(children: [
                Container(
                  width: 50,
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kHabit.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(h.emoji, style: const TextStyle(fontSize: 24)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(h.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
                    const SizedBox(height: 3),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      layoutBuilder: (cur, prev) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...prev, if (cur != null) cur],
                      ),
                      child: Text(
                          (s > 0 ? '🔥 $s day streak' : 'Start your streak today') +
                              (partial ? ' · $cnt/${h.target} today' : ''),
                          key: ValueKey('$s|$cnt'),
                          style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: List.generate(7, (i) {
                        final d = DateTime(monday.year, monday.month, monday.day + i);
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 5),
                          decoration: squareDeco(habitDay(h, d, today), on),
                        );
                      }),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => store.toggleHabit(h, today),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? kHabit : Colors.transparent,
                border: Border.all(
                  color: done ? kHabit : (partial ? kPartial : on.withOpacity(0.35)),
                  width: 2,
                ),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
                child: done
                    ? const Icon(Icons.check_rounded, key: ValueKey('c'), size: 22, color: Colors.white)
                    : (partial
                        ? FittedBox(
                            key: ValueKey('p$cnt'),
                            fit: BoxFit.scaleDown,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: Text('$cnt/${h.target}',
                                  style: const TextStyle(
                                      fontSize: 11, fontWeight: FontWeight.w800, color: kPartial)),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('n'))),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

Future<void> showHabitSheet(BuildContext context, {Habit? habit}) {
  final name = TextEditingController(text: habit?.name ?? '');
  String emoji = habit?.emoji ?? '💧';
  int target = habit?.target ?? 1;
  final options = ['💧', '📚', '🏃', '🧘', '💪', '🥗', '😴', '✍️', '🎧', '🧹', '💻', '🙏'];
  if (!options.contains(emoji)) options.insert(0, emoji);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(habit == null ? 'New habit' : 'Edit habit',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: onSurf(ctx))),
            const SizedBox(height: 16),
            TextField(controller: name, decoration: deco(ctx, 'Habit name (e.g. Drink water)')),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: options.map((e) {
                final sel = e == emoji;
                return GestureDetector(
                  onTap: () => set(() => emoji = e),
                  child: Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: sel ? kAccent.withOpacity(0.3) : onSurf(ctx).withOpacity(0.07),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: sel ? kAccent : Colors.transparent, width: 2),
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 22)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Daily target',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: onSurf(ctx))),
                  Text(
                    target == 1
                        ? 'Complete once a day'
                        : 'Complete $target times to finish the day',
                    style: TextStyle(fontSize: 12, color: onSurf(ctx).withOpacity(0.6)),
                  ),
                ]),
              ),
              IconButton.filledTonal(
                onPressed: target > 1 ? () => set(() => target--) : null,
                icon: const Icon(Icons.remove_rounded),
              ),
              SizedBox(
                width: 38,
                child: Center(
                  child: Text('$target',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: onSurf(ctx))),
                ),
              ),
              IconButton.filledTonal(
                onPressed: target < 20 ? () => set(() => target++) : null,
                icon: const Icon(Icons.add_rounded),
              ),
            ]),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: kAccent,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                onPressed: () {
                  if (name.text.trim().isEmpty) return;
                  if (habit == null) {
                    store.addHabit(Habit(
                      id: newId(),
                      name: name.text.trim(),
                      emoji: emoji,
                      target: target,
                      created: dayKey(DateTime.now()),
                    ));
                  } else {
                    habit.name = name.text.trim();
                    habit.emoji = emoji;
                    habit.target = target;
                    final promote = habit.progress.entries
                        .where((e) => e.value >= target)
                        .map((e) => e.key)
                        .toList();
                    for (final k in promote) {
                      habit.progress.remove(k);
                      if (!habit.days.contains(k)) habit.days.add(k);
                    }
                    store.updateHabit(habit);
                  }
                  Navigator.pop(ctx);
                },
                child: Text(habit == null ? 'Add habit' : 'Save changes',
                    style: const TextStyle(fontSize: 16)),
              ),
            ),
          ]),
        ),
      );
    }),
  );
}

// ───────────────────────── assignments ─────────────────────────
class AssignmentTile extends StatelessWidget {
  final Assignment a;
  const AssignmentTile({super.key, required this.a});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final c = typeColor(a.type);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        onTap: () => showAssignmentDetails(context, a),
        child: Row(children: [
          Container(
            width: 54,
            height: 58,
            decoration: BoxDecoration(
              color: c.withOpacity(0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(DateFormat('d').format(a.date),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c)),
              Text(DateFormat('MMM').format(a.date).toUpperCase(),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: on.withOpacity(a.done ? 0.5 : 1),
                  decoration: a.done ? TextDecoration.lineThrough : null,
                ),
                child: Text(a.title),
              ),
              if (a.subject.isNotEmpty)
                Text(a.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(height: 6),
              Row(children: [
                Pill(a.type, c),
                const SizedBox(width: 8),
                Text(rel(a.date), style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
              ]),
            ]),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutBack,
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: anim,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Icon(
                  a.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(a.done),
                  color: a.done ? kHabit : on.withOpacity(0.5),
                ),
              ),
              onPressed: () {
                a.done = !a.done;
                store.updateAssignment(a);
              },
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<void> showAssignmentSheet(BuildContext context, {Assignment? a, DateTime? date}) {
  final title = TextEditingController(text: a?.title ?? '');
  final subject = TextEditingController(text: a?.subject ?? '');
  String type = a?.type ?? 'Assignment';
  DateTime d = a?.date ?? date ?? DateTime.now();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a == null ? 'New entry' : 'Edit entry',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: onSurf(ctx))),
              const SizedBox(height: 16),
              TextField(controller: title, decoration: deco(ctx, 'Title (e.g. Maths Final)')),
              const SizedBox(height: 12),
              TextField(controller: subject, decoration: deco(ctx, 'Subject (optional)')),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Assignment', label: Text('Assignment'), icon: Icon(Icons.edit_note_rounded)),
                    ButtonSegment(value: 'Exam', label: Text('Exam'), icon: Icon(Icons.school_rounded)),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => set(() => type = s.first),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.event_rounded),
                  label: Text(DateFormat('EEE, d MMM yyyy').format(d)),
                  onPressed: () async {
                    final p = await showDatePicker(
                      context: ctx,
                      initialDate: d,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (p != null) set(() => d = p);
                  },
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: () {
                    if (title.text.trim().isEmpty) return;
                    if (a == null) {
                      store.addAssignment(Assignment(
                        id: newId(),
                        title: title.text.trim(),
                        subject: subject.text.trim(),
                        type: type,
                        date: d,
                      ));
                    } else {
                      a.title = title.text.trim();
                      a.subject = subject.text.trim();
                      a.type = type;
                      a.date = d;
                      store.updateAssignment(a);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(a == null ? 'Add' : 'Save changes', style: const TextStyle(fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

class AssignmentsPage extends StatefulWidget {
  const AssignmentsPage({super.key});
  @override
  State<AssignmentsPage> createState() => _AssignmentsPageState();
}

class _AssignmentsPageState extends State<AssignmentsPage> {
  String filter = 'All';
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final today = dateOnly(DateTime.now());
        final all = store.sorted.where((a) => filter == 'All' || a.type == filter).toList();
        final overdue = all.where((a) => !a.done && dateOnly(a.date).isBefore(today)).toList();
        final upcoming = all.where((a) => !a.done && !dateOnly(a.date).isBefore(today)).toList();
        final done = all.where((a) => a.done).toList();
        return RevealList(
          page: 'asg',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Assignments',
              subtitle: 'Exams & deadlines by date',
              action: GlassIconBtn(Icons.add_rounded, () => showAssignmentSheet(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Wrap(
                spacing: 8,
                children: ['All', 'Exam', 'Assignment'].map((f) {
                  return ChoiceChip(
                    label: Text(f == 'All' ? 'All' : '${f}s'),
                    selected: filter == f,
                    selectedColor: kAccent.withOpacity(0.35),
                    onSelected: (_) => setState(() => filter = f),
                  );
                }).toList(),
              ),
            ),
            if (all.isEmpty) const EmptyCard('📚', 'Nothing here yet.\nTap + to add an exam or assignment.'),
            if (overdue.isNotEmpty) ...[
              const SectionTitle('Overdue'),
              ...overdue.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ],
            if (upcoming.isNotEmpty) ...[
              const SectionTitle('Upcoming'),
              ...upcoming.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ],
            if (done.isNotEmpty) ...[
              const SectionTitle('Completed'),
              ...done.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ],
          ],
        );
      },
    );
  }
}

// ───────────────────────── calendar ─────────────────────────
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime focused = DateTime.now();
  DateTime selected = DateTime.now();

  Widget legend(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(fontSize: 12.5, color: onSurf(context).withOpacity(0.7))),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final dayAssign = store.sorted.where((a) => sameDay(a.date, selected)).toList();
        return RevealList(
          page: 'cal',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            const PageHeader(title: 'Calendar', subtitle: 'Exams, assignments & habits'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
                child: TableCalendar<Object>(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2100, 12, 31),
                  focusedDay: focused,
                  rowHeight: 48,
                  pageAnimationDuration: const Duration(milliseconds: 300),
                  pageAnimationCurve: Curves.easeInOutCubic,
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  selectedDayPredicate: (d) => isSameDay(selected, d),
                  onDaySelected: (s, f) => setState(() {
                    selected = s;
                    focused = f;
                  }),
                  onPageChanged: (f) => focused = f,
                  eventLoader: (day) => <Object>[
                    ...store.assignments.where((a) => sameDay(a.date, day)),
                  ],
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(color: on, fontSize: 17, fontWeight: FontWeight.w700),
                    leftChevronIcon: Icon(Icons.chevron_left_rounded, color: on),
                    rightChevronIcon: Icon(Icons.chevron_right_rounded, color: on),
                  ),
                  daysOfWeekStyle: DaysOfWeekStyle(
                    weekdayStyle: TextStyle(color: on.withOpacity(0.6), fontSize: 12),
                    weekendStyle: TextStyle(color: on.withOpacity(0.6), fontSize: 12),
                  ),
                  calendarStyle: CalendarStyle(
                    outsideDaysVisible: false,
                    defaultTextStyle: TextStyle(color: on),
                    weekendTextStyle: TextStyle(color: on.withOpacity(0.85)),
                    todayTextStyle: TextStyle(color: on, fontWeight: FontWeight.w700),
                    todayDecoration: BoxDecoration(
                      color: kAccent.withOpacity(0.35),
                      shape: BoxShape.circle,
                    ),
                    selectedTextStyle:
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    selectedDecoration:
                        const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                  ),
                  calendarBuilders: CalendarBuilders<Object>(
                    markerBuilder: (ctx, day, events) {
                      if (events.isEmpty) return null;
                      final exam = events.any((e) => e is Assignment && e.type == 'Exam');
                      final asg = events.any((e) => e is Assignment && e.type != 'Exam');
                      Widget dot(Color col) => Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                            decoration: BoxDecoration(color: col, shape: BoxShape.circle),
                          );
                      return Positioned(
                        bottom: 4,
                        child: PopIn(child: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (exam) dot(kExam),
                          if (asg) dot(kAssign),
                        ])),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 20, 0),
              child: Wrap(spacing: 18, children: [
                legend('Exam', kExam),
                legend('Assignment', kAssign),
              ]),
            ),
            const SizedBox(height: 6),
            SectionTitle(
              DateFormat('EEEE, d MMM').format(selected),
              trailing: GlassIconBtn(Icons.add_rounded, () => showAssignmentSheet(c, date: selected)),
            ),
            if (dayAssign.isEmpty)
              const EmptyCard('🗓️', 'Nothing scheduled for this day.'),
            ...dayAssign.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            const SectionTitle('Habit Streak Tracker'),
            if (store.habits.isEmpty)
              const EmptyCard('🔥', 'Add a habit on the Dashboard to start your streak tracker.')
            else ...[
              HabitHeatmapCard(),
              HabitGraphCard(),
            ],
          ],
        );
      },
    );
  }
}


// ───────────────────────── attendance ─────────────────────────
const kPresent = Color(0xFF4ADE80);
const kSelfLeave = Color(0xFFFF6B8A);
const kHoliday = Color(0xFF9CA3AF);
const kWarn = Color(0xFFFACC15);
const kBad = Color(0xFFF87171);

bool isWeekend(DateTime d) => d.weekday >= 6;
DateTime prevDay(DateTime d) => DateTime(d.year, d.month, d.day - 1);
DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

Color attColor(String s) =>
    s == 'present' ? kPresent : (s == 'self' ? kSelfLeave : kHoliday);

String attLabel(String s) {
  if (s == 'present') return 'Present';
  if (s == 'self') return 'Self leave';
  if (s == 'public') return 'Public holiday';
  return 'College holiday';
}

IconData attIcon(String? s) {
  if (s == 'present') return Icons.check_circle_rounded;
  if (s == 'self') return Icons.person_off_rounded;
  if (s == null) return Icons.help_outline_rounded;
  return Icons.beach_access_rounded;
}

class AttStats {
  int present = 0, absent = 0, holidays = 0;
  int get working => present + absent;
  double? get pct => working == 0 ? null : present * 100 / working;
}

AttStats attStats({int? year, int? month}) {
  final st = AttStats();
  store.attendance.forEach((k, v) {
    final d = DateTime.parse(k);
    if (year != null && (d.year != year || d.month != month)) return;
    if (v == 'present') {
      st.present++;
    } else if (v == 'self') {
      st.absent++;
    } else {
      st.holidays++;
    }
  });
  return st;
}

Color pctColor(double? p) {
  if (p == null) return kHoliday;
  if (p >= store.thGreen) return kPresent;
  if (p >= store.thYellow) return kWarn;
  return kBad;
}

String pctLabel(double? p) {
  if (p == null) return 'No data yet';
  if (p >= store.thGreen) return 'On track';
  if (p >= store.thYellow) return 'Needs attention';
  return 'Low attendance';
}

/// Returns [current, longest] streak of attended days.
/// Weekends and holidays are skipped. Self leave and unrecorded weekdays break a streak.
List<int> attStreaks() {
  final a = store.attendance;
  if (a.isEmpty) return [0, 0];
  final today = dateOnly(DateTime.now());
  final first = a.keys.map(DateTime.parse).reduce((x, y) => x.isBefore(y) ? x : y);

  var cur = 0;
  var d = today;
  while (!d.isBefore(first)) {
    final v = a[dayKey(d)];
    if (v == 'present') {
      cur++;
    } else if (v == 'public' || v == 'college') {
    } else if (v == null && (isWeekend(d) || sameDay(d, today))) {
    } else {
      break;
    }
    d = prevDay(d);
  }

  var run = 0, best = 0;
  for (var x = first; !x.isAfter(today); x = nextDay(x)) {
    final v = a[dayKey(x)];
    if (v == 'present') {
      run++;
      if (run > best) best = run;
    } else if (v == 'public' || v == 'college') {
    } else if (v == null && (isWeekend(x) || sameDay(x, today))) {
    } else {
      run = 0;
    }
  }
  return [cur, best];
}

/// Present days divided by elapsed weekdays (holidays excluded). Unrecorded weekdays count against it.
double? attConsistency(int year, int month) {
  final today = dateOnly(DateTime.now());
  final dim = DateUtils.getDaysInMonth(year, month);
  var den = 0, att = 0;
  for (var i = 1; i <= dim; i++) {
    final d = DateTime(year, month, i);
    if (d.isAfter(today)) break;
    final v = store.attendance[dayKey(d)];
    if (sameDay(d, today) && v == null) continue;
    if (v == 'present') att++;
    if (!isWeekend(d) && v != 'public' && v != 'college') den++;
  }
  if (den == 0) return null;
  return (att * 100 / den).clamp(0, 100).toDouble();
}

Future<void> showAttendanceSheet(BuildContext context, DateTime day) {
  final today = dateOnly(DateTime.now());
  final isFuture = dateOnly(day).isAfter(today);
  final current = store.attendance[dayKey(day)];
  String? choice = current;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);

      Widget option(String code, String label, IconData icon) {
        final sel = choice == code;
        final col = attColor(code);
        return Expanded(
          child: GestureDetector(
            onTap: () => set(() => choice = code),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              decoration: BoxDecoration(
                color: sel ? col.withOpacity(0.22) : on.withOpacity(0.07),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: sel ? col : Colors.transparent, width: 1.6),
              ),
              child: Row(children: [
                Icon(icon, size: 20, color: col),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                          color: on)),
                ),
              ]),
            ),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(DateFormat('EEEE, d MMMM yyyy').format(day),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 8),
            Row(children: [
              Text('Current status', style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(width: 8),
              Pill(current == null ? 'Not recorded' : attLabel(current),
                  current == null ? kAccent : attColor(current)),
            ]),
            const SizedBox(height: 18),
            if (isFuture) ...[
              Text("Attendance can't be recorded for future dates.",
                  style: TextStyle(fontSize: 14, color: on.withOpacity(0.7))),
              const SizedBox(height: 18),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Got it'),
              ),
            ] else ...[
              Row(children: [
                option('present', 'Present', Icons.check_circle_rounded),
                const SizedBox(width: 10),
                option('self', 'Self leave', Icons.person_off_rounded),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                option('public', 'Public holiday', Icons.flag_rounded),
                const SizedBox(width: 10),
                option('college', 'College holiday', Icons.school_rounded),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                if (current != null) ...[
                  TextButton(
                    onPressed: () {
                      store.setAttendance(day, null);
                      Navigator.pop(ctx);
                    },
                    child: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccent,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    onPressed: (choice == null || choice == current)
                        ? null
                        : () {
                            store.setAttendance(day, choice);
                            Navigator.pop(ctx);
                          },
                    child: const Text('Save', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      );
    }),
  );
}

Future<void> showNoReasonSheet(BuildContext context, DateTime day) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final on = onSurf(ctx);
      Widget reason(IconData icon, String t, String sub, String code, Color col) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              radius: 18,
              padding: const EdgeInsets.all(14),
              onTap: () {
                store.setAttendance(day, code);
                Navigator.pop(ctx);
              },
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: col.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: col),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                    Text(sub, style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                  ]),
                ),
              ]),
            ),
          );
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Why not?', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 14),
            reason(Icons.flag_rounded, 'Public holiday', 'Excluded from working days', 'public', kHoliday),
            reason(Icons.school_rounded, 'College holiday', 'Excluded from working days', 'college', kHoliday),
            reason(Icons.person_off_rounded, 'Self leave', 'Counts as absent', 'self', kSelfLeave),
          ]),
        ),
      );
    },
  );
}

Future<void> showThresholdSheet(BuildContext context) {
  var g = store.thGreen;
  var y = store.thYellow;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance thresholds',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 4),
            Text('Choose where green and yellow start.',
                style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
            const SizedBox(height: 18),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kPresent),
              const SizedBox(width: 8),
              Expanded(child: Text('Green from $g%', style: TextStyle(fontWeight: FontWeight.w600, color: on))),
            ]),
            Slider(
              value: g.toDouble(),
              min: 51,
              max: 100,
              divisions: 49,
              label: '$g%',
              onChanged: (v) => set(() {
                g = v.round();
                if (y >= g) y = g - 1;
              }),
              onChangeEnd: (_) => store.setThresholds(g, y),
            ),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kWarn),
              const SizedBox(width: 8),
              Expanded(child: Text('Yellow from $y%', style: TextStyle(fontWeight: FontWeight.w600, color: on))),
            ]),
            Slider(
              value: y.toDouble(),
              min: 50,
              max: 99,
              divisions: 49,
              label: '$y%',
              onChanged: (v) => set(() {
                y = v.round();
                if (g <= y) g = y + 1;
              }),
              onChangeEnd: (_) => store.setThresholds(g, y),
            ),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kBad),
              const SizedBox(width: 8),
              Text('Red below $y%', style: TextStyle(fontWeight: FontWeight.w600, color: on)),
            ]),
          ]),
        ),
      );
    }),
  );
}

class AttendanceSummary extends StatelessWidget {
  const AttendanceSummary({super.key});
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: store, builder: (c, _) => _body(c));

  Widget _body(BuildContext context) {
    final on = onSurf(context);
    final v = store.attendance[dayKey(DateTime.now())];
    final p = attStats().pct;
    final st = attStreaks();
    final col = v == null ? kAccent : attColor(v);
    return Glass(
      padding: const EdgeInsets.all(14),
      onTap: () => navIndex.value = 3,
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: col.withOpacity(0.2),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(attIcon(v), color: col),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance today',
                style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
            Text(v == null ? 'Not marked yet' : attLabel(v),
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(p == null ? '–' : '${p.round()}%',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: pctColor(p))),
          Text('overall', style: TextStyle(fontSize: 11, color: on.withOpacity(0.6))),
        ]),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${st[0]}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kWarn)),
          Text('streak', style: TextStyle(fontSize: 11, color: on.withOpacity(0.6))),
        ]),
      ]),
    );
  }
}

class MiniStat extends StatelessWidget {
  final String value, label;
  final Color color;
  const MiniStat(this.value, this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: onSurf(context).withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.65))),
          ),
        ]),
      );
}

class Heatmap extends StatelessWidget {
  final DateTime month, selected;
  final ValueChanged<DateTime> onSelect;
  const Heatmap({super.key, required this.month, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final today = dateOnly(DateTime.now());
    final dim = DateUtils.getDaysInMonth(month.year, month.month);
    final offset = DateTime(month.year, month.month, 1).weekday - 1;
    final cols = ((offset + dim) / 7).ceil();
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return LayoutBuilder(builder: (c, box) {
      const gap = 6.0;
      const lw = 22.0;
      final cell = ((box.maxWidth - lw - cols * gap) / cols).clamp(20.0, 42.0).toDouble();
      return Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(
          children: List.generate(
            7,
            (r) => SizedBox(
              width: lw,
              height: cell + gap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(labels[r],
                    style: TextStyle(fontSize: 11, color: on.withOpacity(0.5))),
              ),
            ),
          ),
        ),
        ...List.generate(
          cols,
          (col) => Column(
            children: List.generate(7, (r) {
              final day = col * 7 + r - offset + 1;
              if (day < 1 || day > dim) {
                return SizedBox(width: cell + gap, height: cell + gap);
              }
              final date = DateTime(month.year, month.month, day);
              final v = store.attendance[dayKey(date)];
              final sel = sameDay(date, selected);
              final isToday = sameDay(date, today);
              final fill = sel
                  ? kAccent
                  : (v == null ? on.withOpacity(0.08) : attColor(v).withOpacity(0.9));
              final txt = sel
                  ? Colors.white
                  : (v == null ? on.withOpacity(0.55) : const Color(0xFF10101C));
              return SizedBox(
                width: cell + gap,
                height: cell + gap,
                child: Padding(
                  padding: const EdgeInsets.only(right: gap, bottom: gap),
                  child: GestureDetector(
                    onTap: () => onSelect(date),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      transformAlignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(sel ? 1.1 : 1.0, sel ? 1.1 : 1.0, 1.0),
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(cell * 0.28),
                        border: isToday && !sel
                            ? Border.all(color: on.withOpacity(0.7), width: 1.5)
                            : null,
                      ),
                      child: Stack(alignment: Alignment.center, children: [
                        Text('$day',
                            style: TextStyle(
                                fontSize: 11.5, fontWeight: FontWeight.w600, color: txt)),
                        if (sel && v != null)
                          Positioned(
                            bottom: 3,
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: attColor(v),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ]);
    });
  }
}

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime selected = dateOnly(DateTime.now());

  bool overall = false;

  void goMonth(int delta) {
    final m = DateTime(month.year, month.month + delta);
    final now = DateTime.now();
    setState(() {
      month = m;
      selected = (m.year == now.year && m.month == now.month) ? dateOnly(now) : m;
    });
  }

  Widget legendItem(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.7))),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final today = dateOnly(DateTime.now());
        final todayV = store.attendance[dayKey(today)];
        final ms = attStats(year: month.year, month: month.month);
        final all = attStats();
        final shown = overall ? all : ms;
        final p = shown.pct;
        final pc = pctColor(p);
        final other = overall ? ms.pct : all.pct;
        final st = attStreaks();
        final cons = attConsistency(month.year, month.month);

        return RevealList(
          page: 'att',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Attendance',
              subtitle: 'Track your college days',
              action: GlassIconBtn(Icons.tune_rounded, () => showThresholdSheet(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: todayV == null
                      ? Column(
                          key: const ValueKey('ask'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Are you going to college today?',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
                            const SizedBox(height: 14),
                            Row(children: [
                              Expanded(
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: kPresent,
                                    foregroundColor: const Color(0xFF0B1F12),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: () => store.setAttendance(today, 'present'),
                                  child: const Text('Yes',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: () => showNoReasonSheet(c, today),
                                  child: const Text('No',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ]),
                          ],
                        )
                      : Row(key: const ValueKey('done'), children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: attColor(todayV).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(attIcon(todayV), color: attColor(todayV)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Today · ${DateFormat('EEE, d MMM').format(today)}',
                                  style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                              Text(attLabel(todayV),
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: on)),
                            ]),
                          ),
                        ]),
                ),
              ),
            ),
            SectionTitle(
              'Analytics',
              trailing: Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: Text(DateFormat('MMMM').format(month)),
                  selected: !overall,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => overall = false),
                ),
                ChoiceChip(
                  label: const Text('Overall'),
                  selected: overall,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => overall = true),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: Column(children: [
                  Row(children: [
                    SizedBox(
                      width: 96,
                      height: 96,
                      child: Stack(alignment: Alignment.center, children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: (p ?? 0) / 100),
                          duration: const Duration(milliseconds: 800),
                          curve: Curves.easeOutCubic,
                          builder: (ctx, v, _) => SizedBox(
                            width: 96,
                            height: 96,
                            child: CircularProgressIndicator(
                              value: v,
                              strokeWidth: 9,
                              strokeCap: StrokeCap.round,
                              backgroundColor: on.withOpacity(0.1),
                              valueColor: AlwaysStoppedAnimation<Color>(pc),
                            ),
                          ),
                        ),
                        Text(p == null ? '–' : '${p.round()}%',
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
                      ]),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(overall ? 'All time' : DateFormat('MMMM yyyy').format(month),
                            style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                        const SizedBox(height: 4),
                        Pill(pctLabel(p), pc),
                        const SizedBox(height: 8),
                        Text(
                          other == null
                              ? (overall ? 'This month: no data' : 'Overall: no data')
                              : (overall
                                  ? 'This month: ${other.round()}%'
                                  : 'Overall: ${other.round()}%'),
                          style: TextStyle(fontSize: 13, color: on.withOpacity(0.7)),
                        ),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: MiniStat('${shown.working}', 'Working days', kAssign)),
                    const SizedBox(width: 10),
                    Expanded(child: MiniStat('${shown.present}', 'Present', kPresent)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: MiniStat('${shown.absent}', 'Absent', kSelfLeave)),
                    const SizedBox(width: 10),
                    Expanded(child: MiniStat('${shown.holidays}', 'Holidays', kHoliday)),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                    'Present days divided by working days. Holidays and unrecorded days are left out.',
                    style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.55)),
                  ),
                ]),
              ),
            ),
            SectionTitle('Attendance Calendar'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: Column(children: [
                  Row(children: [
                    IconButton(
                      icon: Icon(Icons.chevron_left_rounded, color: on),
                      onPressed: () => goMonth(-1),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          DateFormat('MMMM yyyy').format(month),
                          key: ValueKey(month),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: on),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.chevron_right_rounded, color: on),
                      onPressed: () => goMonth(1),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: KeyedSubtree(
                      key: ValueKey(month),
                      child: Heatmap(
                        month: month,
                        selected: selected,
                        onSelect: (d) {
                          setState(() => selected = d);
                          showAttendanceSheet(c, d);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 14, runSpacing: 6, children: [
                    legendItem('Present', kPresent),
                    legendItem('Self leave', kSelfLeave),
                    legendItem('Holiday', kHoliday),
                  ]),
                ]),
              ),
            ),
            SectionTitle('Streaks & Consistency'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: Row(children: [
                  Expanded(child: _streakCell(Icons.local_fire_department_rounded, '${st[0]}', 'Current', kWarn)),
                  Expanded(child: _streakCell(Icons.emoji_events_rounded, '${st[1]}', 'Longest', kAccent)),
                  Expanded(
                    child: _streakCell(Icons.insights_rounded,
                        cons == null ? '–' : '${cons.round()}%', 'Consistency', kPresent),
                  ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _streakCell(IconData icon, String value, String label, Color color) {
    final on = onSurf(context);
    return Column(children: [
      Icon(icon, color: color, size: 26),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
      Text(label, style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
    ]);
  }
}


// ───────────────────────── smart notifications ─────────────────────────
const kNotifCats = ['habit', 'assignment', 'exam', 'attendance'];

final navKey = GlobalKey<NavigatorState>();
final notifier = Notifier();

String catLabel(String c) {
  if (c == 'habit') return 'Habits';
  if (c == 'assignment') return 'Assignments';
  if (c == 'exam') return 'Exams';
  return 'Attendance';
}

IconData catIcon(String c) {
  if (c == 'habit') return Icons.task_alt_rounded;
  if (c == 'assignment') return Icons.assignment_rounded;
  if (c == 'exam') return Icons.school_rounded;
  return Icons.how_to_reg_rounded;
}

Color catColor(String c) {
  if (c == 'habit') return kHabit;
  if (c == 'assignment') return kAssign;
  if (c == 'exam') return kExam;
  return kAccent;
}

int tabFor(String cat) => cat == 'habit' ? 0 : (cat == 'attendance' ? 3 : 1);

String notifTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  final time = DateFormat('h:mm a').format(t);
  if (sameDay(t, now)) return 'Today, $time';
  if (sameDay(t, DateTime(now.year, now.month, now.day - 1))) return 'Yesterday, $time';
  return '${DateFormat('d MMM').format(t)}, $time';
}

class Notif {
  String key, cat, title, body;
  int at;
  bool read;
  Notif({
    required this.key,
    required this.cat,
    required this.title,
    required this.body,
    required this.at,
    this.read = false,
  });
  Map<String, dynamic> toJson() =>
      {'key': key, 'cat': cat, 'title': title, 'body': body, 'at': at, 'read': read};
  factory Notif.fromJson(Map<String, dynamic> j) => Notif(
        key: j['key'],
        cat: j['cat'],
        title: j['title'],
        body: j['body'],
        at: j['at'],
        read: j['read'] ?? false,
      );
}

class Notifier {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<bool> allowed = ValueNotifier<bool>(true);
  bool ready = false;
  bool _syncing = false, _again = false;
  Timer? _debounce, _tick;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    try {
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => _open(r.payload),
      );
      final a = _android;
      for (final c in kNotifCats) {
        await a?.createNotificationChannel(AndroidNotificationChannel(
          'studyflow_$c',
          '${catLabel(c)} reminders',
          description: 'Reminders for ${catLabel(c).toLowerCase()}',
          importance: Importance.high,
        ));
      }
      ready = true;
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d != null && d.didNotificationLaunchApp) _open(d.notificationResponse?.payload);
    } catch (_) {
      return;
    }
    try {
      if (!store.permAsked) {
        await requestPermission();
        store.permAsked = true;
        store.saveNotifs();
      } else {
        await refreshPermission();
      }
    } catch (_) {}
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => deliverDue());
    await sync();
  }

  void _open(String? payload) {
    if (payload == null || payload == 'pomodoro') return;
    navKey.currentState?.popUntil((r) => r.isFirst);
    navIndex.value = tabFor(payload);
  }

  Future<bool> requestPermission() async {
    var ok = true;
    try {
      ok = await _android?.requestNotificationsPermission() ?? true;
    } catch (_) {}
    allowed.value = ok;
    if (ok) requestSync();
    return ok;
  }

  Future<void> refreshPermission() async {
    try {
      allowed.value = await _android?.areNotificationsEnabled() ?? true;
    } catch (_) {}
  }

  void requestSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), sync);
  }

  int _id(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h & 0x7FFFFFFF;
  }

  NotificationDetails _details(String cat, String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          'studyflow_$cat',
          '${catLabel(cat)} reminders',
          channelDescription: 'Reminders for ${catLabel(cat).toLowerCase()}',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  NotificationDetails _pomoDetails(bool sound, String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          sound ? 'studyflow_pomo' : 'studyflow_pomo_quiet',
          sound ? 'Pomodoro alerts' : 'Pomodoro alerts (silent)',
          channelDescription: 'Pomodoro session alerts',
          importance: Importance.high,
          priority: Priority.high,
          playSound: sound,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  Future<void> pomoNow(String title, String body, bool sound) async {
    if (!ready || !allowed.value) return;
    try {
      await _plugin.show(9001, title, body, _pomoDetails(sound, body), payload: 'pomodoro');
    } catch (_) {}
  }

  Future<void> pomoSchedule(DateTime at, String title, String body, bool sound) async {
    if (!ready || !allowed.value || !at.isAfter(DateTime.now())) return;
    try {
      var exact = false;
      try {
        exact = await _android?.canScheduleExactNotifications() ?? false;
      } catch (_) {}
      final u = at.toUtc();
      await _plugin.zonedSchedule(
        9001,
        title,
        body,
        tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second),
        _pomoDetails(sound, body),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'pomodoro',
      );
    } catch (_) {}
  }

  Future<void> pomoCancel() async {
    try {
      await _plugin.cancel(9001);
    } catch (_) {}
  }

  Future<void> sendTest() async {
    const body = 'Reminders are working. You will get them at the times you chose.';
    try {
      await _plugin.show(7, 'StudyFlow notifications are on', body, _details('habit', body));
    } catch (_) {}
  }

  /// Moves notifications whose time has passed from the plan into the inbox.
  void deliverDue() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    final keep = <Notif>[];
    for (final p in store.plan) {
      if (p.at <= now) {
        if (!store.inbox.any((n) => n.key == p.key)) {
          store.inbox.add(Notif(key: p.key, cat: p.cat, title: p.title, body: p.body, at: p.at));
        }
        changed = true;
      } else {
        keep.add(p);
      }
    }
    if (changed) {
      store.plan = keep;
      _prune();
      store.saveNotifs();
    }
  }

  /// Removes inbox items that are old or no longer relevant to the current data.
  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    store.inbox.removeWhere((n) {
      if (n.at < cutoff) return true;
      final p = n.key.split(':');
      if (p.length < 2) return false;
      if (p[0] == 'asg' || p[0] == 'exam') {
        final a = store.assignments.where((x) => x.id == p[1]);
        return a.isEmpty || a.first.done;
      }
      if (p[0] == 'att') return store.attendance.containsKey(p[1]);
      return false;
    });
    store.inbox.sort((a, b) => b.at.compareTo(a.at));
    if (store.inbox.length > 150) store.inbox = store.inbox.sublist(0, 150);
  }

  List<Notif> _build(DateTime now) {
    final out = <Notif>[];
    final today = dateOnly(now);
    DateTime at(DateTime d, int m) => DateTime(d.year, d.month, d.day, m ~/ 60, m % 60);
    void add(String key, String cat, String title, String body, DateTime when) {
      if (!when.isAfter(now)) return;
      out.add(Notif(key: key, cat: cat, title: title, body: body, at: when.millisecondsSinceEpoch));
    }

    final on = store.nOn;
    final tm = store.nTime;

    if (on['habit'] == true && store.habits.isNotEmpty) {
      for (var i = 0; i < 14; i++) {
        final day = DateTime(today.year, today.month, today.day + i);
        String body;
        if (i == 0) {
          final left = store.habits.where((h) => !h.days.contains(dayKey(day))).toList();
          if (left.isEmpty) continue;
          body = left.length == 1
              ? 'Still to do today: ${left.first.name}'
              : '${left.length} habits left today: ${left.take(3).map((h) => h.name).join(", ")}${left.length > 3 ? "..." : ""}';
        } else {
          final n = store.habits.length;
          body = 'Check in on your $n habit${n == 1 ? "" : "s"} today';
        }
        add('habit:${dayKey(day)}', 'habit', 'Habit check-in', body, at(day, tm['habit']!));
      }
    }

    if (on['attendance'] == true) {
      for (var i = 0; i < 14; i++) {
        final day = DateTime(today.year, today.month, today.day + i);
        if (isWeekend(day) || store.attendance.containsKey(dayKey(day))) continue;
        add('att:${dayKey(day)}', 'attendance', 'Are you going to college today?',
            'Tap to mark your attendance.', at(day, tm['attendance']!));
      }
    }

    final horizon = DateTime(today.year, today.month, today.day + 30);
    for (final a in store.assignments) {
      if (a.done) continue;
      final d = dateOnly(a.date);
      if (d.isBefore(today)) continue;
      final isExam = a.type == 'Exam';
      final cat = isExam ? 'exam' : 'assignment';
      if (on[cat] != true) continue;
      final offsets = isExam ? [3, 1, 0] : [1, 0];
      for (final o in offsets) {
        final day = DateTime(d.year, d.month, d.day - o);
        if (day.isAfter(horizon)) continue;
        String title;
        if (isExam) {
          title = o == 0 ? 'Exam today' : (o == 1 ? 'Exam tomorrow' : 'Exam in $o days');
        } else {
          title = o == 0 ? 'Assignment due today' : 'Assignment due tomorrow';
        }
        final sub = a.subject.isEmpty ? '' : ' · ${a.subject}';
        add('${isExam ? "exam" : "asg"}:${a.id}:$o', cat, title,
            '${a.title}$sub · ${DateFormat("EEE, d MMM").format(a.date)}', at(day, tm[cat]!));
      }
    }
    return out;
  }

  Future<void> sync() async {
    if (!ready) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      deliverDue();
      _prune();
      final now = DateTime.now();
      final desired = <String, Notif>{for (final n in _build(now)) n.key: n};
      final old = <String, Notif>{for (final p in store.plan) p.key: p};

      var exact = false;
      try {
        exact = await _android?.canScheduleExactNotifications() ?? false;
      } catch (_) {}

      var pendingIds = <int>{};
      try {
        final pending = await _plugin.pendingNotificationRequests();
        final desiredIds = desired.keys.map(_id).toSet();
        for (final p in pending) {
          if (p.id != 9001 && !desiredIds.contains(p.id)) await _plugin.cancel(p.id);
        }
        pendingIds = pending.map((p) => p.id).toSet();
      } catch (_) {}

      if (allowed.value) {
        for (final n in desired.values) {
          final o = old[n.key];
          final same = o != null && o.at == n.at && o.title == n.title && o.body == n.body;
          if (same && pendingIds.contains(_id(n.key))) continue;
          try {
            final u = DateTime.fromMillisecondsSinceEpoch(n.at).toUtc();
            await _plugin.zonedSchedule(
              _id(n.key),
              n.title,
              n.body,
              tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second),
              _details(n.cat, n.body),
              androidScheduleMode: exact
                  ? AndroidScheduleMode.exactAllowWhileIdle
                  : AndroidScheduleMode.inexactAllowWhileIdle,
              payload: n.cat,
            );
          } catch (_) {}
        }
      }

      store.plan = desired.values.toList()..sort((a, b) => a.at.compareTo(b.at));
      store.saveNotifs();
    } finally {
      _syncing = false;
      if (_again) {
        _again = false;
        requestSync();
      }
    }
  }
}

// ───────────────────────── notification UI ─────────────────────────
Future<void> openScreen(BuildContext context, Widget page) {
  return Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 350),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  ));
}

Widget screenFrame(BuildContext c, Widget body) {
  final d = isDark(c);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: (d ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(statusBarColor: Colors.transparent),
    child: Stack(children: [
      const Positioned.fill(child: Background()),
      Scaffold(backgroundColor: Colors.transparent, body: SafeArea(child: body)),
    ]),
  );
}

class SubHeader extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> actions;
  const SubHeader({super.key, required this.title, required this.subtitle, this.actions = const []});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(children: [
        GlassIconBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(context).pop()),
        const SizedBox(width: 14),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: on)),
              Text(subtitle, style: TextStyle(fontSize: 13.5, color: on.withOpacity(0.6))),
            ]),
          ),
        ),
        for (final a in actions) ...[const SizedBox(width: 10), a],
      ]),
    );
  }
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final n = store.unread;
        return Stack(clipBehavior: Clip.none, children: [
          GlassIconBtn(
            n > 0 ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
            () => openScreen(c, const NotificationCenterPage()),
          ),
          Positioned(
            top: -5,
            right: -5,
            child: AnimatedScale(
              scale: n > 0 ? 1 : 0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: Container(
                constraints: const BoxConstraints(minWidth: 19),
                height: 19,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kExam,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark(c) ? const Color(0xFF15102E) : Colors.white,
                    width: 1.5,
                  ),
                ),
                child: Text(n > 9 ? '9+' : '$n',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});
  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  String filter = 'all';

  String _group(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (sameDay(t, now)) return 'TODAY';
    if (sameDay(t, DateTime(now.year, now.month, now.day - 1))) return 'YESTERDAY';
    return DateFormat('d MMMM yyyy').format(t).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          final items = store.inbox.where((n) => filter == 'all' || n.cat == filter).toList()
            ..sort((a, b) => b.at.compareTo(a.at));
          final unread = store.unread;
          final children = <Widget>[];
          String? last;
          for (var i = 0; i < items.length; i++) {
            final g = _group(items[i].at);
            if (g != last) {
              children.add(Padding(
                key: ValueKey('g_$g'),
                padding: const EdgeInsets.fromLTRB(24, 6, 20, 10),
                child: Text(g,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: on.withOpacity(0.5))),
              ));
              last = g;
            }
            children.add(NotifTile(key: ValueKey('n_${items[i].key}'), n: items[i], index: i));
          }
          return Column(children: [
            SubHeader(
              title: 'Notifications',
              subtitle: unread == 0 ? 'All caught up' : '$unread unread',
              actions: [
                GlassIconBtn(Icons.tune_rounded, () => openScreen(c, const NotificationSettingsPage())),
              ],
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: ['all', ...kNotifCats].map((f) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f == 'all' ? 'All' : catLabel(f)),
                      selected: filter == f,
                      selectedColor: kAccent.withOpacity(0.35),
                      onSelected: (_) => setState(() => filter = f),
                    ),
                  );
                }).toList(),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: unread > 0
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: store.markAllRead,
                          icon: const Icon(Icons.done_all_rounded, size: 18),
                          label: const Text('Mark all as read'),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 8),
            ),
            Expanded(
              child: items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.only(top: 20),
                      children: const [
                        EmptyCard('🔔', 'Nothing here yet.\nYour reminders will show up as they arrive.'),
                      ],
                    )
                  : RevealList(
                      page: 'nc',
                      padding: const EdgeInsets.only(bottom: 30),
                      children: children,
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

class NotifTile extends StatelessWidget {
  final Notif n;
  final int index;
  const NotifTile({super.key, required this.n, required this.index});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final col = catColor(n.cat);
    final unread = !n.read;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (ctx, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 14), child: child),
      ),
      child: Dismissible(
        key: ValueKey(n.key),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => store.deleteNotif(n.key),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 26),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          decoration: BoxDecoration(
            color: kBad.withOpacity(0.22),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Icon(Icons.delete_outline_rounded, color: kBad),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Glass(
            padding: const EdgeInsets.all(14),
            onTap: () {
              store.markRead(n.key);
              Navigator.of(context).pop();
              navIndex.value = tabFor(n.cat);
            },
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: col.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(catIcon(n.cat), color: col),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(n.title,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                          color: on.withOpacity(unread ? 1 : 0.8))),
                  const SizedBox(height: 2),
                  Text(n.body, style: TextStyle(fontSize: 13, color: on.withOpacity(0.65))),
                  const SizedBox(height: 8),
                  Row(children: [
                    Pill(catLabel(n.cat), col),
                    const SizedBox(width: 8),
                    Text(notifTime(n.at),
                        style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
                  ]),
                ]),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: unread ? 10 : 0,
                  height: unread ? 10 : 0,
                  decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class NotificationSettingsPage extends StatelessWidget {
  const NotificationSettingsPage({super.key});

  static const Map<String, String> desc = {
    'habit': 'A daily nudge, skipped once all your habits are done',
    'assignment': 'The day before and on the due date',
    'exam': '3 days before, the day before and on exam day',
    'attendance': 'Weekday prompt, skipped once you have marked it',
  };

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          return RevealList(
            page: 'ns',
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              const SubHeader(title: 'Reminder settings', subtitle: 'Choose what and when'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: ValueListenableBuilder<bool>(
                  valueListenable: notifier.allowed,
                  builder: (ctx, ok, _) => Glass(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: (ok ? kPresent : kBad).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          ok ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
                          color: ok ? kPresent : kBad,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ok ? 'Notifications are on' : 'Notifications are blocked',
                              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                          Text(
                            ok
                                ? 'Reminders arrive even when the app is closed'
                                : "Allow them in your phone's Settings > Apps > StudyFlow",
                            style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6)),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () async {
                          if (ok) {
                            await notifier.sendTest();
                          } else {
                            await notifier.requestPermission();
                          }
                        },
                        child: Text(ok ? 'Test' : 'Allow'),
                      ),
                    ]),
                  ),
                ),
              ),
              ...kNotifCats.map((cat) {
                final enabled = store.nOn[cat] == true;
                final mins = store.nTime[cat]!;
                final col = catColor(cat);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      Row(children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: col.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(catIcon(cat), color: col),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(catLabel(cat),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
                            Text(desc[cat]!,
                                style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                          ]),
                        ),
                        Switch(
                          value: enabled,
                          activeTrackColor: kAccent,
                          onChanged: (v) => store.setNotifOn(cat, v),
                        ),
                      ]),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: enabled
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () async {
                                    final t = await showTimePicker(
                                      context: c,
                                      initialTime: TimeOfDay(hour: mins ~/ 60, minute: mins % 60),
                                    );
                                    if (t != null) store.setNotifTime(cat, t.hour * 60 + t.minute);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: on.withOpacity(0.07),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Row(children: [
                                      Icon(Icons.schedule_rounded, size: 20, color: col),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text('Remind me at',
                                            style: TextStyle(color: on.withOpacity(0.7))),
                                      ),
                                      Text(
                                        TimeOfDay(hour: mins ~/ 60, minute: mins % 60).format(c),
                                        style: TextStyle(fontWeight: FontWeight.w800, color: on),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(Icons.edit_rounded, size: 16, color: on.withOpacity(0.5)),
                                    ]),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ]),
                  ),
                );
              }),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 4, 26, 0),
                child: Text(
                  'Reminders stay in sync with your habits, assignments, exams and attendance. Completed or deleted items never send reminders.',
                  style: TextStyle(fontSize: 12, color: on.withOpacity(0.5)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


// ───────────────────────── motion system ─────────────────────────
const kRevealDuration = Duration(milliseconds: 400);
const int kStaggerMs = 70;
const double kRevealShift = 18;

class _RevealData extends InheritedWidget {
  final Set<String> seen;
  const _RevealData({required this.seen, required super.child});
  static Set<String>? of(BuildContext c) =>
      c.getInheritedWidgetOfExactType<_RevealData>()?.seen;
  @override
  bool updateShouldNotify(_RevealData old) => false;
}

/// Remembers which items were already revealed while a screen is open,
/// so scrolling back never replays an animation. A new screen visit starts fresh.
class RevealScope extends StatefulWidget {
  final Widget child;
  const RevealScope({super.key, required this.child});
  @override
  State<RevealScope> createState() => _RevealScopeState();
}

class _RevealScopeState extends State<RevealScope> {
  final Set<String> _seen = {};
  @override
  Widget build(BuildContext context) => _RevealData(seen: _seen, child: widget.child);
}

/// Fade + upward slide. Staggered when the item is on screen as the page opens,
/// and triggered individually when it scrolls into view.
class Reveal extends StatefulWidget {
  final String id;
  final int index;
  final Widget child;
  Reveal({required this.id, this.index = 0, required this.child}) : super(key: ValueKey('rv_$id'));
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  bool _shown = false;
  bool _first = true;
  Timer? _timer;
  ScrollPosition? _pos;
  Set<String>? _seen;

  @override
  void initState() {
    super.initState();
    _seen = _RevealData.of(context);
    if (_seen?.contains(widget.id) ?? false) {
      _shown = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attach();
    });
  }

  void _attach() {
    if (_shown) return;
    _pos = Scrollable.maybeOf(context)?.position;
    _pos?.addListener(_check);
    _check();
  }

  void _check() {
    if (_shown || !mounted) return;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    final top = ro.localToGlobal(Offset.zero).dy;
    final h = MediaQuery.sizeOf(context).height;
    if (top < h - 100) {
      _pos?.removeListener(_check);
      _seen?.add(widget.id);
      final delay = _first ? (widget.index < 8 ? widget.index : 8) * kStaggerMs : 0;
      if (delay == 0) {
        setState(() => _shown = true);
      } else {
        _timer = Timer(Duration(milliseconds: delay), () {
          if (mounted) setState(() => _shown = true);
        });
      }
    }
    _first = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pos?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _shown ? 1.0 : 0.0),
      duration: kRevealDuration,
      curve: Curves.easeOutCubic,
      builder: (c, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * kRevealShift), child: child),
      ),
      child: widget.child,
    );
  }
}

String _revealId(Widget w, Map<String, int> counts) {
  final k = w.key;
  if (k is ValueKey) return 'k:${k.value}';
  if (w is SectionTitle) return 'st:${w.text}';
  if (w is EmptyCard) return 'ec:${w.text}';
  final t = w.runtimeType.toString();
  final n = counts[t] ?? 0;
  counts[t] = n + 1;
  return '$t#$n';
}

/// Drop-in replacement for ListView(children: ...) that adds entrance and scroll reveals.
class RevealList extends StatelessWidget {
  final String page;
  final EdgeInsetsGeometry? padding;
  final List<Widget> children;
  const RevealList({super.key, required this.page, this.padding, required this.children});

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    return RevealScope(
      child: ListView(
        padding: padding,
        children: [
          for (var i = 0; i < children.length; i++)
            Reveal(id: '$page/${_revealId(children[i], counts)}', index: i, child: children[i]),
        ],
      ),
    );
  }
}

/// Small scale + fade pop used for calendar event markers.
class PopIn extends StatelessWidget {
  final Widget child;
  const PopIn({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (c, v, ch) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.6 + 0.4 * v, child: ch),
      ),
      child: child,
    );
  }
}

/// Tab transition: incoming screen slides in from the direction of travel,
/// the outgoing screen fades out the other way.
class AnimatedPage extends StatefulWidget {
  final int index;
  final List<Widget> pages;
  const AnimatedPage({super.key, required this.index, required this.pages});
  @override
  State<AnimatedPage> createState() => _AnimatedPageState();
}

class _AnimatedPageState extends State<AnimatedPage> {
  int _dir = 1;

  @override
  void didUpdateWidget(AnimatedPage old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _dir = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final incoming = child.key == ValueKey<int>(widget.index);
        final dx = 0.05 * _dir;
        final slide = SlideTransition(
          position: Tween<Offset>(begin: Offset(incoming ? dx : -dx, 0), end: Offset.zero)
              .animate(anim),
          child: child,
        );
        return incoming ? slide : FadeTransition(opacity: anim, child: slide);
      },
      child: KeyedSubtree(key: ValueKey<int>(widget.index), child: widget.pages[widget.index]),
    );
  }
}



// ───────────────────────── habits: states, progress, streak tracker ─────────────────────────
enum HDay { inactive, complete, partial, missed, upcoming }

const kMissed = kBad;
const kPartial = kWarn;

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

String fastKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}';

/// One shared rule for every habit view (week squares, heatmap, graph, streak).
/// Complete = daily target reached. Partial = progress made, target not reached.
/// Missed = a finished day with no completion. Days before the habit existed are
/// inactive; today (not yet over) and future days with no progress are upcoming.
HDay habitDay(Habit h, DateTime d, DateTime today) {
  final k = dayKey(d);
  if (h.days.contains(k)) return HDay.complete;
  if ((h.progress[k] ?? 0) > 0) return HDay.partial;
  final c = h.created == null ? today : DateTime.parse(h.created!);
  if (d.isBefore(c)) return HDay.inactive;
  if (d.isBefore(today)) return HDay.missed;
  return HDay.upcoming;
}

BoxDecoration squareDeco(HDay st, Color on) {
  switch (st) {
    case HDay.complete:
      return BoxDecoration(color: kHabit, borderRadius: BorderRadius.circular(3.5));
    case HDay.partial:
      return BoxDecoration(color: kPartial, borderRadius: BorderRadius.circular(3.5));
    case HDay.missed:
      return BoxDecoration(color: kMissed.withOpacity(0.55), borderRadius: BorderRadius.circular(3.5));
    case HDay.upcoming:
      return BoxDecoration(
        borderRadius: BorderRadius.circular(3.5),
        border: Border.all(color: on.withOpacity(0.3), width: 1.2),
      );
    case HDay.inactive:
      return BoxDecoration(color: on.withOpacity(0.06), borderRadius: BorderRadius.circular(3.5));
  }
}

class HabitsTodayCard extends StatelessWidget {
  const HabitsTodayCard({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final total = store.habits.length;
        final key = dayKey(DateTime.now());
        var done = 0;
        var sum = 0.0;
        for (final h in store.habits) {
          if (h.days.contains(key)) {
            done++;
            sum += 1;
          } else {
            final cn = h.progress[key] ?? 0;
            if (cn > 0) sum += cn / h.target;
          }
        }
        var pct = total == 0 ? 0 : (sum * 100 / total).round();
        if (done < total && pct > 99) pct = 99;
        String msg;
        if (total == 0) {
          msg = 'Add a habit to get started';
        } else if (pct == 100) {
          msg = 'All habits completed!';
        } else if (pct >= 75) {
          msg = 'Almost there!';
        } else if (pct >= 50) {
          msg = 'On track';
        } else if (pct > 0) {
          msg = 'Great progress!';
        } else {
          msg = "Let's get started";
        }
        return Glass(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(alignment: Alignment.center, children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: pct / 100),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (ctx, v, _) => SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      value: v,
                      strokeWidth: 9,
                      strokeCap: StrokeCap.round,
                      backgroundColor: on.withOpacity(0.1),
                      valueColor: const AlwaysStoppedAnimation<Color>(kHabit),
                    ),
                  ),
                ),
                Text('$pct%',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: on)),
              ]),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Habits Today',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
                const SizedBox(height: 2),
                Text('$pct% completed',
                    style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                const SizedBox(height: 10),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  layoutBuilder: (cur, prev) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...prev, if (cur != null) cur],
                  ),
                  child: Pill(msg, kHabit, key: ValueKey(msg)),
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class HabitReorderList extends StatelessWidget {
  const HabitReorderList({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) => ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: store.habits.length,
        onReorder: store.reorderHabits,
        proxyDecorator: (child, index, anim) => AnimatedBuilder(
          animation: anim,
          builder: (ctx, ch) {
            final t = Curves.easeOut.transform(anim.value);
            return Transform.scale(
              scale: 1 + 0.03 * t,
              child: Opacity(opacity: 1 - 0.12 * t, child: ch),
            );
          },
          child: Material(type: MaterialType.transparency, child: child),
        ),
        itemBuilder: (ctx, i) {
          final h = store.habits[i];
          return HabitTile(key: ValueKey('hab_${h.id}'), h: h);
        },
      ),
    );
  }
}

Future<void> showHabitDetails(BuildContext context, Habit h) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final on = onSurf(ctx);
      final since = h.created == null ? null : DateTime.parse(h.created!);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kHabit.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(h.emoji, style: const TextStyle(fontSize: 28)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(h.name,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
                  if (since != null)
                    Text('Tracking since ${DateFormat("d MMM yyyy").format(since)}',
                        style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                ]),
              ),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: MiniStat('${streak(h)}', 'Day streak', kWarn)),
              const SizedBox(width: 10),
              Expanded(child: MiniStat('${h.days.length}', 'Days done', kHabit)),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showHabitSheet(context, habit: h);
                  },
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBad,
                    side: BorderSide(color: kBad.withOpacity(0.5)),
                  ),
                  onPressed: () async {
                    if (await confirmDelete(ctx, h.name)) {
                      store.deleteHabit(h.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                ),
              ),
            ]),
          ]),
        ),
      );
    },
  );
}

Future<void> showAssignmentDetails(BuildContext context, Assignment a) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final on = onSurf(ctx);
      final c = typeColor(a.type);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Pill(a.type, c),
              const SizedBox(width: 8),
              Pill(a.done ? 'Completed' : rel(a.date), a.done ? kHabit : kAccent),
            ]),
            const SizedBox(height: 14),
            Text(a.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
            if (a.subject.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(a.subject, style: TextStyle(fontSize: 14, color: on.withOpacity(0.65))),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Icon(Icons.event_rounded, size: 18, color: c),
              const SizedBox(width: 8),
              Text(DateFormat('EEEE, d MMMM yyyy').format(a.date),
                  style: TextStyle(fontSize: 14, color: on.withOpacity(0.8))),
            ]),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showAssignmentSheet(context, a: a);
                  },
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBad,
                    side: BorderSide(color: kBad.withOpacity(0.5)),
                  ),
                  onPressed: () async {
                    if (await confirmDelete(ctx, a.title)) {
                      store.deleteAssignment(a.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                ),
              ),
            ]),
          ]),
        ),
      );
    },
  );
}

class HabitHeatmapCard extends StatelessWidget {
  const HabitHeatmapCard({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final today = dateOnly(DateTime.now());
        final habits = store.habits;
        final sets = {for (final h in habits) h.id: h.days.toSet()};
        final created = {
          for (final h in habits) h.id: h.created == null ? today : DateTime.parse(h.created!),
        };

        BoxDecoration cellDeco(DateTime d) {
          if (d.isAfter(today)) {
            return BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: on.withOpacity(0.12)),
            );
          }
          final k = fastKey(d);
          var n = 0, complete = 0, partial = 0;
          for (final h in habits) {
            final isDone = sets[h.id]!.contains(k);
            final prog = (h.progress[k] ?? 0) > 0;
            if (d.isBefore(created[h.id]!) && !isDone && !prog) continue;
            n++;
            if (isDone) {
              complete++;
            } else if (prog) {
              partial++;
            }
          }
          if (n == 0) {
            return BoxDecoration(color: on.withOpacity(0.05), borderRadius: BorderRadius.circular(3));
          }
          if (complete == n) {
            return BoxDecoration(color: kHabit, borderRadius: BorderRadius.circular(3));
          }
          if (complete > 0 || partial > 0) {
            return BoxDecoration(color: kPartial, borderRadius: BorderRadius.circular(3));
          }
          if (sameDay(d, today)) {
            return BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: on.withOpacity(0.3), width: 1.2),
            );
          }
          return BoxDecoration(color: kMissed.withOpacity(0.55), borderRadius: BorderRadius.circular(3));
        }

        Widget legend(String t, BoxDecoration d) => Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 11, height: 11, decoration: d),
              const SizedBox(width: 5),
              Text(t, style: TextStyle(fontSize: 11, color: on.withOpacity(0.65))),
            ]);

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Glass(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: LayoutBuilder(builder: (ctx, box) {
              const labelW = 28.0, cell = 12.0, gap = 3.0, stepW = cell + gap;
              final cols = ((box.maxWidth - labelW) / stepW).floor().clamp(8, 30).toInt();
              final thisMonday = addDays(today, -(today.weekday - 1));
              final first = addDays(thisMonday, -7 * (cols - 1));

              final labels = <MapEntry<int, String>>[];
              var lastCol = -10;
              for (var col = 0; col < cols; col++) {
                final mon = addDays(first, 7 * col);
                String? name;
                if (col == 0) {
                  name = DateFormat('MMM').format(mon);
                } else {
                  for (var r = 0; r < 7; r++) {
                    final d = addDays(mon, r);
                    if (d.day == 1) {
                      name = DateFormat('MMM').format(d);
                      break;
                    }
                  }
                }
                if (name != null && col - lastCol >= 3) {
                  labels.add(MapEntry(col, name));
                  lastCol = col;
                }
              }

              const weekdayLabels = ['Mon', '', 'Wed', '', 'Fri', '', ''];
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  height: 14,
                  child: Stack(children: [
                    for (final l in labels)
                      Positioned(
                        left: labelW + l.key * stepW,
                        child: Text(l.value,
                            style: TextStyle(fontSize: 10, color: on.withOpacity(0.55))),
                      ),
                  ]),
                ),
                const SizedBox(height: 4),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Column(
                    children: List.generate(
                      7,
                      (r) => SizedBox(
                        width: labelW,
                        height: stepW,
                        child: Text(weekdayLabels[r],
                            style: TextStyle(fontSize: 9, color: on.withOpacity(0.5))),
                      ),
                    ),
                  ),
                  for (var col = 0; col < cols; col++)
                    Column(
                      children: List.generate(7, (r) {
                        final d = addDays(first, 7 * col + r);
                        return Container(
                          width: cell,
                          height: cell,
                          margin: const EdgeInsets.only(right: gap, bottom: gap),
                          decoration: cellDeco(d),
                        );
                      }),
                    ),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 6, children: [
                  legend('Missed', BoxDecoration(color: kMissed.withOpacity(0.55), borderRadius: BorderRadius.circular(3))),
                  legend('Partial', BoxDecoration(color: kPartial, borderRadius: BorderRadius.circular(3))),
                  legend('Complete', BoxDecoration(color: kHabit, borderRadius: BorderRadius.circular(3))),
                ]),
              ]);
            }),
          ),
        );
      },
    );
  }
}

class GPoint {
  final String label;
  final double? value;
  const GPoint(this.label, this.value);
}

/// Completion rate (%) per bucket, from the same records as everything else.
/// Only finished days (or days already completed) count, so an unfinished
/// today never lowers the rate.
List<GPoint> graphPoints(String period, String habitId) {
  final today = dateOnly(DateTime.now());
  final habits =
      habitId == 'all' ? store.habits : store.habits.where((h) => h.id == habitId).toList();
  final sets = {for (final h in habits) h.id: h.days.toSet()};
  final created = {
    for (final h in habits) h.id: h.created == null ? today : DateTime.parse(h.created!),
  };

  double? rate(DateTime a, DateTime b) {
    var done = 0.0, total = 0;
    for (var d = a; !d.isAfter(b) && !d.isAfter(today); d = addDays(d, 1)) {
      final k = fastKey(d);
      for (final h in habits) {
        if (sets[h.id]!.contains(k)) {
          done += 1;
          total++;
        } else if ((h.progress[k] ?? 0) > 0) {
          done += h.progress[k]! / h.target;
          total++;
        } else if (!d.isBefore(created[h.id]!) && d.isBefore(today)) {
          total++;
        }
      }
    }
    return total == 0 ? null : done * 100 / total;
  }

  final pts = <GPoint>[];
  if (period == 'Day') {
    for (var i = 13; i >= 0; i--) {
      final d = addDays(today, -i);
      pts.add(GPoint('${d.day}', rate(d, d)));
    }
  } else if (period == 'Week') {
    final mon = addDays(today, -(today.weekday - 1));
    for (var i = 11; i >= 0; i--) {
      final st = addDays(mon, -7 * i);
      pts.add(GPoint('${st.day}/${st.month}', rate(st, addDays(st, 6))));
    }
  } else if (period == 'Month') {
    for (var i = 11; i >= 0; i--) {
      final st = DateTime(today.year, today.month - i, 1);
      pts.add(GPoint(DateFormat('MMM').format(st), rate(st, DateTime(st.year, st.month + 1, 0))));
    }
  } else if (period == 'Quarter') {
    final q0 = DateTime(today.year, ((today.month - 1) ~/ 3) * 3 + 1, 1);
    for (var i = 7; i >= 0; i--) {
      final st = DateTime(q0.year, q0.month - 3 * i, 1);
      pts.add(GPoint('Q${(st.month - 1) ~/ 3 + 1} ${st.year % 100}',
          rate(st, DateTime(st.year, st.month + 3, 0))));
    }
  } else {
    for (var i = 4; i >= 0; i--) {
      final y = today.year - i;
      pts.add(GPoint('$y', rate(DateTime(y, 1, 1), DateTime(y, 12, 31))));
    }
  }
  return pts;
}

class LineGraphPainter extends CustomPainter {
  final List<GPoint> pts;
  final Color line, text, grid;
  LineGraphPainter(this.pts, this.line, this.text, this.grid);

  void _label(Canvas canvas, String t, Offset at, double size, Color color, {bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center ? Offset(at.dx - tp.width / 2, at.dy) : at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, right = 10.0, top = 10.0, bottom = 24.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    final n = pts.length;
    if (n == 0 || w <= 0 || h <= 0) return;
    double xAt(int i) => n == 1 ? left + w / 2 : left + w * i / (n - 1);
    double yAt(double v) => top + h * (1 - v / 100);

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in [0, 50, 100]) {
      final y = yAt(v.toDouble());
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gp);
      _label(canvas, '$v%', Offset(0, y - 6), 10.5, text.withOpacity(0.55));
    }

    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    var run = <Offset>[];
    void flush() {
      if (run.length >= 2) {
        final path = Path()..moveTo(run.first.dx, run.first.dy);
        for (final o in run.skip(1)) {
          path.lineTo(o.dx, o.dy);
        }
        final area = Path.from(path)
          ..lineTo(run.last.dx, top + h)
          ..lineTo(run.first.dx, top + h)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [line.withOpacity(0.28), line.withOpacity(0)],
            ).createShader(Rect.fromLTWH(left, top, w, h)),
        );
        canvas.drawPath(path, linePaint);
      }
      run = <Offset>[];
    }

    for (var i = 0; i < n; i++) {
      final v = pts[i].value;
      if (v == null) {
        flush();
      } else {
        run.add(Offset(xAt(i), yAt(v)));
      }
    }
    flush();

    for (var i = 0; i < n; i++) {
      final v = pts[i].value;
      if (v == null) continue;
      final o = Offset(xAt(i), yAt(v));
      canvas.drawCircle(o, 6.5, Paint()..color = line.withOpacity(0.22));
      canvas.drawCircle(o, 3.6, Paint()..color = line);
    }

    final dx = n == 1 ? w : w / (n - 1);
    final step = (38 / dx).ceil().clamp(1, n).toInt();
    for (var i = n - 1; i >= 0; i -= step) {
      _label(canvas, pts[i].label, Offset(xAt(i), size.height - bottom + 7), 10,
          text.withOpacity(0.6),
          center: true);
    }
  }

  @override
  bool shouldRepaint(LineGraphPainter old) => true;
}

class HabitGraphCard extends StatefulWidget {
  const HabitGraphCard({super.key});
  @override
  State<HabitGraphCard> createState() => _HabitGraphCardState();
}

class _HabitGraphCardState extends State<HabitGraphCard> {
  String period = 'Week';
  String habitId = 'all';

  Widget _dropdown<T>(BuildContext c, T value, List<DropdownMenuItem<T>> items, ValueChanged<T?> onCh) {
    final on = onSurf(c);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: on.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          borderRadius: BorderRadius.circular(16),
          dropdownColor: isDark(c) ? const Color(0xFF1B1636) : Colors.white,
          icon: Icon(Icons.keyboard_arrow_down_rounded, color: on.withOpacity(0.6)),
          style: TextStyle(color: on, fontSize: 14, fontWeight: FontWeight.w600),
          items: items,
          onChanged: onCh,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final habits = store.habits;
        final sel = (habitId == 'all' || habits.any((h) => h.id == habitId)) ? habitId : 'all';
        final pts = graphPoints(period, sel);
        final vals = pts.where((p) => p.value != null).map((p) => p.value!).toList();
        final avg = vals.isEmpty ? null : vals.reduce((a, b) => a + b) / vals.length;
        var cur = 0;
        for (final h in habits) {
          if (sel == 'all' || h.id == sel) {
            final s = streak(h);
            if (s > cur) cur = s;
          }
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Glass(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: _dropdown<String>(
                    c,
                    period,
                    const ['Day', 'Week', 'Month', 'Quarter', 'Year']
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    (v) => setState(() => period = v ?? period),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _dropdown<String>(
                    c,
                    sel,
                    [
                      const DropdownMenuItem(value: 'all', child: Text('Overall')),
                      ...habits.map((h) => DropdownMenuItem(
                            value: h.id,
                            child: Text('${h.emoji} ${h.name}', overflow: TextOverflow.ellipsis),
                          )),
                    ],
                    (v) => setState(() => habitId = v ?? 'all'),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: SizedBox(
                  key: ValueKey('$period|$sel'),
                  height: 190,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: LineGraphPainter(pts, kHabit, on, on.withOpacity(0.1)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: MiniStat(avg == null ? '–' : '${avg.round()}%', 'Avg rate', kHabit)),
                const SizedBox(width: 10),
                Expanded(child: MiniStat('$cur', sel == 'all' ? 'Best streak' : 'Streak', kWarn)),
              ]),
            ]),
          ),
        );
      },
    );
  }
}


// ───────────────────────── tools hub ─────────────────────────
/// Every tool in the hub is described by a ToolDef. Adding a future tool means
/// adding one entry to kTools plus its page; nothing else changes.
class ToolDef {
  final String name, desc;
  final IconData icon;
  final Color color;
  final Widget Function() page;
  const ToolDef({
    required this.name,
    required this.desc,
    required this.icon,
    required this.color,
    required this.page,
  });
}

final List<ToolDef> kTools = [
  ToolDef(
    name: 'Quick Links',
    desc: 'Shortcuts to the websites you use most',
    icon: Icons.link_rounded,
    color: kAccent,
    page: () => const QuickLinksPage(),
  ),
  ToolDef(
    name: 'Pomodoro Timer',
    desc: 'Focus, take breaks and stay productive.',
    icon: Icons.timer_rounded,
    color: kPomo,
    page: () => const PomodoroSetupPage(),
  ),
];

class ToolsHubPage extends StatelessWidget {
  const ToolsHubPage({super.key});
  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      RevealList(
        page: 'tools',
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SubHeader(title: 'Tools Hub', subtitle: 'Handy utilities in one place'),
          ...kTools.map((t) => ToolTile(key: ValueKey('tool_${t.name}'), tool: t)),
        ],
      ),
    );
  }
}

class ToolTile extends StatelessWidget {
  final ToolDef tool;
  const ToolTile({super.key, required this.tool});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.all(16),
        onTap: () => openScreen(context, tool.page()),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: tool.color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(tool.icon, color: tool.color, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tool.name,
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: on)),
              const SizedBox(height: 2),
              Text(tool.desc, style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: on.withOpacity(0.5)),
        ]),
      ),
    );
  }
}

// ───────────────────────── quick links ─────────────────────────
const Map<String, IconData> kLinkIcons = {
  'link': Icons.link_rounded,
  'leave': Icons.event_busy_rounded,
  'results': Icons.emoji_events_rounded,
  'materials': Icons.menu_book_rounded,
  'fee': Icons.payments_rounded,
  'school': Icons.school_rounded,
  'assignment': Icons.assignment_rounded,
  'calendar': Icons.calendar_month_rounded,
  'library': Icons.local_library_rounded,
  'mail': Icons.mail_rounded,
  'video': Icons.play_circle_rounded,
  'forum': Icons.forum_rounded,
  'cloud': Icons.cloud_rounded,
  'work': Icons.work_rounded,
  'code': Icons.code_rounded,
  'science': Icons.science_rounded,
  'web': Icons.language_rounded,
  'bank': Icons.account_balance_rounded,
  'badge': Icons.badge_rounded,
  'news': Icons.newspaper_rounded,
  'download': Icons.download_rounded,
  'quiz': Icons.quiz_rounded,
};

const List<Color> kLinkColors = [kAccent, kAssign, kHabit, kExam, kWarn];

IconData linkIcon(String key) => kLinkIcons[key] ?? Icons.link_rounded;

Color linkColor(String key) {
  final i = kLinkIcons.keys.toList().indexOf(key);
  return kLinkColors[(i < 0 ? 0 : i) % kLinkColors.length];
}

class QuickLink {
  String id, name, url, icon;
  QuickLink({required this.id, required this.name, required this.url, required this.icon});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'icon': icon};
  factory QuickLink.fromJson(Map<String, dynamic> j) => QuickLink(
        id: j['id'],
        name: j['name'],
        url: j['url'],
        icon: j['icon'] ?? 'link',
      );
}

/// Returns a clean http(s) URL, adding https:// when no scheme was typed,
/// or null when the text is not a usable web address.
String? normalizeUrl(String raw) {
  var t = raw.trim();
  if (t.isEmpty || t.contains(' ')) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(t)) t = 'https://$t';
  final u = Uri.tryParse(t);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
  if (u.host.isEmpty || !u.host.contains('.') || u.host.endsWith('.')) return null;
  return u.toString();
}

Future<void> openQuickLink(BuildContext context, QuickLink l) async {
  var ok = false;
  final uri = Uri.tryParse(l.url);
  if (uri != null) {
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text("Couldn't open \"${l.name}\". Check the link and try again."),
      ));
  }
}

Future<void> showQuickLinkSheet(BuildContext context, {QuickLink? link}) {
  final name = TextEditingController(text: link?.name ?? '');
  final url = TextEditingController(text: link?.url ?? '');
  var icon = link?.icon ?? 'link';
  String? nameErr, urlErr;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);

      void save() {
        final n = name.text.trim();
        final u = normalizeUrl(url.text);
        set(() {
          nameErr = n.isEmpty ? 'Enter a card name' : null;
          urlErr = url.text.trim().isEmpty
              ? 'Enter a website link'
              : (u == null ? 'Enter a valid link, like example.com' : null);
        });
        if (n.isEmpty || u == null) return;
        if (link == null) {
          store.addLink(QuickLink(id: newId(), name: n, url: u, icon: icon));
        } else {
          link.name = n;
          link.url = u;
          link.icon = icon;
          store.updateLink(link);
        }
        Navigator.pop(ctx);
      }

      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(link == null ? 'New quick link' : 'Edit quick link',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: deco(ctx, 'Card name (e.g. Apply for Leave)').copyWith(errorText: nameErr),
                onChanged: (_) {
                  if (nameErr != null) set(() => nameErr = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                decoration: deco(ctx, 'Website URL (e.g. example.com)').copyWith(errorText: urlErr),
                onChanged: (_) {
                  if (urlErr != null) set(() => urlErr = null);
                },
                onSubmitted: (_) => save(),
              ),
              const SizedBox(height: 16),
              Text('Icon', style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: kLinkIcons.entries.map((e) {
                  final sel = e.key == icon;
                  final col = linkColor(e.key);
                  return GestureDetector(
                    onTap: () => set(() => icon = e.key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: sel ? col.withOpacity(0.25) : on.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: sel ? col : Colors.transparent, width: 2),
                      ),
                      child: Icon(e.value, size: 22, color: sel ? col : on.withOpacity(0.65)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: save,
                  child: Text(link == null ? 'Add quick link' : 'Save changes',
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

class QuickLinksPage extends StatefulWidget {
  const QuickLinksPage({super.key});
  @override
  State<QuickLinksPage> createState() => _QuickLinksPageState();
}

class _QuickLinksPageState extends State<QuickLinksPage> {
  final Set<String> _removing = {};

  Future<void> _delete(BuildContext c, QuickLink l) async {
    if (!await confirmDelete(c, l.name)) return;
    if (mounted) setState(() => _removing.add(l.id));
    await Future.delayed(const Duration(milliseconds: 240));
    store.deleteLink(l.id);
    if (mounted) setState(() => _removing.remove(l.id));
  }

  Widget _empty(BuildContext c) {
    final on = onSurf(c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Glass(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 22),
        child: SizedBox(
          width: double.infinity,
          child: Column(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: kAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.link_rounded, size: 30, color: kAccent),
            ),
            const SizedBox(height: 14),
            Text('No quick links yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 6),
            Text(
              'Save the websites you open most, like results, fee payment or leave forms.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: on.withOpacity(0.6)),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kAccent),
              onPressed: () => showQuickLinkSheet(c),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add quick link'),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final links = store.links;
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              SubHeader(
                title: 'Quick Links',
                subtitle: links.isEmpty
                    ? 'Save your favourite websites'
                    : '${links.length} saved',
                actions: [GlassIconBtn(Icons.add_rounded, () => showQuickLinkSheet(c))],
              ),
              if (links.isEmpty)
                _empty(c)
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: links.length,
                    itemBuilder: (ctx, i) {
                      final l = links[i];
                      return QuickLinkCard(
                        key: ValueKey(l.id),
                        link: l,
                        index: i,
                        removing: _removing.contains(l.id),
                        onOpen: () => openQuickLink(ctx, l),
                        onEdit: () => showQuickLinkSheet(ctx, link: l),
                        onDelete: () => _delete(ctx, l),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class QuickLinkCard extends StatelessWidget {
  final QuickLink link;
  final int index;
  final bool removing;
  final VoidCallback onOpen, onEdit, onDelete;
  const QuickLinkCard({
    super.key,
    required this.link,
    required this.index,
    required this.removing,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final col = linkColor(link.icon);
    final reduce = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: reduce ? Duration.zero : Duration(milliseconds: 320 + (index < 8 ? index : 8) * 40),
      curve: Curves.easeOutCubic,
      builder: (c, v, child) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.92 + 0.08 * v, child: child),
      ),
      child: AnimatedScale(
        scale: removing ? 0.85 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInCubic,
        child: AnimatedOpacity(
          opacity: removing ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          child: Glass(
            padding: const EdgeInsets.all(14),
            onTap: removing ? null : onOpen,
            child: Stack(clipBehavior: Clip.none, children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
                    child: Container(
                      key: ValueKey(link.icon),
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: col.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(linkIcon(link.icon), size: 28, color: col),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(link.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: on)),
                ]),
              ),
              Positioned(
                top: -4,
                right: -6,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    tooltip: 'More',
                    icon: Icon(Icons.more_vert_rounded, size: 20, color: on.withOpacity(0.55)),
                    color: isDark(context) ? const Color(0xFF1B1636) : Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(children: [
                          Icon(Icons.edit_rounded, size: 18, color: on),
                          const SizedBox(width: 10),
                          Text('Edit', style: TextStyle(color: on)),
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete_outline_rounded, size: 18, color: kBad),
                          SizedBox(width: 10),
                          Text('Delete', style: TextStyle(color: kBad)),
                        ]),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}


// ───────────────────────── pomodoro ─────────────────────────
const kPomo = Color(0xFFEC4899);

enum PomoPhase { focus, shortBreak }
enum PomoStatus { idle, running, paused, awaiting }

String phaseLabel(PomoPhase p) => p == PomoPhase.focus ? 'Focus' : 'Short Break';

(Color, Color) phaseColors(PomoPhase p) {
  if (p == PomoPhase.focus) return (const Color(0xFF8B5CF6), const Color(0xFF38BDF8));
  return (const Color(0xFF4ADE80), const Color(0xFF22D3EE));
}

String fmtFocusTime(int seconds) {
  final m = seconds ~/ 60;
  if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
  return '${m}m';
}

// ───────── completion sound ─────────
final pomoAudio = PomoAudio();

/// Plays the user's chosen completion sound. Playback is guarded against rapid
/// duplicate triggers, and a missing file simply reports failure.
class PomoAudio {
  AudioPlayer? _p;
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
  DateTime? _last;

  AudioPlayer _player() {
    var p = _p;
    if (p == null) {
      p = AudioPlayer();
      p.onPlayerStateChanged.listen((st) => playing.value = st == PlayerState.playing);
      _p = p;
    }
    return p;
  }

  /// One shared player: it is always stopped before anything new is played, so
  /// two instances can never overlap. [loop] repeats until stop() is called.
  Future<bool> play(String path, {bool preview = false, bool loop = false}) async {
    final now = DateTime.now();
    if (!preview && _last != null && now.difference(_last!) < const Duration(milliseconds: 800)) {
      return true;
    }
    _last = now;
    try {
      if (!File(path).existsSync()) return false;
      final p = _player();
      await p.stop();
      await p.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
      await p.play(DeviceFileSource(path));
      return true;
    } catch (_) {
      playing.value = false;
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _p?.stop();
      await _p?.setReleaseMode(ReleaseMode.stop);
      await _p?.release();
    } catch (_) {}
    playing.value = false;
  }
}

/// Opens the system picker (Storage Access Framework, no storage permission),
/// then keeps a private copy so the choice survives restarts. Returns an error
/// message, or null on success or cancel.
Future<String?> pickPomoSound() async {
  try {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false);
    if (res == null || res.files.isEmpty) return null;
    final f = res.files.first;
    final src = f.path;
    if (src == null) return "Couldn't read that file. Try another one.";
    final dot = f.name.lastIndexOf('.');
    final ext = dot >= 0 && dot < f.name.length - 1 ? f.name.substring(dot + 1).toLowerCase() : 'mp3';
    final dir = await getApplicationSupportDirectory();
    final dest = '${dir.path}/pomodoro_sound_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await File(src).copy(dest);
    final old = store.pomoSoundPath;
    store.setPomoSound(dest, f.name);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    return null;
  } catch (_) {
    return "Couldn't load that sound. Try another file.";
  }
}

Future<void> removePomoSound() async {
  final old = store.pomoSoundPath;
  store.clearPomoSound();
  if (old != null) {
    try {
      await File(old).delete();
    } catch (_) {}
  }
}

final pomodoro = PomodoroEngine();

/// Deadline-based timer. The remaining time is always computed from the wall
/// clock, so it stays correct across pauses, backgrounding and screen changes.
/// When a countdown ends the engine stops and waits (awaiting) until the user
/// confirms the next session; nothing ever starts on its own.
class PomodoroEngine extends ChangeNotifier {
  PomoPhase phase = PomoPhase.focus;
  PomoStatus status = PomoStatus.idle;
  bool sessionActive = false;
  int focusMin = 25, shortMin = 5, cycles = 4;
  int focusIndex = 0; // focus sessions moved past (completed or skipped) in this cycle
  bool _foreground = true;
  DateTime? _endAt;
  Duration _left = const Duration(minutes: 25);
  Timer? _timer;

  bool get awaiting => status == PomoStatus.awaiting;

  Duration dur(PomoPhase p) => Duration(minutes: p == PomoPhase.focus ? focusMin : shortMin);

  Duration get total => dur(phase);

  Duration get remaining {
    if (status == PomoStatus.running && _endAt != null) {
      final d = _endAt!.difference(DateTime.now());
      return d.isNegative ? Duration.zero : d;
    }
    return _left;
  }

  double get fraction {
    final t = total.inMilliseconds;
    return t == 0 ? 0 : (remaining.inMilliseconds / t).clamp(0.0, 1.0).toDouble();
  }

  /// Session number for the current phase. While a focus session is waiting for
  /// confirmation, or during its break, it is the session that was just finished.
  int get sessionNumber {
    if (phase == PomoPhase.focus) return (focusIndex % cycles) + 1;
    return focusIndex < 1 ? 1 : (focusIndex > cycles ? cycles : focusIndex);
  }

  void configure({required int focus, required int shortB, required int cyc}) {
    focusMin = focus;
    shortMin = shortB;
    cycles = cyc < 1 ? 1 : cyc;
    if (status == PomoStatus.idle && !sessionActive) {
      phase = PomoPhase.focus;
      focusIndex = 0;
      _left = dur(phase);
    }
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void start() {
    if (status == PomoStatus.running || status == PomoStatus.awaiting) return;
    _endAt = DateTime.now().add(_left);
    status = PomoStatus.running;
    sessionActive = true;
    _startTimer();
    notifyListeners();
  }

  void pause() {
    if (status != PomoStatus.running) return;
    _left = remaining;
    _endAt = null;
    _stopTimer();
    status = PomoStatus.paused;
    notifier.pomoCancel();
    notifyListeners();
  }

  void reset() {
    if (status == PomoStatus.awaiting) return;
    _stopTimer();
    _endAt = null;
    status = PomoStatus.idle;
    _left = dur(phase);
    notifier.pomoCancel();
    notifyListeners();
  }

  void stop() {
    _stopTimer();
    pomoAudio.stop();
    _endAt = null;
    status = PomoStatus.idle;
    phase = PomoPhase.focus;
    focusIndex = 0;
    sessionActive = false;
    _left = dur(PomoPhase.focus);
    notifier.pomoCancel();
    notifyListeners();
  }

  /// Moves to the next phase, ready but not started, without counting the
  /// skipped one as completed.
  void skip() {
    if (status == PomoStatus.awaiting) return;
    _stopTimer();
    _endAt = null;
    _moveToNext();
    status = PomoStatus.idle;
    notifier.pomoCancel();
    notifyListeners();
  }

  /// Focus is always followed by a short break, and a break by the next focus.
  /// After the last focus session of a cycle (and its break) a new cycle begins.
  void _moveToNext() {
    if (phase == PomoPhase.focus) {
      focusIndex++;
      phase = PomoPhase.shortBreak;
    } else {
      phase = PomoPhase.focus;
      if (focusIndex >= cycles) focusIndex = 0;
    }
    _left = dur(phase);
  }

  void tick() {
    if (status != PomoStatus.running || _endAt == null) return;
    final now = DateTime.now();
    if (now.isBefore(_endAt!)) return;
    _complete(now.difference(_endAt!));
  }

  /// Runs exactly once per countdown: the status leaves "running" before
  /// anything else happens, so a second tick can never record it again.
  void _complete(Duration lateness) {
    _stopTimer();
    status = PomoStatus.awaiting;
    _endAt = null;
    _left = Duration.zero;
    final wasFocus = phase == PomoPhase.focus;
    if (wasFocus) {
      store.addPomoFocus(dur(phase).inSeconds);
    } else {
      store.addPomoBreak();
    }
    _announce(wasFocus, lateness);
    notifyListeners();
  }

  /// The user confirmed the next session: the sound stops first, then the next
  /// countdown begins.
  Future<void> startNext() async {
    if (status != PomoStatus.awaiting) return;
    try {
      await pomoAudio.stop().timeout(const Duration(milliseconds: 800));
    } catch (_) {}
    if (status != PomoStatus.awaiting) return;
    _moveToNext();
    _endAt = DateTime.now().add(_left);
    status = PomoStatus.running;
    sessionActive = true;
    _startTimer();
    notifier.pomoCancel();
    notifyListeners();
  }

  String _nextText(bool wasFocus) =>
      wasFocus ? 'Time for a short break.' : 'Ready for your next focus session.';

  void _announce(bool wasFocus, Duration lateness) {
    if (!_foreground || lateness > const Duration(seconds: 5)) return;
    final soundOn = store.pomoSound;
    String? custom = soundOn ? store.pomoSoundPath : null;
    if (custom != null && !File(custom).existsSync()) {
      store.clearPomoSound(); // the file was deleted: fall back to the default alert
      custom = null;
    }
    if (soundOn) HapticFeedback.heavyImpact();
    final title = wasFocus ? 'Focus session complete' : 'Break over';
    // With a custom sound the notification stays silent and the sound loops until
    // the user acts; with sound off nothing is played at all.
    notifier.pomoNow(title, _nextText(wasFocus), soundOn && custom == null);
    if (custom != null) {
      pomoAudio.play(custom, loop: true).then((ok) {
        if (!ok) {
          store.clearPomoSound();
          notifier.pomoNow(title, _nextText(wasFocus), true);
        }
      });
    }
  }

  void onBackground() {
    _foreground = false;
    if (status == PomoStatus.running && _endAt != null) {
      final wasFocus = phase == PomoPhase.focus;
      notifier.pomoSchedule(_endAt!, wasFocus ? 'Focus session complete' : 'Break over',
          _nextText(wasFocus), store.pomoSound);
    }
  }

  void onResume() {
    notifier.pomoCancel();
    tick();
    _foreground = true;
    store.rollPomoDay();
    notifyListeners();
  }
}

// ───────── mascot ─────────
class TomatoMascot extends StatefulWidget {
  final double size;
  const TomatoMascot({super.key, this.size = 150});
  @override
  State<TomatoMascot> createState() => _TomatoMascotState();
}

class _TomatoMascotState extends State<TomatoMascot> with TickerProviderStateMixin {
  late final AnimationController _float =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  late final AnimationController _blink =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 130));
  final math.Random _rng = math.Random();
  Timer? _blinkTimer;

  @override
  void initState() {
    super.initState();
    _float.repeat(reverse: true);
    _scheduleBlink();
  }

  void _scheduleBlink() {
    _blinkTimer = Timer(Duration(milliseconds: 2200 + _rng.nextInt(2800)), () async {
      if (!mounted) return;
      await _blink.forward();
      if (!mounted) return;
      await _blink.reverse();
      if (mounted) _scheduleBlink();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _float.stop();
    } else if (!_float.isAnimating) {
      _float.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _float.dispose();
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: TomatoPainter(_float, _blink),
      ),
    );
  }
}

class TomatoPainter extends CustomPainter {
  final Animation<double> float, blink;
  TomatoPainter(this.float, this.blink) : super(repaint: Listenable.merge([float, blink]));

  void _leaf(Canvas c, Offset base, double len, double angle, Paint p) {
    c.save();
    c.translate(base.dx, base.dy);
    c.rotate(angle);
    final path = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(len * 0.35, -len * 0.42, len, 0)
      ..quadraticBezierTo(len * 0.35, len * 0.22, 0, 0)
      ..close();
    c.drawPath(path, p);
    c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final t = Curves.easeInOut.transform(float.value);
    final cx = w / 2;
    final cy = h * 0.58 - 6 * t;
    final rx = w * 0.36, ry = w * 0.33;

    final sh = 1 - 0.2 * t;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, h * 0.93), width: rx * 1.6 * sh, height: 9 * sh),
      Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    final body = Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);
    canvas.drawOval(
      body,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          radius: 1.0,
          colors: [Color(0xFFFF8A7A), Color(0xFFE53935), Color(0xFFA81414)],
          stops: [0, 0.55, 1],
        ).createShader(body),
    );
    canvas.save();
    canvas.translate(cx - rx * 0.48, cy - ry * 0.5);
    canvas.rotate(-0.6);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: rx * 0.5, height: ry * 0.26),
      Paint()..color = Colors.white.withOpacity(0.55),
    );
    canvas.restore();

    final crown = Offset(cx, cy - ry * 0.86);
    final leafPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF86E07A), Color(0xFF2E9B3E)],
      ).createShader(Rect.fromCenter(center: crown, width: rx * 1.4, height: ry * 0.7));
    const angles = [-2.8, -2.2, -1.57, -0.95, -0.35];
    const lens = [0.26, 0.22, 0.17, 0.22, 0.26];
    for (var i = 0; i < angles.length; i++) {
      _leaf(canvas, crown, w * lens[i], angles[i], leafPaint);
    }
    canvas.drawLine(
      crown,
      crown.translate(2, -9),
      Paint()
        ..color = const Color(0xFF3F7D3A)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );

    final cheek = Paint()..color = const Color(0xFFFF9AA2).withOpacity(0.55);
    canvas.drawCircle(Offset(cx - rx * 0.62, cy + ry * 0.22), rx * 0.12, cheek);
    canvas.drawCircle(Offset(cx + rx * 0.62, cy + ry * 0.22), rx * 0.12, cheek);

    final eyeH = (1 - blink.value) * ry * 0.34 + 2;
    final eyeY = cy + ry * 0.02;
    final ex = rx * 0.38;
    final eyePaint = Paint()..color = const Color(0xFF2A1210);
    for (final sx in [-1.0, 1.0]) {
      final c = Offset(cx + sx * ex, eyeY);
      canvas.drawOval(Rect.fromCenter(center: c, width: rx * 0.19, height: eyeH), eyePaint);
      if (blink.value < 0.5) {
        canvas.drawCircle(c.translate(-rx * 0.03, -eyeH * 0.22), rx * 0.04,
            Paint()..color = Colors.white.withOpacity(0.9));
      }
    }

    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, cy + ry * 0.2), width: rx * 0.5, height: ry * 0.32),
      0.2,
      2.7,
      false,
      Paint()
        ..color = const Color(0xFF5A1612)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(TomatoPainter old) => false;
}

// ───────── shared bits ─────────
class GradientButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const GradientButton({super.key, required this.label, required this.icon, required this.onTap});
  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: Container(
          height: 58,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6)]),
            borderRadius: BorderRadius.circular(29),
            boxShadow: [
              BoxShadow(
                color: kAccent.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Row(
                key: ValueKey(widget.label),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: Colors.white, size: 24),
                  const SizedBox(width: 8),
                  Text(widget.label,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Numeric entry dialog used by the tappable values in the timer settings.
Future<int?> askNumber(
  BuildContext context, {
  required String title,
  required int value,
  required int min,
  required int max,
  required String unit,
}) {
  final ctl = TextEditingController(text: '$value');
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  String? err;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      void submit() {
        final v = int.tryParse(ctl.text.trim());
        if (v == null || v < min || v > max) {
          set(() => err = 'Enter a number from $min to $max');
          return;
        }
        Navigator.pop(ctx, v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
          decoration: deco(ctx, unit).copyWith(errorText: err, helperText: 'Between $min and $max'),
          onChanged: (_) {
            if (err != null) set(() => err = null);
          },
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    }),
  );
}

class PomoStepper extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label, unit;
  final int value, min, max, step;
  final ValueChanged<int> onChanged;
  const PomoStepper({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  Widget _btn(BuildContext c, IconData i, bool enabled, VoidCallback onTap) {
    final on = onSurf(c);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.35,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: on.withOpacity(0.25)),
          ),
          child: Icon(i, size: 18, color: on),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
        ),
        _btn(context, Icons.remove_rounded, value > min,
            () => onChanged(math.max(min, value - step))),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final v = await askNumber(
              context,
              title: label,
              value: value,
              min: min,
              max: max,
              unit: unit.isEmpty ? 'Value' : 'Minutes',
            );
            if (v != null) onChanged(v);
          },
          child: Container(
            width: 78,
            height: 34,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: on.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                child: Text(unit.isEmpty ? '$value' : '$value $unit',
                    key: ValueKey(value),
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: on)),
              ),
            ),
          ),
        ),
        _btn(context, Icons.add_rounded, value < max, () => onChanged(math.min(max, value + step))),
      ]),
    );
  }
}

// ───────── screen one: configuration ─────────
class PomodoroSetupPage extends StatelessWidget {
  const PomodoroSetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: Listenable.merge([store, pomodoro]),
        builder: (c, _) {
          store.rollPomoDay();
          final on = onSurf(c);
          final cfg = store.pomoCfg;
          Widget stat(IconData icon, Color col, String value, String label) => Expanded(
                child: Column(children: [
                  Icon(icon, color: col, size: 24),
                  const SizedBox(height: 6),
                  Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
                  const SizedBox(height: 2),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.6))),
                ]),
              );
          return Column(children: [
            SubHeader(
              title: 'Pomodoro',
              subtitle: 'Focus. Study. Achieve.',
              actions: [GlassIconBtn(Icons.settings_rounded, () => showPomoSettings(c))],
            ),
            Expanded(
              child: LayoutBuilder(builder: (ctx, box) {
                final mascot = (box.maxHeight * 0.27).clamp(96.0, 150.0).toDouble();
                return RevealList(
                  page: 'pomo',
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    Center(child: TomatoMascot(size: mascot)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                      child: Glass(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Set Your Timer',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
                          const SizedBox(height: 6),
                          PomoStepper(
                            icon: Icons.timer_rounded,
                            color: kAccent,
                            label: 'Focus Time',
                            unit: 'min',
                            value: cfg['focus']!,
                            min: 1,
                            max: 180,
                            step: 5,
                            onChanged: (v) => store.setPomo('focus', v),
                          ),
                          PomoStepper(
                            icon: Icons.coffee_rounded,
                            color: kHabit,
                            label: 'Short Break',
                            unit: 'min',
                            value: cfg['short']!,
                            min: 1,
                            max: 60,
                            step: 1,
                            onChanged: (v) => store.setPomo('short', v),
                          ),
                          PomoStepper(
                            icon: Icons.repeat_rounded,
                            color: kPomo,
                            label: 'Cycles',
                            unit: '',
                            value: cfg['cycles']!,
                            min: 1,
                            max: 12,
                            step: 1,
                            onChanged: (v) => store.setPomo('cycles', v),
                          ),
                          if (pomodoro.sessionActive)
                            Padding(
                              padding: const EdgeInsets.only(top: 4, bottom: 4),
                              child: Text('Changes apply to your next session.',
                                  style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
                            ),
                        ]),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Glass(
                        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom: 12),
                            child: Text("Today's Progress",
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: on)),
                          ),
                          Row(children: [
                            stat(Icons.check_circle_rounded, kHabit, '${store.pomoCycles}', 'Focus cycles'),
                            stat(Icons.coffee_rounded, kWarn, '${store.pomoBreaks}', 'Breaks'),
                            stat(Icons.schedule_rounded, kAccent, fmtFocusTime(store.pomoFocusSec),
                                'Focus time'),
                          ]),
                        ]),
                      ),
                    ),
                  ],
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
              child: GradientButton(
                label: pomodoro.sessionActive ? 'Resume Session' : 'Start Session',
                icon: Icons.play_arrow_rounded,
                onTap: () {
                  if (!pomodoro.sessionActive) {
                    pomodoro.configure(
                      focus: cfg['focus']!,
                      shortB: cfg['short']!,
                      cyc: cfg['cycles']!,
                    );
                  }
                  openScreen(c, const PomodoroTimerPage());
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

Future<void> showPomoSettings(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const PomoSettingsSheet(),
  ).whenComplete(pomoAudio.stop);
}

class PomoSettingsSheet extends StatefulWidget {
  const PomoSettingsSheet({super.key});
  @override
  State<PomoSettingsSheet> createState() => _PomoSettingsSheetState();
}

class _PomoSettingsSheetState extends State<PomoSettingsSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await pickPomoSound();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final path = store.pomoSoundPath;
        final exists = path != null && File(path).existsSync();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.88),
            child: Glass(
              radius: 30,
              opacity: isDark(c) ? 0.18 : 0.9,
              padding: const EdgeInsets.all(22),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Pomodoro settings',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
                  const SizedBox(height: 14),
                  Row(children: [
                    Icon(store.pomoSound ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                        color: kPomo),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Sound & vibration',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                        Text('Alert when a session ends',
                            style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                      ]),
                    ),
                    Switch(
                      value: store.pomoSound,
                      activeTrackColor: kAccent,
                      onChanged: (_) => store.togglePomoSound(),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Text('Custom completion sound',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                  const SizedBox(height: 2),
                  Text('Plays when a focus session or a break ends.',
                      style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                  const SizedBox(height: 10),
                  if (path == null)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pick,
                        icon: const Icon(Icons.library_music_rounded, size: 20),
                        label: Text(_busy ? 'Loading...' : 'Select Sound'),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: on.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.music_note_rounded, color: kPomo, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(store.pomoSoundName ?? 'Custom sound',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700, color: on)),
                          ),
                          if (!exists) const Pill('File missing', kBad),
                        ]),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: pomoAudio.playing,
                            builder: (ctx, playing, _) => FilledButton.tonalIcon(
                              onPressed: exists
                                  ? () => playing
                                      ? pomoAudio.stop()
                                      : pomoAudio.play(path, preview: true)
                                  : null,
                              icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                                  size: 18),
                              label: Text(playing ? 'Stop' : 'Preview'),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _pick,
                            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                            label: Text(_busy ? 'Loading...' : 'Replace'),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: kBad,
                              side: BorderSide(color: kBad.withOpacity(0.5)),
                            ),
                            onPressed: _busy
                                ? null
                                : () async {
                                    await pomoAudio.stop();
                                    await removePomoSound();
                                  },
                            icon: const Icon(Icons.delete_outline_rounded, size: 18),
                            label: const Text('Remove'),
                          ),
                        ]),
                      ]),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: kBad)),
                    ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: store.resetPomoConfig,
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('Reset durations to default'),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───────── screen two: minimal timer ─────────
/// Bold, rounded countdown. Poppins Bold supplies the geometric numerals and a
/// round-joined outline softens every corner. Each character sits in a fixed
/// cell, so digits never shift as the time changes, and the optical centre of
/// the digits is aligned with the middle of the box.
class RoundedClock extends StatelessWidget {
  final String text;
  final double fontSize;
  final Color color;
  const RoundedClock({super.key, required this.text, required this.fontSize, required this.color});

  TextStyle _style({required bool outline}) => TextStyle(
        fontFamily: 'Poppins',
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        height: 1.0,
        leadingDistribution: TextLeadingDistribution.even,
        color: outline ? null : color,
        foreground: outline
            ? (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = fontSize * 0.05
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round
              ..color = color)
            : null,
      );

  @override
  Widget build(BuildContext context) {
    final fs = fontSize;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final ch in text.split(''))
          SizedBox(
            width: fs * (ch == ':' ? 0.34 : 0.66),
            height: fs,
            child: Transform.translate(
              offset: Offset(0, fs * (ch == ':' ? -0.06 : 0.02)),
              child: OverflowBox(
                maxWidth: fs * 1.2,
                child: Stack(alignment: Alignment.center, children: [
                  Text(ch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: _style(outline: true)),
                  Text(ch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: _style(outline: false)),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}

class RingPainter extends CustomPainter {
  final double fraction;
  final Color c1, c2, track;
  RingPainter(this.fraction, this.c1, this.c2, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 18;
    const stroke = 14.0;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    final sweep = 2 * math.pi * fraction;
    if (sweep < 0.02) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: sweep,
      colors: [c1, c2],
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(rect);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
        ..color = Colors.white.withOpacity(0.55),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
    final endAngle = -math.pi / 2 + sweep;
    canvas.drawCircle(
      Offset(center.dx + radius * math.cos(endAngle), center.dy + radius * math.sin(endAngle)),
      4.5,
      Paint()..color = Colors.white.withOpacity(0.95),
    );
  }

  @override
  bool shouldRepaint(RingPainter old) => true;
}

class TimerRing extends StatefulWidget {
  final double size;
  const TimerRing({super.key, required this.size});
  @override
  State<TimerRing> createState() => _TimerRingState();
}

class _TimerRingState extends State<TimerRing> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}));
    pomodoro.addListener(_sync);
    if (pomodoro.status == PomoStatus.running) _ticker.start();
  }

  void _sync() {
    if (!mounted) return;
    final run = pomodoro.status == PomoStatus.running;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    pomodoro.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final size = widget.size;
    final secs = (pomodoro.remaining.inMilliseconds / 1000).ceil();
    final mm = (secs ~/ 60).toString().padLeft(2, '0');
    final ss = (secs % 60).toString().padLeft(2, '0');
    final pair = phaseColors(pomodoro.phase);
    final idle = pomodoro.status == PomoStatus.idle;
    final phase = pomodoro.phase;
    // Time is laid out on its own at the exact centre; the labels hang below it.
    final fs = size * 0.215;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: pomodoro.status == PomoStatus.running ? null : pomodoro.start,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(children: [
          Positioned.fill(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: pair.$1),
              duration: const Duration(milliseconds: 500),
              builder: (c, c1, _) => TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: pair.$2),
                duration: const Duration(milliseconds: 500),
                builder: (c, c2, _) => RepaintBoundary(
                  child: CustomPaint(
                    painter: RingPainter(
                      pomodoro.fraction,
                      c1 ?? pair.$1,
                      c2 ?? pair.$2,
                      on.withOpacity(0.08),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Center(child: RoundedClock(text: '$mm:$ss', fontSize: fs, color: on)),
          Positioned(
            left: 0,
            right: 0,
            top: size / 2 + fs / 2 + size * 0.03,
            child: Center(
              child: SizedBox(
                width: size * 0.56,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        key: ValueKey(phase),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: on.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            phase == PomoPhase.focus ? Icons.timer_rounded : Icons.coffee_rounded,
                            size: 17,
                            color: pair.$2,
                          ),
                          const SizedBox(width: 7),
                          Text(phaseLabel(phase),
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700, color: on)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedOpacity(
                      opacity: idle ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Text('Tap to start',
                          style: TextStyle(fontSize: 13, color: on.withOpacity(0.55))),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Shown instead of the ring once a countdown ends, until the user confirms.
class CompletionPanel extends StatelessWidget {
  const CompletionPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final focus = pomodoro.phase == PomoPhase.focus;
    final pair = phaseColors(pomodoro.phase);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Glass(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [pair.$1, pair.$2]),
                boxShadow: [
                  BoxShadow(color: pair.$2.withOpacity(0.45), blurRadius: 22, offset: const Offset(0, 6)),
                ],
              ),
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 42),
            ),
            const SizedBox(height: 18),
            Text(focus ? 'Focus Session Completed!' : 'Break Completed!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 8),
            Text(
              focus
                  ? 'Great work! Take a short break to recharge.'
                  : "Break's over. Ready for the next focus session?",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: on.withOpacity(0.65)),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: pomoAudio.playing,
              builder: (c, playing, _) => AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                child: playing
                    ? Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: OutlinedButton.icon(
                          onPressed: pomoAudio.stop,
                          icon: const Icon(Icons.volume_off_rounded, size: 18),
                          label: const Text('Stop Sound'),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class PomodoroTimerPage extends StatelessWidget {
  const PomodoroTimerPage({super.key});

  Widget _mini(BuildContext c, IconData icon, String label, VoidCallback onTap) {
    final on = onSurf(c);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GlassIconBtn(icon, onTap),
      const SizedBox(height: 6),
      Text(label, style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.6))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // leaving a finished session silences its alert
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && pomodoro.awaiting) pomoAudio.stop();
      },
      child: screenFrame(
        context,
        ListenableBuilder(
          listenable: pomodoro,
          builder: (c, _) {
            final on = onSurf(c);
            final st = pomodoro.status;
            final done = st == PomoStatus.awaiting;
            final focusDone = pomodoro.phase == PomoPhase.focus;
            final line =
                '${phaseLabel(pomodoro.phase)} • Session ${pomodoro.sessionNumber} of ${pomodoro.cycles}';
            String label;
            IconData icon;
            VoidCallback onTap;
            if (done) {
              label = focusDone ? 'Start Short Break' : 'Start Next Focus Session';
              icon = focusDone ? Icons.coffee_rounded : Icons.play_arrow_rounded;
              onTap = () => pomodoro.startNext();
            } else if (st == PomoStatus.running) {
              label = 'Pause';
              icon = Icons.pause_rounded;
              onTap = pomodoro.pause;
            } else {
              label = st == PomoStatus.paused ? 'Resume' : 'Start';
              icon = Icons.play_arrow_rounded;
              onTap = pomodoro.start;
            }
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GlassIconBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(c).pop()),
                ),
              ),
              Expanded(
                child: LayoutBuilder(builder: (ctx, box) {
                  final size = math.max(
                      0.0, math.min(math.min(box.maxWidth - 48, box.maxHeight - 16), 340.0));
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    child: done
                        ? CompletionPanel(key: ValueKey('done-${pomodoro.phase}'))
                        : Center(key: const ValueKey('ring'), child: TimerRing(size: size)),
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(line,
                      key: ValueKey(line),
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: on.withOpacity(0.7))),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: pomodoro.sessionActive
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                              if (!done) _mini(c, Icons.restart_alt_rounded, 'Reset', pomodoro.reset),
                              if (!done) _mini(c, Icons.skip_next_rounded, 'Skip', pomodoro.skip),
                              _mini(c, Icons.stop_rounded, 'Stop', () {
                                pomodoro.stop();
                                Navigator.of(c).pop();
                              }),
                            ]),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  GradientButton(label: label, icon: icon, onTap: onTap),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
