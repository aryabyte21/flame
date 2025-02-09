import 'package:flame/src/components/mixins/Draggables.dart';
import 'package:flame/src/events/component_mixins/drag_callbacks.dart';
import 'package:flame/src/events/flame_game_mixins/has_Draggables_components.dart';

/// Mixin that can be added to a game to indicate that is has [Draggables]
/// components (in addition to components with [DragCallbacks]).
///
/// This is a temporary mixin to facilitate the transition between the old and
/// the new event system. In the future it will be deprecated.
mixin HasDraggablesBridge on HasDraggablesComponents {}
