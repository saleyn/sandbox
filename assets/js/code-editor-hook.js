/**
 * Phoenix LiveView Hook mounting a CodeMirror 6 editor for a task's
 * source_code field, with a language picker (python/shell/javascript/elixir).
 *
 * The editor replaces a plain <textarea name="source_code">: that textarea
 * stays in the DOM (hidden) so the surrounding phx-submit="save_task_modal"
 * form keeps working unchanged — this hook just keeps its value in sync
 * with the CodeMirror document on every edit.
 */
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { bracketMatching, indentOnInput, syntaxHighlighting, defaultHighlightStyle, HighlightStyle, StreamLanguage } from "@codemirror/language";
import { closeBrackets, closeBracketsKeymap, autocompletion, completionKeymap } from "@codemirror/autocomplete";
import { searchKeymap } from "@codemirror/search";
import { python } from "@codemirror/lang-python";
import { javascript } from "@codemirror/lang-javascript";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { elixir } from "codemirror-lang-elixir";
import { tags } from "@lezer/highlight";

const LANGUAGES = {
  python: () => python(),
  javascript: () => javascript(),
  shell: () => StreamLanguage.define(shell),
  elixir: () => elixir()
};

// Fixed font metrics so the min line count below translates to an exact
// pixel height rather than depending on inherited/ambient font-size.
const FONT_SIZE_PX = 13;
const LINE_HEIGHT_PX = 20;
const MIN_LINES = 8;

// The editor's parent chain (#source-code-editor -> the "source" tab
// panel -> the drawer's <form>) is already a flex column with flex-1
// min-h-0 at each level (see dag_editor.ex), specifically so the editor
// can stretch to fill whatever vertical space the drawer actually has —
// but CodeMirror's own root/.cm-scroller default to a content-based
// height (auto), which only grows with typed lines instead of filling a
// flex parent, no matter how tall that parent is. `height: 100%` on both
// opts them into filling the flex item's allotted height; minHeight still
// keeps a sane floor (MIN_LINES) for a freshly-opened, mostly-empty file.
const editorTheme = EditorView.theme({
  "&": { fontSize: `${FONT_SIZE_PX}px`, height: "100%" },
  ".cm-content": { lineHeight: `${LINE_HEIGHT_PX}px`, fontFamily: "monospace" },
  ".cm-gutters": { lineHeight: `${LINE_HEIGHT_PX}px` },
  ".cm-scroller": {
    height: "100%",
    minHeight: `${MIN_LINES * LINE_HEIGHT_PX}px`,
    overflow: "auto"
  }
});

const darkEditorTheme = EditorView.theme({
  "&": { color: "#e5e7eb", backgroundColor: "#111827" },
  ".cm-content": { caretColor: "#e5e7eb" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "#e5e7eb" },
  "&.cm-focused .cm-selectionBackground, & .cm-selectionBackground": { backgroundColor: "rgba(59, 130, 246, 0.35)" },
  ".cm-activeLine": { backgroundColor: "rgba(255, 255, 255, 0.04)" },
  ".cm-gutters": { backgroundColor: "#111827", color: "#6b7280", borderRight: "1px solid #374151" },
  ".cm-activeLineGutter": { backgroundColor: "rgba(255, 255, 255, 0.04)", color: "#9ca3af" },
  ".cm-matchingBracket": { backgroundColor: "rgba(59, 130, 246, 0.3)", color: "inherit" }
}, { dark: true });

