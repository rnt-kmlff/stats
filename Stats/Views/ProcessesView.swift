import Cocoa
import Kit
import UserNotifications

final class ProcessesMonitor {
    static let shared = ProcessesMonitor()
    private static let preferencesKey = "ProcessesMonitor.Configuration.v1"
    private let queue = DispatchQueue(label: "eu.exelban.Stats.processes", qos: .utility, autoreleaseFrequency: .workItem)
    private let engine = ProcessesEngine()
    private var timer: DispatchSourceTimer?
    private var workerPaused = false
    private var sleeping = false
    private var tokens: [NSObjectProtocol] = []
    private var generation = 0
    private var workerGeneration = 0
    private(set) var configuration: ProcessesConfiguration
    private(set) var snapshot = ProcessesSnapshot()
    private(set) var status = "Waiting for first sample"
    private(set) var notificationStatus = "Alerts off"
    var onUpdate: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.preferencesKey),
           let decoded = try? JSONDecoder().decode(ProcessesConfiguration.self, from: data) {
            configuration = decoded.validated()
        } else { configuration = ProcessesConfiguration() }
        engine.configure(configuration)
        workerPaused = UserDefaults.standard.bool(forKey: "pause")
        tokens.append(NotificationCenter.default.addObserver(forName: .pause, object: nil, queue: .main) { [weak self] notification in
            let paused = notification.userInfo?["state"] as? Bool ?? false
            self?.queue.async { [weak self] in self?.workerPaused = paused; self?.tick() }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.sleeping = true; self?.tick() }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                _ = self.engine.pause(time: ProcessInfo.processInfo.systemUptime)
                self.sleeping = false; self.tick()
            }
        })
    }
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 5, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil } }
    func setConfiguration(_ newValue: ProcessesConfiguration) {
        let value = newValue.validated()
        configuration = value; generation += 1
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.preferencesKey) }
        let revision = generation
        queue.async { [weak self] in self?.workerGeneration = revision; self?.engine.configure(value); self?.tick() }
        refreshNotificationStatus()
    }
    func select(_ key: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.selectedKey = key
            self.publish(self.engine.snapshot(), status: nil)
        }
    }
    private func tick() {
        let time = ProcessInfo.processInfo.systemUptime
        guard engine.configuration.enabled, !workerPaused, !sleeping else {
            publish(engine.pause(time: time), status: sleeping ? "Sleeping" : workerPaused ? "Paused with Stats" : "Monitoring off")
            return
        }
        let scan = ProcessMemoryCollector.scan()
        var value = engine.update(scan.groups, complete: scan.complete, time: time, unknownPIDs: scan.unknownPIDs)
        value.limited = value.limited || scan.limited
        let sampled = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let status = !scan.complete ? "Process scan unavailable" : value.limited
            ? "Sample limit reached; some processes are omitted" : "Sampled \(sampled) · every 5 seconds"
        publish(value, status: status)
    }
    private func publish(_ value: ProcessesSnapshot, status: String?) {
        let revision = workerGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = value
            if let status { self.status = status }
            self.onUpdate?()
            if self.generation == revision && self.configuration.alerts && self.configuration.enabled && !UserDefaults.standard.bool(forKey: "pause") {
                value.alerts.forEach { self.sendAlert(title: $0.reason, body: "\($0.name): \(Self.memory($0.bytes)). Open Processes to inspect the history.") }
            }
        }
    }
    static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1073741824
        return gb >= 1 ? String(format: "%.2f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1048576)
    }
    func refreshNotificationStatus() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            center.getDeliveredNotifications { notifications in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let count = notifications.filter { $0.request.identifier.hasPrefix("Stats.Processes.") }.count
                    let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                    self.notificationStatus = "Notifications: \(allowed ? "allowed" : "not allowed") · \(count) process alert(s) delivered"
                    self.onUpdate?()
                }
            }
        }
    }
    func testNotification() { sendAlert(title: "Processes notification test", body: "Local process notifications are working. This test does not allocate memory.", test: true) }
    private func sendAlert(title: String, body: String, test: Bool = false) {
        let expectedGeneration = generation
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else { self.notificationStatus = "Notifications are disabled in macOS"; self.onUpdate?(); return }
                guard test || (self.generation == expectedGeneration && self.configuration.alerts && self.configuration.enabled && !UserDefaults.standard.bool(forKey: "pause")) else { return }
                let content = UNMutableNotificationContent()
                content.title = title; content.body = body; content.sound = .default
                let request = UNNotificationRequest(identifier: "Stats.Processes.\(UUID().uuidString)", content: content, trigger: nil)
                center.add(request) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.notificationStatus = error == nil ? "Alert queued: \(title)" : "Alert could not be queued"
                        self.onUpdate?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshNotificationStatus() }
                    }
                }
            }
        }
    }
}

