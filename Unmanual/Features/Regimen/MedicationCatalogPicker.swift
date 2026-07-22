import SwiftUI

struct RegimenMedicationDraft: Identifiable, Equatable {
    enum Origin: Equatable {
        case catalog
        case custom
    }

    let id: UUID
    let catalogID: String?
    let catalogVersion: String?
    let name: String
    let englishName: String
    let detail: String
    let dosageForm: String
    let route: String
    let doseOriginal: String
    let unitOriginal: String
    var schedule: RegimenScheduleInput?
    let productSnapshot: String
    let origin: Origin

    init(
        id: UUID = UUID(),
        catalogID: String? = nil,
        catalogVersion: String? = nil,
        name: String,
        englishName: String = "",
        detail: String,
        dosageForm: String = "",
        route: String = "",
        doseOriginal: String = "",
        unitOriginal: String = "",
        schedule: RegimenScheduleInput? = nil,
        productSnapshot: String? = nil,
        origin: Origin
    ) {
        self.id = id
        self.catalogID = catalogID
        self.catalogVersion = catalogVersion
        self.name = name
        self.englishName = englishName
        self.detail = detail
        self.dosageForm = dosageForm
        self.route = route
        self.doseOriginal = doseOriginal
        self.unitOriginal = unitOriginal
        self.schedule = schedule
        self.productSnapshot = productSnapshot ?? detail
        self.origin = origin
    }
}

struct MedicationCatalogEntry: Identifiable, Hashable {
    enum Group: Hashable {
        case estrogen
        case antiandrogen
        case progestogen

        var title: String {
            switch self {
            case .estrogen: "雌激素相关"
            case .antiandrogen: "抗雄激素相关"
            case .progestogen: "孕激素相关"
            }
        }
    }

    let id: String
    let name: String
    let englishName: String
    let aliases: [String]
    let forms: String
    let group: Group
    let routes: [MedicationCatalogRoute]
    let products: [MedicationProductVariant]

    var searchText: String {
        ([name, englishName, forms, group.title] + aliases).joined(separator: " ")
    }

    func draft(for product: MedicationProductVariant) -> RegimenMedicationDraft {
        RegimenMedicationDraft(
            catalogID: product.id,
            name: product.displayName,
            englishName: englishName,
            detail: "\(product.manufacturer) · \(product.form) · \(product.routeTitle)",
            dosageForm: product.form,
            route: product.routeTitle,
            productSnapshot: "\(product.manufacturer) · \(product.form) · \(product.routeTitle)",
            origin: .catalog
        )
    }
}

struct MedicationCatalogRoute: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
}

struct MedicationProductVariant: Identifiable, Hashable {
    let id: String
    let routeID: String
    let routeTitle: String
    let displayName: String
    let manufacturer: String
    let form: String
    let sourceStatus: String
}

