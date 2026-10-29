extension Int {
    /// "1 task", "3 tasks": the count with its noun, pluralized with a plain "s".
    public func counted(_ noun: String) -> String {
        "\(self) \(self == 1 ? noun : noun + "s")"
    }
}
