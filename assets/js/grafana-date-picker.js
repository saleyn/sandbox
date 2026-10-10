/**
 * Vanilla JavaScript Grafana-style Date Picker
 * Integrates with Phoenix LiveView
 */

// This project already vendors Heroicons via a Tailwind plugin
// (assets/vendor/heroicons.js, loaded in app.css), which turns each icon
// in deps/heroicons/optimized into a `hero-{name}` CSS class — a
// mask-based background-image sized via theme spacing, colored via
// `currentColor`/text-color utilities. No separate SVG markup or fetch
// needed; `hero-clock`, `hero-chevron-down`, `hero-calendar-days`,
// `hero-clipboard`, and `hero-clipboard-document` all resolve to the
// outline set already used elsewhere in this app.
const ICONS = {
  clock: (cls) => `<span class="hero-clock ${cls}"></span>`,
  chevronDown: (cls) => `<span class="hero-chevron-down ${cls}"></span>`,
  calendarDays: (cls) => `<span class="hero-calendar-days ${cls}"></span>`,
  clipboard: (cls) => `<span class="hero-clipboard ${cls}"></span>`,
  clipboardDocument: (cls) => `<span class="hero-clipboard-document ${cls}"></span>`,
  xMark: (cls) => `<span class="hero-x-mark ${cls}"></span>`,
};

// Trigger box height is intentionally identical in both presets — the
// `size` option only ever affects the DROPDOWN panel's internal
// padding/density, never the closed trigger's own size. Keeping these
// fixed (rather than per-preset like everything else below) means
// switching 'normal' <-> 'compact' can't shift layout around it on the
// surrounding page — e.g. a Trigger-execution button sized to match the
// trigger box wouldn't need its own padding adjusted every time this
// picker's preset changes.
const TRIGGER_ICON_PAD = 'px-2';
const TRIGGER_DISPLAY_PAD = 'px-3 py-[7px]';

// Two padding/sizing presets, selected via the `size` option
// ('normal' | 'compact', default 'compact'). Every value referenced in
// render()/renderQuickOptions()/renderTimezones()/renderRecentlyUsed()
// pulls from whichever of these is active, so switching presets rescales
// the dropdown's density consistently rather than piecemeal — but, per
// above, the trigger box itself is NOT part of this and stays fixed.
const SIZE_PRESETS = {
  normal: {
    // w-[calc(100vw-2rem)] + max-w-[460px]: prefers the fixed max-width
    // whenever the viewport has room for it (max-width caps it there),
    // but shrinks to fit (viewport minus a 1rem margin on each side) on
    // narrow screens instead of overflowing off the edge — the panel is
    // `absolute`-positioned with no right-edge anchor, so a fixed width
    // alone had nothing stopping it from running past the viewport on
    // mobile. 460px (down from the original 530px) reflects the
    // right-hand quick-list rows no longer reserving space for a
    // trailing "Last 5m to now"-style annotation next to each label.
    panelWidth: 'w-[calc(100vw-2rem)] max-w-[440px]',
    // Narrower by default so the (flex-1, shrinkable) right column still
    // gets meaningful width out of a narrowed panel on small screens;
    // reverts to the original fixed width once sm: has room for both
    // columns at full size.
    leftColWidth: 'w-44 sm:w-65',
    leftColPad: 'p-4',
    leftColGap: 'space-y-3',
    inputPad: 'pl-3 pr-9 py-2',
    calendarBtnWidth: 'w-8',
    squareBtnSize: 'w-9 h-9',
    applyBtnPad: 'px-4 py-2',
    searchWrapPad: 'p-3',
    rightColPad: 'p-2',
    quickOptPad: 'px-2 py-1.5',
    quickGroupPad: 'px-2 py-1',
    bottomPad: 'px-4 py-3',
    tzBtnPad: 'px-3 py-1.5',
    tzPanelPad: 'p-2',
    tzOptionPad: 'px-2 py-1.5',
    tzActionBtnPad: 'px-2 py-1.5',
    searchInputPad: 'px-3 py-2',
    recentOptPad: 'px-1 py-1',
  },
  compact: {
    panelWidth: 'w-[calc(100vw-2.1rem)] max-w-[380px]',
    leftColWidth: 'w-58 sm:w-60',
    leftColPad: 'p-2',
    leftColGap: 'space-y-1.5',
    inputPad: 'pl-2 pr-7 py-1',
    calendarBtnWidth: 'w-6',
    squareBtnSize: 'w-7 h-7',
    applyBtnPad: 'px-3 py-1',
    searchWrapPad: 'p-1.5',
    rightColPad: 'p-1',
    quickOptPad: 'px-1.5 py-1',
    quickGroupPad: 'px-1.5 py-0.5',
    bottomPad: 'px-2 py-1.5',
    tzBtnPad: 'px-2 py-1',
    tzPanelPad: 'p-1.5',
    tzOptionPad: 'px-1.5 py-1',
    tzActionBtnPad: 'px-1.5 py-1',
    searchInputPad: 'px-2 py-1',
    recentOptPad: 'px-1 py-0.5',
  },
};

class GrafanaDatePicker {
  constructor(element, options = {}) {
    this.element = element;
    this.options = {
      name: options.name || 'date_range',
      onSubmit: options.onSubmit || null,
      timezone: options.timezone || 'UTC',
      ...options,
      // Normalized after the spread so any value other than exactly
      // 'normal' (including a typo, or simply omitted) falls back to
      // 'compact' — matching DatePickerHook's own default — rather than
      // being passed through as-is.
      size: options.size === 'normal' ? 'normal' : 'compact',
    };
    // sz is read throughout render()/renderQuickOptions()/etc. as the
    // single source of truth for the active preset's spacing values.
    this.sz = SIZE_PRESETS[this.options.size];

    this.isOpen = false;
    this.selectedTab = 'relative';
    this.fromValue = '';
    this.toValue = '';
    this.selectedLabel = null;
    this.recentlyUsed = this.loadRecentlyUsed();
    this.init();
  }

  init() {
    if (!this.element.innerHTML.trim()) {
      this.render();
    }
    // Only attach listeners once — re-running this on every LiveView
    // `updated()` call would stack duplicate handlers (especially the
    // document-level click listener), which compounds over time and can
    // freeze the tab after repeated interactions.
    if (!this.listenersAttached) {
      this.attachEventListeners();
      this.listenersAttached = true;
    }
  }

  destroy() {
    if (this.documentClickHandler) {
      document.removeEventListener('click', this.documentClickHandler);
    }
    if (this.documentKeydownHandler) {
      document.removeEventListener('keydown', this.documentKeydownHandler);
    }
  }

