import Foundation

// MARK: - Kiểu

public enum BlockCategory: String, CaseIterable {
    case motion, looks, sound, events, control, sensing, operators, pen, data

    public var title: String {
        switch self {
        case .motion: return "Chuyển động"
        case .looks: return "Hiển thị"
        case .sound: return "Âm thanh"
        case .events: return "Sự kiện"
        case .control: return "Điều khiển"
        case .sensing: return "Cảm biến"
        case .operators: return "Toán tử"
        case .pen: return "Bút vẽ"
        case .data: return "Biến số"
        }
    }

    public var colorHex: UInt32 {
        switch self {
        case .motion: return 0x4C97FF
        case .looks: return 0x9966FF
        case .sound: return 0xCF63CF
        case .events: return 0xE6A800
        case .control: return 0xFFAB19
        case .sensing: return 0x5CB1D6
        case .operators: return 0x59C059
        case .pen: return 0x0FBD8C
        case .data: return 0xFF8C1A
        }
    }
}

public enum BlockShape { case hat, stack, cap, c, cElse, cCap, reporter, boolean }

public struct MenuOption {
    public let value: String
    public let label: String
    public let id: String?
    public init(value: String, label: String, id: String? = nil) {
        self.value = value; self.label = label; self.id = id
    }
}

public enum MenuSource {
    case fixed([MenuOption])
    case touching, gotoTargets, distanceTargets, cloneTargets
    case costumes, backdrops, sounds, broadcasts, variables, lists, keys
}

public enum InputKind {
    case number, text, boolean, color
    case menu(opcode: String, field: String, source: MenuSource)
    case broadcast
}

public struct InputSpec {
    public let name: String
    public let kind: InputKind
    public let defaultValue: String
}

public struct FieldSpec {
    public let name: String
    public let source: MenuSource
    public let defaultValue: String
}

public enum Segment {
    case text(String)
    case input(InputSpec)
    case field(FieldSpec)
}

public struct BlockSpec {
    public let opcode: String
    public let category: BlockCategory
    public let shape: BlockShape
    public let segments: [Segment]

    public var substackNames: [String] {
        switch shape {
        case .c, .cCap: return ["SUBSTACK"]
        case .cElse: return ["SUBSTACK", "SUBSTACK2"]
        default: return []
        }
    }
    public var hasNext: Bool {
        switch shape {
        case .stack, .hat, .c, .cElse: return true
        default: return false
        }
    }
    public var isReporter: Bool { shape == .reporter || shape == .boolean }
}

// MARK: - Ngữ cảnh để lấy danh sách lựa chọn

public struct EditorContext {
    public let target: Target
    public let stage: Target
    public let spriteNames: [String]
    public let broadcasts: [String]

    public init(target: Target, stage: Target, spriteNames: [String], broadcasts: [String]) {
        self.target = target
        self.stage = stage
        self.spriteNames = spriteNames
        self.broadcasts = broadcasts
    }

    private func special(_ v: String) -> MenuOption {
        switch v {
        case "_mouse_": return MenuOption(value: v, label: "con trỏ chuột")
        case "_random_": return MenuOption(value: v, label: "vị trí ngẫu nhiên")
        case "_edge_": return MenuOption(value: v, label: "cạnh sân khấu")
        case "_myself_": return MenuOption(value: v, label: "chính nó")
        default: return MenuOption(value: v, label: v)
        }
    }