enum MedicationCatalog {
#if DEBUG
    static let entries: [MedicationCatalogEntry] = [
        MedicationCatalogEntry(
            id: "estradiol",
            name: "雌二醇",
            englishName: "Estradiol",
            aliases: ["17β-雌二醇", "E2"],
            forms: "片剂、贴片、凝胶等",
            group: .estrogen,
            routes: [
                MedicationCatalogRoute(id: "oral", title: "口服", detail: "片剂等"),
                MedicationCatalogRoute(id: "transdermal", title: "经皮", detail: "贴片、凝胶等")
            ],
            products: [
                MedicationProductVariant(
                    id: "estradiol-oral-placeholder",
                    routeID: "oral",
                    routeTitle: "口服",
                    displayName: "雌二醇片",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "片剂",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                ),
                MedicationProductVariant(
                    id: "estradiol-patch-placeholder",
                    routeID: "transdermal",
                    routeTitle: "经皮",
                    displayName: "雌二醇透皮贴片",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "贴片",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                ),
                MedicationProductVariant(
                    id: "estradiol-gel-placeholder",
                    routeID: "transdermal",
                    routeTitle: "经皮",
                    displayName: "雌二醇凝胶",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "凝胶",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                )
            ]
        ),
        MedicationCatalogEntry(
            id: "estradiol-valerate",
            name: "戊酸雌二醇",
            englishName: "Estradiol valerate",
            aliases: ["补佳乐"],
            forms: "片剂、注射剂等",
            group: .estrogen,
            routes: [
                MedicationCatalogRoute(id: "oral", title: "口服", detail: "片剂等"),
                MedicationCatalogRoute(id: "injection", title: "注射", detail: "注射剂等")
            ],
            products: [
                MedicationProductVariant(
                    id: "estradiol-valerate-oral-placeholder",
                    routeID: "oral",
                    routeTitle: "口服",
                    displayName: "戊酸雌二醇片",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "片剂",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                ),
                MedicationProductVariant(
                    id: "estradiol-valerate-injection-placeholder",
                    routeID: "injection",
                    routeTitle: "注射",
                    displayName: "戊酸雌二醇注射剂",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "注射剂",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                )
            ]
        ),
        MedicationCatalogEntry(
            id: "spironolactone",
            name: "螺内酯",
            englishName: "Spironolactone",
            aliases: ["安体舒通"],
            forms: "片剂等",
            group: .antiandrogen,
            routes: [MedicationCatalogRoute(id: "oral", title: "口服", detail: "片剂等")],
            products: [
                MedicationProductVariant(
                    id: "spironolactone-oral-placeholder",
                    routeID: "oral",
                    routeTitle: "口服",
                    displayName: "螺内酯片",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "片剂",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                )
            ]
        ),
        MedicationCatalogEntry(
            id: "cyproterone-acetate",
            name: "醋酸环丙孕酮",
            englishName: "Cyproterone acetate",
            aliases: ["色普龙"],
            forms: "片剂等",
            group: .antiandrogen,
            routes: [MedicationCatalogRoute(id: "oral", title: "口服", detail: "片剂等")],
            products: [
                MedicationProductVariant(
                    id: "cyproterone-acetate-oral-placeholder",
                    routeID: "oral",
                    routeTitle: "口服",
                    displayName: "醋酸环丙孕酮片",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "片剂",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                )
            ]
        ),
        MedicationCatalogEntry(
            id: "progesterone",
            name: "黄体酮",
            englishName: "Progesterone",
            aliases: ["孕酮", "微粒化黄体酮"],
            forms: "胶囊等",
            group: .progestogen,
            routes: [MedicationCatalogRoute(id: "oral", title: "口服", detail: "胶囊等")],
            products: [
                MedicationProductVariant(
                    id: "progesterone-oral-placeholder",
                    routeID: "oral",
                    routeTitle: "口服",
                    displayName: "黄体酮胶囊",
                    manufacturer: "厂商与批准资料待官方目录接入",
                    form: "胶囊",
                    sourceStatus: "界面示例 · 尚未建立官方资料关联"
                )
            ]
        )
    ]
#else
    static let entries: [MedicationCatalogEntry] = []
#endif

    static func search(_ query: String) -> [MedicationCatalogEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.searchText.localizedCaseInsensitiveContains(term) }
    }
}

@MainActor
struct MedicationCatalogPicker: View {
    @Environment(AppTheme.self) private var theme

    let backAction: () -> Void
    let chooseAction: (RegimenMedicationDraft) -> Void

    @State private var query = ""
    @State private var openedEntry: MedicationCatalogEntry?
    @State private var showsCustomEditor = false
    @FocusState private var searchIsFocused: Bool

