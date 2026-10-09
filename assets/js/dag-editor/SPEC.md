# Custom DAG editor component — spec

## Why this exists

`DagGraphHook` (litegraph.js-based) and `NiceDagHook` (@ebay/nice-dag-core-based)
are the two prior implementations in `assets/js/`. Both work, but nice-dag-core in
particular required bypassing or monkey-patching nearly every interactive piece of
the library to get correct behavior:

- `startEditing()` must run after `withNodes()`+`render()`, or it throws internally
  (nodes not marked `editing` otherwise get silently repositioned by the library's
  own layout pass on any position change).
- `dag.addNode()` never builds a node's DOM content — the library's own
  `mapNodeToElement()` callback is only invoked during the initial `render()` pass,
  not for nodes added afterward. Required calling it manually post-`addNode()`.
- `onEdgeDropped`'s documented "falls back to `.connect()` if unset" behavior never
  triggers — `WritableNiceDag` always defines a no-op `onEdgeDropped`, so the
  fallback check is always false. Required wiring `.connect()` manually.
- `startNodeDragging()`'s ghost-element drag has a confirmed upstream bug
  (eBay/nice-dag#38): the ghost's initial position is computed in the wrong
  coordinate space and snaps on the first frame. Replaced with manual mouse
  tracking + `node.setPoint()`.
- Connected edges don't redraw live during a node drag (eBay/nice-dag#28). Fixed as
  a side effect of the above replacement.
- `startEdgeDragging()` anchors its live preview line (and the resulting
  connection's recorded origin) at a single point derived from the whole node's
  bounding box, with no notion of a node having multiple named connection points.
  Replaced with a fully custom drag-preview + drop-resolution implementation.

At that point almost nothing of the library's *interactive* surface remained in
use — only its initial static layout pass, and `dagre` (which the project already
imports and calls directly for its own "Auto layout" button, independent of
nice-dag-core). The data model (`vNodes`/`pEdges`, slot bookkeeping) is ours.

This spec describes a replacement built from scratch: same visual language, same
DAG/task semantics, no dependency on nice-dag-core. `dagre` is kept (for the
"Auto layout" button) since it's a standalone, well-behaved layout engine, not
the source of any issue encountered so far.

## Scope

In scope:
- Render task nodes (rounded rectangle) and condition nodes (diamond, two named
  outputs: `true`/`false`, one input).
- Add / remove / rename nodes.
- Drag nodes to reposition.
- Drag-to-connect between nodes, including condition nodes' two distinct handles.
- Connection rules: tasks allow N×N connections; conditions allow exactly one
  input and exactly one connection per true/false slot; no cycles,
  no self-to-self connectivity. Connections must have an arrowhead in the direction
  of the connection on the egress side.
- Condition node handle placement adapts to peer position (vertical vs.
  horizontal layout, majority vote across connected peers). Condition input is
  always either on the North or West corner, and outputs are always opposite of
  each other (North, South, true=bottom, false=top) or (West, East, false=left, true=right).
- Select node, delete selected node (and its edges).
- Double-click a node → open the existing task-properties modal (unchanged;
  this lives in `dag_editor.ex`, not in the new component). No text selection on
  the node's face.
- Rename propagation from the modal back into the canvas.
- Save (serialize to the existing `{tasks, layout}` JSON contract) / Load
  (deserialize from the same contract).
- Auto layout via `dagre`, triggered by the existing toolbar button.
- Light/dark theme (grid background, colors) — matches `DagGraphHook`'s existing
  theme handling.
- Pan and zoom: mouse-wheel-zoom + drag-empty-canvas-to-pan. A visible
  zoom-percentage control / reset-to-100% button is needed in the toolbar.
- Multi-node selection / marquee-select: shift-click starts a selection marquee
  rectangle at the coordinates of the click and selects the nodes covered by the
  marquee. The marquee disappears when the mouse button is released. Clicking outside
  of selected nodes deselects all selected (but may select the node on which the
  click is made).
- Copy/paste selected or all nodes.
- Nodes movement can be either smooth or incremental to grid lines.
- `DagGraphHook` (litegraph) and the old `NiceDagHook` should be deleted
   once this lands.
- Connection lines should be changeable: straight, curved (spline), angled
- If the connection is curved or angled, allow at the point-click to move the
  connectoin line (spline) to change the curvature, or for angled, to move the
  middle section of the Z portion (when there's one) horizontally (or vertically)
  in the direction of the connection orientation until the mouse is released (it
  shouldn't be moved before/after the begginning or end connection point). The
  minimum necessary coordinates/offsets of the new connection shape must be saved
  and properly restored on copy/paste.

Out of scope (for this version; flag if you want any added):
- undo/redo.
- Collapsible sub-graphs / grouping.
- Animated "flow" indicators on edges.
- Touch/mobile input.
- SVG/PNG export (litegraph's `DagGraphHook` has this; not ported here unless
  requested).

## Non-negotiable lessons baked into the design

These are direct responses to today's debugging, stated explicitly so the design
doesn't quietly reintroduce the same classes of bug:

1. **One coordinate space, by construction.** All node positions, drag math, and
   edge endpoint math operate in the same "model space" (the same units
   `node.x`/`node.y` are stored in). There is no separate "DOM style px" vs.
   "model" duality — repositioning a node *always* goes through the one function
   that updates both the stored position and the rendered transform together, so
   it's structurally impossible for a test (or a future feature) to move a node
   visually without moving it "for real." (Today's final, most expensive bug was
   exactly this split: a test script set `node.style.left` directly, which moved
   the DOM but left the library's internal `node.x`/`node.y` stale, so edges
   rendered from the old position. A clean design should make "visual-only move"
   inexpressible, not just "a thing to avoid.")
2. **No hidden second rendering pass.** Every node and edge's position is
   recomputed by one function (`render()`/`renderEdges()`), called synchronously
   after every mutation (drag, connect, remove, rename, add). No library-internal
   listener graph that might or might not re-trigger a redraw is in the critical
   path.
3. **Click vs. drag is explicit.** A mousedown on a node/handle does not commit
   to "this is a drag" until the pointer has moved past a small pixel threshold
   (already proven correct in `NiceDagHook`; carried over unchanged).
4. **Edge-drag resolves its target the same way regardless of which handle
   started it.** No handle-specific special-casing in the drop-resolution code —
   the handle only determines the slot label recorded on the resulting edge.
5. Newly added shape should be near the right or bottom (depending on the layout
   direction chosen) of the last added shape.  The very first added one should be
   placed in the middle of the drawing.
6. There should be a timer checking for changes, and every N seconds (2s) When
   changes are made the current drawing should be serialized and cached, in case
   there's a reload from the server. If there's a reload and the same drawing dag
   is in being edited, the design should be restored from the cache.  Dags cached
   for more than a N days (1 - default) can expire from cache, or if the DAG is
   saved at the server (i.e. the server calls save() or whatever is the proper
   method for LiveView, and returns `ok`), the DAG can be erased from cache.

## Visual design (unchanged from `NiceDagHook`)

- **Task node**: white rounded rectangle, `160×50`, 1px `#c9c9c9` border (2px
  `#fbbf24` amber when selected), centered black label, pointer cursor on hover,
  grab cursor while draggable. Support light/dark theme.
- **Condition node**: diamond (45°-rotated inner square inside an axis-aligned
  outer hit-box — proven reliable; `clip-path` was tried and discarded as
  unreliable across the border-rendering case), `64×64` outer box, same
  border/selection colors as tasks. Name label above the diamond. One input
  handle (left or top, depending on orientation — see below), two output
  handles labeled `true`/`false`. The location of the true/false labels should
  be slightly below the connection points (for West/East positioning) or slightly
  to the right of connection points (for North/South positioning), so that they
  are not covered by lines.
- If the title of a condition fits inside the shape, it should be drawn there,
  otherwise by the corner outside of the shape that has no lines attached.
- **Grid background**: theme-aware dotted grid, copy styling from litegrid.js,
- so both editors look consistent if both still exist during a transition period.
- **Edges**: thin gray line (configurable thickness) with a single arrowhead at
  the target end (or in the middle). The arrowhead color is the same as the line.
  The arrowhead position is configurable: end, middle, none.
- **Connector handles**: small white circle, 12px, 1px `#999` border. Different
  color if there's a connection attached.
- Right clicking anywhere on the drawing component displays a context menu with
  options (e.g. Copy/Paste)

## Condition node handle orientation

- Look at every connected peer (the single input that has a connection, plus both
  outputs that currently have a connection).
- Orient **vertical** whenever the peers straddle the condition's own
  vertical center — i.e. at least one peer's center is above it and at least
  one is below (each by more than `ORIENTATION_TOLERANCE_PX`, 15px, so a peer
  essentially on the same row doesn't count toward either side). This is
  deliberately independent of how far to the side those peers also sit: once
  a condition's branches visually split up/down, the diamond should read
  top/bottom even if the targets are also offset horizontally (e.g. dagre's
  LR auto-layout placing both branch targets one rank to the right, stacked
  vertically — see the fixed bug where that case wrongly stayed horizontal
  because overall sideways distance outweighed the up/down split).
- Otherwise **horizontal**.
- **Vertical**: input on top, true=bottom, false=top.
- **Horizontal**: input on left, true=right, false=left.
- Recomputed after every connect/disconnect touching the node; both the
  condition's own handle DOM positions and every attached edge's endpoints are
  refreshed when orientation changes.

## Data model

```
Node {
  id: string              // == task_id
  type: "task" | "condition"
  x, y: number            // model-space, top-left
  width, height: number   // fixed per type (TASK_SIZE / CONDITION_SIZE)
  label: string           // == task_id, shown on the node
  data: {                 // the rest of the DagTask fields, passthrough
    task_type, source_code, source_language, pool, pool_slots,
    priority_weight, queue, max_tries, retries
  }
  orientation?: "vertical" | "horizontal"   // condition nodes only
}

Edge {
  id: string
  sourceId: string
  targetId: string
  slot?: "true" | "false"   // set only when source is a condition node
}
```

Serialization to/from the existing `{tasks, layout}` contract (unchanged shape,
so the server side — `dag_editor.ex`, `DagEditorQuery`, `DagTask` — needs zero
changes):

```
tasks: [{
  task_id, task_type, downstream_list: [{task_id, data_size, slot}],
  source_code, source_language, pool, pool_slots, priority_weight,
  queue, max_tries, retries
}]
layout: {
  [task_id]: {x, y, h, w},
  _canvas: {scale}
}
```

## Rendering approach

Plain DOM + CSS, same as `NiceDagHook` (not canvas): each node is a positioned
`<div>`, each edge is an SVG `<path>` in one `<svg>` overlay sized to the full
canvas. This was already proven to work well for crisp text/labels and simple
CSS-driven theming; no reason to switch to canvas.

```
#dag-canvas-wrapper
  .dag-editor-viewport        (pan/zoom transform applied here)
    .dag-editor-grid           (CSS background, theme-aware)
    svg.dag-editor-edges       (all edges, one <path> each)
    .dag-editor-nodes          (all node <div>s, absolutely positioned)
```

Pan/zoom: a single CSS `transform: translate(...) scale(...)` on
`.dag-editor-viewport`. Model-space ↔ screen-space conversion is one pair of
functions (`toScreen(x,y)` / `toModel(x,y)`) used everywhere coordinates cross
that boundary — this is the concrete mechanism enforcing lesson #1 above.

## Public module surface

A single hand-rolled class, `DagEditor`, framework-agnostic (no LiveView
dependency inside it — the Phoenix hook becomes a thin adapter, same split
`NiceDagHook` already has conceptually, just without the library underneath):

```js
class DagEditor {
  constructor(container, { onNodeDoubleClick, onSave } = {}) {}

  // Data
  loadFromServer(tasks, layout)      // replaces the whole graph
  serializeForServer()               // -> { tasks, layout }
  addNode(type, atPoint)             // -> Node
  removeNode(nodeId)
  renameNode(oldId, newId)
  updateNodeData(nodeId, partialData)

  // Connections
  connect(sourceId, targetId, slot)  // validates rules, throws/returns false on reject
  disconnect(edgeId)

  // View
  autoLayout(vertical | horizontal)  // dagre, same as today
  select([nodeId] | all)
  centerView()
  setTheme(isDark)

  // Lifecycle
  destroy()
}
```

The Phoenix hook (`dag-editor-hook.js`, replacing `nice-dag-hook.js`) wires
`DagEditor`'s callbacks to `pushEvent`/`handleEvent`, exactly as `NiceDagHook`
does today — this file should be the only one that knows about LiveView.

## Connection rules (carried over unchanged)

- `source === target`: rejected.
- Would create a cycle (target can already reach source via existing edges,
  checked via plain BFS over the live edge list): rejected.
- Target is a condition node with an existing incoming edge: rejected.
- Source is a condition node: connecting to an already-used slot (`true` or
  `false`) replaces the existing edge on that slot rather than adding a second.
- Source is a task node: no limit on outgoing edges. No limit on incoming
  edges for a task target, either (N×N).
- Don't allow multiple connections into conditional shape, and only one connection
  allowed per true/false connection point.
- True and false connections cannot connect to the same egress shape.

## Milestones

1. **Static render**: load a `{tasks, layout}` payload, render nodes + edges at
   rest, pan/zoom, theme. No interaction yet. Proves the coordinate-space
   design end to end before any drag logic is added.
2. **Node drag**: reposition via mouse, single coordinate-space update per
   frame, edges attached to a dragged node track live.
3. **Connect**: drag-to-connect for task's single handle and condition's two
   handles; all four connection rules; orientation voting + handle
   repositioning.
4. **Editing operations**: add/remove/rename, double-click → modal (via the
   existing `open_task_modal` event), Save/Load round-trip against the real
   `dag_editor.ex` page.
5. **Auto layout**: wire the existing toolbar button to `dagre`, same math
   `NiceDagHook.autoLayout()` already uses.
6. **Polish**: selection ring, grid/theme parity, cursor states, keyboard
   delete.

Each milestone should be checked against a running copy of the real
`/dag/:dag_id/editor?engine=...` page (a new `engine=custom` value, following
the existing `litegraph`/`nicedag` pattern in `dag_editor.ex`) before moving to
the next, the same way `NiceDagHook` was verified incrementally this session.

---

> For reference of edge routing algorithm see
> [this article](https://pubuzhixing.medium.com/drawing-technology-flow-chart-orthogonal-connection-algorithm-fe23215f5ada)
> and [this library](https://github.com/worktile/plait/tree/develop).