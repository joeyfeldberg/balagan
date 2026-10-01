import Foundation

public struct TerminalControlKeyMapping: Equatable {
    public var keyCode: UInt16
    public var charactersIgnoringModifiers: String?
    public var hasControlModifier: Bool
    public var hasCommandModifier: Bool
    public var hasOptionModifier: Bool

    public init(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        hasControlModifier: Bool,
        hasCommandModifier: Bool,
        hasOptionModifier: Bool
    ) {
        self.keyCode = keyCode
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.hasControlModifier = hasControlModifier
        self.hasCommandModifier = hasCommandModifier
        self.hasOptionModifier = hasOptionModifier
    }

    public var controlCharacter: String? {
        guard let scalar = controlLetterScalar else {
            return nil
        }

        let controlScalarValue = scalar.value - UnicodeScalar("a").value + 1
        guard let controlScalar = UnicodeScalar(controlScalarValue) else {
            return nil
        }

        return String(controlScalar)
    }

    public var controlKeyText: String? {
        controlLetterScalar.map(String.init)
    }

    private var controlLetterScalar: UnicodeScalar? {
        guard hasControlModifier, hasCommandModifier == false, hasOptionModifier == false else {
            return nil
        }

        return letterScalar
    }

    private var letterScalar: UnicodeScalar? {
        if let charactersIgnoringModifiers,
           charactersIgnoringModifiers.isEmpty == false {
            guard let scalar = charactersIgnoringModifiers
                .lowercased()
                .unicodeScalars
                .first
            else {
                return nil
            }

            if UnicodeScalar("a").value...UnicodeScalar("z").value ~= scalar.value {
                return scalar
            }

            if scalar.value >= 32 {
                return nil
            }
        }

        return Self.usKeyboardLetterScalarsByKeyCode[keyCode]
    }

    private static let usKeyboardLetterScalarsByKeyCode: [UInt16: UnicodeScalar] = [
        0: "a",
        11: "b",
        8: "c",
        2: "d",
        14: "e",
        3: "f",
        5: "g",
        4: "h",
        34: "i",
        38: "j",
        40: "k",
        37: "l",
        46: "m",
        45: "n",
        31: "o",
        35: "p",
        12: "q",
        15: "r",
        1: "s",
        17: "t",
        32: "u",
        9: "v",
        13: "w",
        7: "x",
        16: "y",
        6: "z",
    ]
}
