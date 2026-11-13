import Foundation

// MARK: - Chạy thread

extension Runtime {

    /// Chạy một thread tới khi nó nhường (yield), ngủ hoặc kết thúc.
    func run(_ t: ScriptThread) {
        let deadline = now() + 0.5      // giới hạn cho vòng lặp warp, giống Scratch
        while !t.done {
            if let w = t.waitUntil {
                if now() < w { t.sleeping = true; return }
                t.waitUntil = nil
            }
            if t.blocked { t.sleeping = true; return }
            if !t.broadcastWait.isEmpty {
                t.broadcastWait.removeAll(where: { $0.done || !threads.contains(where: { x in x === $0 }) })
                if !t.broadcastWait.isEmpty { t.sleeping = true; return }
            }
            guard !t.stack.isEmpty else { t.done = true; return }

            let top = t.stack.count - 1
            if let bid = t.stack[top].next {
                guard let block = t.target.blocks[bid] else {
                    t.stack[top].next = nil
                    continue
                }
                t.stack[top].next = block.next
                if exec(block, t) { return }
                continue
            }

            // Hết một chuỗi block: xử lý theo loại khung.
            let f = t.stack[top]
            var shouldYield = false
            switch f.loop {
            case .none:
                t.stack.removeLast()
            case .procedure:
                t.stack.removeLast()
            case .forever:
                t.stack[top].next = f.start
                shouldYield = true
            case .repeatN:
                let remaining = f.counter - 1
                if remaining > 0 {
                    t.stack[top].counter = remaining
                    t.stack[top].next = f.start
                    shouldYield = true
                } else {
                    t.stack.removeLast()
                }
            case .until:
                let cond = f.owner.flatMap { t.target.blocks[$0] }
                if let cond = cond, evalInput(cond.inputs["CONDITION"], t).asBool {
                    t.stack.removeLast()
                } else {
                    t.stack[top].next = f.start
                    shouldYield = true
                }
            case .whileLoop:
                let cond = f.owner.flatMap { t.target.blocks[$0] }
                if let cond = cond, evalInput(cond.inputs["CONDITION"], t).asBool {
                    t.stack[top].next = f.start
                    shouldYield = true
                } else {
                    t.stack.removeLast()
                }
            case .forEach:
                let c = f.counter + 1
                if c <= f.limit {
                    t.stack[top].counter = c
                    t.stack[top].next = f.start
                    if let owner = f.owner.flatMap({ t.target.blocks[$0] }),
                       let v = t.target.lookupVariable(id: owner.fieldIds["VARIABLE"],
                                                        name: owner.fields["VARIABLE"]?.asString, stage: stage) {
                        v.value = .number(c)
                    }
                    shouldYield = true
                } else {
                    t.stack.removeLast()
                }
            }
            if shouldYield {
                if t.isWarp {
                    if now() > deadline { return }
                } else {
                    return
                }
            }
        }
    }

    // MARK: Đánh giá input

    func evalInput(_ input: BlockInput?, _ t: ScriptThread) -> ScratchValue {
        guard let input = input else { return .empty }
        switch input {
        case .literal(let v): return v
        case .empty: return .empty
        case .broadcast(let n): return .string(n)
        case .variable(let id, let name):
            return t.target.lookupVariable(id: id, name: name, stage: stage)?.value ?? .empty
        case .list(let id, let name):
            guard let l = t.target.lookupList(id: id, name: name, stage: stage) else { return .empty }
            return .string(joinList(l))
        case .block(let id):
            guard let b = t.target.blocks[id] else { return .empty }
            return evalReporter(b, t)
        }
    }

    func joinList(_ l: ListVariable) -> String {
        let allSingle = l.items.allSatisfy { $0.asString.count == 1 }
        return l.items.map { $0.asString }.joined(separator: allSingle ? "" : " ")
    }

    private func val(_ b: Block, _ name: String, _ t: ScriptThread) -> ScratchValue { evalInput(b.inputs[name], t) }
    private func num(_ b: Block, _ name: String, _ t: ScriptThread) -> Double { evalInput(b.inputs[name], t).asNumber }
    private func str(_ b: Block, _ name: String, _ t: ScriptThread) -> String { evalInput(b.inputs[name], t).asString }
    private func field(_ b: Block, _ name: String) -> String { b.fields[name]?.asString ?? "" }

