/// The `-show` view state over several modes: which mode is current, the
/// query and its matches, and how a mode's result moves between modes
/// (source/rofi.c:201-291, source/view.c:2150-2177).
public struct ModeSwitcher {
    public let modes: [any Mode]
    /// Prompt, title and switcher button text per mode (source/mode.c:189-208).
    public let displayNames: [String]
    public private(set) var currentIndex: Int
    public private(set) var query: String
    /// Visible rows of the current mode with their source positions.
    public private(set) var matches: [DmenuMatch] = []
    public private(set) var selectedVisibleIndex: Int?
    /// False once a mode answered `.exit`.
    public private(set) var isOpen = true

    /// `-show` matching follows rofi's global defaults, case-insensitive
    /// unless configured (config/config.c:108-130, source/helper.c:1672-1691);
    /// only dmenu forces case sensitivity (source/modes/dmenu.c:605-608).
    public let match: MatchOptions
    public let sort: Bool
    public let sortingMethod: SortingMethod
    public let cycle: Bool

    /// `displayNames` defaults to the mode names. `modes` must not be empty.
    public init(
        modes: [any Mode],
        displayNames: [String]? = nil,
        start: Int = 0,
        query: String = "",
        match: MatchOptions = MatchOptions(),
        sort: Bool = false,
        sortingMethod: SortingMethod = .levenshtein,
        cycle: Bool = true
    ) {
        precondition(!modes.isEmpty, "a switcher needs a mode")
        self.modes = modes
        self.displayNames = displayNames ?? modes.map(\.name)
        self.match = match
        self.sort = sort
        self.sortingMethod = sortingMethod
        self.cycle = cycle
        self.query = query
        currentIndex = start
        selectedVisibleIndex = 0
        refilter()
    }

    public var current: any Mode { modes[currentIndex] }
    /// The prompt shows the display name (source/view.c:222-227).
    public var prompt: String { displayName(at: currentIndex) }

    /// `mode_get_display_name` (source/mode.c:189-203): the mode's own name
    /// first, then `-display-<name>` or the name.
    public func displayName(at index: Int) -> String {
        modes[index].displayName ?? displayNames[index]
    }
    /// source/view.c:2156-2159.
    public var windowTitle: String { "rofi - \(prompt)" }
    public var message: String? { current.message }

    public mutating func updateQuery(_ query: String) {
        self.query = query
        selectedVisibleIndex = 0
        refilter()
    }

    public mutating func selectVisibleIndex(_ index: Int?) {
        selectedVisibleIndex = index.flatMap { matches.indices.contains($0) ? $0 : nil }
    }

    /// kb-row-up/kb-row-down. Single steps wrap past the ends unless `-no-cycle`
    /// (`cycle`, config/config.c:115); larger jumps always clamp.
    public mutating func moveSelection(by offset: Int) {
        guard let current = selectedVisibleIndex else { return }
        let target = current + offset
        if cycle, abs(offset) == 1, !matches.isEmpty {
            selectedVisibleIndex = (target + matches.count) % matches.count
        } else {
            selectedVisibleIndex = min(max(target, 0), matches.count - 1)
        }
    }

    /// kb-mode-next (source/view.c:1122-1126, source/rofi.c:262-263).
    public mutating func next() {
        load((currentIndex + 1) % modes.count)
    }

    /// kb-mode-previous (source/view.c:1117-1121, source/rofi.c:264-269).
    public mutating func previous() {
        load(currentIndex == 0 ? modes.count - 1 : currentIndex - 1)
    }

    /// A switcher button click, MENU_QUICK_SWITCH (source/view.c:1614-1631,
    /// source/rofi.c:270-271).
    public mutating func switchTo(_ index: Int) {
        // ponytail: upstream indices are unsigned; a negative one wraps here.
        load(((index % modes.count) + modes.count) % modes.count)
    }

    /// kb-accept-entry: the selected row, or the query as custom input when
    /// nothing is selected (source/view.c:1308-1319). False once closed.
    @discardableResult
    public mutating func accept(alt: Bool = false) -> Bool {
        perform(highlightedSourceIndex == nil ? .customInput : .ok, alt: alt)
    }

    @discardableResult
    public mutating func cancel() -> Bool {
        perform(.cancel)
    }

