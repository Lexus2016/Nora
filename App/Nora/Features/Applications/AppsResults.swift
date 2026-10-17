import MoleKit
import SwiftUI

/// Results of the scan: one sentence, then a card per finding. The updates card is large and
/// carries the module's glass object; Installers is a link to the Installers module.
struct AppsResults: View {
    @Bindable var model: AppsModel
    @Environment(AppModel.self) private var app
    private let module = Module.applications

    var body: some View {
        ModuleScene(module: module, leading: .startOver { model.reset() }) {
            VStack(spacing: 22) {
                ResultHeadline(text: String(localized: "We found \(model.apps.count) apps on your Mac."),
                               button: ("Manage my apps", { model.openList(.all) }))
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 18) {
                        updatesCard.frame(width: (geo.size.width - 36) / 3)
                        ScrollView {
                            // Reflow at the minimum window width instead of squeezing
                            // localized category captions beside their icons.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18)], spacing: 18) {
                                unusedCard.frame(height: max(220, (geo.size.height - 18) / 2))
                                largestCard.frame(height: max(220, (geo.size.height - 18) / 2))
                                installersCard.frame(height: max(220, (geo.size.height - 18) / 2))
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 16).padding(.bottom, 6)
        }
    }

    private var updatesCard: some View {
        let count = model.updateCount
        return CategoryCard(value: "\(count)",
                            caption: String(localized: "Updates available"),
                            detail: model.updatesNote ?? String(localized: "Apps with a newer version, including the ones you downloaded yourself."),
                            symbol: "arrow.triangle.2.circlepath", tint: module.palette.glow, large: true, glass: module.glass,
                            actionTitle: model.updatableIDs.isEmpty ? nil : "Update",
                            review: { model.openUpdates(all: false) },
                            action: model.updatableIDs.isEmpty ? nil : { model.openUpdates(all: true) })
    }

    private var unusedCard: some View {
        CategoryCard(value: "\(model.unusedApps.count)",
                     caption: String(localized: "Unused apps"),
                     detail: String(localized: "Not opened for 90 days or more."),
                     symbol: "moon.zzz", tint: module.palette.glow,
                     review: { model.openList(.unused) })
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: -8) {
                    ForEach(model.unusedApps.prefix(3)) { item in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                            .resizable().frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .padding(.leading, 22).padding(.bottom, 22)
            }
    }

    private var largestCard: some View {
        let top = model.largestApps.prefix(3)
        return CategoryCard(value: Format.bytes(model.sizes[model.largestApps.first?.path ?? ""] ?? 0),
                            caption: String(localized: "Largest apps"),
                            detail: top.map(\.name).joined(separator: ", "),
                            symbol: "chart.bar", tint: module.palette.glow,
                            review: { model.openList(.all) })
    }

    private var installersCard: some View {
        CategoryCard(value: String(localized: "Installers"),
                     caption: String(localized: "Disk images you no longer need"),
                     symbol: Module.installers.symbol, tint: module.palette.glow,
                     reviewTitle: "Open Installers",
                     review: { app.selection = .installers })
    }
}