    public func options(_ src: MenuSource) -> [MenuOption] {
        let others = spriteNames.filter { $0 != target.name }.map { MenuOption(value: $0, label: $0) }
        switch src {
        case .fixed(let o): return o
        case .touching: return [special("_mouse_"), special("_edge_")] + others
        case .gotoTargets: return [special("_random_"), special("_mouse_")] + others
        case .distanceTargets: return [special("_mouse_")] + others
        case .cloneTargets: return (target.isStage ? [] : [special("_myself_")]) + others
        case .costumes: return target.costumes.map { MenuOption(value: $0.name, label: $0.name) }
        case .backdrops: return stage.costumes.map { MenuOption(value: $0.name, label: $0.name) }
        case .sounds: return target.sounds.map { MenuOption(value: $0.name, label: $0.name) }
        case .broadcasts: return broadcasts.map { MenuOption(value: $0, label: $0) }
        case .variables:
            var all = Array(target.variables.values)
            if target !== stage { all += Array(stage.variables.values) }
            return all.sorted { $0.name < $1.name }.map { MenuOption(value: $0.name, label: $0.name, id: $0.id) }
        case .lists:
            var all = Array(target.lists.values)
            if target !== stage { all += Array(stage.lists.values) }
            return all.sorted { $0.name < $1.name }.map { MenuOption(value: $0.name, label: $0.name, id: $0.id) }
        case .keys:
            var o: [MenuOption] = [
                MenuOption(value: "space", label: "phím cách"),
                MenuOption(value: "up arrow", label: "mũi tên lên"),
                MenuOption(value: "down arrow", label: "mũi tên xuống"),
                MenuOption(value: "left arrow", label: "mũi tên trái"),
                MenuOption(value: "right arrow", label: "mũi tên phải"),
                MenuOption(value: "any", label: "bất kỳ phím")
            ]
            for c in "abcdefghijklmnopqrstuvwxyz0123456789" { o.append(MenuOption(value: String(c), label: String(c))) }
            return o
        }
    }

    public func label(for value: String, source: MenuSource) -> String {
        return options(source).first(where: { $0.value == value })?.label ?? value
    }
}

// MARK: - Hàm dựng nhanh (chỉ dùng trong file này)

private func txt(_ s: String) -> Segment { .text(s) }
private func tNum(_ n: String, _ d: String = "") -> Segment {
    .input(InputSpec(name: n, kind: .number, defaultValue: d))
}
private func tStr(_ n: String, _ d: String = "") -> Segment {
    .input(InputSpec(name: n, kind: .text, defaultValue: d))
}
private func tBool(_ n: String) -> Segment {
    .input(InputSpec(name: n, kind: .boolean, defaultValue: ""))
}
private func tColor(_ n: String, _ d: String) -> Segment {
    .input(InputSpec(name: n, kind: .color, defaultValue: d))
}
private func tMenu(_ n: String, _ op: String, _ field: String, _ src: MenuSource, _ d: String = "") -> Segment {
    .input(InputSpec(name: n, kind: .menu(opcode: op, field: field, source: src), defaultValue: d))
}
private func tBcast(_ n: String) -> Segment {
    .input(InputSpec(name: n, kind: .broadcast, defaultValue: ""))
}
private func tField(_ n: String, _ src: MenuSource, _ d: String = "") -> Segment {
    .field(FieldSpec(name: n, source: src, defaultValue: d))
}
private func opt(_ v: String, _ l: String) -> MenuOption { MenuOption(value: v, label: l) }
private func S(_ op: String, _ cat: BlockCategory, _ shape: BlockShape, _ segs: [Segment]) -> BlockSpec {
    BlockSpec(opcode: op, category: cat, shape: shape, segments: segs)
}

// MARK: - Danh mục

public enum BlockCatalog {

    public static func spec(for opcode: String) -> BlockSpec? { index[opcode] }

    public static func specs(in category: BlockCategory) -> [BlockSpec] {
        return all.filter { $0.category == category }
    }

    private static let index: [String: BlockSpec] = {
        var d: [String: BlockSpec] = [:]
        for s in all { d[s.opcode] = s }
        return d
    }()

    public static let all: [BlockSpec] = [motion, looks, sound, events, control, sensing, operators, pen, data]
        .flatMap { $0 }

