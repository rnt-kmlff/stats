//
//  Text.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 08/09/2024
//  Using Swift 5.0
//  Running on macOS 14.6
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//  

import Cocoa

public class TextWidget: WidgetWrapper {
    private var value: String = ""
    private var template: String = ""
    private var memoryObserver: NSObjectProtocol?
    private static let variableRegex = try? NSRegularExpression(pattern: "(\\$[a-zA-Z0-9_]+)(?:\\.([a-zA-Z0-9_]+))?")
    
    public init(title: String, preview: Bool = false) {
        super.init(.text, title: title, frame: CGRect(
            x: 0,
            y: Constants.Widget.margin.y,
            width: 30 + (2*Constants.Widget.margin.x),
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))
        
        if preview {
            self.value = "Text"
        }
        
        self.canDrawConcurrently = true
        self.memoryObserver = NotificationCenter.default.addObserver(forName: AssistantMemoryStore.didChange, object: AssistantMemoryStore.shared, queue: .main) { [weak self] _ in
            guard let self, self.queue.sync(execute: { AssistantMemoryTemplate.contains(self.template) }) else { return }
            self.refreshValue()
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        var value: String = ""
        self.queue.sync {
            value = self.value
        }
        
        if value.isEmpty {
            self.setWidth(0)
            return
        }
        
        let valueSize: CGFloat = 12
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let stringAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: valueSize, weight: .regular),
            NSAttributedString.Key.foregroundColor: NSColor.textColor,
            NSAttributedString.Key.paragraphStyle: style
        ]
        let attributedString = NSAttributedString(string: value, attributes: stringAttributes)
        let size = attributedString.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = (size.width+Constants.Widget.margin.x*2).roundedUpToNearestTen()
        let origin: CGPoint = CGPoint(x: Constants.Widget.margin.x, y: ((Constants.Widget.height-valueSize-1)/2))
        let rect = CGRect(x: origin.x, y: origin.y, width: width - (Constants.Widget.margin.x*2), height: valueSize)
        attributedString.draw(with: rect)
        
        self.setWidth(width)
    }
    
    public func setValue(_ newValue: String) {
        self.queue.sync { self.template = newValue }
        DispatchQueue.main.async { [weak self] in self?.refreshValue() }
    }

    // Called on the main queue, including when process sampling pauses while RAM readers stop.
    private func refreshValue() {
        var text = self.queue.sync { self.template }
        var help: String?
        if AssistantMemoryTemplate.contains(text) {
            let sample = AssistantMemoryStore.shared.current()
            let memory = sample.text { Units(bytes: Int64(clamping: $0)).getReadableMemory(style: .memory) }
            text = AssistantMemoryTemplate.render(text, value: memory)
            help = "ChatGPT / Codex: " + memory + " · " + sample.status.rawValue +
                ". Sum of observed app-family process footprints; separate local-job groups are excluded. This is app memory, not per-chat allocation."
        }
        self.toolTip = help
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel(text)
        self.setAccessibilityHelp(help)
        let updated = self.queue.sync { () -> Bool in
            guard self.value != text else { return false }
            self.value = text
            return true
        }
        if updated { self.needsDisplay = true }
    }

    static public func parseText(_ raw: String) -> [KeyValue_t] {
        var pairs: [KeyValue_t] = []
        guard let regex = TextWidget.variableRegex else { return pairs }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: raw) {
                let key = String(raw[keyRange])
                let value: String?
                if match.range(at: 2).location != NSNotFound, let valueRange = Range(match.range(at: 2), in: raw) {
                    value = String(raw[valueRange])
                } else {
                    value = nil
                }
                pairs.append(KeyValue_t(key: key, value: value ?? ""))
            }
        }
        return pairs
    }
}