    private var results: [MedicationCatalogEntry] {
        MedicationCatalog.search(query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MedicationPickerHeader(label: "返回方案", backAction: backAction)

                VStack(alignment: .leading, spacing: 8) {
                    Text("CATALOG ENTRY")
                        .font(theme.utility(10))
                        .tracking(0.9)
                        .foregroundStyle(theme.vermilion)
                    Text("添加药物")
                        .font(theme.display(36, relativeTo: .largeTitle))
                        .foregroundStyle(theme.indigoDeep)
                    Text("先从成分开始查找。进入条目后，再按给药途径和厂商定位具体产品。")
                        .font(.subheadline)
                        .foregroundStyle(theme.indigo.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 22)
                .padding(.bottom, 20)

                MedicationSearchIndex(query: $query, isFocused: $searchIsFocused)

                V25SectionHeader(
                    title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "药品索引" : "检索结果",
                    detail: "\(results.count) 项"
                )

                if results.isEmpty {
                    MedicationNoResults(
                        query: query,
                        catalogUnavailable: MedicationCatalog.entries.isEmpty
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(results) { entry in
                            MedicationCatalogRow(
                                entry: entry,
                                action: { open(entry) }
                            )
                        }
                    }
                    .background(theme.paper)
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                }

                V25PrivacyFooter(text: "进入条目定位具体产品，再加入当前方案")
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, V25Theme.pagePadding)
            .frame(maxWidth: V25Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .background(theme.rice.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MedicationCatalogCustomBar(action: presentCustomEditor)
        }
        .navigationDestination(item: $openedEntry) { entry in
            MedicationProductPicker(
                entry: entry,
                backAction: { openedEntry = nil },
                chooseAction: chooseAction
            )
        }
        .navigationDestination(isPresented: $showsCustomEditor) {
            MedicationCustomEntryEditor(
                suggestedName: query,
                backAction: { showsCustomEditor = false },
                addAction: chooseAction
            )
        }
    }

    private func open(_ entry: MedicationCatalogEntry) {
        openedEntry = entry
        searchIsFocused = false
    }

    private func presentCustomEditor() {
        searchIsFocused = false
        showsCustomEditor = true
    }
}

private struct MedicationPickerHeader: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let label: String
    let backAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: backAction) {
                Label(dynamicTypeSize.isAccessibilitySize ? "返回" : label, systemImage: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

            Spacer()

            Text(dynamicTypeSize.isAccessibilitySize ? "本机索引" : "LOCAL / INDEX")
                .font(theme.utility(10))
                .tracking(0.9)
        }
        .foregroundStyle(theme.indigo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

private struct MedicationSearchIndex: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dynamicTypeSize.isAccessibilitySize ? "药品索引" : "MEDICATION INDEX")
                    .font(theme.utility(9))
                    .tracking(0.9)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                    Text("中文 · ENGLISH · 商品名")
                        .font(theme.utility(8))
                        .tracking(0.5)
                        .foregroundStyle(theme.indigo.opacity(0.55))
                }
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(theme.blue.opacity(0.18))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }

            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityHidden(true)

                TextField(
                    dynamicTypeSize.isAccessibilitySize ? "搜索药品名称" : "搜索成分、通用名或商品名",
                    text: $query
                )
                    .focused(isFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("medication.search")

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(theme.indigo.opacity(0.58))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, query.isEmpty ? 13 : 1)
            .frame(minHeight: 58)
        }
        .foregroundStyle(theme.indigoDeep)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
        .background(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard.opacity(0.82))
                .offset(x: 5, y: 5)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 5)
        .padding(.bottom, 5)
    }
}

private struct MedicationCatalogRow: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let entry: MedicationCatalogEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        entryCopy
                        HStack {
                            Text(entry.group.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(groupColor)
                            Spacer()
                            actionMark
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        entryCopy
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(entry.group.title)
                                .font(.caption.weight(.black))
                                .foregroundStyle(groupColor)
                            actionMark
                        }
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .contentShape(Rectangle())
            .background(theme.paper)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(groupColor)
                    .frame(width: 6)
                    .padding(.vertical, 10)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo.opacity(0.36)).frame(height: 1)
            }
        }
        .buttonStyle(V25PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.name)，\(entry.englishName)，\(entry.group.title)，\(entry.routes.count) 种给药途径，打开产品选择"
        )
        .accessibilityIdentifier("medication.catalog.\(entry.id)")
    }

    private var entryCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.name)
                .font(.body.weight(.black))
                .foregroundStyle(theme.indigoDeep)
            Text(entry.englishName)
                .font(theme.utility(10))
                .tracking(0.25)
                .foregroundStyle(theme.indigo.opacity(0.66))
            Text("\(entry.routes.count) 种给药途径 · \(entry.products.count) 个产品条目")
                .font(.caption)
                .foregroundStyle(theme.indigo.opacity(0.66))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionMark: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14, weight: .black))
        .foregroundStyle(theme.vermilion)
        .frame(width: 44, height: 44, alignment: .trailing)
    }

    private var groupColor: Color {
        switch group {
        case .estrogen: theme.vermilion
        case .antiandrogen: theme.blue
        case .progestogen: theme.moss
        }
    }

    private var group: MedicationCatalogEntry.Group { entry.group }
}