    // MARK: Chuyển động
    private static let motion: [BlockSpec] = {
        let c = BlockCategory.motion
        let styles = MenuSource.fixed([opt("left-right", "trái-phải"), opt("don't rotate", "không xoay"), opt("all around", "mọi hướng")])
        var a: [BlockSpec] = []
        a.append(S("motion_movesteps", c, .stack, [txt("di chuyển"), tNum("STEPS", "10"), txt("bước")]))
        a.append(S("motion_turnright", c, .stack, [txt("quay phải"), tNum("DEGREES", "15"), txt("độ")]))
        a.append(S("motion_turnleft", c, .stack, [txt("quay trái"), tNum("DEGREES", "15"), txt("độ")]))
        a.append(S("motion_goto", c, .stack, [txt("đi tới"), tMenu("TO", "motion_goto_menu", "TO", .gotoTargets)]))
        a.append(S("motion_gotoxy", c, .stack, [txt("đi tới x:"), tNum("X", "0"), txt("y:"), tNum("Y", "0")]))
        a.append(S("motion_glideto", c, .stack, [txt("lướt"), tNum("SECS", "1"), txt("giây tới"), tMenu("TO", "motion_glideto_menu", "TO", .gotoTargets)]))
        a.append(S("motion_glidesecstoxy", c, .stack, [txt("lướt"), tNum("SECS", "1"), txt("giây tới x:"), tNum("X", "0"), txt("y:"), tNum("Y", "0")]))
        a.append(S("motion_pointindirection", c, .stack, [txt("hướng theo"), tNum("DIRECTION", "90")]))
        a.append(S("motion_pointtowards", c, .stack, [txt("hướng về"), tMenu("TOWARDS", "motion_pointtowards_menu", "TOWARDS", .gotoTargets)]))
        a.append(S("motion_changexby", c, .stack, [txt("thay đổi x một lượng"), tNum("DX", "10")]))
        a.append(S("motion_setx", c, .stack, [txt("đặt x thành"), tNum("X", "0")]))
        a.append(S("motion_changeyby", c, .stack, [txt("thay đổi y một lượng"), tNum("DY", "10")]))
        a.append(S("motion_sety", c, .stack, [txt("đặt y thành"), tNum("Y", "0")]))
        a.append(S("motion_ifonedgebounce", c, .stack, [txt("nảy lại nếu chạm cạnh")]))
        a.append(S("motion_setrotationstyle", c, .stack, [txt("đặt kiểu xoay"), tField("STYLE", styles, "left-right")]))
        a.append(S("motion_xposition", c, .reporter, [txt("vị trí x")]))
        a.append(S("motion_yposition", c, .reporter, [txt("vị trí y")]))
        a.append(S("motion_direction", c, .reporter, [txt("hướng")]))
        return a
    }()

