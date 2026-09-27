//
//  UIList.swift
//  
//
//  Created by Alisa Mylnikova on 24.02.2023.
//

import SwiftUI
import Combine

struct UIList<MessageContent: View>: UIViewRepresentable {

    typealias MessageBuilderParamsClosure = ChatView<MessageContent, InputView, DefaultMessageMenuAction>.MessageBuilderParamsClosure

    @Environment(\.chatTheme) var theme

    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var inputViewModel: InputViewModel

    @Binding var pendingScrollTo: ScrollToParams?
    @Binding var isScrolledToBottom: Bool
    @Binding var tableContentHeight: CGFloat

    // MARK: - View builders

    let messageBuilder: MessageBuilderParamsClosure
    let mainHeaderBuilder: (()->AnyView)?
    let dateHeaderBuilder: ((Date)->AnyView)?

    // MARK: - Data / type

    let type: ChatType
    let bottomOverlayHeight: CGFloat
    let sections: [MessagesSection]
    let ids: [String]

    // MARK: - Customization

    let chatParams: ChatCustomizationParameters
    let messageParams: MessageCustomizationParameters

    // MARK: - State

    @State private var isScrolledToTop = false
    @State private var updateQueue = UpdateQueue()
    @State private var transaction = TableUpdateTransaction()

    @State private var cancellables = Set<AnyCancellable>()

    private let messageMenuLongPressDuration: TimeInterval = 0.35