private struct MedicationNoResults: View {
    @Environment(AppTheme.self) private var theme

    let query: String
    let catalogUnavailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(catalogUnavailable ? "CATALOG PENDING" : "NO MATCH")
                .font(theme.utility(10))
                .tracking(0.8)
                .foregroundStyle(theme.vermilion)
            Text(
                catalogUnavailable
                    ? "正式药品目录尚未提供。"
                    : "索引里暂时没有“\(query)”。"
            )
                .font(theme.display(23, relativeTo: .title3))
                .foregroundStyle(theme.indigoDeep)
            Text("你仍然可以按药盒、处方或自己的原始记录添加，不需要换成目录里的近似名称。")
                .font(.subheadline)
                .foregroundStyle(theme.indigo.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

private struct MedicationCatalogCustomBar: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                dynamicTypeSize.isAccessibilitySize ? "自定义添加" : "没有合适条目？自定义添加",
                systemImage: "plus"
            )
            .frame(maxWidth: .infinity)
            }
        .buttonStyle(V25SecondaryButtonStyle())
        .accessibilityLabel("没有合适条目？自定义添加药物")
        .accessibilityIdentifier("medication.custom")
        .padding(.horizontal, V25Theme.pagePadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: V25Theme.contentWidth)
        .frame(maxWidth: .infinity)
        .background(theme.rice)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

@MainActor
private struct MedicationProductPicker: View {
    @Environment(AppTheme.self) private var theme

    let entry: MedicationCatalogEntry
    let backAction: () -> Void
    let chooseAction: (RegimenMedicationDraft) -> Void

    @State private var selectedRouteID: String
    @State private var selectedProduct: MedicationProductVariant?

    init(
        entry: MedicationCatalogEntry,
        backAction: @escaping () -> Void,
        chooseAction: @escaping (RegimenMedicationDraft) -> Void
    ) {
        self.entry = entry
        self.backAction = backAction
        self.chooseAction = chooseAction
        _selectedRouteID = State(initialValue: entry.routes.first?.id ?? "")
    }

    private var selectedRoute: MedicationCatalogRoute? {
        entry.routes.first { $0.id == selectedRouteID }
    }

    private var visibleProducts: [MedicationProductVariant] {
        entry.products.filter { $0.routeID == selectedRouteID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MedicationPickerHeader(label: "返回药品索引", backAction: backAction)

                MedicationIngredientMasthead(entry: entry)
                    .padding(.top, 22)

                MedicationLocatorStrip(
                    ingredient: entry.name,
                    route: selectedRoute?.title ?? "待选择",
                    product: selectedProduct?.displayName ?? "待选择"
                )
                .padding(.top, 18)

                V25SectionHeader(title: "选择给药途径", detail: "1 / 2")

                VStack(spacing: 0) {
                    ForEach(entry.routes) { route in
                        MedicationRouteRow(
                            route: route,
                            productCount: entry.products.filter { $0.routeID == route.id }.count,
                            isSelected: selectedRouteID == route.id,
                            action: { selectRoute(route) }
                        )
                    }
                }
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

                V25SectionHeader(title: "选择厂商与产品", detail: "2 / 2")

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme.blue)
                            .accessibilityHidden(true)
                        Text("正式目录中，每个厂商、剂型和批准信息都会拆成独立产品条目；当前只展示页面结构。")
                            .font(.caption)
                            .foregroundStyle(theme.indigo.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.blue.opacity(0.13))

                    ForEach(visibleProducts) { product in
                        MedicationProductRow(
                            product: product,
                            isSelected: selectedProduct?.id == product.id,
                            action: { selectedProduct = product }
                        )
                    }
                }
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

            }
            .padding(.bottom, 20)
            .padding(.horizontal, V25Theme.pagePadding)
            .frame(maxWidth: V25Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(theme.rice.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MedicationProductSelectionBar(
                product: selectedProduct,
                action: chooseSelectedProduct
            )
        }
    }

    private func selectRoute(_ route: MedicationCatalogRoute) {
        guard route.id != selectedRouteID else { return }
        selectedRouteID = route.id
        selectedProduct = nil
    }

    private func chooseSelectedProduct() {
        guard let selectedProduct else { return }
        chooseAction(entry.draft(for: selectedProduct))
    }
}

