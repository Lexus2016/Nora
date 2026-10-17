import SwiftUI

/// A single greeting, followed by a quiet resting pose. These finite steps are testable without
/// a display or a timer; disappearance and accessibility changes cancel the SwiftUI task.
enum TrashMascotMotion {
    struct Step: Equatable {
        let angle: Double
        let duration: Double
    }

    static let steps: [Step] = [
        Step(angle: -18, duration: 0.16), Step(angle: 18, duration: 0.18),
        Step(angle: -18, duration: 0.18), Step(angle: 18, duration: 0.18),
        Step(angle: 0, duration: 0.20),
    ]
    static var duration: Double { steps.reduce(0) { $0 + $1.duration } }
}

/// Small glass basket with a friendly folded-paper visitor. It never changes prompt layout,
/// accepts input or announces itself over the important Trash size and deletion warning.
struct TrashMascot: View {
    var size: CGFloat = 76
    var animationEnabled = true

    #if DEBUG
    /// A fixed native screenshot pose. Nil enables the normal finite greeting.
    var snapshotWaveAngle: Double?
    #endif

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var visible = false
    @State private var greeted = false
    @State private var armAngle = 0.0

    private var fixedAngle: Double? {
        #if DEBUG
        snapshotWaveAngle
        #else
        nil
        #endif
    }

    private var motionAllowed: Bool {
        animationEnabled && fixedAngle == nil &&
            DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState, visible: visible)
    }

    var body: some View {
        artwork(waveAngle: fixedAngle ?? (motionAllowed ? armAngle : 0))
            .frame(width: 100, height: 100)
            .scaleEffect(size / 100)
            .frame(width: size, height: size)
            .background(VisibilityProbe(visible: $visible))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: motionAllowed) {
                guard motionAllowed, !greeted else { return }
                greeted = true
                defer { settle() }
                do {
                    for step in TrashMascotMotion.steps {
                        try Task.checkCancellation()
                        withAnimation(.easeInOut(duration: step.duration)) { armAngle = step.angle }
                        try await Task.sleep(for: .seconds(step.duration))
                    }
                } catch {
                    // Cancellation is the normal hidden/inactive/Reduce Motion path.
                }
            }
            .onDisappear {
                greeted = false
                settle()
            }
    }

    private func settle() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { armAngle = 0 }
    }

    private func artwork(waveAngle: Double) -> some View {
        ZStack {
            Ellipse().fill(.black.opacity(0.24)).frame(width: 56, height: 7)
                .blur(radius: 2).position(x: 50, y: 90)

            // The back lip stays behind the paper, giving a clear opening rather than a sticker.
            Ellipse().fill(Color(hex: 0x07564F)).frame(width: 62, height: 16).position(x: 50, y: 47)
                .overlay {
                    Ellipse().stroke(.white.opacity(0.52), lineWidth: 2)
                        .frame(width: 62, height: 16).position(x: 50, y: 47)
                }

            paper.position(x: 48, y: 32).rotationEffect(.degrees(-7), anchor: UnitPoint(x: 0.48, y: 0.46))
            wavingArm.rotationEffect(.degrees(waveAngle), anchor: .bottomLeading)
                .frame(width: 24, height: 27).position(x: 73, y: 33)

            TrashBasketShape()
                .fill(LinearGradient(stops: [.init(color: Color(hex: 0x7BF1D2), location: 0),
                                             .init(color: Color(hex: 0x20B799), location: 0.3),
                                             .init(color: Color(hex: 0x087364), location: 0.78),
                                             .init(color: Color(hex: 0x06483F), location: 1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 60, height: 44).position(x: 50, y: 67)
                .overlay {
                    TrashBasketShape().stroke(LinearGradient(colors: [.white.opacity(0.7), Color(hex: 0x36DCC5).opacity(0.4), .black.opacity(0.35)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.4)
                        .frame(width: 60, height: 44).position(x: 50, y: 67)
                }

            // Broad rounded channels communicate thickness at the actual 76 pt display size.
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.16)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 5, height: 26)
                        .shadow(color: .black.opacity(0.2), radius: 0.5, x: 1, y: 1)
                }
            }
            .position(x: 50, y: 67)
            Ellipse().trim(from: 0, to: 0.5)
                .stroke(LinearGradient(colors: [.white.opacity(0.9), Color(hex: 0x5DF3DD), Color(hex: 0x08776A)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 62, height: 16).position(x: 50, y: 47)
            Capsule().fill(Color(hex: 0xF3FFF9)).frame(width: 10, height: 6)
                .rotationEffect(.degrees(-10)).position(x: 32, y: 47)
        }
    }

    private var paper: some View {
        ZStack(alignment: .topTrailing) {
            FoldedPaperShape()
                .fill(LinearGradient(colors: [.white, Color(hex: 0xD7EBE8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(FoldedPaperShape().stroke(.white.opacity(0.9), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 2)
            Path { p in
                p.move(to: CGPoint(x: 22, y: 0)); p.addLine(to: CGPoint(x: 22, y: 9))
                p.addLine(to: CGPoint(x: 31, y: 9)); p.closeSubpath()
            }.fill(Color(hex: 0xA6D5CC))
            HStack(spacing: 8) {
                Capsule().fill(Color(hex: 0x143B38)).frame(width: 2.7, height: 4)
                Capsule().fill(Color(hex: 0x143B38)).frame(width: 2.7, height: 4)
            }.frame(width: 31).offset(y: 19)
            Path { p in
                p.move(to: CGPoint(x: 11, y: 27))
                p.addQuadCurve(to: CGPoint(x: 22, y: 27), control: CGPoint(x: 16.5, y: 33))
            }.stroke(Color(hex: 0x143B38), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 31, height: 40)
    }

    private var wavingArm: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 2, y: 25))
                p.addQuadCurve(to: CGPoint(x: 16, y: 7), control: CGPoint(x: 16, y: 24))
            }
            .stroke(Color(hex: 0xE9FFF5), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Ellipse().fill(.white).frame(width: 9, height: 11).rotationEffect(.degrees(15)).position(x: 16, y: 5)
        }
        .frame(width: 24, height: 27)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
    }
}

private struct TrashBasketShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - 6))
            p.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY - 6),
                           control: CGPoint(x: rect.midX, y: rect.maxY + 5))
            p.closeSubpath()
        }
    }
}

private struct FoldedPaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + 3, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - 9, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 9))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - 3, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 3))
            p.addQuadCurve(to: CGPoint(x: rect.minX + 3, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            p.closeSubpath()
        }
    }
}
