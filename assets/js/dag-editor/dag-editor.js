/**
 * DagEditor — framework-agnostic DOM-based DAG editor.
 *
 * Replaces both the litegraph-based (dag-graph-hook.js) and
 * nice-dag-core-based (nice-dag-hook.js) implementations. See SPEC.md in
 * this directory for the full design rationale.
 *
 * Renders nodes as plain positioned <div>s and edges as SVG <path>s, all
 * inside one `.dag-editor-viewport` element that carries a single CSS
 * transform for pan/zoom. Every coordinate conversion between screen space
 * and model space goes through toScreen()/toModel() — there is no code
 * path that can move a node's DOM without also moving its model x/y (see
 * SPEC.md "Non-negotiable lessons", #1).
 */
import dagre from "dagre";

export const TASK_SIZE = { width: 160, height: 50 };
export const CONDITION_SIZE = { width: 64, height: 64 };
const DRAG_THRESHOLD_PX = 4;
const ORIENTATION_TOLERANCE_PX = 15;
const MIN_SCALE = 0.2;
const MAX_SCALE = 2.5;
const ZOOM_STEP = 1.1;
const NEW_NODE_GAP = 40;
const EDGE_CLEARANCE_PX = 16;
const GRID_MAJOR_EVERY = 10;
const DEFAULT_CURVE_BULGE_PX = 40;

function defaultTaskProperties(overrides = {}) {
  return {
    task_id: "",
    task_type: "task",
    source_code: "",
    source_language: "python",
    pool: "default_pool",
    pool_slots: 1,
    priority_weight: 1,
    queue: "default",
    max_tries: 0,
    retries: 0,
    ...overrides
  };
}

function nodeSize(type) {
  return type === "condition" ? CONDITION_SIZE : TASK_SIZE;
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]
  ));
}

export class DagEditor {
  constructor(
    container,
    {
      onNodeDoubleClick,
      onSave,
      snapToGrid = false,
      showGrid = true,
      gridSize = 20,
      lineShape = "angled",
      lineWidth = 2,
      arrowPosition = "end",
      layoutDirection = "horizontal"
    } = {}
  ) {
    this.container = container;
    this.onNodeDoubleClick = onNodeDoubleClick;
    this.onSave = onSave;
    this.snapToGrid = snapToGrid;
    this.gridSize = gridSize;
    this.showGrid = showGrid;

    this.nodes = new Map(); // id -> Node
    this.edges = new Map(); // id -> Edge
    this._edgeCounter = 0;
    this._nodeCounter = 0;
    this.selectedNodeIds = new Set();
    this.scale = 1;
    this.panX = 0;
    this.panY = 0;
    this.isDark = false;

    // Global edge rendering style (toolbar-driven — see SPEC.md "Connection
    // lines should be changeable"). lineShape: "straight" | "curved" |
    // "angled" (the existing Z-shaped orthogonal path). lineWidth: px.
    // arrowPosition: "end" | "none".
    this.lineShape = lineShape;
    this.lineWidth = lineWidth;
    this.arrowPosition = arrowPosition;

    this._lastAddedNode = null; // for new-node auto-placement
    this._layoutDirection = layoutDirection;

    this._buildDom();
    this.setGridVisible(this.showGrid);
    this._wireViewportEvents();
  }

  // ───────────────────────── DOM scaffold ─────────────────────────

  _buildDom() {
    this.container.innerHTML = "";
    this.container.style.position = "relative";
    this.container.style.overflow = "hidden";
    this.container.tabIndex = 0;

    const grid = document.createElement("div");
    grid.className = "dag-editor-grid";
    this.container.appendChild(grid);
    this.gridEl = grid;

    // Top-left live zoom readout — lives directly on the container (not
    // the pan/zoom-transformed viewport), so its own position never moves,
    // only the percentage text it displays. Doubles as a reset-zoom button
    // (click to snap back to 100%, same as the toolbar button and context
    // menu item).
    const zoomReadout = document.createElement("div");
    zoomReadout.className = "dag-editor-zoom-readout";
    zoomReadout.addEventListener("click", () => this.resetZoom());
    this.container.appendChild(zoomReadout);
    this.zoomReadoutEl = zoomReadout;

    const viewport = document.createElement("div");
    viewport.className = "dag-editor-viewport";
    this.container.appendChild(viewport);
    this.viewportEl = viewport;

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "dag-editor-edges");
    const defs = document.createElementNS("http://www.w3.org/2000/svg", "defs");
    // Arrowhead triangle with a 35° tip angle (half-angle 17.5°, so the
    // base half-height is 10*tan(17.5°) ≈ 3.15 for a 10-unit-long head).
    defs.innerHTML =
      '<marker id="dag-editor-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">' +
      '<path class="dag-editor-arrowhead" d="M0,1.85 L10,5 L0,8.15 z" /></marker>';
    svg.appendChild(defs);
    viewport.appendChild(svg);
    this.edgesSvg = svg;

    const nodesLayer = document.createElement("div");
    nodesLayer.className = "dag-editor-nodes";
    viewport.appendChild(nodesLayer);
    this.nodesLayer = nodesLayer;

    // Appended to the container, NOT the (pan/zoom-transformed) viewport —
    // the marquee is a screen-space-only selection affordance positioned
    // from raw mouse coordinates, so it must live outside the transform it
    // would otherwise be double-offset by (same class of bug fixed earlier
    // for the edge-drag preview line).
    const marquee = document.createElement("div");
    marquee.className = "dag-editor-marquee";
    marquee.style.display = "none";
    this.container.appendChild(marquee);
    this.marqueeEl = marquee;

    const dragSvg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    dragSvg.setAttribute("class", "dag-editor-drag-preview");
    viewport.appendChild(dragSvg);
    this.dragPreviewSvg = dragSvg;

