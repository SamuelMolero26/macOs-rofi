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

    /// `displayNames` defaults to the mode names. `modes` must not be empty.
    public init(
        modes: [any Mode],
        displayNames: [String]? = nil,
        start: Int = 0,
        query: String = "",
        match: MatchOptions = MatchOptions()
    ) {
        precondition(!modes.isEmpty, "a switcher needs a mode")
        self.modes = modes
        self.displayNames = displayNames ?? modes.map(\.name)
        self.match = match
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
    public mutating func accept() -> Bool {
        perform(highlightedSourceIndex == nil ? .customInput : .ok)
    }

    @discardableResult
    public mutating func cancel() -> Bool {
        perform(.cancel)
    }

    /// Hands `action` to the current mode and applies its result
    /// (source/rofi.c:235-291). Custom input and cancel carry no row
    /// (source/view.c:1296-1301). Returns false once the switcher is closed.
    @discardableResult
    public mutating func perform(_ action: MenuAction) -> Bool {
        guard isOpen else { return false }
        // ponytail: cancel passes no row; upstream passes a stale selected_line.
        let selectedRow = action == .customInput || action == .cancel ? nil : highlightedSourceIndex
        var input: String? = query
        let mode = current
        let result = mode.result(action, input: &input, selectedRow: selectedRow)
        let requestedRow = mode.selectedRowAfterResult
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
            // ponytail: upstream searches the matches from before the reload,
            // then clamps. Unsorted, source row 0 (the only row script mode
            // requests so far) lands on the first visible row either way.
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
    /// ponytail: no sorting; `-sort` is off by default (config/config.c).
    private mutating func refilter() {
        let mode = current
        let rows = mode.rows
        let matcher = Matcher(query: query, options: match)
        matches = rows.enumerated().compactMap { index, row in
            query.isEmpty || mode.matches(row, matcher: matcher) ? DmenuMatch(sourceIndex: index, row: row) : nil
        }
        selectedVisibleIndex = matches.isEmpty ? nil : min(selectedVisibleIndex ?? 0, matches.count - 1)
    }
}
