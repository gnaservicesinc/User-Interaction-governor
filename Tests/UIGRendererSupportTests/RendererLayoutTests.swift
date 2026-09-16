import AppKit
import Testing
@testable import UIGRendererSupport

@Test @MainActor
func scrollableTextHasADrawableDocumentAndGlyphArea() throws {
    let text = "The Govoner is ready."
    let (scroll, textView) = RendererLayout.makeScrollableTextView(
        text: text, editable: false, height: 96, border: .noBorder
    )
    scroll.layoutSubtreeIfNeeded()
    let container = try #require(textView.textContainer)
    let manager = try #require(textView.layoutManager)
    manager.ensureLayout(for: container)

    #expect(scroll.documentView === textView)
    #expect(textView.string == text)
    #expect(textView.frame.width > 0)
    #expect(textView.frame.height > 0)
    #expect(manager.glyphRange(for: container).length == text.utf16.count)
    #expect(manager.usedRect(for: container).width > 0)
    #expect(manager.usedRect(for: container).height > 0)
    #expect(textView.textColor == .labelColor)
}

@Test @MainActor
func editableTextUsesTheSameNonzeroDocumentSizing() {
    let (scroll, textView) = RendererLayout.makeScrollableTextView(
        text: "Starting value", editable: true, height: 120, border: .bezelBorder
    )
    #expect(scroll.documentView === textView)
    #expect(textView.isEditable)
    #expect(textView.frame.size == scroll.contentSize)
}

@Test @MainActor
func longTextExpandsTheDocumentForScrolling() throws {
    let text = (1...100).map { "Line \($0): visible message text" }.joined(separator: "\n")
    let (scroll, textView) = RendererLayout.makeScrollableTextView(
        text: text, editable: false, height: 96, border: .noBorder
    )
    let container = try #require(textView.textContainer)
    let manager = try #require(textView.layoutManager)
    manager.ensureLayout(for: container)
    #expect(manager.usedRect(for: container).height > scroll.contentSize.height)
    #expect(textView.frame.height > scroll.contentSize.height)
}

@Test
func requestedMediaWindowDimensionsOverrideDefaultsAndFitTheScreen() {
    #expect(RendererLayout.fittedMediaWindowSize(
        defaultSize: NSSize(width: 720, height: 480),
        requestedWidth: 640, requestedHeight: 360,
        visibleSize: NSSize(width: 1200, height: 800)
    ) == NSSize(width: 640, height: 360))
    #expect(RendererLayout.fittedMediaWindowSize(
        defaultSize: NSSize(width: 720, height: 480),
        requestedWidth: 2000, requestedHeight: nil,
        visibleSize: NSSize(width: 1200, height: 800)
    ) == NSSize(width: 960, height: 480))
}
