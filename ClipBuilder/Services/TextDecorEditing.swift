import Foundation

/// Binding semantics shared by every editor: reads inherit, writes stay local.
nonisolated enum TextDecorEditing {
    static func value<Value>(_ key: KeyPath<TextDecor, Value?>, stored: TextDecor?, inherited: TextDecor) -> Value? {
        (stored ?? TextDecor()).resolved(over: inherited)[keyPath: key]
    }
    static func setting<Value>(_ key: WritableKeyPath<TextDecor, Value?>, to value: Value?, in stored: TextDecor?) -> TextDecor {
        var result = stored ?? TextDecor()
        result[keyPath: key] = value
        return result
    }
}