private struct MedicationIngredientMasthead: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let entry: MedicationCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            copy

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.group.title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(groupColor)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("\(entry.routes.count) 种途径 · \(entry.products.count) 个产品条目")
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.58))
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 15)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(groupColor)
                .frame(width: 7)
        }
        .background(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard.opacity(0.8))
                .offset(x: 5, y: 5)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 5)
        .padding(.bottom, 5)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("INGREDIENT / 已确定")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.vermilion)
            Text(entry.name)
                .font(theme.display(32, relativeTo: .largeTitle))
                .foregroundStyle(theme.indigoDeep)
            Text(entry.englishName)
                .font(theme.utility(11))
                .tracking(0.35)
                .foregroundStyle(theme.indigo.opacity(0.64))
        }
    }

    private var groupColor: Color {
        switch entry.group {
        case .estrogen: theme.vermilion
        case .antiandrogen: theme.blue
        case .progestogen: theme.moss
        }
    }
}

private struct MedicationLocatorStrip: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let ingredient: String
    let route: String
    let product: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    item(label: "成分", value: ingredient, isPending: false)
                    item(label: "途径", value: route, isPending: false)
                    item(label: "产品", value: product, isPending: product == "待选择")
                }
            } else {
                HStack(spacing: 0) {
                    item(label: "成分", value: ingredient, isPending: false)
                    item(label: "途径", value: route, isPending: false)
                    item(label: "产品", value: product, isPending: product == "待选择")
                }
            }
        }
        .background(theme.indigoDeep)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .accessibilityElement(children: .contain)
    }

    private func item(label: String, value: String, isPending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(theme.utility(8))
                .tracking(0.7)
                .foregroundStyle(theme.mustard)
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(isPending ? theme.paper.opacity(0.52) : theme.paper)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .overlay(alignment: dynamicTypeSize.isAccessibilitySize ? .bottom : .trailing) {
            Rectangle()
                .fill(theme.paper.opacity(0.22))
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? nil : 1,
                    height: dynamicTypeSize.isAccessibilitySize ? 1 : nil
                )
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MedicationRouteRow: View {
    @Environment(AppTheme.self) private var theme

    let route: MedicationCatalogRoute
    let productCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? theme.vermilion : theme.indigo.opacity(0.52))
                    .frame(width: 32, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(route.title)
                        .font(.body.weight(.black))
                    Text(route.detail)
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.64))
                }

                Spacer()

                Text("\(productCount) 个产品条目")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.indigo.opacity(0.58))
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(isSelected ? theme.mustard.opacity(0.16) : theme.paper)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo.opacity(0.34)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(route.title)，\(route.detail)，\(productCount) 个产品条目")
        .accessibilityValue(isSelected ? "已选择" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("medication.route.\(route.id)")
    }
}

private struct MedicationProductRow: View {
    @Environment(AppTheme.self) private var theme

    let product: MedicationProductVariant
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? theme.vermilion : theme.indigo.opacity(0.52))
                    .frame(width: 32, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(product.displayName)
                        .font(.body.weight(.black))
                        .foregroundStyle(theme.indigoDeep)
                    Text(product.manufacturer)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.indigo.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Text("\(product.routeTitle) · \(product.form)")
                        Text(product.sourceStatus)
                            .foregroundStyle(theme.vermilion)
                    }
                    .font(theme.utility(8))
                    .tracking(0.25)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(isSelected ? theme.mustard.opacity(0.16) : theme.paper)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo.opacity(0.34)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(product.displayName)，\(product.manufacturer)，\(product.routeTitle)，\(product.form)，\(product.sourceStatus)"
        )
        .accessibilityValue(isSelected ? "已选择" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("medication.product.\(product.id)")
    }
}

