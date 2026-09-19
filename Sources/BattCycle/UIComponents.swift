import SwiftUI

struct SurfaceCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusBadge: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(color.opacity(0.10), in: Capsule())
            .fixedSize()
    }
}

struct NoticeView: View {
    let title: String
    let message: String
    let symbol: String
    var color: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: 14, weight: .medium))
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ChargeRangeBar: View {
    let lower: Int
    let upper: Int

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: proxy.size.width * CGFloat(max(0, upper - lower)) / 100)
                        .offset(x: proxy.size.width * CGFloat(lower) / 100)
                }
            }
            .frame(height: 8)
            HStack {
                Text("0%")
                Spacer()
                Text("100%")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("循环区间")
        .accessibilityValue("百分之\(lower)到百分之\(upper)")
    }
}

/// 页面滚动交给根视图；分组卡片不再嵌套 Form 的滚动区域。
struct DashboardForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .labeledContentStyle(DashboardLabeledContentStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardSection<Content: View>: View {
    let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                if let title {
                    Text(title).font(.headline)
                }
                content
            }
        }
    }
}

/// 开发快照只关闭流向动画，不改变读数、控制门禁或正常运行的减弱动态设置。
private struct DashboardSnapshotPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dashboardSnapshotPreview: Bool {
        get { self[DashboardSnapshotPreviewKey.self] }
        set { self[DashboardSnapshotPreviewKey.self] = newValue }
    }
}


private struct DashboardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            configuration.label
            Spacer(minLength: 18)
            configuration.content.multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
