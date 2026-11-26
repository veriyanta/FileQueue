import SwiftUI

/// The Command Line Tools SDK declares `@State` as a macro whose compiler plugin only ships
/// with full Xcode. This alias names the underlying property wrapper directly, so the app
/// builds with either toolchain. Behaves exactly like `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>