    // MARK: Hiển thị
    private static let looks: [BlockSpec] = {
        let c = BlockCategory.looks
        let effects = MenuSource.fixed([opt("GHOST", "độ trong suốt")])
        let frontBack = MenuSource.fixed([opt("front", "trước cùng"), opt("back", "sau cùng")])
        let fwdBack = MenuSource.fixed([opt("forward", "lên trên"), opt("backward", "xuống dưới")])
        let numName = MenuSource.fixed([opt("number", "số thứ tự"), opt("name", "tên")])
        var a: [BlockSpec] = []
        a.append(S("looks_sayforsecs", c, .stack, [txt("nói"), tStr("MESSAGE", "Xin chào!"), txt("trong"), tNum("SECS", "2"), txt("giây")]))
        a.append(S("looks_say", c, .stack, [txt("nói"), tStr("MESSAGE", "Xin chào!")]))
        a.append(S("looks_thinkforsecs", c, .stack, [txt("nghĩ"), tStr("MESSAGE", "Hmm..."), txt("trong"), tNum("SECS", "2"), txt("giây")]))
        a.append(S("looks_think", c, .stack, [txt("nghĩ"), tStr("MESSAGE", "Hmm...")]))
        a.append(S("looks_switchcostumeto", c, .stack, [txt("đổi sang trang phục"), tMenu("COSTUME", "looks_costume", "COSTUME", .costumes)]))
        a.append(S("looks_nextcostume", c, .stack, [txt("trang phục kế tiếp")]))
        a.append(S("looks_switchbackdropto", c, .stack, [txt("đổi phông nền sang"), tMenu("BACKDROP", "looks_backdrops", "BACKDROP", .backdrops)]))
        a.append(S("looks_nextbackdrop", c, .stack, [txt("phông nền kế tiếp")]))
        a.append(S("looks_changesizeby", c, .stack, [txt("thay đổi kích thước một lượng"), tNum("CHANGE", "10")]))
        a.append(S("looks_setsizeto", c, .stack, [txt("đặt kích thước thành"), tNum("SIZE", "100"), txt("%")]))
        a.append(S("looks_changeeffectby", c, .stack, [txt("thay đổi hiệu ứng"), tField("EFFECT", effects, "GHOST"), txt("một lượng"), tNum("CHANGE", "25")]))
        a.append(S("looks_seteffectto", c, .stack, [txt("đặt hiệu ứng"), tField("EFFECT", effects, "GHOST"), txt("thành"), tNum("VALUE", "0")]))
        a.append(S("looks_cleargraphiceffects", c, .stack, [txt("xoá hiệu ứng đồ hoạ")]))
        a.append(S("looks_show", c, .stack, [txt("hiện")]))
        a.append(S("looks_hide", c, .stack, [txt("ẩn")]))
        a.append(S("looks_gotofrontback", c, .stack, [txt("đưa lên"), tField("FRONT_BACK", frontBack, "front"), txt("lớp")]))
        a.append(S("looks_goforwardbackwardlayers", c, .stack, [txt("đưa"), tField("FORWARD_BACKWARD", fwdBack, "forward"), tNum("NUM", "1"), txt("lớp")]))
        a.append(S("looks_costumenumbername", c, .reporter, [txt("trang phục"), tField("NUMBER_NAME", numName, "number")]))
        a.append(S("looks_backdropnumbername", c, .reporter, [txt("phông nền"), tField("NUMBER_NAME", numName, "number")]))
        a.append(S("looks_size", c, .reporter, [txt("kích thước")]))
        return a
    }()

    // MARK: Âm thanh
    private static let sound: [BlockSpec] = {
        let c = BlockCategory.sound
        var a: [BlockSpec] = []
        a.append(S("sound_playuntildone", c, .stack, [txt("phát âm thanh"), tMenu("SOUND_MENU", "sound_sounds_menu", "SOUND_MENU", .sounds), txt("đến hết")]))
        a.append(S("sound_play", c, .stack, [txt("bắt đầu âm thanh"), tMenu("SOUND_MENU", "sound_sounds_menu", "SOUND_MENU", .sounds)]))
        a.append(S("sound_stopallsounds", c, .stack, [txt("dừng mọi âm thanh")]))
        a.append(S("sound_changevolumeby", c, .stack, [txt("thay đổi âm lượng một lượng"), tNum("VOLUME", "-10")]))
        a.append(S("sound_setvolumeto", c, .stack, [txt("đặt âm lượng thành"), tNum("VOLUME", "100"), txt("%")]))
        a.append(S("sound_volume", c, .reporter, [txt("âm lượng")]))
        return a
    }()

    // MARK: Sự kiện
    private static let events: [BlockSpec] = {
        let c = BlockCategory.events
        var a: [BlockSpec] = []
        a.append(S("event_whenflagclicked", c, .hat, [txt("khi bấm cờ xanh")]))
        a.append(S("event_whenkeypressed", c, .hat, [txt("khi nhấn phím"), tField("KEY_OPTION", .keys, "space")]))
        a.append(S("event_whenthisspriteclicked", c, .hat, [txt("khi sprite này được bấm")]))
        a.append(S("event_whenstageclicked", c, .hat, [txt("khi sân khấu được bấm")]))
        a.append(S("event_whenbackdropswitchesto", c, .hat, [txt("khi phông nền đổi sang"), tField("BACKDROP", .backdrops)]))
        a.append(S("event_whenbroadcastreceived", c, .hat, [txt("khi nhận tin"), tField("BROADCAST_OPTION", .broadcasts)]))
        a.append(S("event_broadcast", c, .stack, [txt("phát tin"), tBcast("BROADCAST_INPUT")]))
        a.append(S("event_broadcastandwait", c, .stack, [txt("phát tin"), tBcast("BROADCAST_INPUT"), txt("và đợi")]))
        return a
    }()

