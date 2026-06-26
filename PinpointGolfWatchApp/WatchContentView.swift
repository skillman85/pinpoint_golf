import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var store: WatchRoundStore

    var body: some View {
        if let round = store.activeRound,
           let hole = round.holes[safe: round.currentHoleIndex] {
            WatchScoringView(round: round, hole: hole)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "applewatch")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.green)
                Text("No live round")
                    .font(.headline)
                Text("Start or resume a round on iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

struct WatchScoringView: View {
    @EnvironmentObject private var store: WatchRoundStore
    let round: WatchRoundPayload
    let hole: WatchHolePayload

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                HStack(spacing: 8) {
                    RunningPill(title: "Gross", value: "\(round.grossThroughCurrentHole)", color: .orange)
                    RunningPill(title: "Pts", value: "\(round.stablefordThroughCurrentHole)", color: .green)
                }

                WatchStepper(title: "Score", value: hole.score, range: 0...12, color: .orange) { value in
                    update { $0.score = value }
                }

                WatchStepper(title: "Putts", value: hole.putts, range: 0...6, color: .green) { value in
                    update { $0.putts = value }
                }

                if hole.par > 3 {
                    WatchChoiceRow(
                        title: "Fairway",
                        options: [(.hit, "Hit"), (.left, "Left"), (.right, "Right")],
                        selection: hole.fairway,
                        color: .green
                    ) { value in
                        update { $0.fairway = value }
                    }
                }

                WatchChoiceRow(
                    title: "Green",
                    options: [(.hit, "Hit"), (.short, "Short"), (.long, "Long"), (.left, "Left"), (.right, "Right")],
                    selection: hole.green,
                    color: .blue
                ) { value in
                    update {
                        $0.green = value
                        if value != .hit {
                            $0.approachProximity = nil
                        }
                    }
                }

                if hole.green == .hit {
                    WatchProximityRow(selection: hole.approachProximity) { value in
                        update { $0.approachProximity = value }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        store.move(to: round.currentHoleIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(round.currentHoleIndex == 0)

                    Button {
                        store.move(to: round.currentHoleIndex + 1)
                    } label: {
                        Text(round.currentHoleIndex == round.holes.count - 1 ? "Done" : "Next")
                            .fontWeight(.bold)
                    }
                    .disabled(round.currentHoleIndex == round.holes.count - 1)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(round.courseName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text("Hole \(hole.number)")
                    .font(.title2.bold())
                Spacer()
                Text("Par \(hole.par)")
                    .font(.headline)
            }
            Text("\(hole.yards) yds - SI \(hole.strokeIndex) - CH \(round.courseHandicap)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func update(_ mutate: (inout WatchHolePayload) -> Void) {
        var updated = hole
        mutate(&updated)
        store.update(updated, currentHoleIndex: round.currentHoleIndex)
    }
}

struct WatchStepper: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let color: Color
    let update: (Int) -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                update(max(range.lowerBound, value - 1))
            } label: {
                Image(systemName: "minus")
            }
            Text(value == 0 ? "-" : "\(value)")
                .font(.title3.bold())
                .foregroundStyle(color)
                .frame(width: 30)
            Button {
                update(min(range.upperBound, value + 1))
            } label: {
                Image(systemName: "plus")
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WatchChoiceRow: View {
    let title: String
    let options: [(WatchMissValue, String)]
    let selection: WatchMissValue
    let color: Color
    let update: (WatchMissValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(options, id: \.0) { option in
                    Button {
                        update(option.0)
                    } label: {
                        Text(option.1)
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selection == option.0 ? color : .gray)
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WatchProximityRow: View {
    let selection: WatchApproachProximity?
    let update: (WatchApproachProximity?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Proximity")
                    .font(.headline)
                Spacer()
                if selection != nil {
                    Button {
                        update(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], spacing: 6) {
                ForEach(WatchApproachProximity.allCases) { proximity in
                    Button {
                        update(proximity)
                    } label: {
                        Text(shortLabel(for: proximity))
                            .font(.caption2.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selection == proximity ? .green : .gray)
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func shortLabel(for proximity: WatchApproachProximity) -> String {
        proximity.rawValue.replacingOccurrences(of: " ft", with: "")
    }
}

struct RunningPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
