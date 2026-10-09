import SwiftUI

private struct BookCoverNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var bookCoverNamespace: Namespace.ID? {
        get { self[BookCoverNamespaceKey.self] }
        set { self[BookCoverNamespaceKey.self] = newValue }
    }
}

extension View {
    /// 只标记屏幕上的真实封面，让系统从该封面的尺寸与位置开始转场。
    func bookCoverSource(id: String) -> some View {
        modifier(BookCoverSourceModifier(id: id))
    }

    func bookCoverDestination(id: String) -> some View {
        modifier(BookCoverDestinationModifier(id: id))
    }
}

private struct BookCoverSourceModifier: ViewModifier {
    let id: String
    @Environment(\.bookCoverNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct BookCoverDestinationModifier: ViewModifier {
    let id: String
    @Environment(\.bookCoverNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            if #available(iOS 27.0, *) {
                content.navigationTransition(
                    reduceMotion
                        ? AnyNavigationTransition(.automatic)
                        : AnyNavigationTransition(.zoom(sourceID: id, in: namespace))
                )
            } else if reduceMotion {
                content.navigationTransition(.automatic)
            } else {
                content.navigationTransition(.zoom(sourceID: id, in: namespace))
            }
        } else {
            content
        }
    }
}
