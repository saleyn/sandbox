/**
 * Phoenix LiveView Hook wiring DagEditor (assets/js/dag-editor/dag-editor.js)
 * to the DAG editor LiveView page. Replaces DagGraphHook (litegraph-based)
 * and NiceDagHook (nice-dag-core-based) — see
 * assets/js/dag-editor/SPEC.md for the design this implements.
 *
 * This file is the only one that knows about LiveView; DagEditor itself is
 * framework-agnostic.
 */
import { DagEditor, TASK_SIZE, CONDITION_SIZE } from "./dag-editor/dag-editor";

// Remembers the source-code language last used anywhere in the editor
// (across tasks, across DAGs, across page reloads — localStorage, not a
// per-instance field) so a newly-added task starts in that language
// instead of always defaulting to Python.
const LAST_LANGUAGE_STORAGE_KEY = "dagEditor:lastSourceLanguage";

function getLastLanguage() {
  try {
    return localStorage.getItem(LAST_LANGUAGE_STORAGE_KEY) || "python";
  } catch {
    return "python";
  }
}

function setLastLanguage(language) {
  try {
    localStorage.setItem(LAST_LANGUAGE_STORAGE_KEY, language);
  } catch {
    // localStorage unavailable (private browsing, etc.) — not persisting
    // the preference is a reasonable degradation, not worth surfacing.
  }
}

