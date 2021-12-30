import 'package:dart_test_adapter/dart_test_adapter.dart';
import 'package:riverpod/riverpod.dart';
import 'package:collection/collection.dart';
import 'package:spec_cli/src/io.dart';

import 'collection.dart';
import 'dart_test.dart';
import 'dart_test_utils.dart';
import 'groups.dart';
import 'provider_utils.dart';
import 'tests.dart';

final $suiteCount = Provider<AsyncValue<int>>((ref) {
  return ref
      .watch($events)
      .whereType<TestEventAllSuites>()
      .map((e) => e.count)
      .firstDataOrLoading;
}, dependencies: [$events]);

final $suites = Provider<List<Suite>>((ref) {
  final events = ref.watch($events);

  return events
      .whereType<TestEventSuite>()
      .map((event) => event.suite)
      .toList();
}, dependencies: [$events]);

final $hasAllSuites = Provider<bool>((ref) {
  return ref.watch($suiteCount).when(
        error: (err, stack) => false,
        loading: () => false,
        data: (suiteCount) {
          final suites = ref.watch($suites);
          return suites.length == suiteCount;
        },
      );
}, dependencies: [$suites, $suiteCount]);

final $suite = Provider.family<AsyncValue<Suite>, SuiteKey>((ref, suiteKey) {
  return ref
      .watch($events)
      .whereType<TestEventSuite>()
      .where((e) => e.suite.key == suiteKey)
      .map((event) => event.suite)
      .firstDataOrLoading;
}, dependencies: [$events]);

final $suiteStatus =
    Provider.family<AsyncValue<void>, SuiteKey>((ref, suiteKey) {
  return merge((unwrap) {
    final tests = ref.watch($testsForSuite(suiteKey));
    final visibleTests = tests.values.where((test) => !test.isHidden).toList();

    /// We verify that "testIds" contains all ids that this suite is supposed
    /// to have. In case we have yet to receive some test events.
    final hasAllVisibleIds = ref.watch(
      $scaffoldGroup(suiteKey).select(
        (rootGroup) =>
            rootGroup.asData != null &&
            visibleTests.length == rootGroup.asData!.value.testCount,
      ),
    );
    if (!hasAllVisibleIds) {
      // TODO update after https://github.com/dart-lang/test/issues/1652 is resolved
      unwrap(const AsyncLoading());
    }

    // any loading leads to RUNNING, even if there's an error/success
    final hasLoading =
        tests.keys.any((testKey) => ref.watch($testStatus(testKey)).pending);
    if (hasLoading) unwrap(const AsyncLoading());

    final error = tests.keys
        .map((id) => ref.watch($testStatus(id)))
        .firstWhereOrNull((status) => status.failing) as AsyncError?;

    if (error != null) {
      unwrap(
        AsyncError(
          error.error,
          stackTrace: error.stackTrace,
        ),
      );
    }

    return;
  });
}, dependencies: [
  $testsForSuite,
  $scaffoldGroup,
  $testStatus,
]);

final $exitCode = Provider<AsyncValue<int>>((ref) {
  // The exit code will be preemptively obtained when a signal is sent.
  // No matter whether all tests executed are passing or not, since the command
  // didn't have the time to complete, we consider the command as failing
  if (ref.watch($isEarlyAbort)) return AsyncData(-1);

  if (!ref.watch($hasAllSuites)) return const AsyncLoading();

  final suites = ref.watch($suites);

  final hasPendingSuite =
      suites.any((suite) => ref.watch($suiteStatus(suite.key)) is AsyncLoading);
  if (hasPendingSuite) return const AsyncLoading();

  final hasErroredSuite = suites.any(
    (suite) => ref.watch($suiteStatus(suite.key)) is AsyncError,
  );
  if (hasErroredSuite) return const AsyncData(-1);

  // All suites are completed and passing
  return AsyncData(0);
}, dependencies: [$suites, $suiteStatus, $isEarlyAbort, $hasAllSuites]);

final $hasExitCode = Provider<bool>((ref) {
  return ref.watch($exitCode).when(
        data: (_) => true,
        error: (_, __) => false,
        loading: () => false,
      );
}, dependencies: [$exitCode]);