    // MARK: Điều khiển
    private static let control: [BlockSpec] = {
        let c = BlockCategory.control
        let stops = MenuSource.fixed([opt("all", "tất cả"), opt("this script", "script này"), opt("other scripts in sprite", "các script khác")])
        var a: [BlockSpec] = []
        a.append(S("control_wait", c, .stack, [txt("chờ"), tNum("DURATION", "1"), txt("giây")]))
        a.append(S("control_repeat", c, .c, [txt("lặp lại"), tNum("TIMES", "10"), txt("lần")]))
        a.append(S("control_forever", c, .cCap, [txt("lặp mãi mãi")]))
        a.append(S("control_if", c, .c, [txt("nếu"), tBool("CONDITION"), txt("thì")]))
        a.append(S("control_if_else", c, .cElse, [txt("nếu"), tBool("CONDITION"), txt("thì")]))
        a.append(S("control_wait_until", c, .stack, [txt("chờ đến khi"), tBool("CONDITION")]))
        a.append(S("control_repeat_until", c, .c, [txt("lặp lại đến khi"), tBool("CONDITION")]))
        a.append(S("control_while", c, .c, [txt("lặp lại khi"), tBool("CONDITION")]))
        a.append(S("control_for_each", c, .c, [txt("với mỗi"), tField("VARIABLE", .variables), txt("trong"), tNum("VALUE", "10")]))
        a.append(S("control_stop", c, .stack, [txt("dừng"), tField("STOP_OPTION", stops, "all")]))
        a.append(S("control_start_as_clone", c, .hat, [txt("khi tôi bắt đầu là bản sao")]))
        a.append(S("control_create_clone_of", c, .stack, [txt("tạo bản sao của"), tMenu("CLONE_OPTION", "control_create_clone_of_menu", "CLONE_OPTION", .cloneTargets, "_myself_")]))
        a.append(S("control_delete_this_clone", c, .cap, [txt("xoá bản sao này")]))
        return a
    }()

    // MARK: Cảm biến
    private static let sensing: [BlockSpec] = {
        let c = BlockCategory.sensing
        let drag = MenuSource.fixed([opt("draggable", "kéo được"), opt("not draggable", "không kéo được")])
        let current = MenuSource.fixed([opt("YEAR", "năm"), opt("MONTH", "tháng"), opt("DATE", "ngày"), opt("DAYOFWEEK", "thứ"),
                                        opt("HOUR", "giờ"), opt("MINUTE", "phút"), opt("SECOND", "giây")])
        var a: [BlockSpec] = []
        a.append(S("sensing_touchingobject", c, .boolean, [txt("đang chạm"), tMenu("TOUCHINGOBJECTMENU", "sensing_touchingobjectmenu", "TOUCHINGOBJECTMENU", .touching, "_mouse_"), txt("?")]))
        a.append(S("sensing_keypressed", c, .boolean, [txt("phím"), tMenu("KEY_OPTION", "sensing_keyoptions", "KEY_OPTION", .keys, "space"), txt("được nhấn?")]))
        a.append(S("sensing_mousedown", c, .boolean, [txt("chuột được nhấn?")]))
        a.append(S("sensing_distanceto", c, .reporter, [txt("khoảng cách tới"), tMenu("DISTANCETOMENU", "sensing_distancetomenu", "DISTANCETOMENU", .distanceTargets, "_mouse_")]))
        a.append(S("sensing_askandwait", c, .stack, [txt("hỏi"), tStr("QUESTION", "Tên bạn là gì?"), txt("và đợi")]))
        a.append(S("sensing_answer", c, .reporter, [txt("câu trả lời")]))
        a.append(S("sensing_mousex", c, .reporter, [txt("chuột x")]))
        a.append(S("sensing_mousey", c, .reporter, [txt("chuột y")]))
        a.append(S("sensing_setdragmode", c, .stack, [txt("đặt chế độ kéo"), tField("DRAG_MODE", drag, "draggable")]))
        a.append(S("sensing_timer", c, .reporter, [txt("đồng hồ")]))
        a.append(S("sensing_resettimer", c, .stack, [txt("đặt lại đồng hồ")]))
        a.append(S("sensing_current", c, .reporter, [txt("hiện tại"), tField("CURRENTMENU", current, "YEAR")]))
        a.append(S("sensing_dayssince2000", c, .reporter, [txt("số ngày từ năm 2000")]))
        return a
    }()

