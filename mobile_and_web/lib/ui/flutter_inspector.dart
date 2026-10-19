import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/debug_inspector.dart';
import 'theme.dart';

/// A read-only view of the bounded Flutter debug capture.
///
/// It deliberately has no build instrumentation or periodic refresh: observing
/// this dialog must not generate more inspector events or frame notifications.
class FlutterInspectorDialog extends StatefulWidget {
  const FlutterInspectorDialog({
    super.key,
    required this.inspector,
    this.onRefresh,
  });

  final DebugInspector inspector;
  final VoidCallback? onRefresh;

  @override
  State<FlutterInspectorDialog> createState() => _FlutterInspectorDialogState();
}

class _FlutterInspectorDialogState extends State<FlutterInspectorDialog> {
  static const _encoder = JsonEncoder.withIndent('  ');
  final _expandedEvents = <int>{};
  final _eventJson = <int, String>{};
  bool _sqliteDetailsWereEnabled = false;
  bool _httpDetailsWereEnabled = false;
  bool _realtimeDetailsWereEnabled = false;
  late Map<String, Object?> _snapshot;
  late List<Map<String, Object?>> _events;
  String _category = 'all';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _readSnapshot();
    widget.inspector.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant FlutterInspectorDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inspector == widget.inspector) return;
    oldWidget.inspector.removeListener(_refresh);
    widget.inspector.addListener(_refresh);
    _eventJson.clear();
    _expandedEvents.clear();
    _readSnapshot();
  }

  @override
  void dispose() {
    widget.inspector.removeListener(_refresh);
    super.dispose();
  }

  void _readSnapshot({bool exportMetrics = false}) {
    widget.onRefresh?.call();
    if (exportMetrics) widget.inspector.exportMetricsSnapshot();
    _snapshot = widget.inspector.snapshot();
    final sqliteEnabled = _snapshot['sqliteDetailsEnabled'] == true;
    final httpEnabled = _snapshot['httpDetailsEnabled'] == true;
    final realtimeEnabled = _snapshot['realtimeDetailsEnabled'] == true;
    if ((_sqliteDetailsWereEnabled && !sqliteEnabled) ||
        (_httpDetailsWereEnabled && !httpEnabled) ||
        (_realtimeDetailsWereEnabled && !realtimeEnabled)) {
      _eventJson.clear();
    }
    _sqliteDetailsWereEnabled = sqliteEnabled;
    _httpDetailsWereEnabled = httpEnabled;
    _realtimeDetailsWereEnabled = realtimeEnabled;
    _events = _rows(_snapshot['events']);
    final retained = _events.map((event) => event['seq']).toSet();
    _eventJson.removeWhere((seq, _) => !retained.contains(seq));
    _expandedEvents.removeWhere((seq) => !retained.contains(seq));
  }

  void _refresh() {
    if (mounted) setState(_readSnapshot);
  }

  void _refreshCounters() {
    if (mounted) setState(() => _readSnapshot(exportMetrics: true));
  }

  Future<void> _copy() async {
    _refresh();
    try {
      await Clipboard.setData(ClipboardData(text: _encoder.convert(_snapshot)));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Inspector snapshot copied')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not copy the inspector snapshot')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _snapshot['enabled'] == true;
    final paused = _snapshot['paused'] == true;
    final resources = _map(_snapshot['resources']);
    final localLogs = _map(_snapshot['localLogs']);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 860),
        child: SizedBox(
          width: 1100,
          height: 860,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: DefaultTabController(
              length: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Flutter inspector',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        key: const Key('inspector-refresh'),
                        tooltip: 'Refresh counters',
                        onPressed: _refreshCounters,
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(
                        key: const Key('inspector-close'),
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    _snapshot['sqliteDetailsEnabled'] == true
                        ? 'Full debug: HTTP, realtime and SQLite details. Credentials and binary bytes are excluded.'
                        : 'Metadata only. Turn on Full debug traffic logging in Sync diagnostics for payloads.',
                    style: TextStyle(
                      fontSize: 12,
                      color: ChatColors.of(context).muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            container: true,
                            label: 'Capture Flutter events',
                            child: Switch.adaptive(
                              key: const Key('inspector-enabled'),
                              value: enabled,
                              onChanged: widget.inspector.setEnabled,
                            ),
                          ),
                          const Text('Capture'),
                        ],
                      ),
                      TextButton.icon(
                        key: const Key('inspector-pause'),
                        onPressed: enabled
                            ? () => widget.inspector.setPaused(!paused)
                            : null,
                        icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                        label: Text(paused ? 'Resume' : 'Pause'),
                      ),
                      TextButton.icon(
                        key: const Key('inspector-clear'),
                        onPressed: widget.inspector.clear,
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear'),
                      ),
                      TextButton.icon(
                        key: const Key('inspector-copy'),
                        onPressed: _copy,
                        icon: const Icon(Icons.copy, size: 17),
                        label: const Text('Copy JSON'),
                      ),
                      Tooltip(
                        message:
                            'Send new inspector events and enabled SQLite details to the local collector. '
                            'Pause, Clear and Capture off discard pending delivery. '
                            'Already accepted records remain in local logs.',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Semantics(
                              container: true,
                              label: 'Share inspector with local logs',
                              child: Switch.adaptive(
                                key: const Key('inspector-local-logs'),
                                value: localLogs['enabled'] == true,
                                onChanged: localLogs['available'] == true
                                    ? widget.inspector.setShareWithLocalLogs
                                    : null,
                              ),
                            ),
                            const Flexible(
                              child: Text('Share with local logs'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${enabled ? (paused ? 'Paused' : 'Capturing') : 'Capture off'}'
                    ' · ${_events.length} retained'
                    ' · ${resources['droppedEvents'] ?? 0} evicted'
                    ' · ${resources['activeSpans'] ?? 0} active spans',
                    key: const Key('inspector-capture-status'),
                    style: TextStyle(
                      fontSize: 11,
                      color: ChatColors.of(context).muted,
                    ),
                  ),
                  Tooltip(
                    message:
                        '${_localLogStatus(localLogs)}\n'
                        '${localLogs['droppedEvents'] ?? 0} total dropped; '
                        '${localLogs['droppedCriticalEvents'] ?? 0} errors/warnings dropped; '
                        '${localLogs['pendingImportantEvents'] ?? 0} important pending; '
                        '${localLogs['retriedBatches'] ?? 0} retries; '
                        '${localLogs['sampledEvents'] ?? 0} sampled; '
                        '${localLogs['evictedNoiseEvents'] ?? 0} noise evicted; '
                        '${resources['trackedSpans'] ?? 0} DevTools tracked; '
                        '${resources['overflowSpans'] ?? 0} DevTools overflow; '
                        '${resources['droppedSpans'] ?? 0} omitted spans. '
                        '${localLogs['lastFailure'] ?? ''}',
                    child: Text(
                      _localLogStatus(localLogs),
                      key: const Key('inspector-local-logs-status'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: ChatColors.of(context).muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Timeline'),
                      Tab(text: 'Overview'),
                      Tab(text: 'Slow operations'),
                      Tab(text: 'Widgets & frames'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _timeline(enabled),
                        _overview(),
                        _slowOperations(),
                        _widgetsAndFrames(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeline(bool enabled) {
    final events = _events;
    final categories = {
      for (final event in events) event['category']?.toString() ?? 'unknown',
      if (_category != 'all') _category,
    }.toList()..sort();
    final query = _query.trim().toLowerCase();
    final filtered = events.reversed.where((event) {
      if (_category != 'all' && event['category'] != _category) return false;
      if (query.isEmpty) return true;
      return [
        event['name'],
        event['category'],
        event['traceId'],
        event['spanId'],
        event['parentSpanId'],
        event['userId'],
        event['roomId'],
        _outcome(event),
      ].any(
        (value) => value?.toString().toLowerCase().contains(query) ?? false,
      );
    }).toList();
    final search = TextField(
      key: const Key('inspector-search'),
      onChanged: (value) => setState(() => _query = value),
      decoration: const InputDecoration(
        labelText: 'Name, user, room or trace',
        prefixIcon: Icon(Icons.search),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
    final category = InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Category',
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('inspector-category-filter'),
          value: _category,
          isDense: true,
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: 'all', child: Text('All categories')),
            for (final value in categories)
              DropdownMenuItem(value: value, child: Text(value)),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _category = value);
          },
        ),
      ),
    );
    return CustomScrollView(
      key: const Key('inspector-timeline'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth < 540
                      ? Column(
                          children: [
                            search,
                            const SizedBox(height: 10),
                            category,
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: search),
                            const SizedBox(width: 12),
                            SizedBox(width: 210, child: category),
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '${filtered.length} of ${events.length} retained events · newest first',
                    key: const Key('inspector-filter-count'),
                    style: TextStyle(
                      fontSize: 11,
                      color: ChatColors.of(context).muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                enabled
                    ? 'No events match these filters.'
                    : 'Enable capture to inspect Flutter operations.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (filtered.isNotEmpty)
          SliverList.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) => _eventTile(filtered[index]),
          ),
      ],
    );
  }

  Widget _eventTile(Map<String, Object?> event) {
    final seq = event['seq'] as int;
    final duration = event['durationMicros'];
    final identity = [
      if (event['userId'] != null) 'user ${event['userId']}',
      if (event['sessionGeneration'] != null)
        'session ${event['sessionGeneration']}',
      if (event['roomId'] != null) 'room ${event['roomId']}',
    ];
    return ExpansionTile(
      key: Key('inspector-event-$seq'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      initiallyExpanded: _expandedEvents.contains(seq),
      title: Text(
        '${event['name']} · ${event['phase']}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              '${event['timestamp']}',
              '${event['category']}',
              if (duration is num) _duration(duration),
              if (_outcome(event).isNotEmpty) _outcome(event),
            ].join(' · '),
            style: const TextStyle(fontSize: 11),
          ),
          if (identity.isNotEmpty)
            Text(identity.join(' · '), style: const TextStyle(fontSize: 11)),
          Text(
            'trace ${event['traceId'] ?? '—'} · span ${event['spanId'] ?? '—'}'
            ' · parent ${event['parentSpanId'] ?? '—'}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
          ),
        ],
      ),
      onExpansionChanged: (expanded) => setState(() {
        if (expanded) {
          _expandedEvents.add(seq);
        } else {
          _expandedEvents.remove(seq);
        }
      }),
      children: [
        if (_expandedEvents.contains(seq))
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SelectableText(
              _eventJson.putIfAbsent(seq, () => _encoder.convert(event)),
              key: Key('inspector-event-json-$seq'),
              style: _jsonStyle,
            ),
          ),
      ],
    );
  }

  Widget _overview() => ListView(
    key: const Key('inspector-overview'),
    padding: const EdgeInsets.symmetric(vertical: 12),
    children: [
      Text(
        'Refresh counters to include current gauges, widget builds and frames '
        'and share their metadata when local sharing is on. '
        'These counters do not trigger their own UI refresh.',
        style: TextStyle(fontSize: 12, color: ChatColors.of(context).muted),
      ),
      const SizedBox(height: 14),
      _MetricSection(
        title: 'Runtime gauges',
        values: _map(_snapshot['gauges']),
      ),
      const SizedBox(height: 16),
      _MetricSection(
        title: 'Tracked resources and bounds',
        values: _map(_snapshot['resources']),
      ),
      const SizedBox(height: 16),
      _MetricSection(
        title: 'Local log delivery',
        values: _map(_snapshot['localLogs']),
      ),
      const SizedBox(height: 16),
      Text('Current context', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      SelectableText(
        _encoder.convert(_snapshot['context']),
        key: const Key('inspector-context'),
        style: _jsonStyle,
      ),
      const SizedBox(height: 16),
      const _ProfilingGuidance(),
    ],
  );

  Widget _slowOperations() {
    final aggregates = _rows(_snapshot['aggregates'])
      ..sort(
        (a, b) => _number(b['maxMicros']).compareTo(_number(a['maxMicros'])),
      );
    if (aggregates.isEmpty) {
      return const Center(child: Text('No completed operations captured.'));
    }
    return ListView.builder(
      key: const Key('inspector-slow-operations'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: aggregates.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Ordered by maximum duration. Debug timings include instrumentation '
              'overhead and are not release benchmarks.',
              style: TextStyle(
                fontSize: 12,
                color: ChatColors.of(context).muted,
              ),
            ),
          );
        }
        final aggregate = aggregates[index - 1];
        final count = _number(aggregate['count']);
        final average = count == 0
            ? 0
            : _number(aggregate['totalMicros']) / count;
        return ExpansionTile(
          key: Key(
            'inspector-aggregate-${aggregate['category']}-${aggregate['name']}',
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text('${aggregate['category']} · ${aggregate['name']}'),
          subtitle: Text(
            '${aggregate['count']} calls · ${aggregate['errorCount']} errors'
            ' · max ${_duration(_number(aggregate['maxMicros']))}'
            ' · avg ${_duration(average)}'
            ' · total ${_duration(_number(aggregate['totalMicros']))}',
            style: const TextStyle(fontSize: 12),
          ),
          children: [
            SelectableText(_encoder.convert(aggregate), style: _jsonStyle),
          ],
        );
      },
    );
  }

  Widget _widgetsAndFrames() {
    final frames = _map(_snapshot['frames']);
    final builds = _map(_snapshot['builds']).entries.toList()
      ..sort((a, b) => _number(b.value).compareTo(_number(a.value)));
    return ListView.builder(
      key: const Key('inspector-widgets-frames'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: builds.length + 3,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Frame timings',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (frames['supported'] != true)
                Text(
                  'FrameTiming is unavailable on this platform. Profile Web '
                  'rendering in Chrome DevTools Performance.',
                  style: TextStyle(
                    fontSize: 12,
                    color: ChatColors.of(context).muted,
                  ),
                )
              else
                _MetricSection(
                  values: {
                    'Captured frames': frames['count'] ?? 0,
                    'Over 16.67 ms (60 Hz heuristic)':
                        frames['overBudgetCount'] ?? 0,
                    'p95 build': _optionalDuration(frames['p95BuildMicros']),
                    'p95 raster': _optionalDuration(frames['p95RasterMicros']),
                    'p95 total': _optionalDuration(frames['p95TotalMicros']),
                  },
                ),
              const SizedBox(height: 16),
            ],
          );
        }
        if (index == 1) return const _ProfilingGuidance();
        if (index == 2) {
          return Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              'Widget builds${builds.isEmpty ? ' · none captured' : ''}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        final entry = builds[index - 3];
        return ListTile(
          key: Key('inspector-widget-${entry.key}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(entry.key),
          trailing: Text('${entry.value} builds'),
        );
      },
    );
  }
}