const darkHighlightStyle = HighlightStyle.define([
  { tag: [tags.keyword, tags.modifier], color: "#c678dd" },
  { tag: [tags.operator, tags.operatorKeyword, tags.escape, tags.regexp, tags.url], color: "#56b6c2" },
  { tag: [tags.string, tags.inserted], color: "#98c379" },
  { tag: [tags.number, tags.bool, tags.null, tags.atom, tags.constant(tags.name)], color: "#d19a66" },
  { tag: [tags.typeName, tags.className, tags.namespace], color: "#e5c07b" },
  { tag: [tags.propertyName, tags.attributeName], color: "#e5c07b" },
  { tag: [tags.function(tags.variableName), tags.function(tags.propertyName), tags.labelName], color: "#61afef" },
  { tag: [tags.meta, tags.annotation, tags.macroName], color: "#61afef" },
  { tag: [tags.name, tags.deleted, tags.character, tags.self], color: "#e06c75" },
  { tag: [tags.comment, tags.lineComment, tags.blockComment], color: "#7f848e", fontStyle: "italic" },
  { tag: tags.strong, fontWeight: "bold" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through" },
  { tag: tags.heading, fontWeight: "bold", color: "#e06c75" },
  { tag: tags.link, color: "#61afef", textDecoration: "underline" },
  { tag: tags.invalid, color: "#ff5555" }
]);

const themeExtensions = (isDark) => isDark
  ? [darkEditorTheme, syntaxHighlighting(darkHighlightStyle)]
  : [syntaxHighlighting(defaultHighlightStyle, { fallback: true })];

const isDarkTheme = () => document.documentElement.getAttribute("data-theme") === "dark";

const baseExtensions = [
  lineNumbers(),
  highlightActiveLine(),
  history(),
  indentOnInput(),
  bracketMatching(),
  closeBrackets(),
  autocompletion(),
  editorTheme,
  keymap.of([
    ...closeBracketsKeymap,
    ...defaultKeymap,
    ...historyKeymap,
    ...searchKeymap,
    ...completionKeymap,
    indentWithTab
  ])
];

/**
 * Switches between the "Properties" and "Source Code" tabs in the task
 * modal. Purely client-side (no server round-trip) so the CodeMirror
 * instance in the source tab — mounted via phx-update="ignore" — is never
 * unmounted/remounted by a LiveView re-render when switching tabs.
 */
export const TaskModalTabsHook = {
  mounted() {
    this._clickHandler = (e) => {
      const btn = e.target.closest("[data-tab-button]");
      if (!btn) return;
      const target = btn.dataset.tabButton;

      this.el.querySelectorAll("[data-tab-button]").forEach((b) => {
        const active = b.dataset.tabButton === target;
        b.classList.toggle("border-blue-600", active);
        b.classList.toggle("text-blue-600", active);
        b.classList.toggle("dark:text-blue-400", active);
        b.classList.toggle("border-transparent", !active);
        b.classList.toggle("text-gray-500", !active);
        b.classList.toggle("dark:text-gray-400", !active);
      });

      this.el.querySelectorAll("[data-tab-panel]").forEach((panel) => {
        panel.classList.toggle("hidden", panel.dataset.tabPanel !== target);
      });

      if (target === "source") {
        this.el.querySelector("#source-code-editor")?._codeEditorView?.requestMeasure();
      }
    };
    this.el.addEventListener("click", this._clickHandler);

    // The drawer's close triggers (X, Cancel, backdrop) only toggle CSS
    // classes client-side — see close_drawer/1 in dag_editor.ex — so the
    // slide-out transition actually plays instead of the element vanishing
    // the instant a close button is clicked (a server-pushed close_modal
    // chained in the same JS command would fire before the animation had
    // any chance to run, since Phoenix.LiveView.JS command chains don't
    // wait for CSS transitions between ops). Once that transition
    // genuinely finishes, push close_modal ourselves so @show_modal flips
    // false and this whole block unmounts — after the user has actually
    // seen it leave.
    this._transitionEndHandler = (e) => {
      if (e.target !== this.el) return;
      // Tailwind's translate-x-* utilities animate the standalone CSS
      // `translate` property, not `transform` — browsers fire `translate`
      // as the transitionend event's propertyName for that case (only
      // genuine `transform: translate(...)` usage fires "transform").
      // Checking only for "transform" meant this handler never ran at
      // all, so close_modal never got pushed and the drawer/backdrop
      // stayed in the DOM forever after "closing" — including the
      // backdrop's invisible (opacity-0) full-viewport div, which kept
      // intercepting every click on the toolbar underneath it (the
      // reported "page becomes unresponsive" bug).
      if (e.propertyName !== "transform" && e.propertyName !== "translate") return;
      if (!this.el.classList.contains("translate-x-full")) return;
      const event = this.el.dataset.closingEvent;
      if (event) this.pushEvent(event, {});
    };
    this.el.addEventListener("transitionend", this._transitionEndHandler);
  },

  destroyed() {
    this.el.removeEventListener("click", this._clickHandler);
    this.el.removeEventListener("transitionend", this._transitionEndHandler);
  }
};

export const CodeEditorHook = {
  mounted() {
    const textarea = this.el.querySelector("textarea[name='source_code']");
    const languageSelect = this.el.closest("form")?.querySelector("[data-code-editor-language-select]");

    const initialCode = this.el.dataset.sourceCode || "";
    const initialLanguage = this.el.dataset.sourceLanguage || "python";

    this.languageCompartment = new Compartment();
    this.themeCompartment = new Compartment();

    this.view = new EditorView({
      parent: this.el,
      state: EditorState.create({
        doc: initialCode,
        extensions: [
          ...baseExtensions,
          this.themeCompartment.of(themeExtensions(isDarkTheme())),
          this.languageCompartment.of(this.languageExtension(initialLanguage)),
          EditorView.updateListener.of((update) => {
            if (update.docChanged && textarea) {
              textarea.value = update.state.doc.toString();
            }
          })
        ]
      })
    });

    if (textarea) textarea.value = initialCode;

    // Exposed so TaskModalTabsHook can force a re-measure after switching
    // this panel from display:none to visible — CodeMirror can't measure
    // line heights/scroller size while hidden, so the first paint after
    // becoming visible would otherwise look uninitialized/collapsed.
    this.el._codeEditorView = this.view;

    this._languageChangeHandler = (e) => {
      this.view.dispatch({
        effects: this.languageCompartment.reconfigure(this.languageExtension(e.target.value))
      });
    };
    languageSelect?.addEventListener("change", this._languageChangeHandler);
    this._languageSelect = languageSelect;

    this._themeObserver = new MutationObserver(() => {
      this.view.dispatch({
        effects: this.themeCompartment.reconfigure(themeExtensions(isDarkTheme()))
      });
    });
    this._themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  },

  destroyed() {
    this._themeObserver?.disconnect();
    this.view?.destroy();
    if (this._languageSelect && this._languageChangeHandler) {
      this._languageSelect.removeEventListener("change", this._languageChangeHandler);
    }
  },

  languageExtension(language) {
    const factory = LANGUAGES[language] || LANGUAGES.python;
    return factory();
  }
};
