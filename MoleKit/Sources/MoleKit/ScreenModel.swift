/// A minimal VT100 screen: enough of the protocol to read Mole's full-redraw menus.
///
/// Sequences it does not understand are recorded in `unknownSequences`, so drift in
/// Mole's UI shows up as a test failure instead of a silently wrong screen.
public struct ScreenModel: Sendable {
    public let rows: Int
    public let cols: Int
    public private(set) var unknownSequences: [String] = []
    /// Bytes the terminal must answer with (device status / attributes queries).
    public private(set) var pendingReplies: [String] = []

    private var grid: [[Character]]
    private var row = 0
    private var col = 0
    private var saved = (row: 0, col: 0)
    private var state = State.ground
    private var params: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Remaining = 0

    private enum State: Sendable {
        case ground, escape, charset, csi, osc, oscEscape
    }

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        grid = Array(repeating: Array(repeating: " ", count: cols), count: rows)
    }

    /// Screen text, one string per row, trailing blanks removed.
    public var lines: [String] {
        grid.map { chars in
            var line = String(chars)
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    public mutating func takeReplies() -> [String] {
        defer { pendingReplies.removeAll() }
        return pendingReplies
    }

    public mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes { feed(byte) }
    }

    private mutating func feed(_ byte: UInt8) {
        switch state {
        case .ground: ground(byte)
        case .escape: escape(byte)
        case .charset: state = .ground
        case .osc:
            if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .oscEscape }
        case .oscEscape: state = .ground
        case .csi:
            if (0x40...0x7E).contains(byte) {
                dispatchCSI(final: byte)
                state = .ground
            } else {
                params.append(byte)
            }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        if utf8Remaining > 0 {
            utf8.append(byte)
            utf8Remaining -= 1
            if utf8Remaining == 0 {
                for character in String(decoding: utf8, as: UTF8.self) { put(character) }
                utf8.removeAll()
            }
            return
        }
        switch byte {
        case 0x1B: state = .escape
        case 0x0D: col = 0
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x08: col = max(0, min(col, cols - 1) - 1)
        case 0x09: col = min(cols - 1, (col / 8 + 1) * 8)
        case 0x20..<0x7F: put(Character(UnicodeScalar(byte)))
        case 0xC0..<0xE0: startUTF8(byte, remaining: 1)
        case 0xE0..<0xF0: startUTF8(byte, remaining: 2)
        case 0xF0..<0xF8: startUTF8(byte, remaining: 3)
        default: break
        }
    }

    private mutating func startUTF8(_ byte: UInt8, remaining: Int) {
        utf8 = [byte]
        utf8Remaining = remaining
    }

    private mutating func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            params.removeAll()
            state = .csi
        case UInt8(ascii: "]"): state = .osc
        case UInt8(ascii: "("), UInt8(ascii: ")"): state = .charset
        case UInt8(ascii: "7"): saved = (row, col)
        case UInt8(ascii: "8"): (row, col) = saved
        case UInt8(ascii: "M"):
            if row == 0 {
                grid.removeLast()
                grid.insert(blankLine, at: 0)
            } else {
                row -= 1
            }
        case UInt8(ascii: "="), UInt8(ascii: ">"): break
        default: unknownSequences.append("ESC \(Character(UnicodeScalar(byte)))")
        }
    }

    private mutating func dispatchCSI(final: UInt8) {
        let text = String(decoding: params, as: UTF8.self)
        let isPrivate = text.hasPrefix("?")
        let values = text.drop { $0 == "?" || $0 == ">" }
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        // Missing or zero parameters mean "use the default" for movement commands.
        func count(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < values.count, let value = values[index], value > 0 else { return fallback }
            return value
        }
        let mode = values.first.flatMap { $0 } ?? 0

        switch Character(UnicodeScalar(final)) {
        case "m", "t": break
        case "H", "f":
            row = clampRow(count(0) - 1)
            col = clampCol(count(1) - 1)
        case "A": row = max(0, row - count(0))
        case "B": row = min(rows - 1, row + count(0))
        case "C": col = min(cols - 1, col + count(0))
        case "D": col = max(0, min(col, cols - 1) - count(0))
        case "G": col = clampCol(count(0) - 1)
        case "d": row = clampRow(count(0) - 1)
        case "J": eraseDisplay(mode)
        case "K": eraseLine(mode)
        case "s": saved = (row, col)
        case "u": (row, col) = saved
        case "h" where isPrivate, "l" where isPrivate:
            // Alternate screen buffers start blank; cursor, paste and keypad modes don't affect text.
            if values.contains(where: { $0 == 1049 || $0 == 1047 || $0 == 47 }) {
                eraseDisplay(2)
                (row, col) = (0, 0)
            }
        case "n" where mode == 6: pendingReplies.append("\u{1B}[\(row + 1);\(min(col, cols - 1) + 1)R")
        case "c": pendingReplies.append("\u{1B}[?1;2c")
        default: unknownSequences.append("CSI \(text)\(Character(UnicodeScalar(final)))")
        }
    }

    private var blankLine: [Character] { Array(repeating: " ", count: cols) }

    private func clampRow(_ value: Int) -> Int { min(max(value, 0), rows - 1) }
    private func clampCol(_ value: Int) -> Int { min(max(value, 0), cols - 1) }

    private mutating func put(_ character: Character) {
        // Deferred autowrap: a full line wraps only when the next character arrives.
        if col >= cols {
            col = 0
            lineFeed()
        }
        grid[row][col] = character
        col += 1
    }

    private mutating func lineFeed() {
        if row == rows - 1 {
            grid.removeFirst()
            grid.append(blankLine)
        } else {
            row += 1
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for index in (row + 1)..<rows { grid[index] = blankLine }
        case 1:
            eraseLine(1)
            for index in 0..<row { grid[index] = blankLine }
        default:
            grid = Array(repeating: blankLine, count: rows)
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        let cursor = min(col, cols - 1)
        switch mode {
        case 0: for index in cursor..<cols { grid[row][index] = " " }
        case 1: for index in 0...cursor { grid[row][index] = " " }
        default: grid[row] = blankLine
        }
    }
}