    this._applyTransform();
  }

  // ───────────────────────── coordinate space ─────────────────────────

  /** model-space (x, y) -> screen-space pixel offset within the container. */
  toScreen(x, y) {
    return { x: x * this.scale + this.panX, y: y * this.scale + this.panY };
  }

  /** screen-space pixel offset within the container -> model-space (x, y). */
  toModel(x, y) {
    return { x: (x - this.panX) / this.scale, y: (y - this.panY) / this.scale };
  }

  _applyTransform() {
    this.viewportEl.style.transform = `translate(${this.panX}px, ${this.panY}px) scale(${this.scale})`;
    const minorSize = this.gridSize * this.scale;
    const majorSize = this.gridSize * GRID_MAJOR_EVERY * this.scale;
    // .dag-editor-grid's background-image has 4 linear-gradient layers (2
    // minor + 2 major, one per axis each) — every comma-separated value
    // here lines up 1:1 with those 4 layers in the same order, so each
    // gets its own size but they all share the same position (keeping
    // the major lines aligned to the minor grid as pan/zoom changes).
    const pos = `${this.panX}px ${this.panY}px`;
    this.gridEl.style.backgroundPosition = `${pos}, ${pos}, ${pos}, ${pos}`;
    this.gridEl.style.backgroundSize =
      `${minorSize}px ${minorSize}px, ${minorSize}px ${minorSize}px, ${majorSize}px ${majorSize}px, ${majorSize}px ${majorSize}px`;
    this.zoomReadoutEl.textContent = `${Math.round(this.scale * 100)}% zoom`;
  }

  /** Toggles the background grid's visibility without touching
   * snapToGrid — a user may want nodes to keep snapping while hiding the
   * visual lines, or vice versa, so the two are independent settings. */
  setGridVisible(visible) {
    this.showGrid = visible;
    this.gridEl.style.display = visible ? "" : "none";
  }

  snap(v) {
    if (!this.snapToGrid) return v;
    return Math.round(v / this.gridSize) * this.gridSize;
  }

  // ───────────────────────── pan / zoom ─────────────────────────

  _wireViewportEvents() {
    this.container.addEventListener("wheel", (e) => {
      e.preventDefault();
      const rect = this.container.getBoundingClientRect();
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      const before = this.toModel(cx, cy);
      const factor = e.deltaY < 0 ? ZOOM_STEP : 1 / ZOOM_STEP;
      this.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.scale * factor));
      const after = this.toScreen(before.x, before.y);
      this.panX += cx - after.x;
      this.panY += cy - after.y;
      this._applyTransform();
      this._emitViewChange();
    }, { passive: false });

    this.container.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      const onNode = e.target.closest(".dag-node");
      if (onNode) return; // node handles its own mousedown
      const rect = this.container.getBoundingClientRect();
      const startX = e.clientX;
      const startY = e.clientY;

      if (e.shiftKey) {
        this._startMarquee(startX, startY, rect);
        return;
      }

      this.selectNodes([]);
      const startPanX = this.panX;
      const startPanY = this.panY;
      let dragging = false;
      const onMove = (moveEvent) => {
        const dx = moveEvent.clientX - startX;
        const dy = moveEvent.clientY - startY;
        if (!dragging && Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return;
        dragging = true;
        this.container.style.cursor = "grabbing";
        this.panX = startPanX + dx;
        this.panY = startPanY + dy;
        this._applyTransform();
      };
      const onUp = () => {
        this.container.style.cursor = "";
        document.removeEventListener("mousemove", onMove, true);
        document.removeEventListener("mouseup", onUp, true);
        if (dragging) this._emitViewChange();
      };
      document.addEventListener("mousemove", onMove, true);
      document.addEventListener("mouseup", onUp, true);
    });
  }

  _startMarquee(startX, startY, containerRect) {
    this.marqueeEl.style.display = "block";
    const update = (curX, curY) => {
      const x1 = Math.min(startX, curX) - containerRect.left;
      const y1 = Math.min(startY, curY) - containerRect.top;
      const w = Math.abs(curX - startX);
      const h = Math.abs(curY - startY);
      this.marqueeEl.style.left = `${x1}px`;
      this.marqueeEl.style.top = `${y1}px`;
      this.marqueeEl.style.width = `${w}px`;
      this.marqueeEl.style.height = `${h}px`;
      return { x1, y1, x2: x1 + w, y2: y1 + h };
    };
    update(startX, startY);

    const onMove = (moveEvent) => update(moveEvent.clientX, moveEvent.clientY);
    const onUp = (upEvent) => {
      document.removeEventListener("mousemove", onMove, true);
      document.removeEventListener("mouseup", onUp, true);
      const rect = update(upEvent.clientX, upEvent.clientY);
      this.marqueeEl.style.display = "none";

      const topLeft = this.toModel(rect.x1, rect.y1);
      const bottomRight = this.toModel(rect.x2, rect.y2);
      const hits = [];
      for (const node of this.nodes.values()) {
        const overlaps =
          node.x < bottomRight.x && node.x + node.width > topLeft.x &&
          node.y < bottomRight.y && node.y + node.height > topLeft.y;
        if (overlaps) hits.push(node.id);
      }
      this.selectNodes(hits);
    };
    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("mouseup", onUp, true);
  }

  centerView() {
    if (this.nodes.size === 0) {
      this.panX = 0;
      this.panY = 0;
      this.scale = 1;
      this._applyTransform();
      return;
    }
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const node of this.nodes.values()) {
      minX = Math.min(minX, node.x);
      minY = Math.min(minY, node.y);
      maxX = Math.max(maxX, node.x + node.width);
      maxY = Math.max(maxY, node.y + node.height);
    }
    const rect = this.container.getBoundingClientRect();
    const contentW = Math.max(1, maxX - minX);
    const contentH = Math.max(1, maxY - minY);
    this.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, Math.min(rect.width / (contentW + 80), rect.height / (contentH + 80), 1)));
    this.panX = rect.width / 2 - ((minX + maxX) / 2) * this.scale;
    this.panY = rect.height / 2 - ((minY + maxY) / 2) * this.scale;
    this._applyTransform();
  }

  resetZoom() {
    const rect = this.container.getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const before = this.toModel(cx, cy);
    this.scale = 1;
    const after = this.toScreen(before.x, before.y);
    this.panX += cx - after.x;
    this.panY += cy - after.y;
    this._applyTransform();
    this._emitViewChange();
  }

  _emitViewChange() {
    if (this.onViewChange) this.onViewChange({ scale: this.scale });
  }

  setTheme(isDark) {
    this.isDark = isDark;
    this.container.classList.toggle("dag-editor-dark", isDark);
  }

  // ───────────────────────── nodes ─────────────────────────

  addNode(type, atPoint = {}, overrides = {}) {
    this._nodeCounter++;
    const size = nodeSize(type);
    const id = overrides.task_id || `new_${type}_${this._nodeCounter}`;
    const defaultPoint = atPoint.x == null && atPoint.y == null ? this._nextNodePoint(size) : atPoint;
    const node = {
      id,
      type,
      x: this.snap(defaultPoint.x ?? 200),
      y: this.snap(defaultPoint.y ?? 200),
      width: size.width,
      height: size.height,
      data: defaultTaskProperties({ task_id: id, task_type: type, ...overrides }),
      orientation: "horizontal",
      el: null
    };
    this.nodes.set(id, node);
    this._renderNode(node);
    this._lastAddedNode = node;
    return node;
  }

  /** Default placement for a newly added node when no explicit position is
   * given: the very first node is centered in the current viewport; every
   * node after that is placed near the right (horizontal layout direction)
   * or bottom (vertical) of the last-added node, so a sequence of "+Task"
   * clicks reads as a natural chain instead of landing at random points. */
  _nextNodePoint(size) {
    if (!this._lastAddedNode) {
      const rect = this.container.getBoundingClientRect();
      const center = this.toModel(rect.width / 2, rect.height / 2);
      return { x: center.x - size.width / 2, y: center.y - size.height / 2 };
    }
    const last = this._lastAddedNode;
    if (this._layoutDirection === "vertical") {
      return { x: last.x, y: last.y + last.height + NEW_NODE_GAP };
    }
    return { x: last.x + last.width + NEW_NODE_GAP, y: last.y };
  }

  setLayoutDirection(direction) {
    this._layoutDirection = direction === "vertical" ? "vertical" : "horizontal";
  }

  removeNode(nodeId) {
    const node = this.nodes.get(nodeId);
    if (!node) return;
    for (const edge of [...this.edges.values()]) {
      if (edge.sourceId === nodeId || edge.targetId === nodeId) this._removeEdgeInternal(edge.id);
    }
    node.el?.remove();
    this.nodes.delete(nodeId);
    this.selectedNodeIds.delete(nodeId);
    if (this._lastAddedNode === node) this._lastAddedNode = null;
  }

  renameNode(oldId, newId) {
    const node = this.nodes.get(oldId);
    if (!node || oldId === newId) return;
    node.id = newId;
    node.data.task_id = newId;
    this.nodes.delete(oldId);
    this.nodes.set(newId, node);
    for (const edge of this.edges.values()) {
      if (edge.sourceId === oldId) edge.sourceId = newId;
      if (edge.targetId === oldId) edge.targetId = newId;
    }
    if (this.selectedNodeIds.has(oldId)) {
      this.selectedNodeIds.delete(oldId);
      this.selectedNodeIds.add(newId);
    }
    if (node.el) node.el.dataset.nodeId = newId;
    this._setNodeLabel(node);
    this.renderEdges();
  }

  updateNodeData(nodeId, partialData) {
    const node = this.nodes.get(nodeId);
    if (!node) return;
    Object.assign(node.data, partialData);
    this._setNodeLabel(node);
  }

  getNode(nodeId) {
    return this.nodes.get(nodeId);
  }

  _renderNode(node) {
    const el = document.createElement("div");
    el.dataset.nodeId = node.id;
    const isCondition = node.type === "condition";
    el.className = isCondition ? "dag-node dag-node-condition" : "dag-node dag-node-task";

    if (isCondition) {
      el.innerHTML =
        '<div class="diamond-shape"></div>' +
        '<span class="label"></span>' +
        '<div class="connector-handle input-handle" data-handle="input" title="Drag to connect input"></div>' +
        '<div class="connector-handle true-handle" data-handle="output" data-slot="true" title="Drag to connect — true branch"></div>' +
        '<div class="connector-handle false-handle" data-handle="output" data-slot="false" title="Drag to connect — false branch"></div>' +
        '<span class="slot-label true-label">true</span>' +
        '<span class="slot-label false-label">false</span>';
      this._applyConditionOrientation(el, node.orientation);
    } else {
      el.innerHTML =
        '<span class="label"></span>' +
        '<div class="connector-handle input-handle" data-handle="input" title="Drag to connect input"></div>' +
        '<div class="connector-handle output-handle" data-handle="output" title="Drag to connect"></div>';
    }

    node.el = el;
    this._positionNode(node);
    this.nodesLayer.appendChild(el);
    // Label text-fit measurement (scrollWidth) needs the element attached
    // to the DOM first — run after appendChild, not before.
    this._setNodeLabel(node);
    this._wireNodeEvents(node, el);
  }

  _positionNode(node) {
    node.el.style.left = `${node.x}px`;
    node.el.style.top = `${node.y}px`;
    node.el.style.width = `${node.width}px`;
    node.el.style.height = `${node.height}px`;
  }

  _setNodeLabel(node) {
    const label = node.el?.querySelector(".label");
    if (!label) return;
    label.textContent = node.data.task_id || node.id;
    if (node.type === "condition") this._placeConditionLabel(node, label);
  }

  /** Condition nodes are small — the name is drawn inside the diamond when
   * it fits, and only pushed out to a free corner (one with no handle on
   * it) when it doesn't, per SPEC.md. Measured via the label's own
   * scrollWidth against the diamond's inscribed-square usable width, since
   * CSS alone can't make this decision (it depends on the actual text).
   * Forced onto the "inside" font-size/no-wrap style before measuring —
   * scrollWidth under the (larger) "outside" style would overstate the
   * text's width and could never correctly report "fits". */
  _placeConditionLabel(node, label) {
    label.classList.remove("label-outside");
    label.classList.add("label-inside");
    const inscribedWidth = node.width / Math.SQRT2 - 8; // small padding
    const fits = label.scrollWidth <= inscribedWidth;
    label.classList.toggle("label-inside", fits);
    label.classList.toggle("label-outside", !fits);
  }

  _wireNodeEvents(node, el) {
    el.addEventListener("mousedown", (e) => {
      if (e.target.closest(".connector-handle")) return;
      if (e.button !== 0) return;
      e.stopPropagation();

      if (!this.selectedNodeIds.has(node.id)) {
        this.selectNodes(e.shiftKey ? [...this.selectedNodeIds, node.id] : [node.id]);
      }

      const draggingIds = [...this.selectedNodeIds];
      const startX = e.clientX;
      const startY = e.clientY;
      const starts = draggingIds.map((id) => {
        const n = this.nodes.get(id);
        return { id, x: n.x, y: n.y };
      });
      let dragging = false;

      const onMove = (moveEvent) => {
        const dxScreen = moveEvent.clientX - startX;
        const dyScreen = moveEvent.clientY - startY;
        if (!dragging) {
          if (Math.hypot(dxScreen, dyScreen) < DRAG_THRESHOLD_PX) return;
          dragging = true;
          el.style.cursor = "grabbing";
        }
        const dx = dxScreen / this.scale;
        const dy = dyScreen / this.scale;
        for (const s of starts) {
          this.moveNode(s.id, this.snap(s.x + dx), this.snap(s.y + dy));
        }
      };
      const onUp = () => {
        el.style.cursor = "";
        document.removeEventListener("mousemove", onMove, true);
        document.removeEventListener("mouseup", onUp, true);
      };
      document.addEventListener("mousemove", onMove, true);
      document.addEventListener("mouseup", onUp, true);
    });

    el.addEventListener("dblclick", (e) => {
      e.stopPropagation();
      e.preventDefault();
      if (this.onNodeDoubleClick) this.onNodeDoubleClick(node);
    });

    el.querySelectorAll(".connector-handle").forEach((handle) => {
      handle.addEventListener("mousedown", (e) => {
        e.stopPropagation();
        if (e.button !== 0) return;
        if (handle.dataset.handle === "input") return; // connections always start from an output
        this._startEdgeDrag(node, handle.dataset.slot || null, e);
      });
    });
  }

  /** Moves a node by always writing through node.x/node.y AND the DOM
   * together (SPEC.md lesson #1) — there is no other way to reposition a
   * node in this module. */
  moveNode(nodeId, x, y) {
    const node = this.nodes.get(nodeId);
    if (!node) return;
    node.x = x;
    node.y = y;
    this._positionNode(node);

    // Moving any node can change a connected condition's orientation vote
    // (it's based on peer position, not just connect/disconnect) — refresh
    // every condition touching this node, whether it's moving itself or is
    // a peer of the node that moved.
    if (node.type === "condition") {
      this._refreshConditionOrientation(node);
    } else {
      for (const edge of this.edges.values()) {
        if (edge.sourceId === nodeId) {
          const peer = this.nodes.get(edge.targetId);
          if (peer?.type === "condition") this._refreshConditionOrientation(peer);
        }
        if (edge.targetId === nodeId) {
          const peer = this.nodes.get(edge.sourceId);
          if (peer?.type === "condition") this._refreshConditionOrientation(peer);
        }
      }
    }
    this.renderEdges();
  }

  // ───────────────────────── selection ─────────────────────────

  selectNodes(ids) {
    for (const id of this.selectedNodeIds) {
      this.nodes.get(id)?.el?.classList.remove("is-selected");
    }
    this.selectedNodeIds = new Set(ids);
    for (const id of this.selectedNodeIds) {
      this.nodes.get(id)?.el?.classList.add("is-selected");
    }
  }

  selectAll() {
    this.selectNodes([...this.nodes.keys()]);
  }

  deleteSelected() {
    for (const id of [...this.selectedNodeIds]) this.removeNode(id);
  }

  /** Lines up every selected node on a shared horizontal axis (same Y) —
   * "Align middle": each node's own vertical center moves to the average
   * center of the whole selection, so the group settles in the middle
   * rather than snapping to whichever node happened to be highest/lowest. */
  alignSelectedMiddle() {
    const nodes = this._selectedNodesForAlign();
    if (nodes.length < 2) return;
    const avgCenterY = nodes.reduce((sum, n) => sum + n.y + n.height / 2, 0) / nodes.length;
    for (const node of nodes) {
      this.moveNode(node.id, node.x, this.snap(avgCenterY - node.height / 2));
    }
  }

  /** Lines up every selected node on a shared vertical axis (same X) —
   * "Align center": each node's own horizontal center moves to the average
   * center of the whole selection. */
  alignSelectedCenter() {
    const nodes = this._selectedNodesForAlign();
    if (nodes.length < 2) return;
    const avgCenterX = nodes.reduce((sum, n) => sum + n.x + n.width / 2, 0) / nodes.length;
    for (const node of nodes) {
      this.moveNode(node.id, this.snap(avgCenterX - node.width / 2), node.y);
    }
  }

  /** Spreads selected nodes so the horizontal GAPS between consecutive
   * nodes (by left-edge order) are equal, leaving the leftmost and
   * rightmost nodes fixed in place — the usual "distribute" meaning
   * (equalizing space between shapes), as opposed to "align" which moves
   * everything onto one shared line. Needs 3+ nodes: with only 2, there's
   * a single gap and nothing to equalize. */
  distributeSelectedHorizontally() {
    const nodes = this._selectedNodesForAlign();
    if (nodes.length < 3) return;
    nodes.sort((a, b) => a.x - b.x);
    const first = nodes[0];
    const last = nodes[nodes.length - 1];
    const totalWidth = nodes.reduce((sum, n) => sum + n.width, 0);
    const span = last.x + last.width - first.x;
    const gap = (span - totalWidth) / (nodes.length - 1);
    let cursor = first.x;
    for (const node of nodes) {
      this.moveNode(node.id, this.snap(cursor), node.y);
      cursor += node.width + gap;
    }
  }

  /** Vertical counterpart of distributeSelectedHorizontally() — equal
   * gaps top-to-bottom, topmost/bottommost nodes fixed. */
  distributeSelectedVertically() {
    const nodes = this._selectedNodesForAlign();
    if (nodes.length < 3) return;
    nodes.sort((a, b) => a.y - b.y);
    const first = nodes[0];
    const last = nodes[nodes.length - 1];
    const totalHeight = nodes.reduce((sum, n) => sum + n.height, 0);
    const span = last.y + last.height - first.y;
    const gap = (span - totalHeight) / (nodes.length - 1);
    let cursor = first.y;
    for (const node of nodes) {
      this.moveNode(node.id, node.x, this.snap(cursor));
      cursor += node.height + gap;
    }
  }

  /** Alignment/distribution only ever act on an explicit selection (unlike
   * targetNodes(), copy/export's "selection, or everything" fallback) —
   * acting on the whole unselected graph isn't a sensible default, and
   * each op needs at least 2-3 nodes to mean anything (checked by callers). */
  _selectedNodesForAlign() {
    return [...this.selectedNodeIds].map((id) => this.nodes.get(id)).filter(Boolean);
  }

  // ───────────────────────── condition orientation ─────────────────────────

  _conditionOrientation(node) {
    const peers = [];
    for (const edge of this.edges.values()) {
      if (edge.sourceId === node.id) peers.push(this.nodes.get(edge.targetId));
      if (edge.targetId === node.id) peers.push(this.nodes.get(edge.sourceId));
    }
    const valid = peers.filter(Boolean);
    if (valid.length === 0) return "horizontal";
    const midY = node.y + node.height / 2;

    // Vertical whenever the connected peers straddle the condition's own
    // center line — e.g. a true-branch target above and a false-branch
    // target below (or vice versa) — regardless of how far to the side
    // they also sit: once branches visually split up/down, the diamond
    // should read top/bottom, not left/right. Peers within the tolerance
    // band of the center line don't count toward either side, so a single
    // peer on essentially the same row doesn't trip a spurious flip.
    let above = false;
    let below = false;
    for (const peer of valid) {
      const peerMidY = peer.y + peer.height / 2;
      if (peerMidY < midY - ORIENTATION_TOLERANCE_PX) above = true;
      else if (peerMidY > midY + ORIENTATION_TOLERANCE_PX) below = true;
    }
    if (above && below) return "vertical";

    // With only a single connected peer (most commonly just the input,
    // before any outputs exist yet), "straddle both sides" can never be
    // true — but the node should still flip to vertical once the condition
    // ends up clearly ABOVE that single peer (peer's center below the
    // condition's own), since at that point the predecessor reads as
    // "feeding up into" the diamond from below (the same relationship
    // true/false have when they straddle), not "feeding in sideways".
    // Peer-above-condition (the common case: predecessor above-left,
    // condition below it, entering from the W side) stays horizontal.
    if (valid.length === 1 && below) return "vertical";
    return "horizontal";
  }

  _refreshConditionOrientation(node) {
    const orientation = this._conditionOrientation(node);
    if (node.orientation === orientation) return;
    node.orientation = orientation;
    if (node.el) this._applyConditionOrientation(node.el, orientation);
    this.renderEdges();
  }

  _applyConditionOrientation(el, orientation) {
    el.classList.toggle("orientation-vertical", orientation === "vertical");
    el.classList.toggle("orientation-horizontal", orientation === "horizontal");
  }

  // ───────────────────────── edges / connections ─────────────────────────

  _startEdgeDrag(sourceNode, slot, downEvent) {
    // dragPreviewSvg lives inside .dag-editor-viewport, which carries the
    // pan/zoom CSS transform — its coordinate system is model space, not
    // screen space, so every point written into it must go through
    // toModel() first (SPEC.md lesson #1: one coordinate space, by
    // construction). Writing raw clientX/clientY here would double-apply
    // the transform, offsetting the preview line from the cursor.
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    line.setAttribute("class", "dag-editor-drag-line");
    const containerRect = this.container.getBoundingClientRect();
    const start = this.toModel(downEvent.clientX - containerRect.left, downEvent.clientY - containerRect.top);
    line.setAttribute("x1", start.x);
    line.setAttribute("y1", start.y);
    line.setAttribute("x2", start.x);
    line.setAttribute("y2", start.y);
    this.dragPreviewSvg.appendChild(line);

    const onMove = (moveEvent) => {
      const rect = this.container.getBoundingClientRect();
      const point = this.toModel(moveEvent.clientX - rect.left, moveEvent.clientY - rect.top);
      line.setAttribute("x2", point.x);
      line.setAttribute("y2", point.y);
    };

    const onUp = (upEvent) => {
      document.removeEventListener("mousemove", onMove, true);
      document.removeEventListener("mouseup", onUp, true);
      line.remove();

      const dropEl = document.elementFromPoint(upEvent.clientX, upEvent.clientY);
      const wrapper = dropEl?.closest(".dag-node");
      const targetId = wrapper?.dataset?.nodeId;
      const targetNode = targetId ? this.nodes.get(targetId) : null;
      if (targetNode) this.connect(sourceNode.id, targetNode.id, slot);
    };

    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("mouseup", onUp, true);
  }

  /** True if connecting sourceId -> targetId would close a cycle: BFS
   * forward from targetId over the live edge list, looking for sourceId. */
  _wouldCreateCycle(sourceId, targetId) {
    const visited = new Set([targetId]);
    const queue = [targetId];
    while (queue.length > 0) {
      const currentId = queue.shift();
      if (currentId === sourceId) return true;
      for (const edge of this.edges.values()) {
        if (edge.sourceId === currentId && !visited.has(edge.targetId)) {
          visited.add(edge.targetId);
          queue.push(edge.targetId);
        }
      }
    }
    return false;
  }

  /** Validates and creates a connection; returns the created edge, or null
   * if rejected. See SPEC.md "Connection rules". */
  connect(sourceId, targetId, slot = null, offset = 0) {
    if (sourceId === targetId) return null;
    const sourceNode = this.nodes.get(sourceId);
    const targetNode = this.nodes.get(targetId);
    if (!sourceNode || !targetNode) return null;

    if (this._wouldCreateCycle(sourceId, targetId)) {
      console.warn("DagEditor: rejected connection — would create a cycle");
      return null;
    }

    const targetIsCondition = targetNode.type === "condition";
    if (targetIsCondition && [...this.edges.values()].some((e) => e.targetId === targetId)) {
      console.warn("DagEditor: condition nodes accept only one input");
      return null;
    }

    const sourceIsCondition = sourceNode.type === "condition";
    const effectiveSlot = sourceIsCondition ? (slot || "true") : null;

    if (sourceIsCondition) {
      const otherSlotSameTarget = [...this.edges.values()].some(
        (e) => e.sourceId === sourceId && e.targetId === targetId && e.slot !== effectiveSlot
      );
      if (otherSlotSameTarget) {
        console.warn("DagEditor: true/false branches cannot both connect to the same node");
        return null;
      }
      const stale = [...this.edges.values()].find((e) => e.sourceId === sourceId && e.slot === effectiveSlot);
      if (stale) this._removeEdgeInternal(stale.id);
    }

    this._edgeCounter++;
    // offset: manual perpendicular displacement (model-space px) of the
    // curved/angled path's midpoint away from its default position, set by
    // dragging the edge's midpoint handle. 0 until the user drags it.
    const edge = { id: `edge_${this._edgeCounter}`, sourceId, targetId, slot: effectiveSlot, offset };
    this.edges.set(edge.id, edge);

    if (sourceIsCondition) this._refreshConditionOrientation(sourceNode);
    if (targetIsCondition) this._refreshConditionOrientation(targetNode);
    this.renderEdges();
    return edge;
  }

  disconnect(edgeId) {
    const edge = this.edges.get(edgeId);
    if (!edge) return;
    this._removeEdgeInternal(edgeId);
    const sourceNode = this.nodes.get(edge.sourceId);
    const targetNode = this.nodes.get(edge.targetId);
    if (sourceNode?.type === "condition") this._refreshConditionOrientation(sourceNode);
    if (targetNode?.type === "condition") this._refreshConditionOrientation(targetNode);
    this.renderEdges();
  }

  _removeEdgeInternal(edgeId) {
    this.edges.delete(edgeId);
  }

  /** Recomputes every edge's endpoint and redraws the whole SVG layer. The
   * only place edge <path> elements get created — called synchronously
   * after every mutation (SPEC.md lesson #2), never via a listener graph. */
  renderEdges() {
    while (this.edgesSvg.childElementCount > 1) this.edgesSvg.removeChild(this.edgesSvg.lastChild);
    this._updateHandleConnectionState();
    for (const edge of this.edges.values()) {
      const sourceNode = this.nodes.get(edge.sourceId);
      const targetNode = this.nodes.get(edge.targetId);
      if (!sourceNode || !targetNode) continue;
      const anchors = this._edgeAnchorPoints(sourceNode, targetNode, edge.slot);
      const { d, handle, zigZag } = this._edgePathAndHandle(anchors, this._effectiveEdgeOffset(edge), sourceNode, targetNode);

      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      path.setAttribute("d", d);
      path.setAttribute("class", "dag-editor-edge");
      path.setAttribute("stroke-width", String(this.lineWidth));
      path.dataset.edgeId = edge.id;
      if (this.arrowPosition === "end") {
        path.setAttribute("marker-end", "url(#dag-editor-arrow)");
      }
      this.edgesSvg.appendChild(path);

      if (this.lineShape !== "straight" && !zigZag) {
        this._renderEdgeHandle(edge, handle);
      }
    }
  }

  /** Toggles each connector handle's "has-connection" styling to match the
   * live edge list — reset-then-mark on every renderEdges() call rather
   * than incrementally on connect/disconnect, so it can never drift out of
   * sync with what edges actually exist. */
  _updateHandleConnectionState() {
    for (const node of this.nodes.values()) {
      node.el?.querySelectorAll(".connector-handle").forEach((handle) => {
        handle.classList.remove("has-connection");
      });
    }
    for (const edge of this.edges.values()) {
      const sourceNode = this.nodes.get(edge.sourceId);
      const targetNode = this.nodes.get(edge.targetId);
      const outputSelector = edge.slot ? `.${edge.slot}-handle` : ".output-handle";
      sourceNode?.el?.querySelector(outputSelector)?.classList.add("has-connection");
      targetNode?.el?.querySelector(".input-handle")?.classList.add("has-connection");
    }
  }

  /** Builds the SVG path "d" string for one edge, plus the model-space
   * point its draggable midpoint handle sits at (used both to render the
   * handle. `offset` is the user's manual perpendicular displacement from the
   * shape's default midpoint, applied along the axis the connection
   * primarily runs on (so dragging a left-to-right edge's handle moves it
   * vertically, and a top-to-bottom edge's handle moves it horizontally —
   * "in the direction of the connection orientation" per SPEC.md).
   * `anchors` is _edgeAnchorPoints()'s return value (source/target points
   * plus their exit/entry directions); `sourceNode`/`targetNode` (optional
   * — only needed for "angled") are the full node boxes the orthogonal
   * router needs to avoid crossing. */
  _edgePathAndHandle(anchors, offset, sourceNode, targetNode) {
    const { source, target, sourceAxis } = anchors;
    const horizontal = sourceAxis !== "vertical";

    if (this.lineShape === "straight") {
      const handle = { x: (source.x + target.x) / 2, y: (source.y + target.y) / 2 };
      return { d: `M${source.x},${source.y} L${target.x},${target.y}`, handle };
    }

    if (this.lineShape === "curved") {
      const baseX = (source.x + target.x) / 2;
      const baseY = (source.y + target.y) / 2;
      const handle = horizontal ? { x: baseX, y: baseY + offset } : { x: baseX + offset, y: baseY };
      // Both control points sit at the handle's (possibly offset)
      // position, so dragging the handle actually bends the curve — using
      // the endpoints' own un-offset source.y/target.y there instead would
      // silently discard the offset.
      const d = `M${source.x},${source.y} C${handle.x},${handle.y} ${handle.x},${handle.y} ${target.x},${target.y}`;
      return { d, handle };
    }

    // "angled": orthogonal routing via the A*-based elbow-line-route
    // algorithm (see orthogonal-router.js) — inflates both node boxes by a
    // clearance margin, searches a visibility graph for the shortest path
    // with the fewest turns, then snaps bends onto the gap centerline for
    // visual symmetry. This single general algorithm replaces what used
    // to be a hand-written direct-bend/zig-zag branch per relative-
    // position case (B right+above, B right+below, B left, overlapping,
    // etc.) — each of those was a recurring source of bugs because every
    // new relative position needed its own hardcoded shape.
    if (sourceNode && targetNode) {
      const route = generateElbowLineRoute(
        sourceNode, source, anchors.sourceDirection,
        targetNode, target, anchors.targetDirection
      );
      // The draggable midpoint handle sits at the route's own midpoint
      // (by point count, not path length) — manual offset dragging isn't
      // supported for the graph-routed path (its shape is fully derived
      // from obstacle geometry, same as the old zig-zag's zigZag:true
      // case), so the handle is for visual reference only when there are
      // more than 2 segments.
      const mid = route[Math.floor(route.length / 2)];
      const d = route.map((p, i) => `${i === 0 ? "M" : "L"}${p.x},${p.y}`).join(" ");
      return { d, handle: mid, zigZag: route.length > 3 };
    }

    // Fallback (no node boxes available, e.g. during copy/paste SVG
    // export of a subset that excludes one endpoint's node): plain direct
    // bend at the connection's own midpoint.
    if (horizontal) {
      const midX = (source.x + target.x) / 2 + offset;
      const handle = { x: midX, y: (source.y + target.y) / 2 };
      return { d: `M${source.x},${source.y} L${midX},${source.y} L${midX},${target.y} L${target.x},${target.y}`, handle };
    }
    const midY = (source.y + target.y) / 2 + offset;
    const handle = { x: (source.x + target.x) / 2, y: midY };
    return { d: `M${source.x},${source.y} L${source.x},${midY} L${target.x},${midY} L${target.x},${target.y}`, handle };
  }

  /** Renders (and wires dragging for) the small midpoint control dot used
   * to adjust a curved/angled edge's shape — only shown for non-straight
   * shapes, per SPEC.md's "allow at the point-click to move the connection
   * line". Dragging is constrained to the single perpendicular axis the
   * path's midpoint is allowed to move along (see _edgePathAndHandle). */
  _renderEdgeHandle(edge, point) {
    const handle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    handle.setAttribute("class", "dag-editor-edge-handle");
    handle.setAttribute("cx", point.x);
    handle.setAttribute("cy", point.y);
    handle.setAttribute("r", 5);
    handle.dataset.edgeId = edge.id;
    // renderEdges() rebuilds every handle element from scratch on every
    // call, including the ones triggered by this very drag (onMove below)
    // — so "is currently being dragged" can't live on the DOM element
    // itself (that identity doesn't survive the rebuild). Tracked instead
    // on the editor as _draggingEdgeId and re-applied here each time a
    // handle is (re)created, for as long as the drag is in progress.
    if (this._draggingEdgeId === edge.id) handle.classList.add("is-dragging");

    // The mouse axis that actually moves the handle differs by shape:
    // - "curved": offset bulges the curve perpendicular to the
    //   connection's own direction (handle.y for horizontal, handle.x
    //   for vertical — see _edgePathAndHandle), so drag along that same
    //   perpendicular screen axis (vertical mouse movement for a
    //   horizontal connection, horizontal for a vertical one).
    // - "angled": offset slides the Z-path's connecting segment, whose
    //   free axis is the connection's OWN dominant direction (midX for
    //   horizontal, midY for vertical), so drag along that axis instead
    //   — the opposite mapping from "curved".
    // The cursor is set to match, so hovering the handle previews which
    // way a drag will actually move it before the user commits to one.
    const sourceNode = this.nodes.get(edge.sourceId);
    const targetNode = this.nodes.get(edge.targetId);
    let trackHorizontalMouse = true;
    if (sourceNode && targetNode) {
      const { sourceAxis } = this._edgeAnchorPoints(sourceNode, targetNode, edge.slot);
      const horizontal = sourceAxis !== "vertical";
      const curved = this.lineShape === "curved";
      trackHorizontalMouse = curved ? !horizontal : horizontal;
    }
    handle.style.cursor = trackHorizontalMouse ? "ew-resize" : "ns-resize";

    handle.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      e.stopPropagation();
      const startOffset = this._effectiveEdgeOffset(edge);
      const startX = e.clientX;
      const startY = e.clientY;
      this._draggingEdgeId = edge.id;
      handle.classList.add("is-dragging");

      const onMove = (moveEvent) => {
        const dScreen = trackHorizontalMouse ? moveEvent.clientX - startX : moveEvent.clientY - startY;
        edge.offset = this._clampEdgeOffset(edge, startOffset + dScreen / this.scale);
        this.renderEdges();
      };
      const onUp = () => {
        this._draggingEdgeId = null;
        document.removeEventListener("mousemove", onMove, true);
        document.removeEventListener("mouseup", onUp, true);
        // The handle built during the last onMove still carries
        // is-dragging (set at creation time, before this onUp ran) —
        // re-render once more so it reverts to the normal hover-only look
        // immediately on release rather than waiting for the next
        // unrelated redraw.
        this.renderEdges();
      };
      document.addEventListener("mousemove", onMove, true);
      document.addEventListener("mouseup", onUp, true);
    });

    this.edgesSvg.appendChild(handle);
  }

  /** Clamps an in-progress offset drag so the "angled" shape's bend
   * segment can't be dragged past the connection's own start/end
   * coordinate along the axis it moves on (midX bounded by
   * [min(source.x,target.x), max(...)] for a horizontal-axis connection;
   * midY similarly for vertical) — dragging it beyond either endpoint
   * would route the path back on itself rather than just reshaping the
   * bend. Only "angled" has such a bound; "curved" offset is a
   * perpendicular bulge with no natural beginning/end limit. */
  _clampEdgeOffset(edge, offset) {
    if (this.lineShape !== "angled") return offset;
    const sourceNode = this.nodes.get(edge.sourceId);
    const targetNode = this.nodes.get(edge.targetId);
    if (!sourceNode || !targetNode) return offset;
    const { source, target, sourceAxis } = this._edgeAnchorPoints(sourceNode, targetNode, edge.slot);
    const horizontal = sourceAxis !== "vertical";
    if (horizontal) {
      const base = (source.x + target.x) / 2;
      const lo = Math.min(source.x, target.x) - base;
      const hi = Math.max(source.x, target.x) - base;
      return Math.min(hi, Math.max(lo, offset));
    }
    const base = (source.y + target.y) / 2;
    const lo = Math.min(source.y, target.y) - base;
    const hi = Math.max(source.y, target.y) - base;
    return Math.min(hi, Math.max(lo, offset));
  }

  /** The offset actually used to render an edge — like `edge.offset || 0`
   * for "straight"/"angled", but "curved" substitutes a default bulge when
   * untouched (offset === 0 covers that, since a bezier with both control
   * points exactly on the straight line between its endpoints renders as a
   * perfectly straight segment — "Curved" would otherwise look identical
   * to "Straight" for every edge until its handle is manually dragged).
   * The single source of truth for this value, used both when rendering
   * and as a drag's starting offset, so the handle never jumps between
   * "what's drawn" and "what dragging continues from". */
  _effectiveEdgeOffset(edge) {
    const offset = edge.offset || 0;
    if (offset === 0 && this.lineShape === "curved") return DEFAULT_CURVE_BULGE_PX;
    return offset;
  }

  /** Returns the edge's source/target anchor points, plus which axis each
   * one exits/enters along ("horizontal" = left/right side of the node,
   * "vertical" = top/bottom). The Z-path's bend direction is driven by
   * these actual handle sides, NOT by comparing dx/dy — a handle fixed to
   * a node's right edge always exits rightward even when the target
   * happens to sit up-and-to-the-left, and routing by raw dx/dy there
   * produced a path that dropped down past the source node before turning
   * (see the auto-layout condition-orientation fix session, same root
   * cause class: geometry must follow the actual anchor side, not a
   * derived heuristic). */
  _edgeAnchorPoints(sourceNode, targetNode, slot) {
    const isConditionSource = sourceNode.type === "condition";
    const targetIsCondition = targetNode.type === "condition";
    const targetIsVertical = targetIsCondition && (targetNode.orientation || "horizontal") === "vertical";
    const targetPoint = targetIsCondition
      ? this._conditionInputPoint(targetNode)
      : { x: targetNode.x, y: targetNode.y + targetNode.height / 2 };
    const targetAxis = targetIsVertical ? "vertical" : "horizontal";
    // Entry direction is which side of the TARGET box the point sits on —
    // a condition's input is on its N (vertical) or W (horizontal) side; a
    // plain task's input is always its W (left) side.
    const targetDirection = targetIsVertical ? "top" : "left";

    if (!isConditionSource) {
      return {
        source: { x: sourceNode.x + sourceNode.width, y: sourceNode.y + sourceNode.height / 2 },
        target: targetPoint,
        sourceAxis: "horizontal",
        sourceDirection: "right",
        targetAxis,
        targetDirection
      };
    }

    // The diamond has 4 vertices (N/S/E/W) but needs 3 distinct connection
    // points (input, true, false) that must never share a vertex — input
    // is always N (vertical orientation) or W (horizontal), true is always
    // the opposite of input's axis (S or E), and false takes the one
    // remaining vertex (E for vertical, S for horizontal) rather than
    // reusing input's own vertex, which produced lines that visually
    // entered through the "false" handle's position (the reported bug).
    const isTrue = slot === "true";
    const orientation = sourceNode.orientation || "horizontal";
    let sourcePoint;
    let thisAxis;
    let sourceDirection;
    if (orientation === "vertical") {
      if (isTrue) {
        sourcePoint = { x: sourceNode.x + sourceNode.width / 2, y: sourceNode.y + sourceNode.height };
        thisAxis = "vertical";
        sourceDirection = "bottom";
      } else {
        sourcePoint = { x: sourceNode.x + sourceNode.width, y: sourceNode.y + sourceNode.height / 2 };
        thisAxis = "horizontal";
        sourceDirection = "right";
      }
    } else {
      if (isTrue) {
        sourcePoint = { x: sourceNode.x + sourceNode.width, y: sourceNode.y + sourceNode.height / 2 };
        thisAxis = "horizontal";
        sourceDirection = "right";
      } else {
        sourcePoint = { x: sourceNode.x + sourceNode.width / 2, y: sourceNode.y + sourceNode.height };
        thisAxis = "vertical";
        sourceDirection = "bottom";
      }
    }
    return {
      source: sourcePoint,
      target: targetPoint,
      sourceAxis: thisAxis,
      sourceDirection,
      targetAxis,
      targetDirection
    };
  }

  _conditionInputPoint(node) {
    const orientation = node.orientation || "horizontal";
    return orientation === "vertical"
      ? { x: node.x + node.width / 2, y: node.y }
      : { x: node.x, y: node.y + node.height / 2 };
  }

  // ───────────────────────── auto layout ─────────────────────────

  autoLayout(direction = "horizontal") {
    if (this.nodes.size === 0) return;
    const rankdir = direction === "vertical" ? "TB" : "LR";
    const g = new dagre.graphlib.Graph();
    g.setGraph({ rankdir, nodesep: 40, ranksep: 80 });
    g.setDefaultEdgeLabel(() => ({}));
    for (const node of this.nodes.values()) {
      g.setNode(node.id, { width: node.width, height: node.height });
    }
    for (const edge of this.edges.values()) {
      g.setEdge(edge.sourceId, edge.targetId);
    }
    dagre.layout(g);

    for (const node of this.nodes.values()) {
      const pos = g.node(node.id);
      if (!pos) continue;
      this.moveNode(node.id, this.snap(pos.x - node.width / 2), this.snap(pos.y - node.height / 2));
    }
    this.centerView();
  }

  // ───────────────────────── serialize / load ─────────────────────────

  loadFromServer(tasks, layout = {}) {
    this.nodesLayer.innerHTML = "";
    this.nodes.clear();
    this.edges.clear();
    this._nodeCounter = 0;
    this._edgeCounter = 0;
    this._lastAddedNode = null;

    for (const task of tasks) {
      const match = /^new_(?:task|condition)_(\d+)$/.exec(task.task_id);
      if (match) this._nodeCounter = Math.max(this._nodeCounter, Number(match[1]));
    }

    for (const task of tasks) {
      const type = task.task_type === "condition" ? "condition" : "task";
      const size = nodeSize(type);
      const pos = layout[task.task_id] || {};
      const node = {
        id: task.task_id,
        type,
        x: pos.x ?? 0,
        y: pos.y ?? 0,
        width: size.width,
        height: size.height,
        data: defaultTaskProperties({
          task_id: task.task_id,
          task_type: type,
          source_code: task.source_code || "",
          source_language: task.source_language || "python",
          pool: task.pool || "default_pool",
          pool_slots: task.pool_slots || 1,
          priority_weight: task.priority_weight || 1,
          queue: task.queue || "default",
          max_tries: task.max_tries || 0,
          retries: task.retries || 0
        }),
        orientation: "horizontal",
        el: null
      };
      this.nodes.set(node.id, node);
      this._renderNode(node);
    }

    for (const task of tasks) {
      for (const downstream of task.downstream_list || []) {
        if (typeof downstream === "string") continue;
        if (!this.nodes.has(downstream.task_id)) continue;
        this._edgeCounter++;
        const slot = downstream.slot && downstream.slot !== "out" ? downstream.slot : null;
        this.edges.set(`edge_${this._edgeCounter}`, {
          id: `edge_${this._edgeCounter}`,
          sourceId: task.task_id,
          targetId: downstream.task_id,
          slot,
          offset: downstream.offset || 0
        });
      }
    }

    for (const node of this.nodes.values()) {
      if (node.type === "condition") node.orientation = this._conditionOrientation(node);
      this._applyConditionOrientation(node.el, node.orientation);
    }

    const canvasLayout = layout._canvas || {};
    this.scale = canvasLayout.scale || 1;
    this.lineShape = canvasLayout.lineShape || this.lineShape;
    this.lineWidth = canvasLayout.lineWidth || this.lineWidth;
    this.arrowPosition = canvasLayout.arrowPosition || this.arrowPosition;
    this._applyTransform();
    this.renderEdges();
    if (tasks.length > 0) this.centerView();
  }

  serializeForServer() {
    const tasks = [];
    const layout = {};

    for (const node of this.nodes.values()) {
      const props = node.data;
      const downstream_list = [...this.edges.values()]
        .filter((e) => e.sourceId === node.id)
        .map((e) => ({
          task_id: this.nodes.get(e.targetId)?.data.task_id,
          data_size: props.data_size || "M",
          slot: e.slot || "out",
          // Only written when non-zero — the common case (no manual
          // curvature drag) should round-trip as a plain {task_id,
          // data_size, slot} entry, matching what existed before this
          // field was added.
          ...(e.offset ? { offset: Math.round(e.offset) } : {})
        }))
        .filter((d) => d.task_id);

      tasks.push({
        task_id: props.task_id,
        task_type: props.task_type || "task",
        downstream_list,
        source_code: props.source_code || "",
        source_language: props.source_language || "python",
        pool: props.pool || "default_pool",
        pool_slots: props.pool_slots || 1,
        priority_weight: props.priority_weight || 1,
        queue: props.queue || "default",
        max_tries: props.max_tries || 0,
        retries: props.retries || 0
      });

      layout[props.task_id] = {
        x: Math.round(node.x),
        y: Math.round(node.y),
        w: node.width,
        h: node.height
      };
    }

    layout._canvas = {
      scale: this.scale,
      lineShape: this.lineShape,
      lineWidth: this.lineWidth,
      arrowPosition: this.arrowPosition
    };
    return { tasks, layout };
  }

  // ───────────────────────── copy / paste ─────────────────────────

  /** Selected nodes, or every node if nothing is selected. */
  targetNodes() {
    if (this.selectedNodeIds.size > 0) {
      return [...this.selectedNodeIds].map((id) => this.nodes.get(id)).filter(Boolean);
    }
    return [...this.nodes.values()];
  }

  serializeNodes(nodes) {
    const idSet = new Set(nodes.map((n) => n.id));
    const tasks = [];
    const layout = {};
    for (const node of nodes) {
      const props = node.data;
      const downstream_list = [...this.edges.values()]
        .filter((e) => e.sourceId === node.id && idSet.has(e.targetId))
        .map((e) => ({
          task_id: this.nodes.get(e.targetId)?.data.task_id,
          data_size: props.data_size || "M",
          slot: e.slot || "out",
          ...(e.offset ? { offset: Math.round(e.offset) } : {})
        }))
        .filter((d) => d.task_id);
      tasks.push({
        task_id: props.task_id,
        task_type: props.task_type || "task",
        downstream_list,
        source_code: props.source_code || "",
        source_language: props.source_language || "python",
        pool: props.pool || "default_pool",
        pool_slots: props.pool_slots || 1,
        priority_weight: props.priority_weight || 1,
        queue: props.queue || "default",
        max_tries: props.max_tries || 0,
        retries: props.retries || 0
      });
      layout[props.task_id] = { x: Math.round(node.x), y: Math.round(node.y) };
    }
    return { tasks, layout };
  }

  boundsForNodes(nodes) {
    const PAD = 20;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const node of nodes) {
      minX = Math.min(minX, node.x);
      minY = Math.min(minY, node.y);
      maxX = Math.max(maxX, node.x + node.width);
      maxY = Math.max(maxY, node.y + node.height);
    }
    if (!Number.isFinite(minX)) return { x: 0, y: 0, w: 0, h: 0 };
    return { x: minX - PAD, y: minY - PAD, w: maxX - minX + PAD * 2, h: maxY - minY + PAD * 2 };
  }

  nodesToSvg(nodes) {
    const idSet = new Set(nodes.map((n) => n.id));
    const bounds = this.boundsForNodes(nodes);
    const bg = this.isDark ? "#111827" : "#f9fafb";
    const linkColor = this.isDark ? "#94a3b8" : "#64748b";
    const textColor = this.isDark ? "#e5e7eb" : "#1f2937";

    const parts = [];
    parts.push(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${bounds.x} ${bounds.y} ${bounds.w} ${bounds.h}" ` +
      `width="${bounds.w}" height="${bounds.h}" font-family="sans-serif">`
    );
    parts.push(`<rect x="${bounds.x}" y="${bounds.y}" width="${bounds.w}" height="${bounds.h}" fill="${bg}"/>`);
    parts.push(
      '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">' +
      `<path d="M0,1.85 L10,5 L0,8.15 z" fill="${linkColor}"/></marker></defs>`
    );

    for (const edge of this.edges.values()) {
      if (!idSet.has(edge.sourceId) || !idSet.has(edge.targetId)) continue;
      const sourceNode = this.nodes.get(edge.sourceId);
      const targetNode = this.nodes.get(edge.targetId);
      const anchors = this._edgeAnchorPoints(sourceNode, targetNode, edge.slot);
      const { d } = this._edgePathAndHandle(anchors, this._effectiveEdgeOffset(edge), sourceNode, targetNode);
      parts.push(`<path d="${d}" fill="none" stroke="${linkColor}" stroke-width="2" marker-end="url(#arrow)"/>`);
    }

    for (const node of nodes) {
      const { x, y, width: w, height: h } = node;
      const title = escapeHtml(node.data.task_id || node.id);
      if (node.type === "condition") {
        const points = [[x + w / 2, y], [x + w, y + h / 2], [x + w / 2, y + h], [x, y + h / 2]]
          .map((p) => p.join(",")).join(" ");
        parts.push(`<polygon points="${points}" fill="#ffffff" stroke="#c9c9c9" stroke-width="1"/>`);
        parts.push(`<text x="${x + w / 2}" y="${y - 10}" fill="${textColor}" font-size="12" text-anchor="middle">${title}</text>`);
      } else {
        parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="6" fill="#ffffff" stroke="#c9c9c9" stroke-width="1"/>`);
        parts.push(
          `<text x="${x + w / 2}" y="${y + h / 2}" fill="${textColor}" font-size="13" text-anchor="middle" dominant-baseline="middle">${title}</text>`
        );
      }
    }

    parts.push("</svg>");
    return parts.join("\n");
  }

  async copyAsJson(nodes) {
    await navigator.clipboard.writeText(JSON.stringify(this.serializeNodes(nodes), null, 2));
  }

  async copyAsSvg(nodes) {
    await navigator.clipboard.writeText(this.nodesToSvg(nodes));
  }

  async copyAsPng(nodes) {
    const bounds = this.boundsForNodes(nodes);
    const svgText = this.nodesToSvg(nodes);
    const img = new Image();
    const svgBlob = new Blob([svgText], { type: "image/svg+xml" });
    const url = URL.createObjectURL(svgBlob);
    try {
      await new Promise((resolve, reject) => {
        img.onload = resolve;
        img.onerror = reject;
        img.src = url;
      });
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(bounds.w));
      canvas.height = Math.max(1, Math.round(bounds.h));
      const ctx = canvas.getContext("2d");
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
      if (!blob) throw new Error("toBlob failed");
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  /** Pastes a { tasks, layout } document, either replacing the whole graph
   * or appending with an offset so pasted nodes don't land on existing
   * ones, depending on `replace`. */
  pasteDocument({ tasks, layout }, replace) {
    if (replace) {
      this.loadFromServer(tasks, layout || {});
      return;
    }

    const OFFSET = 60;
    const idMap = new Map();
    for (const task of tasks) {
      let newId = task.task_id;
      let n = 1;
      while (this.nodes.has(newId)) {
        newId = `${task.task_id}_copy${n > 1 ? n : ""}`;
        n++;
      }
      idMap.set(task.task_id, newId);
    }

    for (const task of tasks) {
      const newId = idMap.get(task.task_id);
      const type = task.task_type === "condition" ? "condition" : "task";
      const pos = (layout || {})[task.task_id] || {};
      this.addNode(type, { x: (pos.x ?? 0) + OFFSET, y: (pos.y ?? 0) + OFFSET }, {
        task_id: newId,
        source_code: task.source_code || "",
        source_language: task.source_language || "python",
        pool: task.pool || "default_pool",
        pool_slots: task.pool_slots || 1,
        priority_weight: task.priority_weight || 1,
        queue: task.queue || "default",
        max_tries: task.max_tries || 0,
        retries: task.retries || 0
      });
    }

    for (const task of tasks) {
      const newSourceId = idMap.get(task.task_id);
      for (const downstream of task.downstream_list || []) {
        if (typeof downstream === "string") continue;
        const newTargetId = idMap.get(downstream.task_id);
        if (!newTargetId) continue;
        const slot = downstream.slot && downstream.slot !== "out" ? downstream.slot : null;
        this.connect(newSourceId, newTargetId, slot, downstream.offset || 0);
      }
    }

    this.selectNodes([...idMap.values()]);
  }

  destroy() {
    this.container.innerHTML = "";
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Orthogonal (axis-aligned) connection router — formerly
// orthogonal-router.js, folded in here since DagEditor is its only caller.
// https://pubuzhixing.medium.com/drawing-technology-flow-chart-orthogonal-connection-algorithm-fe23215f5ada
//
// Core idea: inflate both the source and target node boxes by a clearance
// margin ("outer rectangle"), build a small visibility graph out of a grid
// of candidate points derived from both outer rectangles' corners/
// midpoints, run A* for the shortest path with the fewest turns, then
// "correct" the result by snapping bend points onto the true gap
// centerline between the two boxes (when they don't overlap on that axis)
// — verifying the snap doesn't introduce a crossing through either node or
// increase the turn count — so the line reads as visually centered rather
// than hugging whichever box's clearance edge the graph search happened
// to pick.
//
// Points are plain {x, y} objects here (the original uses [x, y] tuples).
// ═══════════════════════════════════════════════════════════════════════

// ───────────────────────── rectangle helpers ─────────────────────────

function rectRight(r) { return r.x + r.width; }
function rectBottom(r) { return r.y + r.height; }

function isHitX(a, b) { return a.x < rectRight(b) && b.x < rectRight(a); }
function isHitY(a, b) { return a.y < rectBottom(b) && b.y < rectBottom(a); }
function isHit(a, b) { return isHitX(a, b) && isHitY(a, b); }

function expand(rect, left, top, right, bottom) {
  return {
    x: rect.x - left,
    y: rect.y - top,
    width: rect.width + left + right,
    height: rect.height + top + bottom
  };
}

/** Strictly-interior test (excludes the boundary) — nextSourcePoint/
 * nextTargetPoint are always constructed exactly ON their own outer
 * rectangle's boundary (see nextPoint()), so an inclusive test would
 * wrongly exclude them from the candidate graph, leaving A* with no start
 * or goal node to search from/to (silently falling back to a straight,
 * obstacle-ignoring line — the bug this comment is guarding against). */
function isPointInRectangle(rect, p) {
  return p.x > rect.x && p.x < rectRight(rect) && p.y > rect.y && p.y < rectBottom(rect);
}

/** Gap center between two rectangles along one axis — only meaningful
 * when they don't overlap on that axis. */
function getGapCenter(a, b, horizontal) {
  if (horizontal) {
    const left = rectRight(a) <= b.x ? a : b;
    const right = left === a ? b : a;
    return (rectRight(left) + right.x) / 2;
  }
  const top = rectBottom(a) <= b.y ? a : b;
  const bottom = top === a ? b : a;
  return (rectBottom(top) + bottom.y) / 2;
}

function getRectangleByPoints(points) {
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y };
}

function getCornerPointsByPoints(points) {
  const r = getRectangleByPoints(points);
  return [
    { x: r.x, y: r.y },
    { x: rectRight(r), y: r.y },
    { x: rectRight(r), y: rectBottom(r) },
    { x: r.x, y: rectBottom(r) }
  ];
}

// ───────────────────────── point helpers ─────────────────────────

function pointsEqual(a, b) {
  return Math.abs(a.x - b.x) < 0.01 && Math.abs(a.y - b.y) < 0.01;
}

function pointKey(p) { return `${Math.round(p.x * 100)},${Math.round(p.y * 100)}`; }

function removeDuplicatePoints(points) {
  const seen = new Map();
  for (const p of points) {
    const key = pointKey(p);
    if (!seen.has(key)) seen.set(key, p);
  }
  return [...seen.values()];
}

/** Collapses consecutive collinear points — three or more points in a row
 * sharing an x (or y) contribute only one turn, not several. */
function collapseCollinearPoints(points) {
  if (points.length < 3) return points.slice();
  const result = [points[0]];
  for (let i = 1; i < points.length - 1; i++) {
    const prev = result[result.length - 1];
    const cur = points[i];
    const next = points[i + 1];
    const collinear =
      (Math.round(prev.x) === Math.round(cur.x) && Math.round(cur.x) === Math.round(next.x)) ||
      (Math.round(prev.y) === Math.round(cur.y) && Math.round(cur.y) === Math.round(next.y));
    if (!collinear) result.push(cur);
  }
  result.push(points[points.length - 1]);
  return result;
}

function nextPoint(point, outerRectangle, direction) {
  switch (direction) {
    case "top": return { x: point.x, y: outerRectangle.y };
    case "bottom": return { x: point.x, y: rectBottom(outerRectangle) };
    case "right": return { x: rectRight(outerRectangle), y: point.y };
    default: return { x: outerRectangle.x, y: point.y };
  }
}

// ───────────────────────── outer-rectangle margin reduction ─────────────────────────

const DEF_ROUTE_MARGIN = 20;

/** Shrinks the clearance margin on facing sides when the two boxes are
 * close enough together that the default margin would make the two outer
 * rectangles overlap — splitting the available gap evenly instead, so
 * there's always at least a sliver of clearance on each side. */
function reduceRouteMargin(srcRect, tgtRect) {
  const defOffset = DEF_ROUTE_MARGIN;
  const srcOffset = [defOffset, defOffset, defOffset, defOffset]; // t/r/b/l
  const tgtOffset = [defOffset, defOffset, defOffset, defOffset];

  const leftToRight = srcRect.x - rectRight(tgtRect);
  const right2left = tgtRect.x - rectRight(srcRect);
  if (leftToRight > 0 && leftToRight < defOffset * 2) {
    const offset = leftToRight / 2;
    srcOffset[3] = offset;
    tgtOffset[1] = offset;
  }
  if (right2left > 0 && right2left < defOffset * 2) {
    const offset = right2left / 2;
    tgtOffset[3] = offset;
    srcOffset[1] = offset;
  }

  const topToBottom = srcRect.y - rectBottom(tgtRect);
  const bottomToTop = tgtRect.y - rectBottom(srcRect);
  if (topToBottom > 0 && topToBottom < defOffset * 2) {
    const offset = topToBottom / 2;
    srcOffset[0] = offset;
    tgtOffset[2] = offset;
  }
  if (bottomToTop > 0 && bottomToTop < defOffset * 2) {
    const offset = bottomToTop / 2;
    srcOffset[2] = offset;
    tgtOffset[0] = offset;
  }
  return { srcOffset, tgtOffset };
}

function getSrcAndTgtRect(srcRect, tgtRect) {
  const { srcOffset, tgtOffset } = reduceRouteMargin(srcRect, tgtRect);
  return {
    srcOuterRect: expand(srcRect, srcOffset[3], srcOffset[0], srcOffset[1], srcOffset[2]),
    tgtOuterRect: expand(tgtRect, tgtOffset[3], tgtOffset[0], tgtOffset[1], tgtOffset[2])
  };
}

// ───────────────────────── candidate point grid ─────────────────────────

/** Builds the full candidate point grid: every (x, y) combination from the
 * sorted X coordinates (both rects' left/center/right edges, the gap
 * center, and the two post-clearance points) crossed with the equivalent
 * Y coordinates — excluding any point that falls inside either outer
 * rectangle (points strictly on the boundary are kept; only the interior
 * is excluded). */
function getGraphPoints(options) {
  const { nextSourcePoint, nextTargetPoint, srcOuterRect, tgtOuterRect } = options;
  const x = [];
  const y = [];

  for (const rect of [srcOuterRect, tgtOuterRect]) {
    x.push(rect.x, rect.x + rect.width / 2, rectRight(rect));
    y.push(rect.y, rect.y + rect.height / 2, rectBottom(rect));
  }

  const rectsX = [
    srcOuterRect.x,
    rectRight(srcOuterRect),
    tgtOuterRect.x,
    rectRight(tgtOuterRect)
  ].sort((a, b) => a - b);
  x.push((rectsX[1] + rectsX[2]) / 2, nextSourcePoint.x, nextTargetPoint.x);

  const rectsY = [
    srcOuterRect.y,
    rectBottom(srcOuterRect),
    tgtOuterRect.y,
    rectBottom(tgtOuterRect)
  ].sort((a, b) => a - b);
  y.push((rectsY[1] + rectsY[2]) / 2, nextSourcePoint.y, nextTargetPoint.y);

  let result = [];
  for (let i = 0; i < x.length; i++) {
    for (let j = 0; j < y.length; j++) {
      const point = { x: x[i], y: y[j] };
      const isInSource = isPointInRectangle(srcOuterRect, point);
      const isInTarget = isPointInRectangle(tgtOuterRect, point);
      if (!isInSource && !isInTarget) result.push(point);
    }
  }
  result = removeDuplicatePoints(result).filter((point) => {
    const isInSource = isPointInRectangle(srcOuterRect, point);
    const isInTarget = isPointInRectangle(tgtOuterRect, point);
    return !isInSource && !isInTarget;
  });
  return result;
}

// ───────────────────────── graph + A* ─────────────────────────

/** Builds a grid graph: for every candidate point, connect it to its
 * nearest grid-neighbor in the sorted-X and sorted-Y direction (if that
 * neighbor is itself a candidate point) — i.e. only axis-aligned
 * grid-adjacent points are connected, which is what keeps the search
 * space small and every edge orthogonal. */
function createGraph(points) {
  const adjacency = new Map();
  const xs = [];
  const ys = [];
  const index = new Map();
  for (const p of points) {
    const key = pointKey(p);
    if (!adjacency.has(key)) adjacency.set(key, { point: p, neighbors: [] });
    if (!xs.includes(p.x)) xs.push(p.x);
    if (!ys.includes(p.y)) ys.push(p.y);
    index.set(key, p);
  }
  xs.sort((a, b) => a - b);
  ys.sort((a, b) => a - b);

  const has = (p) => adjacency.has(pointKey(p));
  const connect = (a, b) => {
    adjacency.get(pointKey(a)).neighbors.push(b);
    adjacency.get(pointKey(b)).neighbors.push(a);
  };

  for (let i = 0; i < xs.length; i++) {
    for (let j = 0; j < ys.length; j++) {
      const point = { x: xs[i], y: ys[j] };
      if (!has(point)) continue;
      if (i > 0) {
        const other = { x: xs[i - 1], y: ys[j] };
        if (has(other)) connect(other, point);
      }
      if (j > 0) {
        const other = { x: xs[i], y: ys[j - 1] };
        if (has(other)) connect(other, point);
      }
    }
  }
  return adjacency;
}

function manhattan(a, b) { return Math.abs(a.x - b.x) + Math.abs(a.y - b.y); }
function directionOf(a, b) { return { x: Math.sign(b.x - a.x), y: Math.sign(b.y - a.y) }; }
function sameDir(a, b) { return a && b && a.x === b.x && a.y === b.y; }

/** A* minimizing distance plus a penalty per direction change, so the
 * result is both short and has the fewest turns ("shortest path with the
 * fewest turning points", per the reference). Search-state identity
 * includes the arrival direction, since future turn cost depends on path
 * history, not just position. */
function findRoute(adjacency, start, goal) {
  const TURN_WEIGHT = 50;
  const startKey = pointKey(start);
  const goalKey = pointKey(goal);
  if (!adjacency.has(startKey) || !adjacency.has(goalKey)) return null;

  const stateKey = (point, dir) => `${pointKey(point)}|${dir ? `${dir.x},${dir.y}` : "start"}`;
  const open = [{ point: start, dir: null, g: 0, f: manhattan(start, goal) }];
  const cameFrom = new Map();
  const gScore = new Map([[stateKey(start, null), 0]]);
  const visited = new Set();

  while (open.length > 0) {
    open.sort((a, b) => a.f - b.f);
    const current = open.shift();
    const curKey = stateKey(current.point, current.dir);
    if (visited.has(curKey)) continue;
    visited.add(curKey);

    if (pointsEqual(current.point, goal)) {
      const path = [current.point];
      let walkKey = curKey;
      while (cameFrom.has(walkKey)) {
        const prev = cameFrom.get(walkKey);
        path.unshift(prev.point);
        walkKey = stateKey(prev.point, prev.dir);
      }
      return path;
    }

    const node = adjacency.get(pointKey(current.point));
    for (const neighbor of node.neighbors) {
      const dir = directionOf(current.point, neighbor);
      const cost = manhattan(current.point, neighbor) + (sameDir(current.dir, dir) ? 0 : current.dir ? TURN_WEIGHT : 0);
      const tentativeG = current.g + cost;
      const nKey = stateKey(neighbor, dir);
      if (tentativeG < (gScore.get(nKey) ?? Infinity)) {
        gScore.set(nKey, tentativeG);
        cameFrom.set(nKey, { point: current.point, dir: current.dir });
        open.push({ point: neighbor, dir, g: tentativeG, f: tentativeG + manhattan(neighbor, goal) });
      }
    }
  }
  return null;
}

// ───────────────────────── centerline correction ─────────────────────────

/** For one axis (horizontal=true means correcting along centerX), finds:
 *  - every maximal run of the path that's parallel to that axis
 *    ("parallelPaths" — the segments a correction could slide onto the
 *    centerline), and
 *  - the first point in the path that already sits exactly on the
 *    centerline ("pointOfHit"), if any — the anchor the correction pivots
 *    around.
 */
function getAdjustOptions(path, centerOfAxis, isHorizontal) {
  const parallelPaths = [];
  let start = null;
  let pointOfHit = null;
  const coord = (p) => (isHorizontal ? p.x : p.y);

  for (let index = 0; index < path.length; index++) {
    const previous = path[index - 1];
    const current = path[index];
    if (start === null && previous && coord(previous) === coord(current)) {
      start = previous;
    }
    if (start !== null && previous && coord(previous) !== coord(current)) {
      parallelPaths.push([start, previous]);
      start = null;
    }
    if (Math.round(coord(current)) === Math.round(centerOfAxis)) {
      pointOfHit = current;
    }
  }
  if (start) parallelPaths.push([start, path[path.length - 1]]);
  return { pointOfHit, parallelPaths };
}

/** Attempts to slide the route so it passes through the centerline: for
 * each parallel run, build the rectangle spanned by (pointOfHit, that
 * run's two endpoints); if that rectangle doesn't overlap either node's
 * own (non-inflated) box, splice the route so it passes through the
 * missing corner of that rectangle instead of its original bend — i.e.
 * reroute via the centerline — but only keep the change if it doesn't
 * increase the total turn count. */
function adjust(route, parallelPaths, pointOfHit, srcRect, tgtRect) {
  let result = null;
  for (const parallelPath of parallelPaths) {
    const tempRectPoints = [pointOfHit, parallelPath[0], parallelPath[1]];
    const tempRect = getRectangleByPoints(tempRectPoints);
    if (isHit(tempRect, srcRect) || isHit(tempRect, tgtRect)) continue;

    const tempCorners = getCornerPointsByPoints(tempRectPoints);
    const indexRangeInPath = [];
    const indexRangeInCorner = [];
    route.forEach((point, index) => {
      const cornerResult = tempCorners.findIndex((corner) => pointsEqual(point, corner));
      if (cornerResult !== -1) {
        indexRangeInPath.push(index);
        indexRangeInCorner.push(cornerResult);
      }
    });
    if (indexRangeInPath.length === 0) continue;

    const newPath = route.slice();
    const missCorner = tempCorners.find((c, index) => !indexRangeInCorner.includes(index));
    if (!missCorner) continue;
    const removeLength = Math.abs(indexRangeInPath[0] - indexRangeInPath[indexRangeInPath.length - 1]) + 1;
    newPath.splice(indexRangeInPath[0] + 1, removeLength - 2, missCorner);

    const turnCount = collapseCollinearPoints(route.slice()).length - 1;
    const simplifyPoints = collapseCollinearPoints(newPath.slice());
    const newTurnCount = simplifyPoints.length - 1;
    if (newTurnCount <= turnCount) result = newPath;
  }
  return result;
}

function routeAdjust(path, { centerX, centerY, srcRect, tgtRect }) {
  if (centerX !== undefined) {
    const { pointOfHit, parallelPaths } = getAdjustOptions(path, centerX, true);
    const resultX = pointOfHit && adjust(path, parallelPaths, pointOfHit, srcRect, tgtRect);
    if (resultX) path = resultX;
  }
  if (centerY !== undefined) {
    const { pointOfHit, parallelPaths } = getAdjustOptions(path, centerY, false);
    const resultY = pointOfHit && adjust(path, parallelPaths, pointOfHit, srcRect, tgtRect);
    if (resultY) path = resultY;
  }
  return path;
}

// ───────────────────────── public entry point ─────────────────────────

/**
 * Computes a full orthogonal route (including the two boundary points)
 * from sourcePoint (on srcRect's boundary, exiting along
 * sourceDirection) to targetPoint (on tgtRect's boundary,
 * entering along targetDirection).
 */
function generateElbowLineRoute(srcRect, sourcePoint, sourceDirection, tgtRect, targetPoint, targetDirection) {
  const { srcOuterRect, tgtOuterRect } = getSrcAndTgtRect(srcRect, tgtRect);
  const nextSourcePoint = nextPoint(sourcePoint, srcOuterRect, sourceDirection);
  const nextTargetPoint = nextPoint(targetPoint, tgtOuterRect, targetDirection);

  // Fast path: if either next-point already lands inside the OTHER box's
  // outer rectangle (or the raw points land inside the opposite node), the
  // boxes are too close/overlapping for the graph approach to make sense
  // — fall back to a direct bend between the two boundary points.
  const intersect =
    isPointInRectangle(tgtRect, sourcePoint)          ||
    isPointInRectangle(tgtOuterRect, nextSourcePoint) ||
    isPointInRectangle(srcOuterRect, nextTargetPoint) ||
    isPointInRectangle(srcRect, targetPoint);
  if (intersect) {
    return [sourcePoint, { x: nextSourcePoint.x, y: nextTargetPoint.y }, targetPoint];
  }

  const options = { sourcePoint, nextSourcePoint, srcRect, srcOuterRect, targetPoint, nextTargetPoint, tgtRect, tgtOuterRect };
  const points = getGraphPoints(options);
  const graph = createGraph(points);
  let route = findRoute(graph, nextSourcePoint, nextTargetPoint);
  if (!route) route = [nextSourcePoint, nextTargetPoint];
  route = [sourcePoint, ...route, targetPoint];

  const hitXAxis = isHitX(srcOuterRect, tgtOuterRect);
  const hitYAxis = isHitY(srcOuterRect, tgtOuterRect);
  const centerX = hitXAxis ? undefined : getGapCenter(srcOuterRect, tgtOuterRect, true);
  const centerY = hitYAxis ? undefined : getGapCenter(srcOuterRect, tgtOuterRect, false);
  route = routeAdjust(route, { centerX, centerY, srcRect, tgtRect });

  return collapseCollinearPoints(route);
}
