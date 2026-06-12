//
//  ChatView+SwipeActions.swift
//  Chat
//

import SwiftUI

/// A simple container for both the leading and trailing swipe actions
struct ListSwipeActions {
    let leading: ListSwipeAction?
    let trailing: ListSwipeAction?
    
    init(leading: ListSwipeAction? = nil, trailing: ListSwipeAction? = nil) {
        self.leading = leading
        self.trailing = trailing
    }
}

/// A container for either leading or trailing swipe actions and wether they support fullSwipe actions
struct ListSwipeAction {
    let performsFirstActionWithFullSwipe: Bool
    let actions: [SwipeAction]
}

public struct SwipeAction {
    let action: (Message, @escaping (Message, DefaultMessageMenuAction) -> Void) -> Void
    let activeFor: (Message) -> Bool
    let background: Color?
    private let conversationImage: UIImage
    private let commentsImage: UIImage

    @MainActor
    public init<V: View>(
        action: @escaping (Message, @escaping (Message, DefaultMessageMenuAction) -> Void) -> Void,
        activeFor: @escaping (Message) -> Bool = { _ in true},
        background: Color? = nil,
        @ViewBuilder content: @escaping () -> V
    ) {
        self.background = background
        self.action = action
        self.activeFor = activeFor
        let content = AnyView(content())
        self.conversationImage = SwipeAction.renderImage(content.rotationEffect(.degrees(180)))
        self.commentsImage = SwipeAction.renderImage(content.rotationEffect(.degrees(0)))
    }
    
    func render(type: ChatType) -> UIImage {
        type == .conversation ? conversationImage : commentsImage
    }

    @MainActor
    private static func renderImage<Content: View>(_ content: Content) -> UIImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage!
    }
}
