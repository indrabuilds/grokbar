import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: UsageViewModel
    @State private var showingSettings = false
    @State private var grokIdentityOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showingSettings {
                settingsPage
            } else {
                usagePage
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSettings {
                Button {
                    showingSettings = false
                } label: {
                    Label("Settings", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Back")
                Spacer()
            } else {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var usagePage: some View {
        let _ = model.clockTick

        if model.hasActiveOutage {
            outageBanner
        }

        VStack(alignment: .leading, spacing: 14) {
            grokCard
            if let updated = model.lastUpdatedAt {
                Text("Updated \(Self.updatedFormatter.localizedString(for: updated, relativeTo: Date()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()
        HStack {
            Button("Quit GrokBar") {
                model.quit()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.callout)
            .keyboardShortcut("q")
            Spacer()
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar")
                .font(.headline)
            Toggle("Show days left", isOn: $model.showDaysLeft)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show days until the usage resets next to the percentage, e.g. 42% · 3d")
            Text("Whole days until the pool resets; under a day shows “<1d”. Hidden if the reset date is unknown.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Usage")
                .font(.headline)
            Text("One shared pool for Grok, Grok Bot and Cursor on the X Subscription, read from your Grok sign-in (`grok login`). Cursor doesn’t need to be open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var grokCard: some View {
        switch model.state {
        case .loaded(let snap):
            providerHeader(
                icon: ProviderIcons.grokBot,
                title: snap.subscriptionLabel,
                name: snap.accountName,
                email: snap.accountEmail ?? model.identity?.email,
                identityOpen: $grokIdentityOpen
            )
            usageBlock(
                usedLabel: "\(Int(snap.usedPercent.rounded()))% of \(snap.cycleLabel.lowercased()) limit used",
                reset: snap.periodEnd,
                usedFraction: snap.usedPercent / 100,
                pace: expectedPace(start: snap.periodStart, end: snap.periodEnd, fallbackDays: 7),
                dayCount: 7
            )
            if !snap.productUsage.isEmpty {
                VStack(spacing: 4) {
                    ForEach(snap.productUsage) { item in
                        HStack {
                            Text(item.displayName)
                                .font(.callout)
                            Spacer(minLength: 8)
                            Text("\(Int(item.usagePercent.rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        case .unavailable(let title, let hint):
            Text(title)
                .font(.callout)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading usage…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerHeader(
        icon: NSImage,
        title: String,
        name: String?,
        email: String?,
        identityOpen: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
                Button {
                    if name != nil || email != nil {
                        identityOpen.wrappedValue.toggle()
                    }
                } label: {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show account")
            }
            if identityOpen.wrappedValue {
                if let name, !name.isEmpty, name != email {
                    Text(name)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func usageBlock(
        usedLabel: String,
        reset: Date?,
        usedFraction: Double,
        pace: Double?,
        dayCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usedLabel)
                    .font(.callout)
                Spacer(minLength: 8)
                if let reset {
                    Text("Resets \(Formatters.resetDateTime.string(from: reset))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            UsageMeter(
                used: usedFraction,
                pace: pace,
                overPace: {
                    if let pace { return usedFraction > pace + 0.0001 }
                    return false
                }(),
                dayCount: dayCount
            )
        }
    }

    private static let updatedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var outageBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("xAI status issue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let headline = model.serviceStatus?.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open status.x.ai") {
                model.openStatusPage()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UsageMeter: View {
    var used: Double
    var pace: Double?
    var overPace: Bool
    var dayCount: Int

    private var fill: Color {
        overPace ? Color.red : Color.accentColor
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(fill)
                    .frame(width: max(4, width * min(max(used, 0), 1)))

                if dayCount >= 2 {
                    ForEach(1..<dayCount, id: \.self) { day in
                        let x = width * CGFloat(day) / CGFloat(dayCount)
                        Capsule()
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 1, height: height * 0.78)
                            .offset(x: x - 0.5)
                    }
                }

                if let pace, pace >= 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: height)
                        .offset(x: width * CGFloat(min(max(pace, 0), 1)) - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