    // MARK: Toán tử
    private static let operators: [BlockSpec] = {
        let c = BlockCategory.operators
        let ops = MenuSource.fixed(["abs", "floor", "ceiling", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "e ^", "10 ^"]
            .map { opt($0, $0) })
        var a: [BlockSpec] = []
        a.append(S("operator_add", c, .reporter, [tNum("NUM1"), txt("+"), tNum("NUM2")]))
        a.append(S("operator_subtract", c, .reporter, [tNum("NUM1"), txt("-"), tNum("NUM2")]))
        a.append(S("operator_multiply", c, .reporter, [tNum("NUM1"), txt("×"), tNum("NUM2")]))
        a.append(S("operator_divide", c, .reporter, [tNum("NUM1"), txt("÷"), tNum("NUM2")]))
        a.append(S("operator_random", c, .reporter, [txt("chọn ngẫu nhiên từ"), tNum("FROM", "1"), txt("đến"), tNum("TO", "10")]))
        a.append(S("operator_gt", c, .boolean, [tStr("OPERAND1"), txt(">"), tStr("OPERAND2", "50")]))
        a.append(S("operator_lt", c, .boolean, [tStr("OPERAND1"), txt("<"), tStr("OPERAND2", "50")]))
        a.append(S("operator_equals", c, .boolean, [tStr("OPERAND1"), txt("="), tStr("OPERAND2", "50")]))
        a.append(S("operator_and", c, .boolean, [tBool("OPERAND1"), txt("và"), tBool("OPERAND2")]))
        a.append(S("operator_or", c, .boolean, [tBool("OPERAND1"), txt("hoặc"), tBool("OPERAND2")]))
        a.append(S("operator_not", c, .boolean, [txt("không phải"), tBool("OPERAND")]))
        a.append(S("operator_join", c, .reporter, [txt("kết hợp"), tStr("STRING1", "xin chào "), tStr("STRING2", "thế giới")]))
        a.append(S("operator_letter_of", c, .reporter, [txt("ký tự thứ"), tNum("LETTER", "1"), txt("của"), tStr("STRING", "thế giới")]))
        a.append(S("operator_length", c, .reporter, [txt("độ dài"), tStr("STRING", "thế giới")]))
        a.append(S("operator_contains", c, .boolean, [tStr("STRING1", "thế giới"), txt("chứa"), tStr("STRING2", "t"), txt("?")]))
        a.append(S("operator_mod", c, .reporter, [tNum("NUM1"), txt("chia lấy dư"), tNum("NUM2")]))
        a.append(S("operator_round", c, .reporter, [txt("làm tròn"), tNum("NUM")]))
        a.append(S("operator_mathop", c, .reporter, [tField("OPERATOR", ops, "abs"), txt("của"), tNum("NUM")]))
        return a
    }()