final class ProcessesView: NSStackView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    private let monitor = ProcessesMonitor.shared
    private let outline = NSOutlineView()
    private let graph = ProcessHistoryGraph()
    private let summary = NSTextField(labelWithString: "")
    private let selectedTitle = NSTextField(labelWithString: "Select a row for history and custom alerts")
    private let notifications = NSTextField(labelWithString: "")
    private let validation = NSTextField(labelWithString: "")
    private var rows: [ProcessMemoryRow] = []
    private var selecting = false
    private var inspectorDirty = false
    private var displayedKey: String?
    private let enabled = NSButton(checkboxWithTitle: "Monitor processes", target: nil, action: nil)
    private let alerts = NSButton(checkboxWithTitle: "Memory alerts", target: nil, action: nil)
    private var inputs: [String: NSTextField] = [:]
    private let custom = NSButton(checkboxWithTitle: "Custom alerts for selected row", target: nil, action: nil)
    private let apply = NSButton(title: "Apply custom limits", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        let scroller = ScrollableStackView(orientation: .vertical)
        scroller.stackView.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        scroller.stackView.spacing = 12
        addArrangedSubview(scroller)
        scroller.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scroller.heightAnchor.constraint(equalTo: heightAnchor).isActive = true
        let stack = scroller.stackView
        let controls = NSStackView(views: [enabled, alerts])
        controls.orientation = .horizontal; controls.spacing = 20
        for button in [enabled, alerts] { button.target = self; button.action = #selector(changeToggles) }
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(label("Read-only · one hour of session history · peak since process discovery"))
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        stack.addArrangedSubview(summary)

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true
        tableScroll.borderType = .bezelBorder
        outline.headerView = NSTableHeaderView()
        outline.rowHeight = 24; outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (key, title, width) in [("name", "Process / group", 185.0), ("ram", "RAM", 70.0), ("peak", "Peak", 70.0), ("growth", "Δ 5 min", 70.0), ("status", "Status", 82.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = 55
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.delegate = self; outline.dataSource = self
        outline.setAccessibilityLabel("Watched process memory")
        tableScroll.documentView = outline
        tableScroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
        stack.addArrangedSubview(tableScroll)
        selectedTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(selectedTitle)
        graph.heightAnchor.constraint(equalToConstant: 110).isActive = true
        stack.addArrangedSubview(graph)
        stack.addArrangedSubview(label("Group RAM is the sum of member footprints. Separately listed local jobs are excluded from the app group. Gaps mean missing data; short spikes may be missed."))

        stack.addArrangedSubview(label("Default alert limits", bold: true))
        stack.addArrangedSubview(ruleRow("ChatGPT / Codex", budget: "assistantBudget", growth: "assistantGrowth"))
        stack.addArrangedSubview(ruleRow("Local jobs", budget: "jobsBudget", growth: "jobsGrowth"))
        let timing = NSStackView(views: [label("Hold (seconds)"), field("duration"), label("Cooldown (seconds)"), field("cooldown")])
        timing.orientation = .horizontal; timing.spacing = 8
        stack.addArrangedSubview(timing)
        let save = NSButton(title: "Save default limits", target: self, action: #selector(saveDefaults))
        stack.addArrangedSubview(save)
        custom.target = self; custom.action = #selector(toggleCustom)
        stack.addArrangedSubview(custom)
        stack.addArrangedSubview(ruleRow("Selected row", budget: "customBudget", growth: "customGrowth"))
        apply.target = self; apply.action = #selector(saveCustom)
        stack.addArrangedSubview(apply)
        stack.addArrangedSubview(NSButton(title: "Clear custom limits", target: self, action: #selector(clearCustom)))
        validation.textColor = .systemRed
        stack.addArrangedSubview(validation)
        let test = NSButton(title: "Test notification", target: self, action: #selector(testNotification))
        stack.addArrangedSubview(test)
        notifications.font = .systemFont(ofSize: 11); notifications.textColor = .secondaryLabelColor
        stack.addArrangedSubview(notifications)
        stack.addArrangedSubview(label("Local jobs include Node, Python and common build tools; names alone do not prove a build is running. " +
                                      "Shared app processes cannot identify an individual chat. History stays in memory and clears when Stats quits."))
        for view in stack.arrangedSubviews where view is NSTextField || view === tableScroll || view === graph {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        monitor.onUpdate = { [weak self] in self?.render() }
        loadControls(); render(); monitor.refreshNotificationStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 11)
        value.textColor = bold ? .labelColor : .secondaryLabelColor
        return value
    }
    private func field(_ key: String) -> NSTextField {
        let value = NSTextField(string: "")
        value.identifier = NSUserInterfaceItemIdentifier(key)
        value.delegate = self
        value.setAccessibilityLabel(fieldName(key))
        value.widthAnchor.constraint(equalToConstant: 60).isActive = true
        inputs[key] = value
        return value
    }
    private func ruleRow(_ title: String, budget: String, growth: String) -> NSStackView {
        let name = label(title); name.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [name, label("Budget GB"), field(budget), label("Growth GB / 5 min"), field(growth)])
        row.orientation = .horizontal; row.spacing = 6
        return row
    }
    private func loadControls() {
        let c = monitor.configuration
        enabled.state = c.enabled ? .on : .off; alerts.state = c.alerts ? .on : .off
        let values = [("assistantBudget", c.assistant.budgetGB), ("assistantGrowth", c.assistant.growthGB),
                      ("jobsBudget", c.jobs.budgetGB), ("jobsGrowth", c.jobs.growthGB),
                      ("duration", c.sustainedSeconds), ("cooldown", c.cooldownSeconds)]
        for (key, value) in values { inputs[key]?.stringValue = String(format: "%g", value) }
    }
    private func number(_ key: String, range: ClosedRange<Double>) -> Double? {
        guard let input = inputs[key], let value = Double(input.stringValue.replacingOccurrences(of: ",", with: ".")), value.isFinite, range.contains(value) else {
            validation.stringValue = "Enter \(range.lowerBound)–\(range.upperBound) for \(fieldName(key)). Changes were not saved."
            return nil
        }
        return value
    }
    @objc private func changeToggles() {
        var c = monitor.configuration
        c.enabled = enabled.state == .on; c.alerts = alerts.state == .on
        monitor.setConfiguration(c)
    }
    @objc private func saveDefaults() {
        guard let a = number("assistantBudget", range: 0.05...128), let ag = number("assistantGrowth", range: 0...128),
              let j = number("jobsBudget", range: 0.05...128), let jg = number("jobsGrowth", range: 0...128),
              let duration = number("duration", range: 5...300), let cooldown = number("cooldown", range: 30...3600) else { return }
        var c = monitor.configuration
        c.assistant = MemoryAlertRule(budgetGB: a, growthGB: ag); c.jobs = MemoryAlertRule(budgetGB: j, growthGB: jg)
        c.sustainedSeconds = duration; c.cooldownSeconds = cooldown
        monitor.setConfiguration(c); validation.stringValue = "Saved default limits. These notify; they do not cap or stop processes."
    }
    private func selectedRow() -> ProcessMemoryRow? { outline.item(atRow: outline.selectedRow) as? ProcessMemoryRow }
    @objc private func toggleCustom() { inspectorDirty = true; apply.isEnabled = selectedRow() != nil }
    @objc private func saveCustom() {
        guard let selected = selectedRow() else { return }
        var c = monitor.configuration
        if custom.state == .on {
            guard c.overrides[selected.key] != nil || c.overrides.count < 20 else { validation.stringValue = "The 20 custom-limit slots are full. Remove an existing custom limit first."; return }
            guard let budget = number("customBudget", range: 0.05...128), let growth = number("customGrowth", range: 0...128) else { return }
            c.overrides[selected.key] = MemoryAlertRule(budgetGB: budget, growthGB: growth)
        } else { c.overrides.removeValue(forKey: selected.key) }
        inspectorDirty = false
        monitor.setConfiguration(c); validation.stringValue = "Saved selected-row limits. They apply to this process lifetime."
    }
    @objc private func clearCustom() {
        var c = monitor.configuration; c.overrides = [:]; inspectorDirty = false
        monitor.setConfiguration(c); validation.stringValue = "Custom limits cleared; defaults still apply to groups."
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field.identifier?.rawValue.hasPrefix("custom") == true { inspectorDirty = true }
    }
    private func fieldName(_ key: String) -> String {
        let names = ["assistantBudget": "ChatGPT/Codex budget", "assistantGrowth": "ChatGPT/Codex growth",
                     "jobsBudget": "Local job budget", "jobsGrowth": "Local job growth", "customBudget": "Selected row budget",
                     "customGrowth": "Selected row growth", "duration": "Alert hold seconds", "cooldown": "Alert cooldown seconds"]
        return names[key] ?? key
    }
    @objc private func testNotification() { monitor.testNotification() }
    private func render() {
        let value = monitor.snapshot
        if displayedKey != value.selectedKey { displayedKey = value.selectedKey; inspectorDirty = false }
        var expanded: Set<String> = []
        for row in rows where outline.isItemExpanded(row) { expanded.insert(row.key) }
        selecting = true
        rows = value.rows; outline.reloadData()
        for row in rows where expanded.contains(row.key) { outline.expandItem(row) }
        if let key = value.selectedKey {
            if let parent = rows.first(where: { $0.children.contains(where: { $0.key == key }) }) { outline.expandItem(parent) }
            for index in 0..<outline.numberOfRows where (outline.item(atRow: index) as? ProcessMemoryRow)?.key == key {
                outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        selecting = false
        graph.points = value.history; graph.needsDisplay = true
        summary.stringValue = monitor.status
        notifications.stringValue = monitor.notificationStatus
        if let row = selectedRow() {
            selectedTitle.stringValue = "\(row.name) · PID \(row.pid) · one-hour history"
            let rule = monitor.configuration.overrides[row.key] ?? monitor.configuration.rule(for: row.kind)
            if !inspectorDirty && !(window?.firstResponder is NSTextView) {
                custom.state = monitor.configuration.overrides[row.key] == nil ? .off : .on
                inputs["customBudget"]?.stringValue = String(format: "%g", rule.budgetGB)
                inputs["customGrowth"]?.stringValue = String(format: "%g", rule.growthGB)
            }
            apply.isEnabled = true
        } else { selectedTitle.stringValue = "No matching processes; sampling continues"; apply.isEnabled = false }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? ProcessMemoryRow)?.children.count ?? rows.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? ProcessMemoryRow)?.children[index] ?? rows[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? ProcessMemoryRow)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? ProcessMemoryRow, let column = tableColumn else { return nil }
        let cell = NSTextField(labelWithString: "")
        cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: row.isGroup ? .medium : .regular)
        cell.lineBreakMode = .byTruncatingTail
        switch column.identifier.rawValue {
        case "name": cell.stringValue = "\(row.name) [\(row.pid)]"
        case "ram": cell.stringValue = row.current.map(ProcessesMonitor.memory) ?? "—"
        case "peak": cell.stringValue = ProcessesMonitor.memory(row.peak)
        case "growth": cell.stringValue = row.growth.map { String(format: "%+.2f GB", $0 / 1073741824) } ?? "—"
        default: cell.stringValue = row.status
        }
        cell.toolTip = cell.stringValue
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let row = selectedRow() else { return }
        inspectorDirty = false
        monitor.select(row.key)
    }
}

private final class ProcessHistoryGraph: NSView {
    var points: [MemoryHistoryPoint] = []
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let valid = points.compactMap { $0.bytes }
        guard let last = points.last, !valid.isEmpty else {
            ("Collecting history" as NSString).draw(at: NSPoint(x: 12, y: 45), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let maximum = max(Double(valid.max() ?? 1), 1048576)
        let start = max(points.first?.time ?? last.time, last.time - 3600)
        let duration = max(5, last.time - start)
        let path = NSBezierPath(); path.lineWidth = 1.6
        var continuing = false
        for point in points {
            guard let bytes = point.bytes else { continuing = false; continue }
            let p = NSPoint(x: 10 + (point.time - start) / duration * max(1, bounds.width - 20),
                            y: 20 + Double(bytes) / maximum * max(1, bounds.height - 40))
            if continuing { path.line(to: p) } else { path.move(to: p); continuing = true }
        }
        NSColor.controlAccentColor.setStroke(); path.stroke()
        let caption = "\(ProcessesMonitor.memory(valid.max() ?? 0)) max · \(Int(duration / 60)) min shown · gaps = unavailable"
        (caption as NSString).draw(at: NSPoint(x: 10, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
    }
}
