import Foundation

/// 从 `batt adapter disable --help` 一类文本判断是否存在限时关闭选项。
/// 按选项词匹配，绝不把 `--force` 等超集当成 `--for`。本类型不执行 batt、不写入。
public enum TimedDisableHelp {
    /// 帮助文本含独立选项 `--for` 或 `--for=` 时为 true；仅有 `--force` 时为 false。
    /// 按选项名精确比较，不用 `contains("--for")`，避免 `--force` 子串命中。
    public static func supportsTimedDisable(_ helpText: String) -> Bool {
        optionTokens(in: helpText).contains { token in
            optionName(of: token) == "--for"
        }
    }

    /// `--for=5s` 的选项名是 `--for`；`--force` 的选项名仍是 `--force`。
    private static func optionName(of token: String) -> String {
        String(token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(token))
    }

    /// 按空白拆成词，再抽出 `--option` / `--option=value`。不把 `--force` 拆成 `--for`。
    public static func optionTokens(in helpText: String) -> [String] {
        helpText.split(whereSeparator: \.isWhitespace).compactMap { piece in
            optionToken(in: piece)
        }
    }

    /// 从单个空白分隔片段取出以 `--` 开头的选项；尾部标点去掉，避免 `[--for=5s]` 漏检。
    private static func optionToken(in piece: Substring) -> String? {
        guard let start = piece.range(of: "--") else { return nil }
        var token = String(piece[start.lowerBound...])
        while let last = token.last, ")]},.;:".contains(last) {
            token.removeLast()
        }
        guard token.hasPrefix("--"), token.count > 2 else { return nil }
        return token
    }
}