  render() {
    // Only render if empty to avoid recreating on updates
    if (this.element.querySelector('.gdp-trigger')) {
      return; // Already rendered
    }

    const sz = this.sz;

    this.element.innerHTML = `
      <div class="relative w-full">
        <!-- Trigger: a readonly input so clicking/tabbing into it shows the
             normal input focus ring and text cursor, but typing has no
             effect — all editing happens via the dropdown below. -->
        <div class="gdp-trigger relative flex items-stretch w-full border border-base-300 rounded-lg bg-field text-field-content cursor-pointer overflow-hidden">
          <!-- Clock icon gets its own shaded segment + right border, like
               an input-group prefix, instead of floating directly on the
               same background as the text. -->
          <span class="flex items-center justify-center ${TRIGGER_ICON_PAD} bg-base-200 border-r border-base-300 shrink-0">
            ${ICONS.clock('w-4 h-4 text-base-content/50')}
          </span>
          <input
            type="text"
            readonly
            class="gdp-display flex-1 min-w-0 ${TRIGGER_DISPLAY_PAD} bg-transparent border-none outline-none cursor-pointer text-field-content placeholder:text-field-content/40"
            value="Select date range"
          />
          <!-- Shaded segment + left border mirrors the clock prefix on the
               other side. items-center centers the icon within this span's
               own box; without it the icon (an inline mask element) sits
               on the text baseline and reads as offset downward. The
               rotation lives on the INNER span, not this one — rotating a
               box that itself has a one-sided border would visually flip
               the border to the opposite edge when open. -->
          <span class="flex items-center justify-center ${TRIGGER_ICON_PAD} bg-base-200 border-l border-base-300 shrink-0">
            <span class="gdp-chevron inline-flex items-center justify-center transition-transform duration-150">
              ${ICONS.chevronDown('w-4 h-4')}
            </span>
          </span>
        </div>

        <!-- Picker Panel -->
        <div class="gdp-panel absolute top-full mt-1 ${sz.panelWidth} bg-base-100 border border-base-300 rounded-lg shadow-xl z-50 hidden flex flex-col">
          <!-- Main Content: Two equal-width columns. overflow-hidden here is
               load-bearing: max-h-96 alone only stops the box from growing,
               it does NOT clip children — without this, a long Recently
               Used list would visually spill out past this row and over
               the bottom timezone bar. -->
          <div class="flex flex-1 max-h-96 overflow-hidden">
            <!-- Left Panel: Date Inputs. Fixed width rather than flex-1 so
                 the right-hand quick-list controls its own width instead
                 of splitting space 50/50. The 'compact' preset's width was
                 tuned so the input's text area (full width minus padding
                 minus the reserved calendar-icon gutter) just fits
                 "YYYY-MM-DD HH:MM:SS" (19 chars) at text-sm — narrower and
                 the trailing ":00" seconds clip. overflow-y-auto so if its
                 own content (inputs + buttons + recently-used) is ever
                 taller than the row allows, IT scrolls internally rather
                 than pushing/overflowing past the row boundary above. -->
            <div class="${sz.leftColWidth} shrink-0 flex flex-col border-r border-base-300 ${sz.leftColPad} ${sz.leftColGap} overflow-y-auto">
              <div class="relative">
                <label class="block text-xs font-medium text-base-content/50 uppercase mb-1">From</label>
                <div class="relative">
                  <input
                    type="text"
                    class="gdp-from-input w-full ${sz.inputPad} bg-field border border-base-300 rounded text-field-content text-sm placeholder:text-field-content/40 focus:outline-none focus:border-focus"
                    placeholder="Last 7d"
                    value="${this.fromValue}"
                  />
                  <button
                    type="button"
                    class="gdp-calendar-toggle-from absolute inset-y-0 right-0 flex items-center justify-center ${sz.calendarBtnWidth} text-base-content/50 hover:text-base-content transition-colors"
                    title="Pick a date from the calendar"
                  >
                    ${ICONS.calendarDays('w-4 h-4')}
                  </button>
                </div>
                <!-- position: fixed (set at open-time via JS, not CSS) so
                     this popup is positioned relative to the viewport, not
                     the scrolling left column — an absolutely-positioned
                     popup here would still count toward that column's
                     scrollable content size and force scrollbars once it
                     extends past the column's visible height. -->
                <div class="gdp-calendar-popup-from hidden fixed z-50"></div>
              </div>

              <div class="relative">
                <label class="block text-xs font-medium text-base-content/50 uppercase mb-1">To</label>
                <div class="relative">
                  <input
                    type="text"
                    class="gdp-to-input w-full ${sz.inputPad} bg-field border border-base-300 rounded text-field-content text-sm placeholder:text-field-content/40 focus:outline-none focus:border-focus"
                    placeholder="now"
                    value="${this.toValue}"
                  />
                  <button
                    type="button"
                    class="gdp-calendar-toggle-to absolute inset-y-0 right-0 flex items-center justify-center ${sz.calendarBtnWidth} text-base-content/50 hover:text-base-content transition-colors"
                    title="Pick a date from the calendar"
                  >
                    ${ICONS.calendarDays('w-4 h-4')}
                  </button>
                </div>
                <!-- See the From popup's comment above re: fixed vs absolute. -->
                <div class="gdp-calendar-popup-to hidden fixed z-50"></div>
              </div>

              <!-- Copy/Paste are fixed square icon buttons (sized via
                   squareBtnSize to match the row's own height); Apply
                   fills the remaining width so all three share one line. -->
              <div class="flex gap-2 pt-2">
                <button
                  type="button"
                  class="gdp-copy shrink-0 ${sz.squareBtnSize} flex items-center justify-center bg-base-200 hover:bg-base-300 text-base-content rounded transition-colors"
                  title="Copy to clipboard"
                >
                  ${ICONS.clipboard('w-4 h-4')}
                </button>
                <button
                  type="button"
                  class="gdp-paste shrink-0 ${sz.squareBtnSize} flex items-center justify-center bg-base-200 hover:bg-base-300 text-base-content rounded transition-colors"
                  title="Paste from clipboard"
                >
                  ${ICONS.clipboardDocument('w-4 h-4')}
                </button>
                <button
                  type="button"
                  class="gdp-apply flex-1 ${sz.applyBtnPad} bg-primary hover:bg-primary/90 text-primary-content font-semibold rounded transition-colors text-sm"
                >
                  Apply range
                </button>
              </div>

              <!-- Shown only when To resolves to an earlier instant than
                   From; cleared again on the next successful Apply. -->
              <p class="gdp-range-error hidden text-xs text-error">"FROM" date must be less than "TO" date</p>

              <!-- Recently used ranges: flex-1 + min-h-0 lets this section
                   claim remaining space in the column and scroll
                   internally (own max-h as a soft cap), while the overall
                   column overflow-y-auto above is the hard backstop. -->
              <div class="pt-2 border-t border-base-300 flex-1 min-h-0 flex flex-col">
                <p class="text-xs font-medium text-base-content/50 uppercase mb-1 shrink-0">Recently used absolute ranges</p>
                <div class="gdp-recently-used space-y-2 overflow-y-auto">
                  ${this.renderRecentlyUsed()}
                </div>
              </div>
            </div>

            <!-- Right Panel: Quick Search and Presets. flex-1 so it fills
                 whatever space remains next to the left column's fixed
                 width — a fixed width here instead left a gap between
                 this panel's actual content and the dropdown's right
                 edge, which made its internal scrollbar sit awkwardly in
                 the middle rather than flush against that edge. min-w-0
                 lets it shrink below its content's natural min-width if
                 needed, so a long search placeholder etc. can't force
                 this panel wider than its share and squeeze the left
                 column instead.

                 flex-col + min-h-0 here (NOT overflow-y-auto on this
                 outer div) is what keeps the search box pinned: only the
                 options list below it scrolls. Putting overflow-y-auto
                 on this whole column — the previous approach — scrolled
                 the search box away with everything else, since it was
                 just another child in the same scrolling box. -->
            <div class="flex-1 min-w-0 flex flex-col">
              <!-- shrink-0: fixed header, never part of the
                   scrollable area below. -->
              <div class="${sz.searchWrapPad} border-b border-base-300 shrink-0">
                <input
                  type="text"
                  class="gdp-search-input w-full ${sz.searchInputPad} bg-field border border-base-300 rounded text-field-content text-sm placeholder:text-field-content/40 focus:outline-none focus:border-focus"
                  placeholder="Search ranges"
                />
              </div>
              <!-- min-h-0 lets this actually shrink and scroll inside the
                   parent's max-h-96 instead of forcing the flex item to
                   its content's natural (taller) height. -->
              <div class="${sz.rightColPad} flex-1 min-h-0 overflow-y-auto">
                ${this.renderQuickOptions()}
              </div>
            </div>
          </div>

          <!-- Bottom Panel: Browser Time and Timezone. Matches the dropdown
               panel's own background (see the gdp-panel div above). -->
          <div class="flex items-center justify-between border-t border-base-300 ${sz.bottomPad} bg-base-100">
            <div class="text-sm text-base-content/50">
              Browser Time: <span class="gdp-browser-time font-medium text-base-content">EDT</span>
            </div>
            <div class="relative">
              <button
                type="button"
                class="gdp-timezone-btn flex items-center gap-2 ${sz.tzBtnPad} text-sm bg-base-200 hover:bg-base-300 text-base-content rounded transition-colors"
              >
                <span class="gdp-timezone-display">UTC-04:00</span>
                <span class="gdp-timezone-chevron inline-flex items-center justify-center transition-transform duration-150">
                  ${ICONS.chevronDown('w-3 h-3')}
                </span>
              </button>

              <!-- Timezone Dropdown (hidden by default) -->
              <div class="gdp-timezone-panel hidden absolute bottom-full mb-2 right-0 w-48 bg-base-100 border border-base-300 rounded-lg shadow-xl z-50">
                <div class="${sz.tzPanelPad} border-b border-base-300 flex items-center gap-2">
                  <input
                    type="text"
                    class="gdp-timezone-search flex-1 min-w-0 ${sz.searchInputPad} bg-field border border-base-300 rounded text-field-content text-sm placeholder:text-field-content/40 focus:outline-none focus:border-focus"
                    placeholder="Search timezones"
                  />
                  <!-- Closes the dropdown without committing the staged
                       selection — same effect as clicking outside it or
                       pressing Esc, just reachable without leaving the
                       panel. -->
                  <button
                    type="button"
                    class="gdp-timezone-close shrink-0 p-1 text-base-content/50 hover:text-base-content transition-colors"
                    title="Close"
                  >
                    ${ICONS.xMark('w-4 h-4')}
                  </button>
                </div>
                <div class="gdp-timezone-list max-h-48 overflow-y-auto ${sz.tzPanelPad}">
                  ${this.renderTimezones()}
                </div>
                <div class="flex gap-2 ${sz.tzPanelPad} border-t border-base-300">
                  <button
                    type="button"
                    class="gdp-timezone-reset flex-1 ${sz.tzActionBtnPad} bg-base-200 hover:bg-base-300 text-base-content text-xs font-medium rounded transition-colors"
                    title="Reset to browser timezone"
                  >
                    Reset
                  </button>
                  <button
                    type="button"
                    class="gdp-timezone-accept flex-1 ${sz.tzActionBtnPad} bg-primary hover:bg-primary/90 text-primary-content text-xs font-medium rounded transition-colors"
                  >
                    Accept
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    `;
  }

