/**
 * Tag/chip-style multi-value input (DAG Properties drawer's Maintainers /
 * Supporters / Labels fields). Renders the initial values (data-values, a
 * JSON array) as removable chips plus a text box; typing a value and
 * pressing Enter or "," adds a new chip, clicking a chip's × removes it.
 *
 * phx-update="ignore" on this element (see dag_editor.ex's chip_list_input
 * component) — LiveView never re-renders the chip list itself after mount,
 * only reads its state back out via the hidden inputs below, which are
 * ordinary form fields the surrounding <.form>'s phx-change/phx-submit
 * payload already picks up (name="dag[field][]" per chip, Plug parses
 * repeated bracketed names into a list automatically).
 */
export const ChipListHook = {
  mounted() {
    this.fieldName = this.el.dataset.fieldName;
    let initialValues = [];
    try {
      initialValues = JSON.parse(this.el.dataset.values || "[]");
    } catch {
      initialValues = [];
    }

    this.chipsContainer = document.createElement("div");
    this.chipsContainer.className = "flex flex-wrap gap-1.5 flex-1";
    this.el.appendChild(this.chipsContainer);

    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.placeholder = "Add…";
    this.input.className =
      "flex-1 min-w-[6rem] text-sm bg-transparent outline-none text-gray-900 dark:text-white placeholder-gray-400";
    this.el.appendChild(this.input);

    for (const value of initialValues) this._addChip(value);

    this._keydownHandler = (e) => {
      if (e.key === "Enter" || e.key === ",") {
        e.preventDefault();
        this._commitInput();
      } else if (e.key === "Backspace" && this.input.value === "") {
        this._removeLastChip();
      }
    };
    this.input.addEventListener("keydown", this._keydownHandler);

    // Typing a value and clicking elsewhere (not pressing Enter) should
    // still add it as a chip rather than silently discarding it.
    this._blurHandler = () => this._commitInput();
    this.input.addEventListener("blur", this._blurHandler);
  },

  _commitInput() {
    const value = this.input.value.trim();
    if (value) this._addChip(value);
    this.input.value = "";
  },

  _removeLastChip() {
    const last = this.chipsContainer.lastElementChild;
    last?.remove();
  },

  _addChip(value) {
    const chip = document.createElement("span");
    chip.className =
      "inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 text-xs";

    const label = document.createElement("span");
    label.textContent = value;
    chip.appendChild(label);

    const hidden = document.createElement("input");
    hidden.type = "hidden";
    hidden.name = this.fieldName;
    hidden.value = value;
    chip.appendChild(hidden);

    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "×";
    remove.className = "hover:text-blue-950 dark:hover:text-white leading-none px-0.5";
    remove.addEventListener("click", () => chip.remove());
    chip.appendChild(remove);

    this.chipsContainer.appendChild(chip);
  },

  destroyed() {
    this.input.removeEventListener("keydown", this._keydownHandler);
    this.input.removeEventListener("blur", this._blurHandler);
  }
};
