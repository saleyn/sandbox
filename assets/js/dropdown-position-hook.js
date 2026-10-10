/**
 * Clamps a dropdown/menu element to stay fully within the viewport, both
 * horizontally (shifts left/right) and vertically (flips to open upward
 * instead of downward when there isn't enough room below) — recalculated
 * every time the element becomes visible, since the trigger that opens it
 * (e.g. Layouts.theme_toggle's button, or the sidebar's own theme toggle
 * near the bottom of the screen) may be anywhere, including right at an
 * edge of the viewport.
 *
 * Usage: phx-hook="DropdownPositionHook" on the dropdown element itself.
 * The dropdown's own immediate parent must be the trigger's
 * position:relative wrapper (true for every current usage) — the hook
 * reads that wrapper's getBoundingClientRect() to know where the trigger
 * actually is on screen, which is what the vertical flip decision needs
 * (horizontal clamping alone never needed this, since it only adjusts the
 * dropdown's own rect). Pure positioning only — open/close state is still
 * driven by whatever Phoenix.LiveView.JS show/hide/toggle commands the
 * caller already uses; this hook just corrects left/right/top/bottom
 * after the element is shown.
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
      this._repositionHorizontal();
      this._repositionVertical();
    } finally {
      this._observer.observe(this.el, { attributes: true, attributeFilter: ["class", "style"] });
    }
  },

  _repositionHorizontal() {
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
  },

  // Flips the dropdown to open upward (anchored above the trigger, growing
  // toward the top of the screen) when it doesn't fit below — needed once
  // a trigger can sit near the bottom of the viewport (e.g. the sidebar's
  // theme toggle, pinned to the bottom of a tall sidebar), where the
  // default "open downward from the trigger" placement would run the menu
  // off the bottom edge.
  _repositionVertical() {
    const trigger = this.el.parentElement;
    if (!trigger) return;
    const triggerRect = trigger.getBoundingClientRect();
    const menuRect = this.el.getBoundingClientRect();

    const fitsBelow = triggerRect.bottom + menuRect.height + VIEWPORT_PADDING_PX <= window.innerHeight;
    const fitsAbove = triggerRect.top - menuRect.height - VIEWPORT_PADDING_PX >= 0;

    // Prefer the default "below" placement whenever it fits; only flip
    // above when below genuinely doesn't fit AND above does — if neither
    // fits (a very short viewport), leave the CSS default alone rather
    // than picking whichever is "less bad", since that's an edge case the
    // menu's own max-height/scroll (if any) should handle, not this hook.
    if (fitsBelow) {
      this.el.style.top = "";
      this.el.style.bottom = "";
      this.el.classList.remove("dropdown-position-flipped-up");
    } else if (fitsAbove) {
      this.el.style.top = "auto";
      this.el.style.bottom = `${trigger.offsetHeight + 8}px`;
      this.el.classList.add("dropdown-position-flipped-up");
    }
  },

  destroyed() {
    this._observer?.disconnect();
    window.removeEventListener("resize", this._reposition);
  }
};