class _MetricSection extends StatelessWidget {
  const _MetricSection({this.title, required this.values});

  final String? title;
  final Map<String, Object?> values;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (title != null) ...[
        Text(title!, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
      ],
      if (values.isEmpty)
        const Text('No counters captured.', style: TextStyle(fontSize: 12))
      else
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / 170).floor().clamp(1, 5);
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in values.entries)
                  Container(
                    key: Key('inspector-metric-${entry.key}'),
                    width: width,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ChatColors.of(context).canvas,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.key,
                          style: TextStyle(
                            fontSize: 11,
                            color: ChatColors.of(context).muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${entry.value}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
    ],
  );
}

class _ProfilingGuidance extends StatelessWidget {
  const _ProfilingGuidance();

  @override
  Widget build(BuildContext context) => Text(
    'Debug timings include instrumentation overhead; use profile/release builds '
    'for performance benchmarks. Tracked resources and widget counts are not '
    'heap leak proof. Use Chrome DevTools Performance and Memory for Web, '
    'or Flutter DevTools for native CPU and heap profiling.',
    style: TextStyle(
      fontSize: 12,
      color: ChatColors.of(context).muted,
      height: 1.45,
    ),
  );
}

const _jsonStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 11,
  height: 1.45,
);

Map<String, Object?> _map(Object? value) => value is Map
    ? {for (final entry in value.entries) '${entry.key}': entry.value}
    : <String, Object?>{};

