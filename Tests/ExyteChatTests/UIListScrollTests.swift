import SwiftUI
import Testing
import UIKit

@testable import ExyteChat

@MainActor
struct UIListScrollTests {
    @Test func explicitHistoryScrollSurvivesDeferredBottomAnchor() async {
        let list = makeList()
        let coordinator = makeCoordinator(for: list)
        let source = Rows()
        let table = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), style: .plain)
        table.dataSource = source
        defer { withExtendedLifetime(source) {} }
        table.rowHeight = 44
        table.reloadData()
        table.layoutIfNeeded()

        list.maintainBottomAnchorIfNeeded(table, wasPinnedToBottom: true, coordinator: coordinator)
        list.performScrollTo(table, scrollToParams: ScrollToParams(.oldestMessage), coordinator: coordinator)
        let historyOffset = table.contentOffset.y
        #expect(historyOffset > 1000)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(abs(table.contentOffset.y - historyOffset) < 1)
    }

    @Test func pendingHistoryScrollSuppressesImmediateBottomAnchor() {
        let list = makeList(pending: ScrollToParams(.oldestMessage))
        let coordinator = makeCoordinator(for: list)
        let source = Rows()
        let table = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), style: .plain)
        table.dataSource = source
        defer { withExtendedLifetime(source) {} }
        table.rowHeight = 44
        table.reloadData()
        table.layoutIfNeeded()
        table.setContentOffset(CGPoint(x: 0, y: 400), animated: false)

        list.maintainBottomAnchorIfNeeded(table, wasPinnedToBottom: true, coordinator: coordinator)

        #expect(table.contentOffset.y == 400)
    }

    private func makeCoordinator(for list: UIList<EmptyView>) -> UIList<EmptyView>.Coordinator {
        UIList<EmptyView>.Coordinator(
            viewModel: list.viewModel, inputViewModel: list.inputViewModel,
            isScrolledToBottom: .constant(true), isScrolledToTop: .constant(false),
            messageBuilder: list.messageBuilder, mainHeaderBuilder: nil, dateHeaderBuilder: nil,
            type: list.type, sections: list.sections, ids: list.ids,
            chatParams: list.chatParams, messageParams: list.messageParams, mainBackgroundColor: .clear)
    }

    private func makeList(pending: ScrollToParams? = nil) -> UIList<EmptyView> {
        UIList(
            viewModel: ChatViewModel(), inputViewModel: InputViewModel(),
            pendingScrollTo: .constant(pending), isScrolledToBottom: .constant(true),
            tableContentHeight: .constant(0), messageBuilder: { _ in EmptyView() },
            mainHeaderBuilder: nil, dateHeaderBuilder: nil, type: .conversation,
            bottomOverlayHeight: 0, sections: [], ids: [],
            chatParams: ChatCustomizationParameters(), messageParams: MessageCustomizationParameters())
    }
}

@MainActor
private final class Rows: NSObject, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 40 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        UITableViewCell(style: .default, reuseIdentifier: nil)
    }
}
