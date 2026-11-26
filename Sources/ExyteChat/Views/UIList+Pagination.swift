//
//  UIList+Pagination.swift
//  Chat
//
//  Created by Alisa Mylnikova on 05.05.2026.
//

import SwiftUI
import ActivityIndicatorView

final class PaginationState: ObservableObject {
    @Published var olderInProgress = false
    @Published var newerInProgress = false
}

struct HeaderView<TopContent: View>: View {
    @ObservedObject var paginationState: PaginationState

    let isFirst: Bool
    let type: ChatType
    let handler: PaginationHandler?

    let topContent: () -> TopContent

    var body: some View {
        VStack(spacing: 0) {
            if paginationState.newerInProgress, let handler, isFirst {
                handler.loadingIndicatorBuilder()
            }
            if type == .comments {
                topContent()
            }
        }
    }
}

struct FooterView<TopContent: View>: View {
    @ObservedObject var paginationState: PaginationState

    let isLast: Bool
    let type: ChatType
    let handler: PaginationHandler?

    let topContent: () -> TopContent

    var body: some View {
        VStack(spacing: 0) {
            if paginationState.olderInProgress, let handler, isLast {
                handler.loadingIndicatorBuilder()
            }
            if type == .conversation {
                topContent()
            }
        }
    }
}

extension UITableView {
    /// Updates header and footer heights, such as a loading row's, without a full reload.
    /// Unanimated, because an animated update animates the table's bounds while a fling
    /// may still be moving them.
    func relayoutHeadersFooters(_ changes: () -> Void = {}) {
        UIView.performWithoutAnimation {
            beginUpdates()
            changes()
            endUpdates()
        }
    }
}

public struct DefaultActivityIndicator: View {

    @Environment(\.chatTheme) var theme
    var size: CGFloat
    var color: Color?

    public init(size: CGFloat = 30, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        ActivityIndicatorView(type: .default())
            .foregroundColor(color != nil ? color! : theme.colors.sendButtonBackground)
            .viewSize(size)
            .padding(.vertical, 10)
    }
}
