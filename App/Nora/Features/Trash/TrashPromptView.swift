import SwiftUI

/// Approved 520 × 260 pt horizontal reminder. All content and actions stay inside the panel.
struct TrashPromptView: View {
    @Bindable var model: TrashReminderModel
    var animationEnabled = true
    var openNora: () -> Void = {}
    @Environment(\.locale) private var locale

    private let foreground = Color(hex: 0xEBFFF9)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nora · Trash").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: model.dismiss) { Image(systemName: "xmark").font(.system(size: 13, weight: .medium)) }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text("Close Trash reminder"))
                    .help(Text("Close Trash reminder"))
            }
            .frame(height: 20)
            .padding(.bottom, 8)

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    TrashMascot(size: 76, animationEnabled: animationEnabled)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sizeText)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.68)
                            .accessibilityLabel(Text("Trash logical size"))
                            .accessibilityValue(sizeText)
                        Text(model.snapshot == nil ? "Size unknown" : "logical size")
                            .font(.system(size: 10))
                            .foregroundStyle(foreground.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 174)
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .bold))
                        .lineLimit(2).minimumScaleFactor(0.85)
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: warningSymbol).foregroundStyle(Color(hex: 0xFFE091)).font(.system(size: 12))
                            .accessibilityHidden(true)
                        explanation.font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3).minimumScaleFactor(0.85)
                    }
                    Text("Only ~/.Trash. External disks are excluded.")
                        .font(.system(size: 10))
                        .foregroundStyle(foreground.opacity(0.86))
                        .lineLimit(2).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 88)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Button(action: primaryAction) {
                    Text(primaryTitle).font(.system(size: 13, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 280, height: 38)
                        .foregroundStyle(Color(hex: 0x123F38))
                        .background(.white.opacity(primaryDisabled ? 0.58 : 1), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(primaryDisabled)
                // Deliberately no defaultAction/Return shortcut on either deletion step.
                .accessibilityHint(primaryHint)
                Button(action: secondaryAction) {
                    Text(secondaryTitle).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 188, height: 38)
                        .background(Color(hex: 0x073B38).opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .disabled(model.stopRequested && model.phase == .cleaning)
            }
            .padding(.bottom, 10)
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                .padding(.bottom, 8)
            Toggle(isOn: Binding(get: { model.remindersEnabled }, set: model.setRemindersEnabled)) {
                Text("Remind me about Trash").font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).tint(Color(hex: 0x23C49E))
            .controlSize(.small)
            .accessibilityHint(Text("Reminders work while Nora is running. You can always review Trash manually."))
            .help(Text("Reminders work while Nora is running. You can always review Trash manually."))
            .frame(height: 26)
        }
        .padding(22)
        .frame(width: 520, height: 260)
        .foregroundStyle(foreground)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x246E60), Color(hex: 0x0C4744), Color(hex: 0x103A46)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.28), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Nora Trash review"))
    }

    private var sizeText: String {
        guard let snapshot = model.snapshot else { return "—" }
        return snapshot.logicalBytes.formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb, .tb]).locale(locale))
    }

    private var title: LocalizedStringKey {
        switch model.phase {
        case .idle, .scanning: return "Checking home Trash…"
        case .review: return model.snapshot?.topLevelItemCount == 0 ? "Home Trash is empty" : "New files in your Trash"
        case .confirmation: return "Delete these items permanently?"
        case .cleaning: return model.stopRequested ? "Stopping safely…" : "Emptying reviewed Trash…"
        case .unavailable: return "Trash could not be checked"
        case .recoveryRequired: return "Trash recovery needs attention"
        case .finished:
            switch model.outcome?.status {
            case .completed: return "Reviewed items removed"
            case .cancelled: return "Trash cleanup stopped"
            case .requiresNewReview: return "Trash changed during cleanup"
            default: return "Trash cleanup needs attention"
            }
        }
    }

    private var explanation: Text {
        if let notice = model.notice { return Text(verbatim: notice) }
        switch model.phase {
        case .idle, .scanning: return Text("Reading a bounded snapshot. Nothing is deleted.")
        case .review where model.snapshot?.topLevelItemCount == 0: return Text("No items were found in your home Trash.")
        case .review: return Text("Files will be permanently deleted. This cannot be undone.")
        case .confirmation:
            let count = model.snapshot?.topLevelItemCount ?? 0
            return Text("\(count) reviewed items will be permanently deleted. This cannot be undone.")
        case .cleaning: return Text("Only reviewed items are eligible. Stopping may leave some items already deleted.")
        case .unavailable: return Text("Size is unknown. Unreadable items are never treated as an empty Trash.")
        case .recoveryRequired: return Text("Preserved items need review. Permanent deletion is blocked.")
        case .finished:
            let count = model.outcome?.deletedEntryCount ?? 0
            return Text("\(count) entries removed. Disk space reclaimed may differ from logical size.")
        }
    }

    private var warningSymbol: String {
        switch model.phase {
        case .idle, .scanning, .finished: return "info.circle"
        case .review where model.snapshot?.topLevelItemCount == 0: return "checkmark.circle"
        default: return "exclamationmark.triangle"
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch model.phase {
        case .idle, .scanning: return "Checking…"
        case .review: return model.snapshot?.topLevelItemCount == 0 ? "Check again" : "Empty Trash…"
        case .confirmation: return "Delete permanently"
        case .cleaning: return "Cleaning…"
        case .recoveryRequired: return "Review recovery in Nora"
        case .unavailable, .finished: return "Review again"
        }
    }

    private var primaryDisabled: Bool {
        model.isWorking || model.phase == .scanning || model.phase == .cleaning
    }

    private var primaryHint: Text {
        if model.phase == .confirmation { return Text("Permanently delete only the reviewed items from home Trash. This cannot be undone.") }
        return Text("Refresh the contents before a separate permanent-deletion confirmation.")
    }

    private var secondaryTitle: LocalizedStringKey {
        if model.phase == .confirmation { return "Go back" }
        if model.isWorking && model.canCancelOperation { return model.stopRequested ? "Stopping…" : "Cancel" }
        return "Not now"
    }

    private func primaryAction() {
        switch model.phase {
        case .review where model.canReviewDeletion: model.requestDeletionConfirmation()
        case .confirmation: model.confirmDeletion()
        case .recoveryRequired: openNora()
        case .unavailable, .finished, .review: model.openReview()
        default: break
        }
    }

    private func secondaryAction() {
        if model.phase == .confirmation { model.cancelConfirmation() }
        else if model.isWorking && model.canCancelOperation { model.cancelCurrentOperation() }
        else { model.dismiss() }
    }
}

/// Reuse this row in Settings and the app's manual review area. Monitoring belongs to AppModel.
struct TrashReminderSettingsSection: View {
    @Bindable var model: TrashReminderModel
    var body: some View {
        Section {
            Toggle("Remind me about Trash", isOn: Binding(get: { model.remindersEnabled }, set: model.setRemindersEnabled))
            Text("Reminders work while Nora is running. Only home Trash (~/.Trash) is checked; external disks are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Review home Trash…", action: model.openReview)
            if model.phase == .recoveryRequired {
                Text("Finish the pending recovery in Nora before emptying Trash.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Restore preserved Trash items", action: model.recoverPreservedItems)
                    .disabled(model.isWorking || model.externalBlocker() != nil)
                if model.isWorking && !model.canCancelOperation {
                    Text("Checking or restoring preserved Trash items…").font(.caption)
                }
                if let diagnostic = model.diagnostic {
                    Text(diagnostic).font(.caption).textSelection(.enabled)
                }
            }
        } header: { Text("Trash reminders") }
    }
}
