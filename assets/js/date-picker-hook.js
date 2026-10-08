/**
 * Phoenix LiveView Hook for GrafanaDatePicker
 */

export const DatePickerHook = {
  mounted() {
    this.initPicker();
  },

  updated() {
    // Reinitialize picker with new data attributes
    this.initPicker();
  },

  destroyed() {
    // Clean up the document-level click listener so it doesn't leak
    // across LiveView patches/navigations.
    this.picker?.destroy();
  },

  initPicker() {
    const container = this.el;
    const from = container.dataset.from || '';
    const to = container.dataset.to || '';
    // The server stores and echoes back whichever symbolic label (e.g.
    // "Last 1 hour") accompanied the last filter_by_date event, so the
    // picker can keep showing that instead of resolving "now - 1h" into a
    // concrete timestamp on every round-trip.
    const label = container.dataset.label || null;
    // data-size="normal" on the hook's element selects the larger
    // padding preset; anything else (including omitted) is 'compact',
    // which is this hook's default when the attribute isn't set at all.
    const size = container.dataset.size === 'normal' ? 'normal' : 'compact';

    // If we already have a picker instance for this container, just
    // update its values instead of constructing a new one (which would
    // re-attach listeners on top of the existing ones). Size is fixed at
    // construction time — changing data-size on an existing container
    // requires a fresh element (new DOM id) to take effect, same as any
    // other structural prop in this hook.
    if (this.picker) {
      this.picker.setValue(from, to, label);
      return;
    }

    // Create new picker
    const picker = new window.GrafanaDatePicker(container, {
      size,
      onSubmit: (fromVal, toVal, labelVal) => {
        // Push event to LiveView, including the symbolic label so the
        // server can store and echo it back on the next render.
        this.pushEvent('filter_by_date', {
          date_from: fromVal,
          date_to: toVal,
          label: labelVal || ''
        });
      }
    });

    // Set initial values if provided
    if (from || to) {
      picker.setValue(from, to, label);
    }

    // Store picker reference for updates
    this.picker = picker;
  }
};