private struct MedicationProductSelectionBar: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let product: MedicationProductVariant?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let product {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("已定位")
                        .font(theme.utility(9))
                        .tracking(0.6)
                        .foregroundStyle(theme.vermilion)
                    Text(product.displayName)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(theme.indigoDeep)
                    Spacer()
                    Text(product.routeTitle)
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.6))
                }
            }

            Button(
                product == nil
                    ? (dynamicTypeSize.isAccessibilitySize ? "先选择产品" : "选择具体产品后加入")
                    : "加入方案草稿",
                action: action
            )
            .buttonStyle(V25PrimaryButtonStyle())
            .disabled(product == nil)
            .opacity(product == nil ? 0.46 : 1)
            .accessibilityIdentifier("medication.product.add")
        }
        .padding(.horizontal, V25Theme.pagePadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: V25Theme.contentWidth)
        .frame(maxWidth: .infinity)
        .background(theme.rice)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

@MainActor
private struct MedicationCustomEntryEditor: View {
    @Environment(AppTheme.self) private var theme

    let suggestedName: String
    let backAction: () -> Void
    let addAction: (RegimenMedicationDraft) -> Void

    @State private var name: String
    @State private var genericName = ""
    @State private var dosageForm = ""
    @State private var route = ""
    @State private var doseOriginal = ""
    @State private var unitOriginal = ""

    init(
        suggestedName: String,
        backAction: @escaping () -> Void,
        addAction: @escaping (RegimenMedicationDraft) -> Void
    ) {
        self.suggestedName = suggestedName
        self.backAction = backAction
        self.addAction = addAction
        _name = State(initialValue: suggestedName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        V25EditorPage(
            register: "LOCAL / CUSTOM ENTRY",
            eyebrow: "ORIGINAL WORDING",
            title: "自定义药物",
            detail: "按药盒、处方或自己的记录原样填写；以后可以再关联到药品目录。",
            cancel: backAction
        ) {
            VStack(spacing: V25Theme.fieldSpacing) {
                V25FieldSurface("显示名称") {
                    TextField("例如：药盒上的名称", text: $name)
                        .accessibilityIdentifier("medication.custom.name")
                }

                V25FieldSurface("成分或通用名（可选）") {
                    TextField("不知道可以留空", text: $genericName)
                        .accessibilityIdentifier("medication.custom.generic")
                }

                V25FieldSurface("剂型（可选）") {
                    TextField("例如：片剂、凝胶", text: $dosageForm)
                        .accessibilityIdentifier("medication.custom.form")
                }

                V25FieldSurface("给药途径（可选）") {
                    TextField("例如：口服、经皮", text: $route)
                        .accessibilityIdentifier("medication.custom.route")
                }

                V25FieldSurface(
                    "用量原文（可选）",
                    note: "只保存你的原始写法，不推荐或纠正用量。"
                ) {
                    TextField("例如：药盒或自己的记录原文", text: $doseOriginal)
                        .accessibilityIdentifier("medication.custom.dose")
                }

                V25FieldSurface("单位原文（可选）") {
                    TextField("例如：片、泵、贴", text: $unitOriginal)
                        .accessibilityIdentifier("medication.custom.unit")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            V25SaveBar(
                title: "加入方案草稿",
                isEnabled: canAdd,
                accessibilityIdentifier: "medication.custom.add",
                action: add
            )
        }
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenericName = genericName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedForm = dosageForm.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoute = route.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDose = doseOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unitOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [trimmedForm, trimmedRoute, trimmedDose, trimmedUnit]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        addAction(
            RegimenMedicationDraft(
                name: trimmedName,
                englishName: trimmedGenericName,
                detail: detail.isEmpty ? "自定义条目 · 待补充" : detail,
                dosageForm: trimmedForm,
                route: trimmedRoute,
                doseOriginal: trimmedDose,
                unitOriginal: trimmedUnit,
                origin: .custom
            )
        )
    }
}

#Preview("添加药物 · 药品索引") {
    NavigationStack {
        MedicationCatalogPicker(backAction: {}, chooseAction: { _ in })
    }
    .environment(AppTheme())
}
