import 'package:flutter/material.dart';

import '../core/negotiable_apps.dart';
import '../platform/android_lockdown.dart';

/// Settings editor for the user-approved set of apps the guardian is ALLOWED to
/// unlock during lockdown. Being on this list does NOT unlock anything; it only
/// authorizes the `unlock_app` tool to free that app for a timed window. The
/// guardian cannot free apps that are not on this list.
///
/// Backed by [NegotiableAppStore]; the catalog comes from
/// [AndroidLockdown.listInstalledApps] (no QUERY_ALL_PACKAGES).
class AllowlistEditorScreen extends StatefulWidget {
  const AllowlistEditorScreen({super.key});

  @override
  State<AllowlistEditorScreen> createState() => _AllowlistEditorScreenState();
}

class _AllowlistEditorScreenState extends State<AllowlistEditorScreen> {
  final _store = NegotiableAppStore.instance;
  List<AndroidInstalledApp> _catalog = const [];
  bool _loadingCatalog = true;

  static const _bg = Color(0xFFF0F4FA);
  static const _indigo = Color(0xFF5B5FEF);
  static const _ink = Color(0xFF1A1A2E);
  static const _muted = Color(0xFF8E8EA0);

  @override
  void initState() {
    super.initState();
    _store.load();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    final apps = await AndroidLockdown.listInstalledApps();
    if (mounted) {
      setState(() {
        _catalog = apps;
        _loadingCatalog = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: _ink,
        title: const Text('Apps the guardian can unlock',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _indigo,
        onPressed: _loadingCatalog ? null : _showAddSheet,
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('Add app',
            style: TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<List<NegotiableApp>>(
        stream: _store.changes,
        initialData: _store.apps,
        builder: (context, snapshot) {
          final apps = snapshot.data ?? const [];
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
            children: [
              const Text(
                'Pick the apps you trust the guardian to free for a few minutes '
                'during lockdown (e.g. a messaging app for a genuine emergency). '
                'The guardian can never unlock anything outside this list.',
                style: TextStyle(fontSize: 14, color: _muted, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (apps.isEmpty)
                _emptyState()
              else
                ...apps.map(_approvedTile),
            ],
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Column(
        children: [
          Icon(Icons.lock_outline_rounded, color: _muted, size: 32),
          SizedBox(height: 12),
          Text(
            'No apps approved yet.\nThe guardian cannot unlock any app during '
            'lockdown until you add one here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _approvedTile(NegotiableApp app) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.apps_rounded, color: _indigo, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.label,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: _ink)),
                Text(app.package,
                    style: const TextStyle(fontSize: 11, color: _muted),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline_rounded,
                color: Color(0xFFFF3B30)),
            onPressed: () => _store.remove(app.package),
          ),
        ],
      ),
    );
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _AddAppSheet(
        catalog: _catalog,
        alreadyApproved: _store.apps.map((a) => a.package).toSet(),
        onPick: (app) {
          _store.add(NegotiableApp(package: app.package, label: app.label));
          Navigator.of(context).pop();
        },
      ),
    );
  }
}

class _AddAppSheet extends StatefulWidget {
  final List<AndroidInstalledApp> catalog;
  final Set<String> alreadyApproved;
  final void Function(AndroidInstalledApp app) onPick;

  const _AddAppSheet({
    required this.catalog,
    required this.alreadyApproved,
    required this.onPick,
  });

  @override
  State<_AddAppSheet> createState() => _AddAppSheetState();
}

class _AddAppSheetState extends State<_AddAppSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = widget.catalog
        .where((a) => !widget.alreadyApproved.contains(a.package))
        .where((a) =>
            q.isEmpty ||
            a.label.toLowerCase().contains(q) ||
            a.package.toLowerCase().contains(q))
        .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE5E5EA),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: false,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search apps',
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF0F4FA),
                ),
              ),
            ),
            if (widget.catalog.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No installed apps found. (App catalog is only available '
                      'on a real Android device.)',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Color(0xFF8E8EA0), fontSize: 13),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final app = filtered[i];
                    return ListTile(
                      leading: const Icon(Icons.apps_rounded,
                          color: Color(0xFF5B5FEF)),
                      title: Text(app.label),
                      subtitle: Text(app.package,
                          style: const TextStyle(fontSize: 11)),
                      onTap: () => widget.onPick(app),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