    // MARK: Bút vẽ
    private static let pen: [BlockSpec] = {
        let c = BlockCategory.pen
        let params = MenuSource.fixed([opt("color", "màu"), opt("saturation", "độ bão hoà"), opt("brightness", "độ sáng"), opt("transparency", "độ trong suốt")])
        var a: [BlockSpec] = []
        a.append(S("pen_clear", c, .stack, [txt("xoá hết nét vẽ")]))
        a.append(S("pen_stamp", c, .stack, [txt("đóng dấu")]))
        a.append(S("pen_penDown", c, .stack, [txt("hạ bút")]))
        a.append(S("pen_penUp", c, .stack, [txt("nhấc bút")]))
        a.append(S("pen_setPenColorToColor", c, .stack, [txt("đặt màu bút thành"), tColor("COLOR", "#ff0000")]))
        a.append(S("pen_changePenColorParamBy", c, .stack, [txt("thay đổi"), tMenu("COLOR_PARAM", "pen_menu_colorParam", "colorParam", params, "color"), txt("của bút một lượng"), tNum("VALUE", "10")]))
        a.append(S("pen_setPenColorParamTo", c, .stack, [txt("đặt"), tMenu("COLOR_PARAM", "pen_menu_colorParam", "colorParam", params, "color"), txt("của bút thành"), tNum("VALUE", "50")]))
        a.append(S("pen_changePenSizeBy", c, .stack, [txt("thay đổi cỡ bút một lượng"), tNum("SIZE", "1")]))
        a.append(S("pen_setPenSizeTo", c, .stack, [txt("đặt cỡ bút thành"), tNum("SIZE", "1")]))
        return a
    }()

    // MARK: Biến số & danh sách
    private static let data: [BlockSpec] = {
        let c = BlockCategory.data
        var a: [BlockSpec] = []
        a.append(S("data_setvariableto", c, .stack, [txt("đặt"), tField("VARIABLE", .variables), txt("thành"), tStr("VALUE", "0")]))
        a.append(S("data_changevariableby", c, .stack, [txt("thay đổi"), tField("VARIABLE", .variables), txt("một lượng"), tNum("VALUE", "1")]))
        a.append(S("data_showvariable", c, .stack, [txt("hiện biến"), tField("VARIABLE", .variables)]))
        a.append(S("data_hidevariable", c, .stack, [txt("ẩn biến"), tField("VARIABLE", .variables)]))
        a.append(S("data_addtolist", c, .stack, [txt("thêm"), tStr("ITEM", "thứ gì đó"), txt("vào"), tField("LIST", .lists)]))
        a.append(S("data_deleteoflist", c, .stack, [txt("xoá mục"), tNum("INDEX", "1"), txt("của"), tField("LIST", .lists)]))
        a.append(S("data_deletealloflist", c, .stack, [txt("xoá hết các mục của"), tField("LIST", .lists)]))
        a.append(S("data_insertatlist", c, .stack, [txt("chèn"), tStr("ITEM", "thứ gì đó"), txt("vào vị trí"), tNum("INDEX", "1"), txt("của"), tField("LIST", .lists)]))
        a.append(S("data_replaceitemoflist", c, .stack, [txt("thay mục"), tNum("INDEX", "1"), txt("của"), tField("LIST", .lists), txt("bằng"), tStr("ITEM", "thứ gì đó")]))
        a.append(S("data_variable", c, .reporter, [tField("VARIABLE", .variables)]))
        a.append(S("data_listcontents", c, .reporter, [tField("LIST", .lists)]))
        a.append(S("data_itemoflist", c, .reporter, [txt("mục"), tNum("INDEX", "1"), txt("của"), tField("LIST", .lists)]))
        a.append(S("data_itemnumoflist", c, .reporter, [txt("vị trí của"), tStr("ITEM", "thứ gì đó"), txt("trong"), tField("LIST", .lists)]))
        a.append(S("data_lengthoflist", c, .reporter, [txt("độ dài"), tField("LIST", .lists)]))
        a.append(S("data_listcontainsitem", c, .boolean, [tField("LIST", .lists), txt("chứa"), tStr("ITEM", "thứ gì đó"), txt("?")]))
        return a
    }()
}
