import SwiftUI

/// Per-view memo for derived collections that are expensive to rebuild
/// (filter → group → sort over the scene library) but change only when
/// their inputs do. Hold one in `@State`; it is a plain reference so
/// reading or refreshing it inside `body` never invalidates the view.
///
///     @State private var gridMemo = MemoBox<GridKey, GridContents>()
///     let contents = gridMemo(key) { computeGridContents() }
final class MemoBox<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    init() {}

    func callAsFunction(_ key: Key, _ compute: () -> Value) -> Value {
        if self.key == key, let value { return value }
        let fresh = compute()
        self.key = key
        self.value = fresh
        return fresh
    }
}
