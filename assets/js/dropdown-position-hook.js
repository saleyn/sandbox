/**
 * Clamps a dropdown/menu element to stay fully within the viewport
 * horizontally, with a small padding margin — recalculated every time the
 * element becomes visible, since the trigger that opens it (e.g.
 * Layouts.theme_toggle's button) may itself be anywhere, including near or
 * past the right edge of an overflowing toolbar.
 *
 * Usage: phx-hook="DropdownPositionHook" on the dropdown element itself.
 * Pure positioning only — open/close state is still driven by whatever
 * Phoenix.LiveView.JS show/hide/toggle commands the caller already uses;
 * this hook just corrects `left`/`right` after the element is shown.
 */
const VIEWPORT_PADDING_PX = 8;

export const DropdownPositionHook = {
  mounted() {
    this._reposition = () => this.reposition();
    // MutationObserver on the "hidden" class/attribute covers both
    // JS.toggle and JS.show, without needing the caller to dispatch a
    // custom event just for this hook's benefit.
    this._observer = new MutationObserver(this._reposition);
    this._observer.observe(this.el, { attributes: true, attributeFilter: ["class", "style"] });
    window.addEventListener("resize", this._reposition);
  },

  reposition() {
    // Tailwind's `hidden` CLASS is never actually removed by
    // Phoenix.LiveView.JS.toggle/show/hide — those commands manipulate the
    // element's inline `display` style on top of it, so checking
    // classList.contains("hidden") here would always be true and this
    // would never run. offsetParent is null both while display:none and
    // while the element (or an ancestor) is detached/not laid out, which
    // is exactly "not currently visible" regardless of which mechanism
    // hid it.
    if (this.el.offsetParent === null) return;

    // Writing to this.el.style below is itself a "style" attribute
    // mutation, which the observer below is also watching — without
    // disconnecting first, each correction re-triggers this same handler
    // via the observer's queued microtask, forever (an infinite loop that
    // hangs the page solid, since MutationObserver callbacks run
    // synchronously relative to rendering). Disconnect for the duration
    // of our own write, then reconnect, so only EXTERNAL class/style
    // changes (the actual open/close toggle) schedule a reposition.
    this._observer.disconnect();
    try {
      // If we previously corrected this element, undo ONLY that
      // correction (restore the exact prior inline left/right rather than
      // clearing to the CSS default) before re-measuring — clearing to
      // the class-authored default here is unsafe for an
      // absolutely-positioned element with neither left nor right
      // present, since it can fall back to its static-flow position,
      // which for `position: absolute` can be a completely different
      // spot than where it was actually rendered (observed: jumping the
      // menu by 1000+px). Measuring with whatever positioning is
      // CURRENTLY in effect (first open: the CSS right-0 class; later
      // opens: our own previous correction) is always representative of
      // where it's actually on screen right now.
      const rect = this.el.getBoundingClientRect();
      if (rect.right > window.innerWidth - VIEWPORT_PADDING_PX || rect.left < VIEWPORT_PADDING_PX) {
        // Switch to a pure `left` offset, computed from the CURRENT
        // rect's position — setting `left` while the `right-0` class is
        // still active would make the browser stretch/shrink the
        // element's width to satisfy both constraints instead of moving
        // it, so `right` must be neutralized in the same write.
        const clampedLeft = Math.min(
          Math.max(rect.left, VIEWPORT_PADDING_PX),
          window.innerWidth - rect.width - VIEWPORT_PADDING_PX
        );
        this.el.style.right = "auto";
        this.el.style.left = `${clampedLeft}px`;
      }
    } finally {
      this._observer.observe(this.el, { attributes: true, attributeFilter: ["class", "style"] });
    }
  },

  destroyed() {
    this._observer?.disconnect();
    window.removeEventListener("resize", this._reposition);
  }
};