    /// A keymap action as the return value source/view.c:1148-1199,
    /// 1280-1306 sets for it. False once closed.
    @discardableResult
    public mutating func perform(key action: KeyAction) -> Bool {
        switch action {
        // MENU_OK | MENU_CUSTOM_ACTION, or MENU_CUSTOM_INPUT | MENU_CUSTOM_ACTION
        // with no visible row (view.c:1280-1293).
        case .acceptAlt:
            return accept(alt: true)
        // MENU_CUSTOM_INPUT, no row (view.c:1295-1301); the alt adds
        // MENU_CUSTOM_ACTION (1302-1309).
        case .acceptCustom:
            return perform(.customInput)
        case .acceptCustomAlt:
            return perform(.customInput, alt: true)
        // MENU_CUSTOM_COMMAND carries `action - CUSTOM_1` (view.c:1199).
        case .customKey(let n):
            return perform(.customKey(n - 1))
        // Ignored without a visible row (view.c:1148-1155).
        case .deleteEntry:
            guard highlightedSourceIndex != nil else { return isOpen }
            return perform(.deleteEntry)
        // MENU_COMPLETE with the highlighted source row, or none
        // (view.c:1128-1136). A mode without completion ignores it.
        case .modeComplete:
            guard isOpen else { return false }
            var input: String? = query
            let mode = current
            guard let result = mode.complete(input: &input, selectedRow: highlightedSourceIndex) else { return isOpen }
            return apply(result, input: input, requestedRow: mode.selectedRowAfterResult)
        case .rowTab, .pagePrev, .pageNext, .rowFirst, .rowLast, .selectRow:
            return isOpen
        }
    }

    /// Hands `action` to the current mode and applies its result
    /// (source/rofi.c:235-291). Custom input and cancel carry no row
    /// (source/view.c:1296-1301). `alt` is MENU_CUSTOM_ACTION. Returns false
    /// once the switcher is closed.
    @discardableResult
    public mutating func perform(_ action: MenuAction, alt: Bool = false) -> Bool {
        guard isOpen else { return false }
        // ponytail: cancel passes no row; upstream passes a stale selected_line.
        let selectedRow = action == .customInput || action == .cancel ? nil : highlightedSourceIndex
        var input: String? = query
        let mode = current
        let result = mode.result(action, alt: alt, input: &input, selectedRow: selectedRow)
        return apply(result, input: input, requestedRow: mode.selectedRowAfterResult)
    }

    /// Applies a mode's answer and its rewritten input (source/rofi.c:235-291).
    private mutating func apply(_ result: ModeResult, input: String?, requestedRow: Int?) -> Bool {
        // source/rofi.c:243-251: nil clears the input, anything else replaces it.
        query = input ?? ""
        switch result {
        case .exit:
            isOpen = false
        case .next:
            next()
        case .previous:
            previous()
        case .reload:
            load(currentIndex)
        case .reset:
            // source/view.c:2138-2143.
            // ponytail: upstream selects the old visible position of source
            // row 0, which after clearing is usually the first row.
            query = ""
            selectedVisibleIndex = 0
            load(currentIndex)
        case .switchTo(let index):
            switchTo(index)
        }
        if let requestedRow {
            // view.c:369-382: the requested source row's visible position,
            // else the first. ponytail: upstream searches the matches from
            // before the reload; they differ only under keep-filter when the
            // new rows reorder.
            selectedVisibleIndex = matches.isEmpty ? nil : matches.firstIndex { $0.sourceIndex == requestedRow } ?? 0
        }
        return isOpen
    }

    private var highlightedSourceIndex: Int? {
        selectedVisibleIndex.map { matches[$0].sourceIndex }
    }

    /// rofi_view_switch_mode: re-read the rows and refilter, keeping the query
    /// (source/view.c:2150-2177).
    private mutating func load(_ index: Int) {
        currentIndex = index
        refilter()
    }

    /// An empty query shows every row without asking the mode
    /// (source/view.c:829-917). The visible selection is kept, clamped to the
    /// new matches (source/widgets/listview.c:614-623, 651-656).
    ///
    private mutating func refilter() {
        let mode = current
        let rows = mode.rows
        // view.c:833-836: the mode's preprocessed query is matched and scored.
        let pattern = query.isEmpty ? "" : mode.preprocessInput(query)
        let matcher = Matcher(query: pattern, options: match)
        matches = rows.enumerated().compactMap { index, row in
            query.isEmpty || mode.matches(row, at: index, matcher: matcher)
                ? DmenuMatch(sourceIndex: index, row: row) : nil
        }
        if sort {
            matches = sortedByScore(matches, query: pattern, match: match, method: sortingMethod) {
                mode.completion(at: $0.sourceIndex)
            }
        }
        selectedVisibleIndex = matches.isEmpty ? nil : min(selectedVisibleIndex ?? 0, matches.count - 1)
    }
}