    func makeUIView(context: Context) -> UITableView {
        let style = mainHeaderBuilder != nil || chatParams.showDateHeaders ? UITableView.Style.grouped : .plain
        let tableView = UITableView(frame: .zero, style: style)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.transform = CGAffineTransform(rotationAngle: (type == .conversation ? .pi : 0))

        tableView.showsVerticalScrollIndicator = false
        tableView.estimatedSectionHeaderHeight = 1
        tableView.estimatedSectionFooterHeight = UITableView.automaticDimension
        tableView.backgroundColor = UIColor(theme.contentBG)
        tableView.scrollsToTop = false
        tableView.isScrollEnabled = chatParams.isScrollEnabled
        tableView.keyboardDismissMode = chatParams.keyboardDismissMode
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionHeaderHeight = 0
        tableView.sectionFooterHeight = 0
        tableView.tableHeaderView = nil
        tableView.tableFooterView = UIView(frame: .zero)
        updateInsets(for: tableView)

        let dismissKeyboardTapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleListTapToDismissKeyboard(_:))
        )
        dismissKeyboardTapRecognizer.cancelsTouchesInView = false
        dismissKeyboardTapRecognizer.delegate = context.coordinator
        tableView.addGestureRecognizer(dismissKeyboardTapRecognizer)

        if chatParams.showMessageMenuOnLongPress {
            tableView.addGestureRecognizer(
                context.coordinator.makeMessageMenuLongPressGesture(
                    minimumPressDuration: messageMenuLongPressDuration
                )
            )
        }

        transaction.updateQueue = updateQueue
        chatParams.onTransactionReady?(transaction)

        return tableView
    }

    private func scrollToBottom(_ tableView: UITableView, animated: Bool) {
        guard tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 else { return }

        let scrollPosition: UITableView.ScrollPosition = type == .conversation ? .top : .bottom
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: scrollPosition, animated: animated)
    }

    private func isPinnedToBottom(_ tableView: UITableView) -> Bool {
        guard type == .conversation else { return false }
        return tableView.contentOffset.y <= 1
    }

    private func canAdjustBottomAnchor(_ tableView: UITableView) -> Bool {
        !tableView.isDragging && !tableView.isTracking && !tableView.isDecelerating
    }

    private func maintainBottomAnchorIfNeeded(_ tableView: UITableView, wasPinnedToBottom: Bool) {
        guard wasPinnedToBottom, canAdjustBottomAnchor(tableView) else { return }

        scrollToBottom(tableView, animated: false)

        DispatchQueue.main.async { [weak tableView] in
            guard let tableView, self.canAdjustBottomAnchor(tableView) else { return }
            self.scrollToBottom(tableView, animated: false)
        }
    }

    private func resolvedContentInsets() -> UIEdgeInsets {
        var insets = chatParams.contentInsets
        let overlayHeight = max(bottomOverlayHeight, 0)

        switch type {
        case .conversation:
            insets.top += overlayHeight
        case .comments:
            insets.bottom += overlayHeight
        }

        return insets
    }

    private func updateInsets(for tableView: UITableView) {
        let insets = resolvedContentInsets()

        guard tableView.contentInset != insets ||
                tableView.verticalScrollIndicatorInsets != insets ||
                tableView.horizontalScrollIndicatorInsets != insets else { return }

        let shouldMaintainLiveEdge = isPinnedToBottom(tableView)

        tableView.contentInset = insets
        tableView.verticalScrollIndicatorInsets = insets
        tableView.horizontalScrollIndicatorInsets = insets

        if shouldMaintainLiveEdge {
            if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 {
                maintainBottomAnchorIfNeeded(tableView, wasPinnedToBottom: true)
            } else {
                tableView.setContentOffset(
                    CGPoint(x: tableView.contentOffset.x, y: -insets.top),
                    animated: false
                )
            }
        }
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.messageBuilder = messageBuilder

        if tableView.isScrollEnabled != chatParams.isScrollEnabled {
            tableView.isScrollEnabled = chatParams.isScrollEnabled
        }
        if tableView.keyboardDismissMode != chatParams.keyboardDismissMode {
            tableView.keyboardDismissMode = chatParams.keyboardDismissMode
        }

        updateInsets(for: tableView)

        if !chatParams.isScrollEnabled {
            DispatchQueue.main.async {
                tableContentHeight = tableView.contentSize.height
            }
        }

        context.coordinator.chatParams = chatParams

        let needToUpdateSections = context.coordinator.latestUpdateSections != sections
        let needToScroll = pendingScrollTo != nil

        //print("changes animationMode: \(animationMode) needToUpdateSections: \(needToUpdateSections), needToScroll: \(needToScroll), pendingScrollTo: \(pendingScrollTo)")

        guard needToUpdateSections || needToScroll else { return }

        context.coordinator.latestUpdateSections = sections
        context.coordinator.updateInProgress = true
        let previousIDs = context.coordinator.ids

        Task { @MainActor in
            let animationMode = await updateQueue.getAnimationMode()
            let transactionAnimated: Bool
            if case .none = animationMode {
                transactionAnimated = false
            } else {
                transactionAnimated = true
            }
            let shouldAnimateTableUpdate = chatParams.animateMessageUpdates && TableUpdateAnimationPolicy.shouldAnimate(
                transactionAnimated: transactionAnimated,
                needsExternalScroll: needToScroll,
                previousIDs: previousIDs,
                newIDs: ids
            )
            await updateQueue.markRealUpdate()

            await updateQueue.createJob {
                if needToUpdateSections {
                    if !shouldAnimateTableUpdate
                        || animationMode == .none
                        || context.coordinator.sections.isEmpty
                        || pendingScrollTo != nil { // if we're gonna scroll later, then update cells without animation, and animate scrolling later
                        updateTableNoAnimation(tableView, context.coordinator)
                    } else if animationMode == .natural, isPinnedToBottom(tableView) {
                        await updateTableWithAnimation(tableView, context.coordinator)
                    } else {
                        // if transaction.animationMode == .keepStable
                        // || (transaction.animationMode == .natural && tableView.contentOffset != .zero) {
                        await performInsertPreservingOffset(tableView, context.coordinator)
                    }
                }

                context.coordinator.ids = ids

                if needToScroll, let scrollToParams = pendingScrollTo {
                    pendingScrollTo = nil // reset to only scroll once

                    let perform = {
                        performScrollTo(tableView, scrollToParams: scrollToParams)
                    }

                    if chatParams.animateMessageUpdates, animationMode == .natural {
                        await withCheckedContinuation { continuation in
                            UIView.animate(withDuration: 0.25) {
                                perform()
                            } completion: { _ in
                                continuation.resume()
                            }
                        }
                    } else {
                        perform()
                    }
                }

                tableView.beginUpdates()
                context.coordinator.updateInProgress = false
                context.coordinator.paginationState.olderInProgress = false
                context.coordinator.paginationState.newerInProgress = false
                tableView.endUpdates()
                tableView.relayoutHeadersFooters()
            }
        }
    }

    // MARK: scroll to

    func performScrollTo(_ tableView: UITableView, scrollToParams: ScrollToParams) {
        switch scrollToParams.scrollTo {
        case .messageID(let messageID, let position, let offset):
            scrollToRow(tableView, messageID: messageID, position: position, additionalOffset: offset)
        case .tableOffset(let offset):
            tableView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        case .newestMessage:
            scrollToBottom(tableView, animated: false)
        case .oldestMessage:
            // An empty table has no section 0 to ask about: clamping the index
            // to 0 makes numberOfRows(inSection:) raise
            // "Requested the number of rows for section (0) which is out of bounds".
            guard tableView.numberOfSections > 0 else { return }

            let lastSection = tableView.numberOfSections - 1
            let lastRow = tableView.numberOfRows(inSection: lastSection) - 1

            guard lastRow >= 0 else { return }

            tableView.scrollToRow(
                at: IndexPath(row: lastRow, section: lastSection),
                at: .bottom,
                animated: false
            )
        }
    }

    @MainActor
    func scrollToRow(_ tableView: UITableView, messageID: String, position: UITableView.ScrollPosition, additionalOffset: CGFloat) {
        let indicatorIP = UIList.lastReadIndicatorIndexPath(sections: sections, enabled: chatParams.showLastReadIndicator)
        guard let indexPath = indexPath(for: messageID, in: sections, indicatorIndexPath: indicatorIP),
              let rect = tableView.rectForRow(at: indexPath) as CGRect? else { return }

        let adjustedPosition =
        (position == .middle || type == .comments) ? position
        : position == .bottom ? .top: .bottom

        let baseY: CGFloat
        switch adjustedPosition {
        case .top:
            baseY = rect.minY - tableView.adjustedContentInset.top
        case .middle:
            baseY = rect.midY - tableView.bounds.height / 2
        default:
            baseY = rect.maxY - tableView.bounds.height + tableView.adjustedContentInset.bottom
        }

        let targetY = baseY + additionalOffset

        let minOffset = -tableView.adjustedContentInset.top
        let maxOffset = tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom

        let clampedY = max(minOffset, min(targetY, maxOffset))

        tableView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
    }

    static func lastReadIndicatorIndexPath(sections: [MessagesSection], enabled: Bool) -> IndexPath? {
        guard enabled else { return nil }
        for (si, section) in sections.enumerated() {
            for (ri, row) in section.rows.enumerated() {
                if case .readBy = row.message.status, si > 0 || ri > 0 {
                    return IndexPath(row: ri, section: si)
                }
            }
        }
        return nil
    }

    func indexPath(for id: String, in sections: [MessagesSection], indicatorIndexPath: IndexPath? = nil) -> IndexPath? {
        for (sectionIndex, section) in sections.enumerated() {
            if let rowIndex = section.rows.firstIndex(where: { $0.message.id == id }) {
                if let ip = indicatorIndexPath, ip.section == sectionIndex, rowIndex >= ip.row {
                    return IndexPath(row: rowIndex + 1, section: sectionIndex)
                }
                return IndexPath(row: rowIndex, section: sectionIndex)
            }
        }
        return nil
    }

    // MARK: update table

    func performInsertPreservingOffset(_ tableView: UITableView, _ coordinator: Coordinator) async {
        let oldIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: coordinator.sections, enabled: chatParams.showLastReadIndicator)

        // Skip the indicator row — it has no backing message to preserve by ID
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        guard let firstVisibleIndexPath = visibleIndexPaths.first(where: { $0 != oldIndicatorIP }),
              let preservedVisibleRect = tableView.rectForRow(at: firstVisibleIndexPath) as CGRect? else { return }

        let dataRow = adjustedDataRow(firstVisibleIndexPath.row, section: firstVisibleIndexPath.section, indicator: oldIndicatorIP)
        let firstVisibleRow = coordinator.sections[firstVisibleIndexPath.section].rows[dataRow]
        let preservedVisibleMessageID = firstVisibleRow.message.id
        let preservedOffset = tableView.contentOffset.y

        coordinator.sections = sections

        CATransaction.setDisableActions(true)

        tableView.reloadData()
        tableView.layoutIfNeeded()

        let newIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: sections, enabled: chatParams.showLastReadIndicator)
        guard let newIndexPath = indexPath(for: preservedVisibleMessageID, in: sections, indicatorIndexPath: newIndicatorIP) else { return }
        let newRectForCell = tableView.rectForRow(at: newIndexPath)
        let newOffset = preservedOffset + (newRectForCell.minY - preservedVisibleRect.minY)
        tableView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)

        tableView.relayoutHeadersFooters()
    }

    private func adjustedDataRow(_ tableRow: Int, section: Int, indicator: IndexPath?) -> Int {
        guard let ip = indicator, ip.section == section, tableRow > ip.row else { return tableRow }
        return tableRow - 1
    }

    @MainActor
    private func updateTableNoAnimation(_ tableView: UITableView, _ coordinator: Coordinator) {
        let shouldMaintainBottomAnchor = isPinnedToBottom(tableView)
        coordinator.sections = sections

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
        }

        maintainBottomAnchorIfNeeded(tableView, wasPinnedToBottom: shouldMaintainBottomAnchor)

        CATransaction.commit()
    }

    @MainActor
    private func updateTableWithAnimation(_ tableView: UITableView, _ coordinator: Coordinator) async {
        let prevSections = coordinator.sections
        let splitInfo = SplitInfo.operationsSplit(oldSections: prevSections, newSections: sections)
        await applyOperations(tableView, splitInfo: splitInfo, prevSections: prevSections, animated: true) {
            coordinator.sections = $0
        }
    }

    @MainActor
    private func applyOperations(
        _ tableView: UITableView,
        splitInfo: SplitInfo,
        prevSections: [MessagesSection],
        animated: Bool,
        updateContextClosure: ([MessagesSection]) -> Void
    ) async {
        let shouldMaintainBottomAnchor = isPinnedToBottom(tableView)

        if shouldFallbackToFullReload(splitInfo: splitInfo) {
            updateContextClosure(sections)
            UIView.performWithoutAnimation {
                tableView.reloadData()
                tableView.layoutIfNeeded()
            }

            maintainBottomAnchorIfNeeded(tableView, wasPinnedToBottom: shouldMaintainBottomAnchor)
            if !chatParams.isScrollEnabled {
                tableContentHeight = tableView.contentSize.height
            }
            return
        }

        // step 0: preparation
        // prepare intermediate sections and operations
//        print("whole appliedDeletes:\n", formatSections(splitInfo.appliedDeletes), "\n")
//        print("whole appliedDeletesSwapsAndEdits:\n", formatSections(splitInfo.appliedDeletesSwapsAndEdits), "\n")
//        print("whole final sections:\n", formatSections(sections), "\n")
//
//        print("operations delete:\n", splitInfo.deleteOperations.map { $0.description })
//        print("operations swap:\n", splitInfo.swapOperations.map { $0.description })
//        print("operations edit:\n", splitInfo.editOperations.map { $0.description })
//        print("operations insert:\n", splitInfo.insertOperations.map { $0.description })

        await performBatchTableUpdatesIfNeeded(tableView, animated: animated) {
            // step 1: deletes
            let deleteIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: prevSections, enabled: chatParams.showLastReadIndicator)
            updateContextClosure(splitInfo.appliedDeletes)
            for operation in splitInfo.deleteOperations {
                applyOperation(operation, tableView: tableView, indicatorIndexPath: deleteIndicatorIP)
            }
        }

        await performBatchTableUpdatesIfNeeded(tableView, animated: animated) {
            // step 2: swaps
            let swapIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: splitInfo.appliedDeletes, enabled: chatParams.showLastReadIndicator)
            updateContextClosure(splitInfo.appliedDeletesSwapsAndEdits)
            for operation in splitInfo.swapOperations {
                applyOperation(operation, tableView: tableView, indicatorIndexPath: swapIndicatorIP)
            }
        }

        await performBatchTableUpdatesIfNeeded(tableView, animated: false) {
            // step 3: edits
            let editIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: splitInfo.appliedDeletesSwapsAndEdits, enabled: chatParams.showLastReadIndicator)
            updateContextClosure(splitInfo.appliedDeletesSwapsAndEdits)
            for operation in splitInfo.editOperations {
                applyOperation(operation, tableView: tableView, indicatorIndexPath: editIndicatorIP)
            }
        }

        // step 4: inserts
        let prevIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: splitInfo.appliedDeletesSwapsAndEdits, enabled: chatParams.showLastReadIndicator)
        let insertIndicatorIP = UIList.lastReadIndicatorIndexPath(sections: sections, enabled: chatParams.showLastReadIndicator)
        updateContextClosure(sections)

        await performBatchTableUpdatesIfNeeded(tableView, animated: animated) {
            for operation in splitInfo.insertOperations {
                applyOperation(operation, tableView: tableView, indicatorIndexPath: insertIndicatorIP)

                // When a section is inserted, UITableView uses its cached row counts as "before".
                // If the indicator moves away from an existing section to the new one (or disappears),
                // that section silently loses a virtual row — UITableView sees this as inconsistent.
                // Explicitly delete the virtual indicator row so the before→after counts stay valid.
                if case .insertSection(let newSection) = operation, let oldIP = prevIndicatorIP {
                    let shiftedSection = newSection <= oldIP.section ? oldIP.section + 1 : oldIP.section
                    if insertIndicatorIP?.section != shiftedSection {
                        tableView.deleteRows(at: [IndexPath(row: oldIP.row, section: oldIP.section)], with: .none)
                    }
                }
            }
        }
        //print("4 finished inserts")

        tableView.relayoutHeadersFooters()

        maintainBottomAnchorIfNeeded(tableView, wasPinnedToBottom: shouldMaintainBottomAnchor)

        if !chatParams.isScrollEnabled {
            tableContentHeight = tableView.contentSize.height
        }
    }

    @MainActor
    private func performBatchTableUpdatesIfNeeded(
        _ tableView: UITableView,
        animated: Bool,
        _ closure: () -> Void
    ) async {
        guard animated else {
            UIView.setAnimationsEnabled(false)
            defer { UIView.setAnimationsEnabled(true) }

            await performBatchTableUpdates(tableView) {
                closure()
            }
            return
        }

        await performBatchTableUpdates(tableView) {
            closure()
        }
    }

    private func shouldFallbackToFullReload(splitInfo: SplitInfo) -> Bool {
        // When callers explicitly disable message update animations, prefer a single reload
        // over multiple non-animated batch phases that can still visibly reflow self-sizing rows.
        // This is especially important for optimistic-send -> confirmed-send transitions.
        if !chatParams.animateMessageUpdates,
           (!splitInfo.insertOperations.isEmpty
            || !splitInfo.deleteOperations.isEmpty
            || !splitInfo.swapOperations.isEmpty
            || !splitInfo.editOperations.isEmpty) {
            return true
        }

        let hasSectionOperations =
            splitInfo.deleteOperations.contains(where: isSectionOperation)
            || splitInfo.insertOperations.contains(where: isSectionOperation)

        if hasSectionOperations {
            return true
        }

        // Diff-based row inserts are only stable at the live edges in this inverted table setup.
        if !splitInfo.insertOperations.isEmpty && !(isScrolledToBottom || isScrolledToTop) {
            return true
        }

        return false
    }

    private func isSectionOperation(_ operation: Operation) -> Bool {
        switch operation {
        case .deleteSection, .insertSection:
            return true
        case .delete, .insert, .swap, .edit, .editChangingHeight:
            return false
        }
    }

    // MARK: - Operations

    enum Operation {
        case deleteSection(Int)
        case insertSection(Int)

        case delete(Int, Int)
        case insert(Int, Int)
        case swap(Int, Int, Int)

        case edit(Int, Int) // reload the element without animation (otherwise it blinks)
        case editChangingHeight(Int, Int) // reload the element with simple animation

        var description: String {
            switch self {
            case .deleteSection(let int):
                return "deleteSection \(int)"
            case .insertSection(let int):
                return "insertSection \(int)"
            case .delete(let int, let int2):
                return "delete section \(int) row \(int2)"
            case .insert(let int, let int2):
                return "insert section \(int) row \(int2)"
            case .swap(let int, let int2, let int3):
                return "swap section \(int) rowFrom \(int2) rowTo \(int3)"
            case .edit(let int, let int2):
                return "edit section \(int) row \(int2)"
            case .editChangingHeight(let int, let int2):
                return "editChangingHeight section \(int) row \(int2)"
            }
        }
    }

    func applyOperation(_ operation: Operation, tableView: UITableView, animateInserts: Bool = true, indicatorIndexPath: IndexPath? = nil) {
        func tableRow(_ section: Int, _ row: Int) -> Int {
            guard let ip = indicatorIndexPath, ip.section == section, row >= ip.row else { return row }
            return row + 1
        }

        switch operation {
        case .deleteSection(let section):
            tableView.deleteSections([section], with: .automatic)
        case .insertSection(let section):
            tableView.insertSections([section], with: .top)
        case .delete(let section, let row):
            tableView.deleteRows(at: [IndexPath(row: tableRow(section, row), section: section)], with: .top)
        case .insert(let section, let row):
            tableView.insertRows(at: [IndexPath(row: tableRow(section, row), section: section)], with: animateInserts ? .top : .none)
        case .swap(let section, let rowFrom, let rowTo):
            tableView.deleteRows(at: [IndexPath(row: tableRow(section, rowFrom), section: section)], with: .top)
            tableView.insertRows(at: [IndexPath(row: tableRow(section, rowTo), section: section)], with: .top)
        case .edit(let section, let row):
            tableView.reconfigureRows(at: [IndexPath(row: tableRow(section, row), section: section)])
        case .editChangingHeight(let section, let row):
            tableView.reloadRows(at: [IndexPath(row: tableRow(section, row), section: section)], with: .automatic)
        }
    }

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(
            viewModel: viewModel,
            inputViewModel: inputViewModel,
            isScrolledToBottom: $isScrolledToBottom,
            isScrolledToTop: $isScrolledToTop,

            messageBuilder: messageBuilder,
            mainHeaderBuilder: mainHeaderBuilder,
            dateHeaderBuilder: dateHeaderBuilder,

            type: type,
            sections: sections,
            ids: ids,

            chatParams: chatParams,
            messageParams: messageParams,
            mainBackgroundColor: theme.contentBG
        )
    }

    class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {

        @ObservedObject var viewModel: ChatViewModel
        @ObservedObject var inputViewModel: InputViewModel

        @Binding var isScrolledToBottom: Bool
        @Binding var isScrolledToTop: Bool

        // MARK: - View builders

        var messageBuilder: MessageBuilderParamsClosure
        let mainHeaderBuilder: (()->AnyView)?
        let dateHeaderBuilder: ((Date)->AnyView)?

        // MARK: - Data / type

        let type: ChatType
        var sections: [MessagesSection] {
            didSet {
                if let id = sections.last?.rows.last?.message.id {
                    olderPaginationTargetMessageID = id
                }
                if let id = sections.first?.rows.first?.message.id {
                    newerPaginationTargetMessageID = id
                }
            }
        }
        var ids: [String]

        // MARK: - Customization

        var chatParams: ChatCustomizationParameters
        let messageParams: MessageCustomizationParameters
        let mainBackgroundColor: Color

        var updateInProgress: Bool = false
        /// call pagination handler when this row is reached
        /// without this there is a bug: during new cells insertion willDisplay is called one extra time for the cell which used to be the last one while it is being updated (its position in group is changed from first to middle)
        var olderPaginationTargetMessageID: String?
        var newerPaginationTargetMessageID: String?
        let paginationState = PaginationState()

        // helpers to avoid queueing same updates multiple times
        var latestUpdateSections: [MessagesSection] = []
        private let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)

        init(
            viewModel: ChatViewModel,
            inputViewModel: InputViewModel,
            isScrolledToBottom: Binding<Bool>,
            isScrolledToTop: Binding<Bool>,

            messageBuilder: @escaping MessageBuilderParamsClosure,
            mainHeaderBuilder: (() -> AnyView)?,
            dateHeaderBuilder: ((Date) -> AnyView)?,

            type: ChatType,
            sections: [MessagesSection],
            ids: [String],

            chatParams: ChatCustomizationParameters,
            messageParams: MessageCustomizationParameters,
            mainBackgroundColor: Color
        ) {
            self.viewModel = viewModel
            self.inputViewModel = inputViewModel
            self._isScrolledToBottom = isScrolledToBottom
            self._isScrolledToTop = isScrolledToTop

            self.messageBuilder = messageBuilder
            self.mainHeaderBuilder = mainHeaderBuilder
            self.dateHeaderBuilder = dateHeaderBuilder

            self.type = type
            self.sections = sections
            self.ids = ids

            self.chatParams = chatParams
            self.messageParams = messageParams
            self.mainBackgroundColor = mainBackgroundColor
        }

        @objc
        func handleListTapToDismissKeyboard(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }

        func makeMessageMenuLongPressGesture(minimumPressDuration: TimeInterval) -> UILongPressGestureRecognizer {
            let recognizer = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleMessageMenuLongPress(_:))
            )
            recognizer.minimumPressDuration = minimumPressDuration
            // After the menu long press wins, child tap handlers must not also fire on release.
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            return recognizer
        }

        var lastReadIndicatorIndexPath: IndexPath? {
            UIList.lastReadIndicatorIndexPath(sections: sections, enabled: chatParams.showLastReadIndicator)
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            sections.count
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            let base = sections[section].rows.count
            if let ip = lastReadIndicatorIndexPath, ip.section == section {
                return base + 1
            }
            return base
        }

        private func messageRow(at indexPath: IndexPath) -> MessageRow? {
            let indicatorIP = lastReadIndicatorIndexPath
            guard indexPath != indicatorIP else { return nil }
            let dataRow: Int
            if let ip = indicatorIP, ip.section == indexPath.section, indexPath.row > ip.row {
                dataRow = indexPath.row - 1
            } else {
                dataRow = indexPath.row
            }
            return sections[indexPath.section].rows[dataRow]
        }

        // MARK: - headers/footers

        // small optimization: exclude sections that can't possibly have a header/footer
        func hasSectionView(_ section: Int) -> Bool {
            chatParams.showDateHeaders || section == 0 || section == sections.count - 1
        }

        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            hasSectionView(section) ? UITableView.automaticDimension : 0
        }

        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
            hasSectionView(section) ? UITableView.automaticDimension : 0
        }

        func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            hasSectionView(section) ? makeHostingView { sectionHeaderView(section) } : nil
        }

        func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
            hasSectionView(section) ? makeHostingView { sectionFooterView(section) } : nil
        }

        // table's section header: on top of table for .comments, bottom for .conversation
        func sectionHeaderView(_ section: Int) -> some View {
            HeaderView(
                paginationState: paginationState,
                isFirst: section == 0,
                type: type,
                handler: chatParams.newerMessagesPaginationHandler,
                topContent: { self.sectionTopView(section) }
            )
        }

        // table's section footer: at the bottom of table for .comments, top for .conversation
        func sectionFooterView(_ section: Int) -> some View {
            FooterView(
                paginationState: paginationState,
                isLast: section == sections.count - 1,
                type: type,
                handler: chatParams.olderMessagesPaginationHandler,
                topContent: { self.sectionTopView(section) }
            )
        }

        // is on top for both chat styles
        func sectionTopView(_ section: Int) -> some View {
            VStack(spacing: 0) {
                if let mainHeaderBuilder,
                    (section == 0 && type == .comments) ||
                    (section == sections.count - 1 && type == .conversation) {
                    mainHeaderBuilder()
                }
                if chatParams.showDateHeaders {
                    dateViewBuilder(section)
                }
            }
        }

        @ViewBuilder
        func dateViewBuilder(_ section: Int) -> some View {
            if let dateHeaderBuilder {
                dateHeaderBuilder(sections[section].date)
            } else {
                Text(sections[section].formattedDate)
                    .font(.system(size: 11))
                    .padding(.top, 30)
                    .padding(.bottom, 8)
                    .foregroundColor(.gray)
            }
        }

        func makeHostingView<Content: View>(@ViewBuilder _ content: () -> Content) -> UIView? {
            let view = UIHostingController(rootView:
                content().rotationEffect(Angle(degrees: (type == .conversation ? 180 : 0)))
            ).view
            view?.backgroundColor = UIColor(mainBackgroundColor)
            return view
        }

        // MARK: - cells

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let tableViewCell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            tableViewCell.selectionStyle = .none
            tableViewCell.backgroundColor = UIColor(mainBackgroundColor)

            if indexPath == lastReadIndicatorIndexPath {
                tableViewCell.contentConfiguration = UIHostingConfiguration {
                    LastReadIndicatorView()
                        .rotationEffect(Angle(degrees: (type == .conversation ? 180 : 0)))
                }
                .minSize(width: 0, height: 0)
                .margins(.all, 0)
                return tableViewCell
            }

            let row = messageRow(at: indexPath)!
            tableViewCell.contentConfiguration = UIHostingConfiguration {
                ChatMessageView(
                    viewModel: viewModel,
                    messageBuilder: messageBuilder,
                    row: row,
                    chatType: type,
                    messageParams: messageParams,
                    isDisplayingMessageMenu: false
                )
                .background(MessageMenuPreferenceViewSetter(id: row.id))
                .rotationEffect(Angle(degrees: (type == .conversation ? 180 : 0)))
            }
            .minSize(width: 0, height: 0)
            .margins(.all, 0)

            return tableViewCell
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if updateInProgress { return }

            guard let row = messageRow(at: indexPath) else { return }
            lazy var message = row.message

            if let onWillDisplayCell = chatParams.onWillDisplayCell {
                onWillDisplayCell(message)
            }

            if !paginationState.olderInProgress,
               let messageID = olderPaginationTargetMessageID,
               message.id == messageID,
               let handler = chatParams.olderMessagesPaginationHandler,
               handler.hasMoreToLoad,
               case .cellIndex(_) = handler.triggerType {
                performOlderPagination(tableView)
            }

            if !paginationState.newerInProgress,
               let messageID = newerPaginationTargetMessageID,
               message.id == messageID,
               let handler = chatParams.newerMessagesPaginationHandler,
               handler.hasMoreToLoad,
               case .cellIndex(_) = handler.triggerType {
                performNewerPagination(tableView)
            }
        }

        func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let items = type == .conversation ? chatParams.listSwipeActions.trailing : chatParams.listSwipeActions.leading else { return nil }
            guard !items.actions.isEmpty else { return nil }
            guard let row = messageRow(at: indexPath) else { return nil }
            let message = row.message
            let conf = UISwipeActionsConfiguration(actions: items.actions.filter({ $0.activeFor(message) }).map { toContextualAction($0, message: message) })
            conf.performsFirstActionWithFullSwipe = items.performsFirstActionWithFullSwipe
            return conf
        }

        func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let items = type == .conversation ? chatParams.listSwipeActions.leading : chatParams.listSwipeActions.trailing else { return nil }
            guard !items.actions.isEmpty else { return nil }
            guard let row = messageRow(at: indexPath) else { return nil }
            let message = row.message
            let conf = UISwipeActionsConfiguration(actions: items.actions.filter({ $0.activeFor(message) }).map { toContextualAction($0, message: message) })
            conf.performsFirstActionWithFullSwipe = items.performsFirstActionWithFullSwipe
            return conf
        }

        private func toContextualAction(_ item: SwipeAction, message: Message) -> UIContextualAction {
            let ca = UIContextualAction(style: .normal, title: nil) { (_, _, completionHandler) in
                item.action(message, self.viewModel.messageMenuAction())
                completionHandler(true)
            }
            ca.image = item.render(type: type)

            let bgColor = item.background ?? mainBackgroundColor
            ca.backgroundColor = UIColor(bgColor)

            return ca
        }

        @objc
        private func handleMessageMenuLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let tableView = recognizer.view as? UITableView else { return }

            let location = recognizer.location(in: tableView)
            guard let indexPath = tableView.indexPathForRow(at: location),
                  sections.indices.contains(indexPath.section),
                  indexPath.row < self.tableView(tableView, numberOfRowsInSection: indexPath.section),
                  let row = messageRow(at: indexPath) else { return }

            impactGenerator.impactOccurred()
            impactGenerator.prepare()
            viewModel.messageMenuRow = row
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let contentOffset = scrollView.contentOffset.y
            let maxTopOffset = scrollView.contentSize.height - scrollView.frame.height - 1
            let scrolledToBottom = contentOffset <= 0
            let scrolledToTop = contentOffset >= maxTopOffset

            chatParams.onContentOffsetChange?(contentOffset)

            if isScrolledToBottom != scrolledToBottom || isScrolledToTop != scrolledToTop {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isScrolledToBottom != scrolledToBottom {
                        self.isScrolledToBottom = scrolledToBottom
                    }
                    if self.isScrolledToTop != scrolledToTop {
                        self.isScrolledToTop = scrolledToTop
                    }
                }
            }

            guard !sections.isEmpty, !updateInProgress else { return }

            if !paginationState.olderInProgress,
               let handler = chatParams.olderMessagesPaginationHandler,
               handler.hasMoreToLoad,
               case let .pixels(offset) = handler.triggerType,
               contentOffset >= maxTopOffset - offset,
               let tableView = scrollView as? UITableView {
                performOlderPagination(tableView)
            }

            //print(contentOffset, sections.count)

            if !paginationState.newerInProgress,
               let handler = chatParams.newerMessagesPaginationHandler,
               handler.hasMoreToLoad,
               case let .pixels(offset) = handler.triggerType,
               contentOffset <= offset,
               let tableView = scrollView as? UITableView {
                performNewerPagination(tableView)
            }
        }

        func performOlderPagination(_ tableView: UITableView) {
            if let handler = chatParams.olderMessagesPaginationHandler {
                Task { @MainActor in
                    tableView.beginUpdates()
                    paginationState.olderInProgress = true
                    tableView.endUpdates()
                    tableView.relayoutHeadersFooters()
                    await handler.handleClosure()
                    // set olderInProgress to false after table update is complete
                }
            }
        }

        func performNewerPagination(_ tableView: UITableView) {
            if let handler = chatParams.newerMessagesPaginationHandler {
                paginationState.newerInProgress = true
                Task { @MainActor in
                    tableView.beginUpdates()
                    tableView.endUpdates()
                    tableView.relayoutHeadersFooters()
                    await handler.handleClosure()
                    // set newerInProgress to false after table update is complete
                }
            }
        }
    }

}

enum TableUpdateAnimationPolicy {
    static func shouldAnimate(
        transactionAnimated: Bool,
        needsExternalScroll: Bool,
        previousIDs: [String],
        newIDs: [String]
    ) -> Bool {
        transactionAnimated && !needsExternalScroll && previousIDs != newIDs
    }
}

@MainActor
func performBatchTableUpdates(_ tableView: UITableView, closure: ()->()) async {
    await withCheckedContinuation { continuation in
        tableView.performBatchUpdates {
            closure()
        } completion: { _ in
            continuation.resume()
        }
    }
}

