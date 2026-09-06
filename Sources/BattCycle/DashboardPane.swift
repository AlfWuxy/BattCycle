import Foundation

/// 原生侧栏只负责导航；监测、控制与缺测判断仍由对应页面和控制器负责。
enum DashboardPane: String, CaseIterable, Identifiable, Hashable {
    case overview, history, adapter, cycle, advice, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "电池概览"
        case .history: return "曲线与历史"
        case .adapter: return "适配器控制"
        case .cycle: return "循环实验"
        case .advice: return "使用建议"
        case .settings: return "设置与诊断"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "battery.75percent"
        case .history: return "chart.xyaxis.line"
        case .adapter: return "powerplug"
        case .cycle: return "arrow.triangle.2.circlepath"
        case .advice: return "lightbulb"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "看清电量、能量流向与每一项读数的来源。"
        case .history: return "回看电量与净功率，理解时间里的变化。"
        case .adapter: return "查看连接与能力，在明确边界内控制供电。"
        case .cycle: return "设定充放电区间，以及这次实验的边界。"
        case .advice: return "依据本地观测给出建议，由你决定下一步。"
        case .settings: return "管理历史记录、隐私与运行环境。"
        }
    }
}
