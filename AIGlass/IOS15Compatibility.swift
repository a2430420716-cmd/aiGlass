import SwiftUI

// MARK: - Navigation (iOS 15 → NavigationView)

/// 无 path：iOS 16+ NavigationStack；iOS 15 NavigationView。
struct CompatibleNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

/// 带 `[Value]` path（配对流程）。
struct CompatibleNavigationStackPath<Value: Hashable, Root: View, Destination: View>: View {
    @Binding var path: [Value]
    @ViewBuilder var root: () -> Root
    @ViewBuilder var destination: (Value) -> Destination

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) {
                root()
                    .navigationDestination(for: Value.self) { value in
                        destination(value)
                    }
            }
        } else {
            NavigationView {
                CompatiblePathLevel(
                    path: $path,
                    index: 0,
                    rootView: AnyView(root()),
                    destination: destination
                )
            }
            .navigationViewStyle(.stack)
        }
    }
}

/// iOS 15：`NavigationLink(isActive:)` 按 path 下标逐层 push。
private struct CompatiblePathLevel<Value: Hashable, Destination: View>: View {
    @Binding var path: [Value]
    let index: Int
    let rootView: AnyView
    let destination: (Value) -> Destination

    private var isActive: Binding<Bool> {
        Binding(
            get: { path.count > index },
            set: { active in
                if !active, path.count > index {
                    path.removeLast(path.count - index)
                }
            }
        )
    }

    var body: some View {
        rootView
            .background(
                NavigationLink(
                    isActive: isActive,
                    destination: {
                        if path.count > index {
                            CompatiblePathLevel(
                                path: $path,
                                index: index + 1,
                                rootView: AnyView(destination(path[index])),
                                destination: destination
                            )
                        } else {
                            EmptyView()
                        }
                    },
                    label: { EmptyView() }
                )
                .frame(width: 0, height: 0)
                .hidden()
            )
    }
}

/// 替代 `navigationDestination(isPresented:)`（iOS 17+）。
struct CompatibleNavigationDestination<Destination: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var destination: () -> Destination

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(isPresented: $isPresented, destination: destination)
        } else {
            content.background(
                NavigationLink(
                    isActive: $isPresented,
                    destination: destination,
                    label: { EmptyView() }
                )
                .frame(width: 0, height: 0)
                .hidden()
            )
        }
    }
}

struct CompatibleNavigationDestinationItem<Item: Hashable, Destination: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder var destination: (Item) -> Destination

    private var isPresented: Binding<Bool> {
        Binding(
            get: { item != nil },
            set: { active in
                if !active { item = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $item, destination: destination)
        } else {
            content.background(
                NavigationLink(
                    isActive: isPresented,
                    destination: {
                        if let item {
                            destination(item)
                        } else {
                            EmptyView()
                        }
                    },
                    label: { EmptyView() }
                )
                .frame(width: 0, height: 0)
                .hidden()
            )
        }
    }
}

extension View {
    func compatibleNavigationDestination<D: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> D
    ) -> some View {
        modifier(CompatibleNavigationDestination(isPresented: isPresented, destination: destination))
    }

    /// 可选 item push（对齐 iOS 17 `navigationDestination(item:)`）。
    func compatibleNavigationDestination<Item: Hashable, D: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> D
    ) -> some View {
        modifier(CompatibleNavigationDestinationItem(item: item, destination: destination))
    }

    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (_ newValue: V) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value, perform: action)
        }
    }

    @ViewBuilder
    func compatiblePresentationDetents(_ detents: Set<CompatiblePresentationDetent>) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents(Set(detents.map(\.systemDetent)))
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePresentationDragIndicator(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(visibility)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePresentationCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            presentationCornerRadius(radius)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(style)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleToolbarBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleNavigationContainerBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 18.0, *) {
            containerBackground(style, for: .navigation)
        } else {
            self
        }
    }

    /// iOS 17+ carousel snap；iOS 15/16 普通横滑。
    @ViewBuilder
    func compatibleScrollTargetLayout() -> some View {
        if #available(iOS 17.0, *) {
            scrollTargetLayout()
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollTargetBehaviorViewAligned() -> some View {
        if #available(iOS 17.0, *) {
            scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollPosition(id: Binding<Int?>) -> some View {
        if #available(iOS 17.0, *) {
            scrollPosition(id: id)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollDisabled(_ disabled: Bool) -> some View {
        if #available(iOS 16.0, *) {
            scrollDisabled(disabled)
        } else {
            self
        }
    }
}

enum CompatiblePresentationDetent: Hashable {
    case height(CGFloat)

    @available(iOS 16.0, *)
    var systemDetent: PresentationDetent {
        switch self {
        case .height(let value):
            return .height(value)
        }
    }
}