List<Map<String, Object?>> _rows(Object? value) => value is List
    ? value.whereType<Map>().map(_map).toList()
    : <Map<String, Object?>>[];

num _number(Object? value) => value is num ? value : 0;

String _duration(num micros) => micros < 1000
    ? '${micros.toStringAsFixed(0)} µs'
    : '${(micros / 1000).toStringAsFixed(2)} ms';

String _optionalDuration(Object? value) =>
    value is num ? _duration(value) : '—';

String _outcome(Map<String, Object?> event) {
  final data = _map(event['data']);
  if (data['errorType'] != null) return 'error: ${data['errorType']}';
  return '${data['outcome'] ?? data['status'] ?? (event['phase'] == 'end' ? 'completed' : '')}';
}

String _localLogStatus(Map<String, Object?> logs) {
  if (logs['available'] != true) {
    return 'Local logs unavailable: configure a loopback HTTP LOCAL_LOGS_URL.';
  }
  final status = logs['enabled'] != true
      ? 'off'
      : logs['active'] == true
      ? (_number(logs['pendingRetryEvents']) > 0 ? 'retrying' : 'sharing')
      : 'waiting for capture';
  return 'Local logs $status'
      ' · ${logs['sentEvents'] ?? 0} sent'
      ' · ${logs['queuedEvents'] ?? 0} queued'
      ' · ${logs['droppedImportantEvents'] ?? 0} important dropped'
      ' · ${logs['pendingRetryEvents'] ?? 0} retry pending'
      ' · ${logs['failedBatches'] ?? 0} failed batches';
}
