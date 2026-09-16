import AppKit

public enum RendererLayout {
    public static func makeScrollableTextView(
        text: String,
        editable: Bool,
        height: CGFloat,
        border: NSBorderType
    ) -> (NSScrollView, NSTextView) {
        // NSScrollView does not size its document view with Auto Layout. A default
        // NSTextView has a zero frame, leaving its text present but invisible.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: height))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = border
        scroll.drawsBackground = editable

        let contentSize = scroll.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = editable
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = text
        scroll.documentView = textView
        return (scroll, textView)
    }

    public static func fittedMediaWindowSize(
        defaultSize: NSSize,
        requestedWidth: Int?,
        requestedHeight: Int?,
        visibleSize: NSSize
    ) -> NSSize {
        let requested = NSSize(
            width: requestedWidth.map(CGFloat.init) ?? defaultSize.width,
            height: requestedHeight.map(CGFloat.init) ?? defaultSize.height
        )
        return NSSize(
            width: min(requested.width, visibleSize.width * 0.8),
            height: min(requested.height, visibleSize.height * 0.8)
        )
    }
}
