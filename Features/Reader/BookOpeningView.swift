import SwiftUI

/// 阅读器共用的工具栏容器；显隐只改变透明度，不改变正文尺寸。
struct ReaderChrome<Header: View, Footer: View>: View {
    let isPresented: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)

            Spacer(minLength: 0)

            footer()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
        }
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPresented)
    }
}

struct ReaderBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回书籍")
    }
}

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
