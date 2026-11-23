import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/tree_repository.dart';
import '../domain/tree_models.dart';

const _uuid = Uuid();
String newTreeId() => _uuid.v4();

/// Debounced Realtime tick for one family's tree.
final treeTickProvider = StreamProvider.autoDispose.family<int, String>((ref, familyId) {
  final controller = StreamController<int>();
  var tick = 0;
  Timer? debounce;
  final sub = ref.watch(treeRepositoryProvider).watch(familyId).listen((_) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () => controller.add(++tick));
  });
  ref.onDispose(() {
    debounce?.cancel();
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

final treeDataProvider = FutureProvider.autoDispose.family<TreeData, String>((ref, familyId) {
  ref.watch(treeTickProvider(familyId));
  return ref.watch(treeRepositoryProvider).load(familyId);
});

/// How a person is related to me; recomputed when the tree changes.
final relationshipProvider = FutureProvider.autoDispose.family<Relationship, ({String familyId, String personId})>((
  ref,
  k,
) {
  ref.watch(treeTickProvider(k.familyId));
  return ref.watch(treeRepositoryProvider).relationship(k.familyId, k.personId);
});
