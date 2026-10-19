import 'package:flutter/material.dart';

String presenceLabel(
  BuildContext context, {
  required bool? online,
  DateTime? lastSeenAt,
  required String unknownLabel,
}) {
  if (online == true) return 'Online';
  if (online == null) return unknownLabel;
  if (lastSeenAt == null) return 'Offline';
  final local = lastSeenAt.toLocal();
  final localization = MaterialLocalizations.of(context);
  final date = localization.formatShortDate(local);
  final time = localization.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return 'Last seen $date at $time';
}