  renderQuickOptions() {
    // Every from/to below is a genuinely relative EXPRESSION (parsed by
    // resolveDateExpr, mirrored server-side by parse_date_expr/2) rather
    // than a pre-resolved "YYYY-MM-DD" snapshot — so e.g. "This week"
    // picked today and "This week" picked next Tuesday both correctly
    // mean "the week containing whenever this is applied", not a fixed
    // date frozen at click time.
    const quickOptions = [
      { label: 'Last 5 minutes', from: 'now - 5 minutes', to: 'now' },
      { label: 'Last 15 minutes', from: 'now - 15 minutes', to: 'now' },
      { label: 'Last 30 minutes', from: 'now - 30 minutes', to: 'now' },
      { label: 'Last 1 hour', from: 'now - 1 hour', to: 'now' },
      { label: 'Last 3 hours', from: 'now - 3 hours', to: 'now' },
      { label: 'Last 6 hours', from: 'now - 6 hours', to: 'now' },
      { label: 'Last 12 hours', from: 'now - 12 hours', to: 'now' },
      { label: 'Last 24 hours', from: 'now - 24 hours', to: 'now' },
      { label: 'Last 3 days', from: 'now - 3 days', to: 'now' },
      { label: 'Last 7 days', from: 'now - 7 days', to: 'now' },
      { label: 'Last 30 days', from: 'now - 30 days', to: 'now' },
      { label: 'Last 90 days', from: 'now - 90 days', to: 'now' },
      { label: 'Last 3 months', from: 'now - 3 months', to: 'now' },
      { label: 'Last 6 months', from: 'now - 6 months', to: 'now' },
      // "Today" is "the last 24 hours", per the spec's own framing
      // ("Yesterday" From = "now - 2 days", i.e. Today's From shifted
      // back one more day) — not "since midnight".
      { label: 'Today', from: 'now - 1 day', to: 'now' },
      { label: 'Yesterday', from: 'now - 2 days', to: 'now - 1 day' },
      { label: 'Today - 2 days', from: 'now - 2 days', to: 'now' },
      { label: 'Today - 3 days', from: 'now - 3 days', to: 'now' },
      { label: 'This week', from: 'Sunday', to: 'now' },
      { label: 'Last week', from: 'Last Sunday - 7 days', to: 'Last Sunday' },
      { label: 'This month', from: '1st day of this month', to: 'now' },
      { label: 'Last month', from: '1st day of last month', to: 'End of last month' },
    ];

    // end: 22 (not 18) — quickOptions grew from 18 to 22 entries ("Last 3
    // months"/"Last 6 months"/"Today - 2 days"/"Today - 3 days" were
    // added into the middle of the array) without these group ranges
    // being extended to match, which orphaned "This week"/"Last
    // week"/"This month"/"Last month": defined in quickOptions but
    // outside every group's start/end range, so renderQuickOptions()
    // silently never emitted them at all.
    const groups = [
      { label: 'Common', start: 0, end: 8 },
      { label: 'By day', start: 8, end: 18 },
      { label: 'By wk/month', start: 18, end: 22 },
    ];

    let html = '';
    for (const group of groups) {
      // gdp-quick-group wraps the header + its options so the search
      // handler (attachEventListeners) can hide the whole group — header
      // included — once every option inside it is filtered out, instead
      // of leaving an orphaned "Common"/"By day" label with nothing
      // underneath it.
      html += `<div class="gdp-quick-group mb-2">
        <div class="gdp-quick-group-label text-xs font-medium text-base-content/50 uppercase tracking-wider ${this.sz.quickGroupPad}">
          ${group.label}
        </div>`;

      for (let i = group.start; i < group.end; i++) {
        const opt = quickOptions[i];
        if (opt) {
          // No trailing "${opt.display}" annotation (e.g. "Last 5m to
          // now") — dropping it is what let the panel narrow down for
          // small screens in the first place, since the label alone no
          // longer needs the extra horizontal room that second span and
          // its justify-between gap used to reserve. opt.display itself
          // stays on the object: formatDisplay()/addToRecentlyUsed()
          // still use it for the trigger's own text once a range is
          // applied, this is only about the picklist's own row.
          html += `<button
            type="button"
            class="gdp-quick-option w-full ${this.sz.quickOptPad} text-left text-sm text-base-content hover:bg-base-200 rounded transition-colors"
            data-from="${opt.from}"
            data-to="${opt.to}"
            data-label="${opt.label}"
          >
            ${opt.label}
          </button>`;
        }
      }
      html += '</div>';
    }
    // Shown when a search query matches nothing at all; toggled in
    // attachEventListeners' search handler, not here, since this method
    // only runs once at render time.
    html += '<p class="gdp-quick-no-results hidden text-xs text-base-content/40 text-center py-4">No matches</p>';
    return html;
  }

  renderTimezones() {
    const timezones = [
      'UTC', 'UTC-12:00', 'UTC-11:00', 'UTC-10:00', 'UTC-09:00', 'UTC-08:00',
      'UTC-07:00', 'UTC-06:00', 'UTC-05:00', 'UTC-04:00', 'UTC-03:00', 'UTC-02:00',
      'UTC-01:00', 'UTC+01:00', 'UTC+02:00', 'UTC+03:00', 'UTC+04:00', 'UTC+05:00',
      'UTC+06:00', 'UTC+07:00', 'UTC+08:00', 'UTC+09:00', 'UTC+10:00', 'UTC+11:00',
      'UTC+12:00', 'EST', 'EDT', 'CST', 'CDT', 'MST', 'MDT', 'PST', 'PDT'
    ];

    return timezones.map(tz => `
      <button
        type="button"
        class="gdp-tz-option w-full ${this.sz.tzOptionPad} text-left text-sm text-base-content hover:bg-base-200 rounded transition-colors"
        data-tz="${tz}"
      >
        ${tz}
      </button>
    `).join('');
  }

