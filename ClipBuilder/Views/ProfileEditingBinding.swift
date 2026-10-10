import SwiftUI

extension AppStore {
    func editingBinding<Value>(_ keyPath: WritableKeyPath<ProfileEditingDefaults, Value>) -> Binding<Value> {
        Binding(get: { self.editingDefaults[keyPath: keyPath] }, set: { value in
            var editing = self.editingDefaults
            editing[keyPath: keyPath] = value
            self.activeProfile.editing = editing
            self.saveActiveProfile()
        })
    }
}