export const DagEditorHook = {
  mounted() {
    const container = this.el;
    const canvasWrapper = container.querySelector("#dag-canvas-wrapper");
    if (!canvasWrapper) {
      console.error("DagEditorHook: no #dag-canvas-wrapper found");
      return;
    }

    const editorContainer = document.createElement("div");
    editorContainer.style.width = "100%";
    editorContainer.style.height = "100%";
    canvasWrapper.appendChild(editorContainer);

    // ── Initial settings (server-provided — see @settings in
    // AirWeb.Pages.DagEditor) ──
    let initialSettings = {};
    try {
      initialSettings = JSON.parse(container.dataset.settings || "{}");
    } catch (e) {
      console.error("DagEditorHook: failed to parse data-settings", e);
    }

    const editor = new DagEditor(editorContainer, {
      onNodeDoubleClick: (node) => this.pushEvent("open_task_modal", { ...node.data }),
      onHistoryChange: ({ canUndo, canRedo }) => this._updateUndoRedoButtons(canUndo, canRedo),
      snapToGrid: initialSettings.snap_to_grid ?? false,
      showGrid: initialSettings.show_grid ?? true,
      lineShape: initialSettings.line_shape ?? "angled",
      lineWidth: initialSettings.line_width ?? 2,
      arrowPosition: initialSettings.arrow_position ?? "end",
      layoutDirection: initialSettings.layout_direction ?? "horizontal"
    });
    this.editor = editor;
    editor.setTheme(document.documentElement.getAttribute("data-theme") === "dark");

    this._themeObserver = new MutationObserver(() => {
      editor.setTheme(document.documentElement.getAttribute("data-theme") === "dark");
    });
    this._themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

    this._resizeObserver = new ResizeObserver(() => {});
    this._resizeObserver.observe(canvasWrapper);

    // ── Load initial data ──
    const graphDataAttr = container.dataset.graph;
    if (graphDataAttr) {
      try {
        const { tasks, layout } = JSON.parse(graphDataAttr);
        editor.loadFromServer(tasks || [], layout || {});
      } catch (e) {
        console.error("DagEditorHook: failed to parse data-graph", e);
      }
    }

    // ── Keyboard delete / undo / redo ──
    // Ctrl+Z / Cmd+Z = undo; Ctrl+Shift+Z or Ctrl+Y / Cmd+Shift+Z = redo
    // (both redo bindings are common across editors, so support either).
    editorContainer.addEventListener("keydown", (e) => {
      if (e.key === "Delete" || e.key === "Backspace") {
        editor.deleteSelected();
        return;
      }
      const mod = e.ctrlKey || e.metaKey;
      if (!mod) return;
      if (e.key === "z" || e.key === "Z") {
        e.preventDefault();
        if (e.shiftKey) editor.redo();
        else editor.undo();
      } else if (e.key === "y" || e.key === "Y") {
        e.preventDefault();
        editor.redo();
      }
    });

    // ── Toolbar button handlers ──
    // Listens on `document`, not `container` (#dag-editor-root) — the
    // toolbar buttons (Save, etc.) live in a sibling title bar OUTSIDE
    // #dag-editor-root (so LiveView can patch that bar's title text; see
    // dag_editor.ex), so a click on them never bubbles through `container`
    // at all. A page-wide delegated listener still only reacts to actual
    // [data-graph-action] elements, so this is safe even though it's not
    // scoped to this hook's own subtree.
    this._toolbarHandler = (e) => {
      const btn = e.target.closest("[data-graph-action]");
      if (!btn) return;
      const action = btn.dataset.graphAction;

      if (action === "save") this.pushEvent("save_graph", editor.serializeForServer());
      if (action === "undo") editor.undo();
      if (action === "redo") editor.redo();
    };
    document.addEventListener("click", this._toolbarHandler);

    // ── Right-click context menu (Copy / Paste) ──
    this._contextMenuHandler = (e) => {
      if (!e.target.closest(".dag-editor-viewport") && e.target !== editorContainer) return;
      e.preventDefault();
      this.showContextMenu(e.clientX, e.clientY);
    };
    canvasWrapper.addEventListener("contextmenu", this._contextMenuHandler);
    // Capture-phase mousedown anywhere dismisses the menu — EXCEPT inside
    // the menu itself. Without that exclusion, a mousedown on a menu item
    // (including a submenu item) removes the whole menu tree from the DOM
    // before the browser gets to dispatch the follow-up "click" event on
    // it, so the item's own click handler (which runs the actual copy/
    // paste/delete action) silently never fires — the menu closes but
    // nothing happens.
    this._dismissContextMenuHandler = (e) => {
      if (this._contextMenuEl && this._contextMenuEl.contains(e.target)) return;
      this.hideContextMenu();
    };
    document.addEventListener("mousedown", this._dismissContextMenuHandler, true);

    // ── Handle server push events ──
    this.handleEvent("task-updated", ({ original_task_id, properties }) => {
      const node = editor.getNode(original_task_id);
      if (!node) return;
      editor.updateNodeData(original_task_id, properties);
      if (properties.task_id && properties.task_id !== original_task_id) {
        editor.renameNode(original_task_id, properties.task_id);
      }
      if (properties.source_language) setLastLanguage(properties.source_language);
    });

    // Buttons start disabled in the server-rendered markup (no history
    // exists yet at mount); sync them once immediately in case the editor
    // somehow already has state by the time this listener is wired
    // (defensive — not expected today, but cheap to be correct about).
    this._updateUndoRedoButtons(editor.canUndo(), editor.canRedo());
  },

  /** Keeps the toolbar's Undo/Redo buttons' disabled state in sync with
   * the editor's undo stack — called from DagEditor's onHistoryChange
   * callback after every undoable change/undo/redo/history-clear, so the
   * buttons never go stale without needing to poll. */
  _updateUndoRedoButtons(canUndo, canRedo) {
    const undoBtn = document.getElementById("dag-editor-undo-btn");
    const redoBtn = document.getElementById("dag-editor-redo-btn");
    if (undoBtn) undoBtn.disabled = !canUndo;
    if (redoBtn) redoBtn.disabled = !canRedo;
  },

  showContextMenu(x, y) {
    this.hideContextMenu();
    const isDark = document.documentElement.getAttribute("data-theme") === "dark";

    const hasSelection = this.editor.selectedNodeIds.size > 0;
    const hasAnyNodes = this.editor.nodes.size > 0;
    const selectionCount = this.editor.selectedNodeIds.size;

    // Model-space point under the cursor at the moment the menu was
    // opened — "Add" places the new shape centered there, same coordinate
    // conversion _wireViewportEvents() uses for marquee-select/pan so it
    // stays correct across any pan/zoom state.
    const containerRect = this.editor.container.getBoundingClientRect();
    const modelPoint = this.editor.toModel(x - containerRect.left, y - containerRect.top);

    const items = [
      {
        label: "Add",
        icon: "hero-plus",
        submenu: [
          {
            label: "Task",
            icon: "hero-rectangle-group",
            action: () => this.addNodeAt("task", modelPoint)
          },
          {
            label: "Condition",
            icon: "hero-share",
            action: () => this.addNodeAt("condition", modelPoint)
          }
        ]
      },
      { separator: true },
      {
        label: "Undo",
        icon: "hero-arrow-uturn-left",
        disabled: !this.editor.canUndo(),
        action: () => this.editor.undo()
      },
      {
        label: "Redo",
        icon: "hero-arrow-uturn-right",
        disabled: !this.editor.canRedo(),
        action: () => this.editor.redo()
      },
      { separator: true },
      {
        label: "Copy as…",
        icon: "hero-document-duplicate",
        disabled: !hasAnyNodes,
        submenu: [
          { label: "PNG", icon: "hero-photo", action: () => this.copySelection("png") },
          { label: "SVG", icon: "hero-code-bracket-square", action: () => this.copySelection("svg") },
          { label: "JSON", icon: "hero-document-text", action: () => this.copySelection("json") }
        ]
      },
      { label: "Paste", icon: "hero-clipboard-document", action: () => this.pasteFromClipboard() },
      {
        label: "Delete selected",
        icon: "hero-trash",
        action: () => this.editor.deleteSelected(),
        disabled: !hasSelection
      },
      { separator: true },
      {
        label: "Align",
        icon: "hero-bars-3-center-left",
        disabled: selectionCount < 2,
        submenu: [
          {
            label: "Align middle",
            icon: "hero-bars-3-center-left",
            disabled: selectionCount < 2,
            action: () => this.editor.alignSelectedMiddle()
          },
          {
            label: "Align center",
            icon: "hero-view-columns",
            disabled: selectionCount < 2,
            action: () => this.editor.alignSelectedCenter()
          },
          {
            label: "Distribute horizontally",
            icon: "hero-arrows-right-left",
            disabled: selectionCount < 3,
            action: () => this.editor.distributeSelectedHorizontally()
          },
          {
            label: "Distribute vertically",
            icon: "hero-arrows-up-down",
            disabled: selectionCount < 3,
            action: () => this.editor.distributeSelectedVertically()
          }
        ]
      },
      {
        label: "Snap to grid",
        icon: "hero-table-cells",
        checkbox: true,
        checked: this.editor.snapToGrid,
        action: () => {
          this.editor.snapToGrid = !this.editor.snapToGrid;
          this.pushSettingChange("snap_to_grid", this.editor.snapToGrid);
        }
      },
      {
        label: "Show grid",
        icon: "hero-eye",
        checkbox: true,
        checked: this.editor.showGrid,
        action: () => {
          this.editor.setGridVisible(!this.editor.showGrid);
          this.pushSettingChange("show_grid", this.editor.showGrid);
        }
      },
      {
        label: "Auto layout",
        icon: "hero-squares-2x2",
        submenu: [
          { label: "Horizontal", icon: "hero-arrows-right-left", action: () => this.runAutoLayout("horizontal") },
          { label: "Vertical", icon: "hero-arrows-up-down", action: () => this.runAutoLayout("vertical") }
        ]
      },
      { separator: true },
      {
        label: "Line style",
        icon: "hero-pencil",
        submenu: [
          ...["straight", "curved", "angled"].map((shape) => ({
            label: shape[0].toUpperCase() + shape.slice(1),
            radio: true,
            checked: this.editor.lineShape === shape,
            action: () => {
              this.editor.lineShape = shape;
              this.editor.renderEdges();
              this.pushSettingChange("line_shape", shape);
            }
          })),
          { separator: true },
          ...[
            { value: "end", label: "Arrow: end" },
            { value: "none", label: "Arrow: none" }
          ].map(({ value, label }) => ({
            label,
            radio: true,
            checked: this.editor.arrowPosition === value,
            action: () => {
              this.editor.arrowPosition = value;
              this.editor.renderEdges();
              this.pushSettingChange("arrow_position", value);
            }
          }))
        ]
      },
      {
        label: "Line width",
        icon: "hero-adjustments-horizontal",
        submenu: [1, 2, 3, 4, 6].map((width) => ({
          label: `${width} px`,
          radio: true,
          checked: this.editor.lineWidth === width,
          action: () => {
            this.editor.lineWidth = width;
            this.editor.renderEdges();
            this.pushSettingChange("line_width", width);
          }
        }))
      },
      { separator: true },
      { label: "Reset zoom", icon: "hero-viewfinder-circle", action: () => this.editor.resetZoom() }
    ];

    const menu = this._buildContextMenuLevel(items, isDark);
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    document.body.appendChild(menu);
    this._positionWithinViewport(menu);
    this._contextMenuEl = menu;
  },

  /** Builds one menu <div> (used for both the top-level menu and any
   * submenu) — items with a `submenu` array open a nested menu on hover
   * instead of running an action directly on click. */
  _buildContextMenuLevel(items, isDark) {
    const menu = document.createElement("div");
    menu.className = "dag-editor-context-menu";
    menu.classList.toggle("dag-editor-dark", isDark);

    for (const item of items) {
      if (item.separator) {
        const sep = document.createElement("div");
        sep.className = "dag-editor-context-menu-separator";
        menu.appendChild(sep);
        continue;
      }

      const el = document.createElement("div");
      el.className = "dag-editor-context-menu-item";
      if (item.disabled) el.classList.add("is-disabled");

      // Every item reserves the same leading icon gutter, whether or not it
      // has an icon, so labels all align on one text column instead of
      // icon-bearing items looking indented relative to plain ones. A
      // checkbox item shows a check glyph in that same gutter in place of
      // its icon once checked, like a native app menu's checkbox items. A
      // radio item (one of several mutually-exclusive options, e.g. line
      // style/width) shows a filled dot when it's the active choice and
      // deliberately shows NOTHING — not its own icon — otherwise, since
      // every option in that group shares one icon on the parent "Line
      // style"/"Line width" item already; repeating it per option would
      // just be noise, and a checkmark would misleadingly suggest each
      // option is independently toggleable rather than one-of-many.
      const iconSlot = document.createElement("span");
      iconSlot.className = "dag-editor-context-menu-icon";
      if (item.radio) {
        if (item.checked) iconSlot.classList.add("dag-editor-context-menu-radio-dot");
      } else if (item.checkbox && item.checked) {
        iconSlot.classList.add("hero-check");
      } else if (item.icon) {
        iconSlot.classList.add(item.icon);
      }
      el.appendChild(iconSlot);

      const label = document.createElement("span");
      label.className = "dag-editor-context-menu-label";
      label.textContent = item.label;
      el.appendChild(label);

      if (item.submenu) {
        el.classList.add("has-submenu");
        const caret = document.createElement("span");
        caret.className = "dag-editor-context-menu-caret";
        caret.textContent = "▸";
        el.appendChild(caret);

        let submenuEl = null;
        el.addEventListener("mouseenter", () => {
          if (item.disabled) return;
          submenuEl = this._buildContextMenuLevel(item.submenu, isDark);
          el.appendChild(submenuEl);
          this._positionSubmenu(submenuEl, el);
        });
        el.addEventListener("mouseleave", () => {
          submenuEl?.remove();
          submenuEl = null;
        });
      } else {
        el.addEventListener("click", (e) => {
          e.stopPropagation();
          if (!item.disabled) item.action();
          this.hideContextMenu();
        });
      }
      menu.appendChild(el);
    }
    return menu;
  },

  /** Flips a submenu to the left side of its parent item when it would
   * otherwise overflow the right edge of the viewport, and nudges it up
   * when it would overflow the bottom — a submenu can be taller than the
   * remaining space below its parent item (e.g. "Line style" grew past 6
   * rows once arrow-position moved in), in which case opening flush with
   * the item's top edge would push the lower rows off-screen and make
   * them unclickable. */
  _positionSubmenu(submenuEl, parentItemEl) {
    submenuEl.style.left = "100%";
    submenuEl.style.top = "0";
    let rect = submenuEl.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      submenuEl.style.left = "auto";
      submenuEl.style.right = "100%";
    }
    if (rect.bottom > window.innerHeight) {
      submenuEl.style.top = `${Math.min(0, window.innerHeight - rect.bottom - 8)}px`;
    }
  },

  /** Nudges the top-level menu back on-screen if it was opened close
   * enough to the right/bottom edge of the viewport to overflow. */
  _positionWithinViewport(menu) {
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = `${Math.max(0, window.innerWidth - rect.width - 8)}px`;
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${Math.max(0, window.innerHeight - rect.height - 8)}px`;
    }
  },

  /** Adds a task/condition node centered on the given model-space point —
   * used by the context menu's "Add" submenu so a shape lands under the
   * cursor that was right-clicked, rather than wherever addNode()'s normal
   * "next to the last-added node" auto-placement would put it. */
  addNodeAt(type, modelPoint) {
    const size = type === "condition" ? CONDITION_SIZE : TASK_SIZE;
    const overrides = type === "task" ? { source_language: getLastLanguage() } : {};
    this.editor.addNode(type, { x: modelPoint.x - size.width / 2, y: modelPoint.y - size.height / 2 }, overrides);
  },

  /** Runs auto-layout in the given direction from the context menu's
   * "Auto layout" submenu, and remembers the direction so a future
   * invocation without an explicit direction (there's currently no such
   * caller, but keeps the editor's own state coherent) would reuse it. */
  runAutoLayout(direction) {
    this._layoutDirection = direction;
    this.editor.setLayoutDirection(direction);
    this.editor.autoLayout(direction);
    this.pushSettingChange("layout_direction", direction);
  },

  /** Fires the server-side event that persists one editor setting. Called
   * from every place a setting can change — the toolbar <select>s and the
   * right-click menu's equivalent items — so both entry points persist
   * identically instead of only one of them being wired up. */
  pushSettingChange(name, value) {
    this.pushEvent("update_settings", { name, value });
  },

  hideContextMenu() {
    this._contextMenuEl?.remove();
    this._contextMenuEl = null;
  },

  async copySelection(format) {
    const nodes = this.editor.targetNodes();
    try {
      if (format === "json") await this.editor.copyAsJson(nodes);
      if (format === "svg") await this.editor.copyAsSvg(nodes);
      if (format === "png") await this.editor.copyAsPng(nodes);
    } catch (e) {
      console.error("DagEditorHook: copy failed", e);
    }
  },

  async pasteFromClipboard() {
    let doc;
    try {
      const text = await navigator.clipboard.readText();
      doc = JSON.parse(text);
    } catch (e) {
      console.error("DagEditorHook: clipboard has no valid JSON to paste", e);
      return;
    }
    if (!doc || !Array.isArray(doc.tasks)) {
      console.error("DagEditorHook: pasted JSON is not a { tasks, layout } document");
      return;
    }

    const hasExisting = this.editor.nodes.size > 0;
    const replace = hasExisting
      ? window.confirm("Replace the current DAG with the pasted one?\n\nCancel to append instead.")
      : false;
    this.editor.pasteDocument(doc, replace);
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect();
    if (this._themeObserver) this._themeObserver.disconnect();
    if (this._toolbarHandler) document.removeEventListener("click", this._toolbarHandler);
    if (this._contextMenuHandler) {
      this.el.querySelector("#dag-canvas-wrapper")?.removeEventListener("contextmenu", this._contextMenuHandler);
    }
    if (this._dismissContextMenuHandler) document.removeEventListener("mousedown", this._dismissContextMenuHandler, true);
    this.hideContextMenu();
    if (this.editor) this.editor.destroy();
  }
};