    private func substack(_ b: Block, _ name: String) -> String? {
        if case .block(let id)? = b.inputs[name] { return id }
        return nil
    }

    static func wrapDirection(_ d: Double) -> Double {
        var r = d.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 } else if r <= -180 { r += 360 }
        return r
    }

    // MARK: Reporter

    func evalReporter(_ b: Block, _ t: ScriptThread) -> ScratchValue {
        let target = t.target
        switch b.opcode {

        // Motion
        case "motion_xposition": return .number(round2(target.x))
        case "motion_yposition": return .number(round2(target.y))
        case "motion_direction": return .number(target.direction)

        // Looks
        case "looks_size": return .number((target.size).rounded())
        case "looks_costumenumbername":
            if field(b, "NUMBER_NAME") == "name" { return .string(target.costume?.name ?? "") }
            return .number(Double(target.currentCostume + 1))
        case "looks_backdropnumbername":
            if field(b, "NUMBER_NAME") == "name" { return .string(stage.costume?.name ?? "") }
            return .number(Double(stage.currentCostume + 1))

        // Sound
        case "sound_volume": return .number(target.volume)

        // Operators
        case "operator_add": return .number(num(b, "NUM1", t) + num(b, "NUM2", t))
        case "operator_subtract": return .number(num(b, "NUM1", t) - num(b, "NUM2", t))
        case "operator_multiply": return .number(num(b, "NUM1", t) * num(b, "NUM2", t))
        case "operator_divide": return .number(num(b, "NUM1", t) / num(b, "NUM2", t))
        case "operator_mod":
            let n = num(b, "NUM1", t), m = num(b, "NUM2", t)
            if m == 0 { return .number(.nan) }
            var r = n.truncatingRemainder(dividingBy: m)
            if r / m < 0 { r += m }
            return .number(r)
        case "operator_round": return .number((num(b, "NUM", t) + 0.5).rounded(.down))
        case "operator_random":
            let a = val(b, "FROM", t), c = val(b, "TO", t)
            let lo = min(a.asNumber, c.asNumber), hi = max(a.asNumber, c.asNumber)
            if a.isInteger && c.isInteger {
                let l = Int(lo.rounded(.up)), h = Int(hi.rounded(.down))
                if h < l { return .number(lo) }
                return .number(Double(Int.random(in: l...h)))
            }
            return .number(lo + Double.random(in: 0...1) * (hi - lo))
        case "operator_gt": return .bool(ScratchValue.compare(val(b, "OPERAND1", t), val(b, "OPERAND2", t)) > 0)
        case "operator_lt": return .bool(ScratchValue.compare(val(b, "OPERAND1", t), val(b, "OPERAND2", t)) < 0)
        case "operator_equals": return .bool(ScratchValue.compare(val(b, "OPERAND1", t), val(b, "OPERAND2", t)) == 0)
        case "operator_and": return .bool(val(b, "OPERAND1", t).asBool && val(b, "OPERAND2", t).asBool)
        case "operator_or": return .bool(val(b, "OPERAND1", t).asBool || val(b, "OPERAND2", t).asBool)
        case "operator_not": return .bool(!val(b, "OPERAND", t).asBool)
        case "operator_join": return .string(str(b, "STRING1", t) + str(b, "STRING2", t))
        case "operator_letter_of":
            let i = Int(num(b, "LETTER", t)) - 1
            let s = Array(str(b, "STRING", t))
            return .string(i >= 0 && i < s.count ? String(s[i]) : "")
        case "operator_length": return .number(Double(str(b, "STRING", t).count))
        case "operator_contains":
            return .bool(str(b, "STRING1", t).lowercased().contains(str(b, "STRING2", t).lowercased())
                         || str(b, "STRING2", t).isEmpty)
        case "operator_mathop": return .number(mathop(field(b, "OPERATOR"), num(b, "NUM", t)))

        // Data
        case "data_variable":
            return target.lookupVariable(id: b.fieldIds["VARIABLE"], name: field(b, "VARIABLE"), stage: stage)?.value ?? .empty
        case "data_listcontents":
            guard let l = target.lookupList(id: b.fieldIds["LIST"], name: field(b, "LIST"), stage: stage) else { return .empty }
            return .string(joinList(l))
        case "data_itemoflist":
            guard let l = target.lookupList(id: b.fieldIds["LIST"], name: field(b, "LIST"), stage: stage),
                  let i = listIndex(val(b, "INDEX", t), count: l.items.count) else { return .empty }
            return l.items[i - 1]
        case "data_itemnumoflist":
            guard let l = target.lookupList(id: b.fieldIds["LIST"], name: field(b, "LIST"), stage: stage) else { return .number(0) }
            let item = val(b, "ITEM", t)
            if let i = l.items.firstIndex(where: { ScratchValue.compare($0, item) == 0 }) { return .number(Double(i + 1)) }
            return .number(0)
        case "data_lengthoflist":
            let l = target.lookupList(id: b.fieldIds["LIST"], name: field(b, "LIST"), stage: stage)
            return .number(Double(l?.items.count ?? 0))
        case "data_listcontainsitem":
            guard let l = target.lookupList(id: b.fieldIds["LIST"], name: field(b, "LIST"), stage: stage) else { return .bool(false) }
            let item = val(b, "ITEM", t)
            return .bool(l.items.contains(where: { ScratchValue.compare($0, item) == 0 }))

        // Procedures
        case "argument_reporter_string_number", "argument_reporter_boolean":
            let name = field(b, "VALUE")
            for f in t.stack.reversed() {
                if let a = f.args, let v = a[name] { return v }
            }
            return b.opcode == "argument_reporter_boolean" ? .bool(false) : .number(0)

        // Sensing
        case "sensing_touchingobject":
            return .bool(isTouching(target, menu: str(b, "TOUCHINGOBJECTMENU", t)))
        case "sensing_touchingcolor", "sensing_coloristouchingcolor":
            noteUnsupported(b.opcode)
            return .bool(false)
        case "sensing_distanceto":
            let (px, py) = pointOf(str(b, "DISTANCETOMENU", t), target)
            return .number(hypot(px - target.x, py - target.y))
        case "sensing_answer": return .string(answer)
        case "sensing_keypressed":
            let key = str(b, "KEY_OPTION", t).lowercased()
            if key == "any" { return .bool(!keysDown.isEmpty) }
            return .bool(keysDown.contains(key))
        case "sensing_mousedown": return .bool(mouseDown)
        case "sensing_mousex": return .number(mouseX.rounded())
        case "sensing_mousey": return .number(mouseY.rounded())
        case "sensing_timer": return .number(now() - timerStart)
        case "sensing_loudness": return .number(0)
        case "sensing_username": return .string("")
        case "sensing_dayssince2000":
            let ref = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                     year: 2000, month: 1, day: 1).date ?? Date(timeIntervalSince1970: 946684800)
            return .number(Date().timeIntervalSince(ref) / 86400)
        case "sensing_current":
            let c = Calendar.current
            let d = Date()
            switch field(b, "CURRENTMENU").lowercased() {
            case "year": return .number(Double(c.component(.year, from: d)))
            case "month": return .number(Double(c.component(.month, from: d)))
            case "date": return .number(Double(c.component(.day, from: d)))
            case "dayofweek": return .number(Double(c.component(.weekday, from: d)))
            case "hour": return .number(Double(c.component(.hour, from: d)))
            case "minute": return .number(Double(c.component(.minute, from: d)))
            default: return .number(Double(c.component(.second, from: d)))
            }
        case "sensing_of": return sensingOf(b, t)

        default:
            // Menu / shadow block: chỉ có một field -> trả về giá trị đó.
            if b.fields.count == 1, let v = b.fields.values.first { return v }
            noteUnsupported(b.opcode)
            return .empty
        }
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    private func mathop(_ op: String, _ n: Double) -> Double {
        switch op {
        case "abs": return abs(n)
        case "floor": return n.rounded(.down)
        case "ceiling": return n.rounded(.up)
        case "sqrt": return n.squareRoot()
        case "sin": return (sin(n * .pi / 180) * 1e10).rounded() / 1e10
        case "cos": return (cos(n * .pi / 180) * 1e10).rounded() / 1e10
        case "tan":
            let m = n.truncatingRemainder(dividingBy: 360)
            if m == 90 || m == -270 { return .infinity }
            if m == 270 || m == -90 { return -.infinity }
            return (tan(n * .pi / 180) * 1e10).rounded() / 1e10
        case "asin": return asin(n) * 180 / .pi
        case "acos": return acos(n) * 180 / .pi
        case "atan": return atan(n) * 180 / .pi
        case "ln": return log(n)
        case "log": return log10(n)
        case "e ^": return exp(n)
        case "10 ^": return pow(10, n)
        default: return 0
        }
    }

    func listIndex(_ v: ScratchValue, count: Int, allowAll: Bool = false) -> Int? {
        if case .string(let s) = v {
            let l = s.lowercased()
            if l == "last" { return count > 0 ? count : nil }
            if l == "random" || l == "any" { return count > 0 ? Int.random(in: 1...count) : nil }
        }
        let i = Int(v.asNumber.rounded(.down))
        return (i >= 1 && i <= count) ? i : nil
    }

    private func pointOf(_ menu: String, _ me: Target) -> (Double, Double) {
        if menu == "_mouse_" { return (mouseX, mouseY) }
        if let o = target(named: menu) { return (o.x, o.y) }
        return (0, 0)
    }

    private func isTouching(_ me: Target, menu: String) -> Bool {
        guard let spatial = spatial else { return false }
        if menu == "_mouse_" { return spatial.touching(me, x: mouseX, y: mouseY) }
        if menu == "_edge_" {
            guard let r = spatial.bounds(of: me) else { return false }
            return r.minX <= -240 || r.maxX >= 240 || r.minY <= -180 || r.maxY >= 180
        }
        if menu == "_stage_" { return false }
        for o in targets where !o.isStage && o.visible && o.name == menu && o !== me {
            if spatial.touching(me, o) { return true }
        }
        return false
    }

    private func sensingOf(_ b: Block, _ t: ScriptThread) -> ScratchValue {
        let objName = str(b, "OBJECT", t)
        let prop = field(b, "PROPERTY")
        let obj: Target? = objName == "_stage_" ? stage : target(named: objName)
        guard let o = obj else { return .number(0) }
        switch prop {
        case "x position": return .number(o.x)
        case "y position": return .number(o.y)
        case "direction": return .number(o.direction)
        case "costume #", "backdrop #": return .number(Double(o.currentCostume + 1))
        case "costume name", "backdrop name": return .string(o.costume?.name ?? "")
        case "size": return .number(o.size)
        case "volume": return .number(o.volume)
        default:
            return o.lookupVariable(id: nil, name: prop, stage: nil)?.value ?? .number(0)
        }
    }

    // MARK: Statement

    /// Trả về true nếu thread phải nhường (yield).
    func exec(_ b: Block, _ t: ScriptThread) -> Bool {
        let target = t.target
        let isReentry = (t.reentry == b.id)
        t.reentry = nil

        /// Chạy lại chính block này ở lần lặp sau.
        func requeue() -> Bool {
            t.stack[t.stack.count - 1].next = b.id
            t.reentry = b.id
            return true
        }

        switch b.opcode {

        // MARK: Motion
        case "motion_movesteps":
            let steps = num(b, "STEPS", t)
            let r = (90 - target.direction) * .pi / 180
            setXY(target, target.x + steps * cos(r), target.y + steps * sin(r))
        case "motion_turnright":
            target.direction = Runtime.wrapDirection(target.direction + num(b, "DEGREES", t)); requestRedraw()
        case "motion_turnleft":
            target.direction = Runtime.wrapDirection(target.direction - num(b, "DEGREES", t)); requestRedraw()
        case "motion_pointindirection":
            target.direction = Runtime.wrapDirection(num(b, "DIRECTION", t)); requestRedraw()
        case "motion_pointtowards":
            let menu = str(b, "TOWARDS", t)
            if menu == "_random_" {
                target.direction = Double(Int.random(in: -179...180))
            } else {
                let (px, py) = pointOf(menu, target)
                let dx = px - target.x, dy = py - target.y
                target.direction = Runtime.wrapDirection(90 - atan2(dy, dx) * 180 / .pi)
            }
            requestRedraw()
        case "motion_gotoxy": setXY(target, num(b, "X", t), num(b, "Y", t))
        case "motion_goto":
            let menu = str(b, "TO", t)
            if menu == "_random_" {
                setXY(target, Double(Int.random(in: -240...240)), Double(Int.random(in: -180...180)))
            } else {
                let (px, py) = pointOf(menu, target)
                setXY(target, px, py)
            }
        case "motion_changexby": setXY(target, target.x + num(b, "DX", t), target.y)
        case "motion_setx": setXY(target, num(b, "X", t), target.y)
        case "motion_changeyby": setXY(target, target.x, target.y + num(b, "DY", t))
        case "motion_sety": setXY(target, target.x, num(b, "Y", t))
        case "motion_ifonedgebounce": bounceOffEdge(target)
        case "motion_setrotationstyle":
            if let s = RotationStyle(rawValue: field(b, "STYLE")) { target.rotationStyle = s }
            requestRedraw()
        case "motion_glidesecstoxy", "motion_glideto":
            if t.glide == nil || !isReentry {
                let dur = num(b, "SECS", t)
                var ex = 0.0, ey = 0.0
                if b.opcode == "motion_glidesecstoxy" {
                    ex = num(b, "X", t); ey = num(b, "Y", t)
                } else {
                    let menu = str(b, "TO", t)
                    if menu == "_random_" { ex = Double(Int.random(in: -240...240)); ey = Double(Int.random(in: -180...180)) }
                    else { (ex, ey) = pointOf(menu, target) }
                }
                if dur <= 0 { setXY(target, ex, ey); t.glide = nil; return false }
                t.glide = GlideState(start: now(), duration: dur, sx: target.x, sy: target.y, ex: ex, ey: ey)
            }
            if let g = t.glide {
                let p = (now() - g.start) / g.duration
                if p >= 1 {
                    setXY(target, g.ex, g.ey)
                    t.glide = nil
                } else {
                    setXY(target, g.sx + (g.ex - g.sx) * p, g.sy + (g.ey - g.sy) * p)
                    return requeue()
                }
            }

        // MARK: Looks
        case "looks_say", "looks_think":
            setBubble(target, str(b, "MESSAGE", t), think: b.opcode == "looks_think")
        case "looks_sayforsecs", "looks_thinkforsecs":
            if isReentry {
                target.bubble = nil; requestRedraw()
            } else {
                setBubble(target, str(b, "MESSAGE", t), think: b.opcode == "looks_thinkforsecs")
                t.waitUntil = now() + max(0, num(b, "SECS", t))
                return requeue()
            }
        case "looks_switchcostumeto":
            switchCostume(target, to: val(b, "COSTUME", t))
        case "looks_nextcostume":
            if !target.costumes.isEmpty { target.currentCostume = (target.currentCostume + 1) % target.costumes.count }
            requestRedraw()
        case "looks_switchbackdropto":
            switchBackdrop(val(b, "BACKDROP", t))
        case "looks_nextbackdrop":
            if !stage.costumes.isEmpty {
                stage.currentCostume = (stage.currentCostume + 1) % stage.costumes.count
                fireBackdropHats()
            }
            requestRedraw()
        case "looks_changesizeby":
            target.size = clampSize(target.size + num(b, "CHANGE", t)); requestRedraw()
        case "looks_setsizeto":
            target.size = clampSize(num(b, "SIZE", t)); requestRedraw()
        case "looks_changeeffectby":
            let e = field(b, "EFFECT").lowercased()
            target.effects[e, default: 0] += num(b, "CHANGE", t); requestRedraw()
        case "looks_seteffectto":
            target.effects[field(b, "EFFECT").lowercased()] = num(b, "VALUE", t); requestRedraw()
        case "looks_cleargraphiceffects":
            target.effects.removeAll(); requestRedraw()
        case "looks_show": target.visible = true; requestRedraw()
        case "looks_hide": target.visible = false; requestRedraw()
        case "looks_gotofrontback":
            if field(b, "FRONT_BACK") == "front" { moveToFront(target) } else { moveToBack(target) }
        case "looks_goforwardbackwardlayers":
            let n = Int(num(b, "NUM", t))
            shiftLayer(target, by: field(b, "FORWARD_BACKWARD") == "forward" ? n : -n)

        // MARK: Sound
        case "sound_play", "sound_playuntildone":
            let sound = findSound(target, val(b, "SOUND_MENU", t))
            if let s = sound, let player = soundPlayer {
                if b.opcode == "sound_playuntildone" {
                    if isReentry { break }
                    t.blocked = true
                    player.play(s, volume: target.volume) { [weak t, weak self] in
                        t?.blocked = false
                        _ = self
                    }
                    return requeue()
                } else {
                    player.play(s, volume: target.volume) {}
                }
            }
        case "sound_stopallsounds": soundPlayer?.stopAll()
        case "sound_changevolumeby": target.volume = min(100, max(0, target.volume + num(b, "VOLUME", t)))
        case "sound_setvolumeto": target.volume = min(100, max(0, num(b, "VOLUME", t)))
        case "sound_changeeffectby", "sound_seteffectto", "sound_cleareffects": break

        // MARK: Events
        case "event_broadcast":
            _ = broadcast(str(b, "BROADCAST_INPUT", t))
        case "event_broadcastandwait":
            if isReentry { break }
            let started = broadcast(str(b, "BROADCAST_INPUT", t))
            if started.isEmpty { return false }
            t.broadcastWait = started
            return requeue()

        // MARK: Control
        case "control_wait":
            if isReentry { break }
            t.waitUntil = now() + max(0, num(b, "DURATION", t))
            return requeue()
        case "control_repeat":
            let n = num(b, "TIMES", t).rounded()
            if n > 0 {
                let s = substack(b, "SUBSTACK")
                t.stack.append(Frame(next: s, start: s, loop: .repeatN, counter: n, owner: b.id, warp: false))
            }
        case "control_forever":
            let s = substack(b, "SUBSTACK")
            t.stack.append(Frame(next: s, start: s, loop: .forever, owner: b.id))
        case "control_if":
            if val(b, "CONDITION", t).asBool, let s = substack(b, "SUBSTACK") {
                t.stack.append(Frame(next: s, start: s))
            }
        case "control_if_else":
            let key = val(b, "CONDITION", t).asBool ? "SUBSTACK" : "SUBSTACK2"
            if let s = substack(b, key) { t.stack.append(Frame(next: s, start: s)) }
        case "control_wait_until":
            if !val(b, "CONDITION", t).asBool { return requeue() }
        case "control_repeat_until":
            if !val(b, "CONDITION", t).asBool {
                let s = substack(b, "SUBSTACK")
                t.stack.append(Frame(next: s, start: s, loop: .until, owner: b.id))
            }
        case "control_while":
            if val(b, "CONDITION", t).asBool {
                let s = substack(b, "SUBSTACK")
                t.stack.append(Frame(next: s, start: s, loop: .whileLoop, owner: b.id))
            }
        case "control_for_each":
            let n = num(b, "VALUE", t)
            if n >= 1 {
                if let v = target.lookupVariable(id: b.fieldIds["VARIABLE"], name: field(b, "VARIABLE"), stage: stage) {
                    v.value = .number(1)
                }
                let s = substack(b, "SUBSTACK")
                t.stack.append(Frame(next: s, start: s, loop: .forEach, counter: 1, limit: n, owner: b.id))
            }
        case "control_stop":
            switch field(b, "STOP_OPTION") {
            case "all": stopAll(); return true
            case "this script": t.done = true; return true
            case "other scripts in sprite", "other scripts in stage":
                for o in threads where o.target === target && o !== t { o.done = true }
            default: break
            }
        case "control_create_clone_of":
            let menu = str(b, "CLONE_OPTION", t)
            if menu == "_myself_" { createClone(of: target) }
            else if let o = self.target(named: menu) { createClone(of: o) }
        case "control_delete_this_clone":
            if target.isClone { removeClone(target); t.done = true; return true }

        // MARK: Sensing
        case "sensing_askandwait":
            if isReentry { break }
            let q = str(b, "QUESTION", t)
            guard let handler = askHandler else { answer = ""; break }
            t.blocked = true
            handler(q) { [weak self, weak t] a in
                self?.answer = a
                t?.blocked = false
            }
            return requeue()
        case "sensing_resettimer": timerStart = now()
        case "sensing_setdragmode": target.draggable = field(b, "DRAG_MODE") == "draggable"

        // MARK: Data
        case "data_setvariableto":
            target.lookupVariable(id: b.fieldIds["VARIABLE"], name: field(b, "VARIABLE"), stage: stage)?.value = val(b, "VALUE", t)
        case "data_changevariableby":
            if let v = target.lookupVariable(id: b.fieldIds["VARIABLE"], name: field(b, "VARIABLE"), stage: stage) {
                v.value = .number(v.value.asNumber + num(b, "VALUE", t))
            }
        case "data_showvariable", "data_hidevariable":
            if let v = target.lookupVariable(id: b.fieldIds["VARIABLE"], name: field(b, "VARIABLE"), stage: stage) {
                setMonitor(variableId: v.id, visible: b.opcode == "data_showvariable")
            }
        case "data_showlist", "data_hidelist": break
        case "data_addtolist":
            list(b, target)?.items.append(val(b, "ITEM", t))
        case "data_deleteoflist":
            if let l = list(b, target) {
                if case .string(let s) = val(b, "INDEX", t), s.lowercased() == "all" { l.items.removeAll() }
                else if let i = listIndex(val(b, "INDEX", t), count: l.items.count) { l.items.remove(at: i - 1) }
            }
        case "data_deletealloflist": list(b, target)?.items.removeAll()
        case "data_insertatlist":
            if let l = list(b, target) {
                let idxVal = val(b, "INDEX", t)
                var i: Int?
                if case .string(let s) = idxVal, s.lowercased() == "last" { i = l.items.count + 1 }
                else {
                    let n = Int(idxVal.asNumber.rounded(.down))
                    i = (n >= 1 && n <= l.items.count + 1) ? n : nil
                    if case .string(let s) = idxVal, s.lowercased() == "random" { i = Int.random(in: 1...(l.items.count + 1)) }
                }
                if let i = i { l.items.insert(val(b, "ITEM", t), at: i - 1) }
            }
        case "data_replaceitemoflist":
            if let l = list(b, target), let i = listIndex(val(b, "INDEX", t), count: l.items.count) {
                l.items[i - 1] = val(b, "ITEM", t)
            }

        // MARK: Pen
        case "pen_clear": pen?.clear(); requestRedraw()
        case "pen_stamp": pen?.stamp(target); requestRedraw()
        case "pen_penDown":
            target.pen.isDown = true
            pen?.line(fromX: target.x, fromY: target.y, toX: target.x, toY: target.y, pen: target.pen)
            requestRedraw()
        case "pen_penUp": target.pen.isDown = false
        case "pen_setPenColorToColor":
            let (h, s, v) = Runtime.hsv(fromHex: val(b, "COLOR", t))
            target.pen.hue = h; target.pen.saturation = s; target.pen.brightness = v
            target.pen.transparency = 0
        case "pen_changePenColorParamBy", "pen_setPenColorParamTo":
            let param = str(b, "COLOR_PARAM", t)
            let amount = num(b, "VALUE", t)
            let relative = b.opcode == "pen_changePenColorParamBy"
            func apply(_ cur: Double) -> Double { relative ? cur + amount : amount }
            switch param {
            case "color": target.pen.hue = (apply(target.pen.hue).truncatingRemainder(dividingBy: 100) + 100).truncatingRemainder(dividingBy: 100)
            case "saturation": target.pen.saturation = min(100, max(0, apply(target.pen.saturation)))
            case "brightness": target.pen.brightness = min(100, max(0, apply(target.pen.brightness)))
            case "transparency": target.pen.transparency = min(100, max(0, apply(target.pen.transparency)))
            default: break
            }
        case "pen_changePenSizeBy": target.pen.size = max(1, target.pen.size + num(b, "SIZE", t))
        case "pen_setPenSizeTo": target.pen.size = max(1, num(b, "SIZE", t))

        // MARK: Procedures
        case "procedures_call":
            guard let code = b.mutation["proccode"], let info = target.procedureCache[code],
                  let def = target.blocks[info.definitionId] else { break }
            if t.stack.count > 1500 { t.done = true; return true }
            var args: [String: ScratchValue] = [:]
            for (i, argId) in info.argIds.enumerated() where i < info.argNames.count {
                args[info.argNames[i]] = val(b, argId, t)
            }
            t.stack.append(Frame(next: def.next, start: def.next, loop: .procedure, args: args, warp: info.warp))

        // Các hat, comment hoặc block không có hiệu ứng khi chạy.
        case "procedures_definition", "event_whenflagclicked", "event_whenkeypressed",
             "event_whenthisspriteclicked", "event_whenstageclicked", "event_whenbroadcastreceived",
             "event_whenbackdropswitchesto", "event_whengreaterthan", "control_start_as_clone":
            break

        default:
            noteUnsupported(b.opcode)
        }
        return false
    }

    // MARK: Helper cho statement

    private func list(_ b: Block, _ target: Target) -> ListVariable? {
        return target.lookupList(id: b.fieldIds["LIST"], name: b.fields["LIST"]?.asString, stage: stage)
    }

    private func setBubble(_ t: Target, _ text: String, think: Bool) {
        t.bubble = text.isEmpty ? nil : Bubble(text: text, isThought: think)
        requestRedraw()
    }

    private func clampSize(_ s: Double) -> Double {
        // Giới hạn đơn giản: 5% .. 540%.
        return min(540, max(5, s))
    }

    private func switchCostume(_ t: Target, to v: ScratchValue) {
        guard !t.costumes.isEmpty else { return }
        if let i = t.costumes.firstIndex(where: { $0.name == v.asString }) {
            t.currentCostume = i
        } else if case .string(let s) = v, s == "next costume" {
            t.currentCostume = (t.currentCostume + 1) % t.costumes.count
        } else if case .string(let s) = v, s == "previous costume" {
            t.currentCostume = (t.currentCostume - 1 + t.costumes.count) % t.costumes.count
        } else if let n = v.numericValue, !(v.asString.trimmingCharacters(in: .whitespaces).isEmpty) {
            let i = Int(n.rounded()) - 1
            t.currentCostume = ((i % t.costumes.count) + t.costumes.count) % t.costumes.count
        }
        requestRedraw()
    }

    private func switchBackdrop(_ v: ScratchValue) {
        let before = stage.currentCostume
        if case .string(let s) = v, s == "random backdrop", !stage.costumes.isEmpty {
            stage.currentCostume = Int.random(in: 0..<stage.costumes.count)
        } else {
            switchCostume(stage, to: v)
        }
        _ = before
        fireBackdropHats()
        requestRedraw()
    }

    private func fireBackdropHats() {
        let name = stage.costume?.name ?? ""
        startHats("event_whenbackdropswitchesto") { _, b in (b.fields["BACKDROP"]?.asString ?? "") == name }
    }

    private func findSound(_ t: Target, _ v: ScratchValue) -> Sound? {
        if let s = t.sounds.first(where: { $0.name == v.asString }) { return s }
        if let n = v.numericValue, !t.sounds.isEmpty {
            let i = Int(n.rounded()) - 1
            return t.sounds[((i % t.sounds.count) + t.sounds.count) % t.sounds.count]
        }
        return nil
    }

    private func bounceOffEdge(_ t: Target) {
        guard let r = spatial?.bounds(of: t) else { return }
        var dist = [(Double, String)]()
        dist.append((max(0, r.minX + 240), "left"))
        dist.append((max(0, 180 - r.maxY), "top"))
        dist.append((max(0, 240 - r.maxX), "right"))
        dist.append((max(0, r.minY + 180), "bottom"))
        guard let nearest = dist.min(by: { $0.0 < $1.0 }), nearest.0 <= 0 else { return }
        let rad = (90 - t.direction) * .pi / 180
        var dx = cos(rad), dy = -sin(rad)
        switch nearest.1 {
        case "left": dx = max(0.2, abs(dx))
        case "top": dy = max(0.2, abs(dy))
        case "right": dx = -max(0.2, abs(dx))
        default: dy = -max(0.2, abs(dy))
        }
        t.direction = Runtime.wrapDirection(atan2(dy, dx) * 180 / .pi + 90)
        // Đẩy sprite trở lại trong sân khấu.
        var mx = 0.0, my = 0.0
        if r.minX < -240 { mx = -240 - r.minX } else if r.maxX > 240 { mx = 240 - r.maxX }
        if r.minY < -180 { my = -180 - r.minY } else if r.maxY > 180 { my = 180 - r.maxY }
        t.x += mx; t.y += my
        requestRedraw()
    }

    // MARK: Màu

    static func hsv(fromHex v: ScratchValue) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0
        let s = v.asString
        if s.hasPrefix("#"), s.count >= 7, let n = Int(s.dropFirst().prefix(6), radix: 16) {
            r = Double((n >> 16) & 0xff) / 255
            g = Double((n >> 8) & 0xff) / 255
            b = Double(n & 0xff) / 255
        } else {
            let n = Int(v.asNumber) & 0xffffff
            r = Double((n >> 16) & 0xff) / 255
            g = Double((n >> 8) & 0xff) / 255
            b = Double(n & 0xff) / 255
        }
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        let sat = mx == 0 ? 0 : d / mx
        return (h * 100, sat * 100, mx * 100)
    }

    /// Chuyển trạng thái bút sang RGB 0...1.
    public static func rgb(of pen: PenState) -> (r: Double, g: Double, b: Double, a: Double) {
        let h = pen.hue / 100 * 6, s = pen.saturation / 100, v = pen.brightness / 100
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return (r, g, b, 1 - pen.transparency / 100)
    }
}