  attachEventListeners() {
    const trigger = this.element.querySelector('.gdp-trigger');
    const panel = this.element.querySelector('.gdp-panel');
    const quickOptions = this.element.querySelectorAll('.gdp-quick-option');
    const applyBtn = this.element.querySelector('.gdp-apply');
    const copyBtn = this.element.querySelector('.gdp-copy');
    const pasteBtn = this.element.querySelector('.gdp-paste');
    const searchInput = this.element.querySelector('.gdp-search-input');
    const timezoneBtn = this.element.querySelector('.gdp-timezone-btn');
    const timezonePanel = this.element.querySelector('.gdp-timezone-panel');
    const timezoneChevron = this.element.querySelector('.gdp-timezone-chevron');
    const tzOptions = this.element.querySelectorAll('.gdp-tz-option');
    const tzSearch = this.element.querySelector('.gdp-timezone-search');

    // Centralized show/hide so every path that opens or closes this panel
    // (toggle button, Accept, Close, Reset, outside-click, Esc) keeps the
    // chevron's rotation in sync with the panel's visibility — rather
    // than each call site remembering to flip it individually. Defined up
    // here (not next to the other timezone wiring below) specifically so
    // documentClickHandler/documentKeydownHandler, which close this panel
    // too, can use the same two functions instead of toggling the raw
    // classList and forgetting the chevron.
    const hideTimezonePanel = () => {
      timezonePanel.classList.add('hidden');
      timezoneChevron?.classList.remove('rotate-180');
    };
    const showTimezonePanel = () => {
      timezonePanel.classList.remove('hidden');
      timezoneChevron?.classList.add('rotate-180');
    };

    // Toggle panel on click anywhere in the trigger (the icon spans
    // aren't real <button>s, but clicks on them bubble up to this same
    // handler via `trigger`, so the whole bar — icons included — behaves
    // consistently).
    //
    // This used to be open-only ("if (!this.isOpen) openPanel()"), which
    // meant clicking the trigger again while the panel was already open
    // did nothing — there was no way to close it from the trigger itself.
    //
    // A plain toggle based on `this.isOpen` at click time doesn't work
    // either, though: clicking the readonly display input fires `focus`
    // (which opens the panel, see below) BEFORE `click`, so by the time
    // this handler ran `this.isOpen` would already read true from that
    // same click — making the first click open-then-immediately-close.
    // Snapshotting the state on `mousedown` (which fires before focus)
    // sidesteps that: the click handler toggles based on what the state
    // was *before* this interaction started, not after focus already
    // changed it.
    let wasOpenBeforeThisInteraction = false;
    trigger.addEventListener('mousedown', () => {
      wasOpenBeforeThisInteraction = this.isOpen;
    });
    trigger.addEventListener('click', () => {
      if (wasOpenBeforeThisInteraction) {
        this.closePanel();
      } else {
        this.openPanel();
      }
    });

    // Recently-used entries: delegated from the (stable) container rather
    // than bound to individual buttons, since refreshRecentlyUsedUI()
    // replaces those buttons' innerHTML every time an item is added —
    // per-button listeners attached once here would be destroyed on the
    // very first re-render and silently stop working.
    //
    // Touch devices only ever deliver a single "click" per tap (no
    // separate dblclick without two deliberate taps), so a single tap
    // applies there. On a device with a real mouse, a single click is
    // reserved as a "did you mean this one?" affordance and only
    // dblclick actually applies — avoids misclicks instantly overwriting
    // the current range.
    const applyRecentOption = (opt) => {
      this.fromValue = opt.dataset.from;
      this.toValue = opt.dataset.to;
      this.selectedLabel = opt.dataset.label || null;

      // Write the raw from/to strings into the actual input fields,
      // verbatim — no resolving to resolved timestamps and no
      // substituting the quick-pick label (e.g. "Last 1 hour") in place
      // of its underlying "Last 1h"/"now" values. Previously these
      // fields were only synced in openPanel(), so a click here left them
      // showing whatever was last typed until the panel was reopened.
      const fromInput = this.element.querySelector('.gdp-from-input');
      const toInput = this.element.querySelector('.gdp-to-input');
      if (fromInput) fromInput.value = opt.dataset.from;
      if (toInput) toInput.value = opt.dataset.to;

      this.submit();
    };

    const recentlyUsedContainer = this.element.querySelector('.gdp-recently-used');
    recentlyUsedContainer?.addEventListener('click', (e) => {
      if (!this.isTouchDevice()) return;
      const opt = e.target.closest('.gdp-recent-option');
      if (opt) applyRecentOption(opt);
    });
    recentlyUsedContainer?.addEventListener('dblclick', (e) => {
      if (this.isTouchDevice()) return;
      const opt = e.target.closest('.gdp-recent-option');
      if (opt) applyRecentOption(opt);
    });

    // Clicking/tabbing into the readonly input focuses it (native cursor +
    // focus ring via focus-within) without allowing edits, and opens the
    // dropdown just like clicking the trigger wrapper.
    const displayInput = this.element.querySelector('.gdp-display');
    displayInput?.addEventListener('focus', () => {
      if (!this.isOpen) this.openPanel();
    });
    // Block actual text entry — readonly already does this for typing, but
    // this also stops paste/drag-drop from mutating the value.
    displayInput?.addEventListener('beforeinput', (e) => e.preventDefault());

    // Close on outside click. Store the handler references so they can be
    // removed in destroy() — otherwise every re-render/re-init would add
    // another document-level listener that never gets cleaned up.
    this.documentClickHandler = (e) => {
      if (!this.element.contains(e.target)) {
        if (this.isOpen) this.closePanel();
      }
      // Timezone panel closes on ANY click outside itself (and its toggle
      // button), even clicks elsewhere inside the main picker — not just
      // clicks outside the whole widget.
      if (
        !timezonePanel.classList.contains('hidden') &&
        !timezonePanel.contains(e.target) &&
        !timezoneBtn.contains(e.target)
      ) {
        hideTimezonePanel();
      }
      // Same rule for each From/To calendar popup.
      (this.calendarPopups || []).forEach(({ popup, toggleBtn }) => {
        if (!popup.classList.contains('hidden') && !popup.contains(e.target) && !toggleBtn.contains(e.target)) {
          popup.classList.add('hidden');
        }
      });
    };
    document.addEventListener('click', this.documentClickHandler);

    // Esc closes the topmost open popup: a calendar first, then timezone,
    // then the main panel.
    this.documentKeydownHandler = (e) => {
      if (e.key !== 'Escape') return;
      const openCalendar = (this.calendarPopups || []).find(({ popup }) => !popup.classList.contains('hidden'));
      if (openCalendar) {
        openCalendar.popup.classList.add('hidden');
      } else if (!timezonePanel.classList.contains('hidden')) {
        hideTimezonePanel();
      } else if (this.isOpen) {
        this.closePanel();
      }
    };
    document.addEventListener('keydown', this.documentKeydownHandler);

    // Quick option selection — remember the option's own label so the
    // trigger shows e.g. "Last 15 minutes" instead of resolved timestamps.
    quickOptions.forEach(opt => {
      opt.addEventListener('click', () => {
        this.fromValue = opt.dataset.from;
        this.toValue = opt.dataset.to;
        this.selectedLabel = opt.dataset.label;
        this.submit();
      });
    });

    // Apply button — custom range, so show resolved "YYYY-MM-DD HH:MM:SS to
    // YYYY-MM-DD HH:MM:SS" rather than a canned label.
    applyBtn?.addEventListener('click', () => {
      const from = this.element.querySelector('.gdp-from-input').value;
      const to = this.element.querySelector('.gdp-to-input').value;
      if (!this.validateRange(from, to)) return;
      this.fromValue = from;
      this.toValue = to;
      this.selectedLabel = null;
      this.submit();
    });

    // Calendar pickers for From/To: clicking the calendar icon opens a
    // small date grid; picking a day writes "YYYY-MM-DD" into that input
    // (focus-without-edit per the input itself is unaffected — only this
    // button opens/populates it) and closes the popup.
    this.setupCalendarToggle('from');
    this.setupCalendarToggle('to');

    // Copy/Paste buttons
    copyBtn?.addEventListener('click', () => {
      const fromInput = this.element.querySelector('.gdp-from-input');
      const toInput = this.element.querySelector('.gdp-to-input');
      const text = `${fromInput.value} to ${toInput.value}`;
      this.copyToClipboard(text, copyBtn);
    });

    pasteBtn?.addEventListener('click', () => {
      this.pasteFromClipboard(pasteBtn);
    });

    // Search quick options. Filters individual option rows, then hides
    // each group's header too if the query matched nothing inside that
    // group (an empty "Common" header with nothing under it reads as a
    // rendering bug, not "no results in this group"), and finally shows
    // a "No matches" message if the ENTIRE list comes up empty, so an
    // unmatched search doesn't look like the list silently broke.
    searchInput?.addEventListener('input', (e) => {
      const query = e.target.value.toLowerCase();
      let anyVisible = false;

      this.element.querySelectorAll('.gdp-quick-group').forEach(group => {
        let groupHasVisible = false;
        group.querySelectorAll('.gdp-quick-option').forEach(opt => {
          const matches = opt.textContent.toLowerCase().includes(query);
          opt.style.display = matches ? '' : 'none';
          if (matches) groupHasVisible = true;
        });
        group.style.display = groupHasVisible ? '' : 'none';
        if (groupHasVisible) anyVisible = true;
      });

      const noResults = this.element.querySelector('.gdp-quick-no-results');
      noResults?.classList.toggle('hidden', anyVisible);
    });

    // Timezone selector
    const timezoneResetBtn = this.element.querySelector('.gdp-timezone-reset');
    const timezoneAcceptBtn = this.element.querySelector('.gdp-timezone-accept');
    const timezoneCloseBtn = this.element.querySelector('.gdp-timezone-close');
    const timezoneDisplay = this.element.querySelector('.gdp-timezone-display');

    // Track a pending selection separately from the committed one, so
    // clicking an option just highlights it — it only takes effect when
    // "Accept" is pressed (mirrors Grafana's confirm/cancel pattern).
    this.pendingTimezone = timezoneDisplay.textContent;

    timezoneBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      const opening = timezonePanel.classList.contains('hidden');
      if (opening) {
        showTimezonePanel();
        this.pendingTimezone = timezoneDisplay.textContent;
        this.highlightTimezoneOption(this.pendingTimezone);
      } else {
        hideTimezonePanel();
      }
    });

    // Commits the staged (or just-clicked) timezone and closes the panel —
    // shared by the Accept button and double-clicking an option.
    const acceptTimezone = (tz) => {
      timezoneDisplay.textContent = tz;
      hideTimezonePanel();
    };

    // Selecting an option only stages it — doesn't close the panel or
    // commit the change yet.
    tzOptions.forEach(opt => {
      opt.addEventListener('click', () => {
        this.pendingTimezone = opt.dataset.tz;
        this.highlightTimezoneOption(this.pendingTimezone);
      });

      // Double-click is equivalent to selecting + hitting Accept in one step.
      opt.addEventListener('dblclick', () => {
        this.pendingTimezone = opt.dataset.tz;
        acceptTimezone(this.pendingTimezone);
      });
    });

    // Accept commits the staged selection.
    timezoneAcceptBtn?.addEventListener('click', () => {
      acceptTimezone(this.pendingTimezone);
    });

    // Close discards whatever was staged (no commit) and just hides the
    // panel — equivalent to clicking outside it or pressing Esc, but
    // reachable without leaving the panel first.
    timezoneCloseBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      hideTimezonePanel();
    });

    // Reset falls back to the browser's own timezone offset.
    timezoneResetBtn?.addEventListener('click', () => {
      const browserTz = this.detectBrowserTimezone();
      this.pendingTimezone = browserTz;
      timezoneDisplay.textContent = browserTz;
      this.highlightTimezoneOption(browserTz);
      hideTimezonePanel();
    });

    // Timezone search
    tzSearch?.addEventListener('input', (e) => {
      const query = e.target.value.toLowerCase();
      tzOptions.forEach(opt => {
        const text = opt.textContent.toLowerCase();
        opt.style.display = text.includes(query) ? '' : 'none';
      });
    });

    // Enter key to submit
    const inputs = this.element.querySelectorAll('.gdp-from-input, .gdp-to-input');
    inputs.forEach(input => {
      input.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
          const from = this.element.querySelector('.gdp-from-input').value;
          const to = this.element.querySelector('.gdp-to-input').value;
          if (!this.validateRange(from, to)) return;
          this.fromValue = from;
          this.toValue = to;
          this.submit();
        }
      });
    });
  }

  // Returns true (and clears any prior error) when `to` resolves to the
  // same instant or later than `from`. Shows an inline error and returns
  // false otherwise. Either side failing to resolve at all (e.g. mid-typing
  // garbage) is treated as "can't tell, so don't block" — only a definite
  // to < from is rejected.
  validateRange(from, to) {
    const errorEl = this.element.querySelector('.gdp-range-error');
    const fromDate = this.resolveDateExpr(from);
    const toDate = this.resolveDateExpr(to);

    if (fromDate && toDate && toDate.getTime() < fromDate.getTime()) {
      errorEl?.classList.remove('hidden');
      return false;
    }

    errorEl?.classList.add('hidden');
    return true;
  }

  // Briefly swaps an icon-only button's content for a check/x mark to
  // confirm a copy/paste action succeeded or failed, then restores it.
  showIconButtonFeedback(button, ok) {
    if (!button) return;
    const original = button.innerHTML;
    const iconName = ok ? 'hero-check' : 'hero-x-mark';
    button.innerHTML = `<span class="${iconName} w-4 h-4"></span>`;
    setTimeout(() => { button.innerHTML = original; }, 1200);
  }

  // Copies text to the clipboard, falling back to a hidden-textarea +
  // execCommand trick when the async Clipboard API is unavailable (e.g.
  // non-HTTPS origins, some embedded/WebView contexts) or denied by
  // permissions. Gives brief visual feedback on the button either way.
  copyToClipboard(text, button) {
    const showFeedback = (ok) => this.showIconButtonFeedback(button, ok);

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => showFeedback(true)).catch(() => {
        this.copyViaFallback(text) ? showFeedback(true) : showFeedback(false);
      });
    } else {
      this.copyViaFallback(text) ? showFeedback(true) : showFeedback(false);
    }
  }

  copyViaFallback(text) {
    try {
      const textarea = document.createElement('textarea');
      textarea.value = text;
      textarea.style.position = 'fixed';
      textarea.style.opacity = '0';
      document.body.appendChild(textarea);
      textarea.focus();
      textarea.select();
      const ok = document.execCommand('copy');
      document.body.removeChild(textarea);
      return ok;
    } catch (err) {
      console.error('Copy fallback failed:', err);
      return false;
    }
  }

  // Reads clipboard text and, if it looks like "<from> to <to>", fills the
  // From/To inputs. Falls back to a visible prompt() when the async
  // Clipboard API is unavailable or denied (readText has no execCommand
  // equivalent, so this is the only reliable fallback).
  pasteFromClipboard(button) {
    const applyText = (text) => {
      const parts = (text || '').split(' to ');
      if (parts.length === 2) {
        this.element.querySelector('.gdp-from-input').value = parts[0].trim();
        this.element.querySelector('.gdp-to-input').value = parts[1].trim();
        return true;
      }
      return false;
    };

    const showFeedback = (ok) => this.showIconButtonFeedback(button, ok);

    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText()
        .then((text) => showFeedback(applyText(text)))
        .catch((err) => {
          console.error('Failed to paste:', err);
          const manual = window.prompt('Paste blocked by browser — paste the range manually ("<from> to <to>"):');
          if (manual !== null) showFeedback(applyText(manual));
        });
    } else {
      const manual = window.prompt('Paste the range manually ("<from> to <to>"):');
      if (manual !== null) showFeedback(applyText(manual));
    }
  }

  // Visually marks which timezone option matches the given value, so the
  // list reflects the in-progress (not-yet-accepted) selection.
  highlightTimezoneOption(tz) {
    this.element.querySelectorAll('.gdp-tz-option').forEach(opt => {
      opt.classList.toggle('bg-base-200', opt.dataset.tz === tz);
    });
  }

  // Best-effort touch-device detection. Checked once and cached — media
  // queries (not just UA sniffing) catch most hybrid laptop/tablet cases,
  // but there's no fully reliable signal, hence "best-effort."
  isTouchDevice() {
    if (this._isTouchDevice === undefined) {
      this._isTouchDevice =
        (typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(pointer: coarse)').matches) ||
        'ontouchstart' in window ||
        navigator.maxTouchPoints > 0;
    }
    return this._isTouchDevice;
  }

  // Best-effort mapping from the browser's IANA offset to one of our
  // UTC±HH:MM labels, falling back to plain "UTC" if anything's off.
  detectBrowserTimezone() {
    const offsetMinutes = -new Date().getTimezoneOffset();
    if (offsetMinutes === 0) return 'UTC';

    const sign = offsetMinutes >= 0 ? '+' : '-';
    const abs = Math.abs(offsetMinutes);
    const hours = String(Math.floor(abs / 60)).padStart(2, '0');
    const minutes = String(abs % 60).padStart(2, '0');
    return `UTC${sign}${hours}:${minutes}`;
  }

  togglePanel() {
    if (this.isOpen) {
      this.closePanel();
    } else {
      this.openPanel();
    }
  }

  openPanel() {
    this.isOpen = true;
    const panel = this.element.querySelector('.gdp-panel');
    panel.classList.remove('hidden');
    this.element.querySelector('.gdp-chevron')?.classList.add('rotate-180');

    // Update inputs with current values
    const fromInput = this.element.querySelector('.gdp-from-input');
    const toInput = this.element.querySelector('.gdp-to-input');
    if (fromInput) fromInput.value = this.fromValue;
    if (toInput) toInput.value = this.toValue;
  }

  closePanel() {
    this.isOpen = false;
    const panel = this.element.querySelector('.gdp-panel');
    panel.classList.add('hidden');
    this.element.querySelector('.gdp-chevron')?.classList.remove('rotate-180');
  }

  static RECENTLY_USED_STORAGE_KEY = 'grafana-date-picker:recently-used';
  static RECENTLY_USED_MAX = 10;

  // Loads the persisted recently-used list from localStorage. Falls back
  // to an empty list if storage is unavailable (private browsing, etc.) or
  // the stored value is corrupt. Also drops any non-absolute (alphanumeric,
  // e.g. "Last 1h") entries that may have been saved by an older version
  // of this component before the absolute-date-only restriction existed —
  // those get purged here rather than left to linger.
  loadRecentlyUsed() {
    try {
      const raw = localStorage.getItem(GrafanaDatePicker.RECENTLY_USED_STORAGE_KEY);
      const parsed = raw ? JSON.parse(raw) : [];
      if (!Array.isArray(parsed)) return [];

      const filtered = parsed
        .filter(r => r && this.isAbsoluteDateRange(r.from, r.to))
        .slice(0, GrafanaDatePicker.RECENTLY_USED_MAX);

      if (filtered.length !== parsed.length) {
        // Persist the cleanup so we don't re-filter on every load.
        this.recentlyUsed = filtered;
        this.saveRecentlyUsed();
      }

      return filtered;
    } catch (err) {
      console.error('Failed to load recently-used ranges:', err);
      return [];
    }
  }

  saveRecentlyUsed() {
    try {
      localStorage.setItem(
        GrafanaDatePicker.RECENTLY_USED_STORAGE_KEY,
        JSON.stringify(this.recentlyUsed)
      );
    } catch (err) {
      console.error('Failed to persist recently-used ranges:', err);
    }
  }

  // A "numeric range" here means an explicit custom range (typed/applied
  // via the From/To inputs or pasted) rather than a quick-list pick —
  // those are what get saved to recently-used per the requirement that
  // selecting one is pushed to the top of the persisted, pickable list.
  addToRecentlyUsed(from, to, label) {
    const entry = { from, to, label: label || null, displayText: this.formatDisplay() };

    // Remove duplicate if exists, then add to front.
    this.recentlyUsed = this.recentlyUsed.filter(r => !(r.from === from && r.to === to));
    this.recentlyUsed.unshift(entry);
    // Cap at 10 entries.
    this.recentlyUsed = this.recentlyUsed.slice(0, GrafanaDatePicker.RECENTLY_USED_MAX);

    this.saveRecentlyUsed();
    this.refreshRecentlyUsedUI();
  }

  renderRecentlyUsed() {
    if (!this.recentlyUsed || this.recentlyUsed.length === 0) {
      return '<p class="text-xs text-base-content/40">None yet</p>';
    }

    return this.recentlyUsed.map(r => `
      <button
        type="button"
        class="gdp-recent-option w-full ${this.sz.recentOptPad} my-0 text-left text-[10px] leading-tight text-base-content hover:bg-base-200 rounded transition-colors whitespace-nowrap overflow-hidden text-ellipsis"
        data-from="${r.from}"
        data-to="${r.to}"
        data-label="${r.label || ''}"
        title="${r.displayText}"
      >
        ${r.displayText}
      </button>
    `).join('');
  }

  refreshRecentlyUsedUI() {
    const container = this.element.querySelector('.gdp-recently-used');
    if (!container) return;

    container.innerHTML = this.renderRecentlyUsed();
    // Click handling is delegated from the container (see
    // attachEventListeners) rather than bound per-button here, since this
    // method re-renders the buttons' innerHTML on every add — per-button
    // listeners would need re-attaching every time, and the initial
    // render (done directly in render(), not through this method) would
    // otherwise end up with no listener at all.
  }

  submit() {
    const display = this.formatDisplay();
    this.element.querySelector('.gdp-display').value = display || 'Select date range';
    this.updateTriggerTooltip();

    // Only absolute "YYYY-..." dates go into the recently-used list —
    // symbolic/alphanumeric expressions (quick-pick labels like
    // "Last 1 hour", or raw relative text like "Last 1h") are excluded,
    // since they're already one click away in the quick-list and aren't
    // meaningfully "recalled" the way a specific typed/pasted/calendar
    // date is.
    if (this.isAbsoluteDateRange(this.fromValue, this.toValue)) {
      this.addToRecentlyUsed(this.fromValue, this.toValue, this.selectedLabel);
    }

    this.closePanel();

    // Trigger LiveView event. Pass the symbolic label (e.g. "Last 1
    // hour") alongside the resolved from/to strings — the server stores
    // it and echoes it back via data-label on the next render, so
    // setValue() can restore the symbolic display instead of resolving
    // "Last 1h" into a timestamp that drifts from what the user chose.
    if (this.options.onSubmit) {
      this.options.onSubmit(this.fromValue, this.toValue, this.selectedLabel);
    }
  }

  // True when both sides begin with a 4-digit year — i.e. an absolute
  // "YYYY-MM-DD" / "YYYY-MM-DD HH:MM:SS" date — as opposed to a symbolic
  // or relative expression ("now", "Last 1h", a quick-pick label, etc.).
  // This is deliberately a prefix check, not a full date-format
  // validator: resolveDateExpr already handles rejecting malformed dates
  // elsewhere, so this only needs to classify "numeric-looking" vs. not.
  isAbsoluteDateRange(from, to) {
    const STARTS_WITH_YEAR = /^\d{4}-/;
    return STARTS_WITH_YEAR.test((from || '').trim()) && STARTS_WITH_YEAR.test((to || '').trim());
  }

  formatDisplay() {
    if (!this.fromValue || !this.toValue) return '';

    // A quick-list pick (e.g. "Last 15 minutes") shows its own label
    // rather than resolved timestamps.
    if (this.selectedLabel) return this.selectedLabel;

    return `${this.formatSideForDisplay(this.fromValue)} to ${this.formatSideForDisplay(this.toValue)}`;
  }

  // Shows a relative/symbolic expression ("now", "Last 3d") verbatim
  // rather than resolving it to a fixed point in time: resolving a
  // rolling window makes it look like a static range frozen at the
  // moment Apply was clicked, and that resolved value would silently
  // drift further from reality (or re-render differently) every time
  // "now" ticks forward. Only genuinely absolute input (literal
  // "YYYY-MM-DD..." text with no "now" in it) gets resolved + reformatted
  // — mainly to normalize a bare "2026-01-01" into the full
  // "2026-01-01 00:00:00". Falls back to the raw text if resolution fails.
  formatSideForDisplay(value) {
    const trimmed = (value || '').trim();
    if (/now/i.test(trimmed)) return trimmed;

    const resolved = this.resolveDateExpr(trimmed);
    return resolved ? this.formatDateForDisplay(resolved) : trimmed;
  }

  // Resolves "now", "now - 7 days", "Last 7d", "Sunday", "Last Sunday",
  // "1st day of this month", "End of last month", plain ISO dates, etc.
  // into a concrete JS Date, mirroring the server-side parser in
  // DagExecutionHistoryDemo so the displayed value matches what will
  // actually be queried. Grammar is deliberately kept in lockstep with
  // parse_date_expr/1 + parse_relative_date/2 there — every branch below
  // has a same-shaped counterpart on the server.
  resolveDateExpr(expr) {
    const trimmed = (expr || '').trim();
    if (!trimmed) return null;

    if (/^now$/i.test(trimmed)) return new Date();

    // "Sunday" / "Last Sunday" — most recent Sunday at midnight, or the
    // Sunday one week before that. Monday remains this app's own
    // week-start convention elsewhere (startOfIsoWeek, the calendar
    // grid); these two phrases exist purely as the specific vocabulary
    // "This week"/"Last week" are built from, not a switch to a
    // Sunday-start week model in general.
    if (/^Sunday$/i.test(trimmed)) return this.mostRecentSunday(new Date());
    if (/^Last\s+Sunday$/i.test(trimmed)) return this.addDays(this.mostRecentSunday(new Date()), -7);

    // "Last Sunday - 7 days" — anchors to the Sunday-before-last, then
    // applies a plain day offset on top. The " - N days" suffix is
    // intentionally only supported after "Last Sunday" (what "Last
    // week"'s own From needs), not as a fully general suffix grammar.
    const sundayOffsetMatch = trimmed.match(/^Last\s+Sunday\s*-\s*(\d+)\s*days?$/i);
    if (sundayOffsetMatch) {
      const amount = parseInt(sundayOffsetMatch[1], 10);
      const lastSunday = this.addDays(this.mostRecentSunday(new Date()), -7);
      return this.addDays(lastSunday, -amount);
    }

    // "1st day of this month" / "1st day of last month"
    const firstOfMonthMatch = trimmed.match(/^1st day of (this|last) month$/i);
    if (firstOfMonthMatch) {
      const base = firstOfMonthMatch[1].toLowerCase() === 'last' ? this.addMonths(new Date(), -1) : new Date();
      return this.startOfMonth(base);
    }

    // "End of last month" — 23:59:59 on the last calendar day of last
    // month, i.e. one second before this month's own 1st-day boundary.
    if (/^End of last month$/i.test(trimmed)) {
      const endOfLastMonth = this.addDays(this.startOfMonth(new Date()), -1);
      endOfLastMonth.setHours(23, 59, 59, 0);
      return endOfLastMonth;
    }

    // "now - 3 months" / "Last 3 months" — the one unit that's a whole
    // word rather than a single letter, and (unlike d/h/m/w) needs
    // calendar-aware month arithmetic rather than a fixed-length
    // Date.setX offset, so it's matched and handled separately before
    // the generic single-letter-unit pattern below.
    const monthsMatch = trimmed.match(/^(?:now\s*-|Last)\s+(\d+)\s+months?$/i);
    if (monthsMatch) {
      const amount = parseInt(monthsMatch[1], 10);
      return this.addMonths(new Date(), -amount);
    }

    // "now - 1 day" / "now - 15 minutes" — full-word units, space
    // separated from both the number and the "now -" prefix.
    const fullWordMatch = trimmed.match(/^now\s*-\s*(\d+)\s+(minutes?|hours?|days?|weeks?)$/i);
    if (fullWordMatch) {
      const amount = parseInt(fullWordMatch[1], 10);
      const unit = fullWordMatch[2].toLowerCase();
      const date = new Date();

      if (unit.startsWith('minute')) { date.setMinutes(date.getMinutes() - amount); return date; }
      if (unit.startsWith('hour')) { date.setHours(date.getHours() - amount); return date; }
      if (unit.startsWith('day')) { date.setDate(date.getDate() - amount); return date; }
      if (unit.startsWith('week')) { date.setDate(date.getDate() - amount * 7); return date; }
      return null;
    }

    // "Last 15m", "Last 7d", "Last 3w", "now - 7d" — single-letter unit
    // glued to the number, same as the server's
    // parse_relative_date_glued_unit/1.
    const relativeMatch = trimmed.match(/^(?:now\s*-|Last)\s+(\d+)\s*([a-z]+)$/i);
    if (relativeMatch) {
      const amount = parseInt(relativeMatch[1], 10);
      const unit = relativeMatch[2].toLowerCase();
      const date = new Date();

      switch (unit) {
        case 'm': date.setMinutes(date.getMinutes() - amount); return date;
        case 'h': date.setHours(date.getHours() - amount); return date;
        case 'd': date.setDate(date.getDate() - amount); return date;
        case 'w': date.setDate(date.getDate() - amount * 7); return date;
        default: return null;
      }
    }

    // Try parsing as an absolute date/time (ISO-ish formats)
    const parsed = new Date(trimmed.replace(' ', 'T'));
    return isNaN(parsed.getTime()) ? null : parsed;
  }

  // Midnight on the most recent Sunday on/before `date` (inclusive — if
  // `date` itself is a Sunday, returns that same day at midnight).
  mostRecentSunday(date) {
    const d = this.startOfDay(date);
    return this.addDays(d, -d.getDay()); // getDay(): Sun=0..Sat=6
  }

  // Formats a Date as "YYYY-MM-DD HH:MM:SS" in local time.
  formatDateForDisplay(date) {
    const pad = (n) => String(n).padStart(2, '0');
    const year = date.getFullYear();
    const month = pad(date.getMonth() + 1);
    const day = pad(date.getDate());
    const hours = pad(date.getHours());
    const minutes = pad(date.getMinutes());
    const seconds = pad(date.getSeconds());
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }

  // Formats a Date as "YYYY-MM-DD" (no time component) — used for the
  // "By day" quick options' absolute calendar-boundary values.
  formatDateOnly(date) {
    const pad = (n) => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  }

  // Formats a Date as "HH:MM:SS" (no date component) — seeds the calendar
  // popup's <input type="time"> field.
  formatTimeOnly(date) {
    const pad = (n) => String(n).padStart(2, '0');
    return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }

  startOfDay(date) {
    const d = new Date(date);
    d.setHours(0, 0, 0, 0);
    return d;
  }

  addDays(date, n) {
    const d = new Date(date);
    d.setDate(d.getDate() + n);
    return d;
  }

  addMonths(date, n) {
    const d = new Date(date);
    d.setMonth(d.getMonth() + n);
    return d;
  }

  startOfMonth(date) {
    const d = this.startOfDay(date);
    d.setDate(1);
    return d;
  }

  // Monday-start week boundary (ISO 8601), matching Grafana's own
  // "This week"/"Last week" semantics.
  startOfIsoWeek(date) {
    const d = this.startOfDay(date);
    const isoDay = d.getDay() === 0 ? 7 : d.getDay(); // Sun=0 -> 7
    return this.addDays(d, 1 - isoDay);
  }

  // Wires the calendar-icon button + popup for one of the From/To inputs
  // (side is 'from' or 'to'). Each side gets its own independent month
  // cursor so navigating one doesn't disturb the other.
  setupCalendarToggle(side) {
    const toggleBtn = this.element.querySelector(`.gdp-calendar-toggle-${side}`);
    const popup = this.element.querySelector(`.gdp-calendar-popup-${side}`);
    const input = this.element.querySelector(`.gdp-${side}-input`);
    if (!toggleBtn || !popup || !input) return;

    const state = { month: this.startOfMonth(new Date()) };

    const renderInto = () => {
      popup.innerHTML = this.renderCalendar(state.month, input.value);
      popup.querySelector('.gdp-cal-prev')?.addEventListener('click', (e) => {
        e.stopPropagation();
        state.month = this.addMonths(state.month, -1);
        renderInto();
      });
      popup.querySelector('.gdp-cal-next')?.addEventListener('click', (e) => {
        e.stopPropagation();
        state.month = this.addMonths(state.month, 1);
        renderInto();
      });
      const timeInput = popup.querySelector('.gdp-cal-time');

      // Combines whatever day was clicked (or is already selected) with
      // the time field's current value and writes it into the From/To
      // input, then closes the popup. Shared by both the day buttons and
      // the Set button so either path produces the same "YYYY-MM-DD
      // HH:MM:SS" format.
      const commit = (dateKey) => {
        const time = timeInput?.value || '00:00:00';
        // <input type="time"> gives "HH:MM" normally and "HH:MM:SS" only
        // when seconds are actually edited — pad to a full HH:MM:SS so
        // resolveDateExpr's absolute-date branch parses it consistently.
        const fullTime = time.length === 5 ? `${time}:00` : time;
        input.value = `${dateKey} ${fullTime}`;
        popup.classList.add('hidden');
      };

      popup.querySelectorAll('.gdp-cal-day').forEach(dayEl => {
        dayEl.addEventListener('click', (e) => {
          e.stopPropagation();
          // Clicking a day commits immediately using whatever time is
          // currently in the time field (defaults to midnight) — matches
          // how the quick-pick list behaves (one click = done), while the
          // time field + Set button cover adjusting time without
          // re-opening/re-finding the same day.
          commit(dayEl.dataset.date);
        });
      });

      popup.querySelector('.gdp-cal-set')?.addEventListener('click', (e) => {
        e.stopPropagation();
        const selectedDay = popup.querySelector('.gdp-cal-day.bg-primary')?.dataset.date
          || this.formatDateOnly(new Date());
        commit(selectedDay);
      });

      // Keep clicks/keystrokes inside the time input from bubbling to the
      // outside-click handler and closing the popup mid-edit.
      timeInput?.addEventListener('click', (e) => e.stopPropagation());
    };

    toggleBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const opening = popup.classList.contains('hidden');
      // Close the other side's popup if open, so only one calendar shows
      // at a time.
      this.element.querySelectorAll('.gdp-calendar-popup-from, .gdp-calendar-popup-to').forEach(p => {
        if (p !== popup) p.classList.add('hidden');
      });
      if (opening) {
        // Start the grid on whatever month the input currently resolves
        // to (falls back to today's month for relative/unparseable text).
        const resolved = this.resolveDateExpr(input.value);
        state.month = this.startOfMonth(resolved || new Date());
        renderInto();
        // Since the popup is `fixed`, its position is no longer inherited
        // from a `relative` CSS ancestor — anchor it to the INPUT's actual
        // viewport position (not the calendar-icon button, which sits at
        // the input's right edge — anchoring there would start the popup
        // partway across the input instead of flush with its left edge).
        // The 256px-wide calendar is wider than the input column it opens
        // from, so clamp the left edge to avoid overflowing off the right
        // of the window. `clientWidth` (not `innerWidth`) is used because
        // it excludes the scrollbar's own width — using innerWidth here
        // let the popup's right edge land just past the true visible
        // viewport, which is itself what re-triggered a horizontal
        // scrollbar on the parent.
        const rect = input.getBoundingClientRect();
        const popupWidth = 256; // matches renderCalendar's w-64
        const maxLeft = document.documentElement.clientWidth - popupWidth - 8;
        popup.style.top = `${rect.bottom + 4}px`;
        popup.style.left = `${Math.min(rect.left, Math.max(8, maxLeft))}px`;
      }
      popup.classList.toggle('hidden');
    });

    // Register with the shared outside-click/Esc handlers.
    this.calendarPopups = this.calendarPopups || [];
    this.calendarPopups.push({ popup, toggleBtn });
  }

  // Renders a single month grid + time-of-day input for the calendar
  // popup. `selectedValue` is the input's raw current text — if it
  // resolves to a date in this month, that day is highlighted and its
  // time (if any) seeds the time field; otherwise the time field defaults
  // to midnight. The grid alone only carries day resolution, so a visible
  // time input is required to let the user pick anything more precise.
  renderCalendar(month, selectedValue) {
    const WEEKDAY_LABELS = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
    const monthLabel = month.toLocaleString('default', { month: 'long', year: 'numeric' });
    const firstOfMonth = this.startOfMonth(month);
    const gridStart = this.startOfIsoWeek(firstOfMonth);
    const selectedDate = this.resolveDateExpr(selectedValue);
    const selectedKey = selectedDate ? this.formatDateOnly(selectedDate) : null;
    const todayKey = this.formatDateOnly(new Date());
    const timeValue = selectedDate ? this.formatTimeOnly(selectedDate) : '00:00:00';

    let days = '';
    for (let i = 0; i < 42; i++) {
      const d = this.addDays(gridStart, i);
      const key = this.formatDateOnly(d);
      const inMonth = d.getMonth() === month.getMonth();
      const isSelected = key === selectedKey;
      const isToday = key === todayKey;

      days += `<button
        type="button"
        class="gdp-cal-day w-7 h-7 text-xs rounded flex items-center justify-center transition-colors
          ${inMonth ? 'text-base-content' : 'text-base-content/30'}
          ${isSelected ? 'bg-primary text-primary-content' : 'hover:bg-base-200'}
          ${isToday && !isSelected ? 'ring-1 ring-primary' : ''}"
        data-date="${key}"
      >${d.getDate()}</button>`;
    }

    return `
      <div class="bg-base-100 border border-base-300 rounded-lg shadow-xl p-3 w-75">
        <div class="flex items-center justify-between mb-2">
          <button type="button" class="gdp-cal-prev p-1 hover:bg-base-200 rounded text-base-content">${ICONS.chevronDown('w-4 h-4 rotate-90')}</button>
          <span class="text-sm text-base-content font-medium">${monthLabel}</span>
          <button type="button" class="gdp-cal-next p-1 hover:bg-base-200 rounded text-base-content">${ICONS.chevronDown('w-4 h-4 -rotate-90')}</button>
        </div>
        <div class="grid grid-cols-7 gap-0.5 mb-1">
          ${WEEKDAY_LABELS.map(w => `<div class="text-[10px] text-base-content/40 text-center">${w}</div>`).join('')}
        </div>
        <div class="grid grid-cols-7 gap-0.5 mb-3">
          ${days}
        </div>
        <div class="flex items-center gap-2 pt-2 border-t border-base-300">
          <label class="text-xs text-base-content/50 shrink-0">Time</label>
          <input
            type="time"
            step="1"
            class="gdp-cal-time flex-1 px-2 py-1 bg-field border border-base-300 rounded text-field-content text-xs focus:outline-none focus:border-focus"
            value="${timeValue}"
          />
          <button type="button" class="gdp-cal-set px-2 py-1 bg-primary hover:bg-primary/90 text-primary-content text-xs font-medium rounded transition-colors">Set</button>
        </div>
      </div>
    `;
  }

  // `label`, when provided, is the symbolic quick-pick label (e.g. "Last
  // 1 hour") that produced this from/to pair — passed through from the
  // server, which now stores whatever label accompanied the last
  // filter_by_date event. Previously this always reset to null, which
  // meant every server round-trip (even one that only echoed back the
  // same symbolic choice) silently replaced the label with resolved
  // timestamps. Omitting `label` (e.g. a caller with no symbolic concept)
  // still falls back to resolved/raw-expression display, same as before.
  setValue(from, to, label = null) {
    this.fromValue = from;
    this.toValue = to;
    this.selectedLabel = label;
    const display = this.formatDisplay();
    const displayEl = this.element.querySelector('.gdp-display');
    if (displayEl) {
      displayEl.value = display || 'Select date range';
    }
    this.updateTriggerTooltip();
  }

  // Sets (or clears) a native `title` tooltip on the trigger input: when
  // the current from/to isn't a plain absolute "YYYY-..." range — i.e.
  // it's symbolic/relative ("now", "Last 7d", a quick-pick label) —
  // hovering shows what that actually resolves to right now, since the
  // visible text alone doesn't tell you the concrete dates being
  // queried. A native `title` (rather than a custom-built popup) is
  // used deliberately: it needs no positioning/z-index/outside-click
  // handling of its own and works identically on every platform.
  updateTriggerTooltip() {
    const displayEl = this.element.querySelector('.gdp-display');
    if (!displayEl) return;

    if (!this.fromValue || !this.toValue || this.isAbsoluteDateRange(this.fromValue, this.toValue)) {
      displayEl.removeAttribute('title');
      return;
    }

    const fromDate = this.resolveDateExpr(this.fromValue);
    const toDate = this.resolveDateExpr(this.toValue);
    if (!fromDate || !toDate) {
      displayEl.removeAttribute('title');
      return;
    }

    displayEl.title = `${this.formatDateForDisplay(fromDate)} to ${this.formatDateForDisplay(toDate)}`;
  }
}

// Export for use in Phoenix LiveView hooks
window.GrafanaDatePicker = GrafanaDatePicker;
