import XCTest
@testable import ScratchCore

final class ScratchCoreTests: XCTestCase {

    // MARK: Value

    func testValueConversions() {
        XCTAssertEqual(ScratchValue.string("12").asNumber, 12)
        XCTAssertEqual(ScratchValue.string("abc").asNumber, 0)
        XCTAssertEqual(ScratchValue.number(3).asString, "3")
        XCTAssertEqual(ScratchValue.number(0.5).asString, "0.5")
        XCTAssertFalse(ScratchValue.string("false").asBool)
        XCTAssertFalse(ScratchValue.string("0").asBool)
        XCTAssertTrue(ScratchValue.string("hello").asBool)
    }

    func testCompare() {
        XCTAssertEqual(ScratchValue.compare(.string("10"), .number(9)), 1)
        XCTAssertEqual(ScratchValue.compare(.string("Apple"), .string("apple")), 0)
        XCTAssertEqual(ScratchValue.compare(.string("a"), .string("b")), -1)
    }

    // MARK: Zip

    func testZipRoundTrip() throws {
        let files: [(name: String, data: Data)] = [
            ("project.json", Data("{\"a\":1}".utf8)),
            ("abc.svg", Data("<svg/>".utf8))
        ]
        let zip = ZipArchive.write(files)
        let back = try ZipArchive.read(zip)
        XCTAssertEqual(back["project.json"], files[0].data)
        XCTAssertEqual(back["abc.svg"], files[1].data)
    }

    // MARK: Runtime

    private func makeProject() throws -> Project {
        let json = """
        {"targets":[{"isStage":true,"name":"Stage","variables":{"v1":["score",0]},"lists":{},"broadcasts":{},
        "blocks":{
          "hat":{"opcode":"event_whenflagclicked","next":"set","parent":null,"inputs":{},"fields":{},"topLevel":true},
          "set":{"opcode":"data_setvariableto","next":"rep","parent":"hat","inputs":{"VALUE":[1,[10,"5"]]},"fields":{"VARIABLE":["score","v1"]},"topLevel":false},
          "rep":{"opcode":"control_repeat","next":null,"parent":"set","inputs":{"TIMES":[1,[6,"3"]],"SUBSTACK":[2,"chg"]},"fields":{},"topLevel":false},
          "chg":{"opcode":"data_changevariableby","next":null,"parent":"rep","inputs":{"VALUE":[1,[4,"2"]]},"fields":{"VARIABLE":["score","v1"]},"topLevel":false}
        },
        "comments":{},"currentCostume":0,"costumes":[],"sounds":[],"volume":100,"layerOrder":0}],
        "monitors":[],"extensions":[],"meta":{"semver":"3.0.0"}}
        """
        return try Project(projectJSON: Data(json.utf8), assets: [:])
    }

    func testRepeatChangesVariable() throws {
        let project = try makeProject()
        let rt = Runtime(project: project)
        rt.greenFlag()
        for _ in 0..<20 { rt.step() }
        XCTAssertFalse(rt.isRunning)
        XCTAssertEqual(project.stage.variables["v1"]?.value.asNumber, 11)
    }

    func testSaveKeepsVariables() throws {
        let project = try makeProject()
        let rt = Runtime(project: project)
        rt.greenFlag()
        for _ in 0..<20 { rt.step() }
        let data = try rt.exportSB3()
        let reopened = try Project(sb3: data)
        XCTAssertEqual(reopened.stage.variables["v1"]?.value.asNumber, 11)
    }

    // MARK: Chỉnh sửa

    private func blankContext(_ rt: Runtime, _ sprite: Target) -> EditorContext {
        return EditorContext(target: sprite, stage: rt.stage, spriteNames: [sprite.name], broadcasts: ["message1"])
    }

    func testEditAndExportRoundTrip() throws {
        let project = Project.blank()
        let rt = Runtime(project: project)
        let sprite = rt.targets.first(where: { !$0.isStage })!
        let ctx = blankContext(rt, sprite)

        let hat = sprite.makeBlock(BlockCatalog.spec(for: "event_whenflagclicked")!, context: ctx)
        sprite.addScript(hat.id)
        let move = sprite.makeBlock(BlockCatalog.spec(for: "motion_movesteps")!, context: ctx)
        sprite.insertBlock(move.id, after: hat.id)
        sprite.setLiteral(block: move.id, input: "STEPS", value: "25")

        let data = try rt.exportSB3()
        let reopened = try Project(sb3: data)
        let rt2 = Runtime(project: reopened)
        rt2.greenFlag()
        for _ in 0..<5 { rt2.step() }
        let s2 = rt2.targets.first(where: { !$0.isStage })!
        XCTAssertEqual(s2.x, 25, accuracy: 0.01)
    }

    func testRepeatWithNestedSubstackAndReporter() throws {
        let project = Project.blank()
        let rt = Runtime(project: project)
        let sprite = rt.targets.first(where: { !$0.isStage })!
        let ctx = blankContext(rt, sprite)

        let hat = sprite.makeBlock(BlockCatalog.spec(for: "event_whenflagclicked")!, context: ctx)
        sprite.addScript(hat.id)
        let rep = sprite.makeBlock(BlockCatalog.spec(for: "control_repeat")!, context: ctx)
        sprite.insertBlock(rep.id, after: hat.id)
        sprite.setLiteral(block: rep.id, input: "TIMES", value: "4")
        let move = sprite.makeBlock(BlockCatalog.spec(for: "motion_movesteps")!, context: ctx)
        sprite.insertBlock(move.id, intoSubstackOf: rep.id, input: "SUBSTACK")
        // STEPS = 2 + 3
        let add = sprite.makeBlock(BlockCatalog.spec(for: "operator_add")!, context: ctx)
        sprite.setLiteral(block: add.id, input: "NUM1", value: "2")
        sprite.setLiteral(block: add.id, input: "NUM2", value: "3")
        sprite.setInput(block: move.id, input: "STEPS", reporter: add)

        // lưu rồi mở lại để chắc chắn cấu trúc được ghi đúng
        let reopened = try Project(sb3: try rt.exportSB3())
        let rt2 = Runtime(project: reopened)
        rt2.greenFlag()
        for _ in 0..<30 { rt2.step() }
        let s2 = rt2.targets.first(where: { !$0.isStage })!
        XCTAssertEqual(s2.x, 20, accuracy: 0.01)
    }

    func testMoveAndRemoveBlocks() throws {
        let project = Project.blank()
        let rt = Runtime(project: project)
        let sprite = rt.targets.first(where: { !$0.isStage })!
        let ctx = blankContext(rt, sprite)

        let hat = sprite.makeBlock(BlockCatalog.spec(for: "event_whenflagclicked")!, context: ctx)
        sprite.addScript(hat.id)
        let a = sprite.makeBlock(BlockCatalog.spec(for: "motion_movesteps")!, context: ctx)
        let b = sprite.makeBlock(BlockCatalog.spec(for: "motion_turnright")!, context: ctx)
        sprite.insertBlock(a.id, after: hat.id)
        sprite.insertBlock(b.id, after: a.id)
        XCTAssertEqual(hat.next, a.id)

        XCTAssertTrue(sprite.moveBlockUp(b.id))       // b lên trước a
        XCTAssertEqual(hat.next, b.id)
        XCTAssertEqual(b.next, a.id)

        XCTAssertFalse(sprite.moveBlockUp(b.id))      // b đã ở đầu, không vượt được hat

        sprite.removeBlock(b.id)
        XCTAssertEqual(hat.next, a.id)
        XCTAssertNil(sprite.blocks[b.id])
    }

    func testAddSpriteIsSaved() throws {
        let project = Project.blank()
        let rt = Runtime(project: project)
        let t = project.makeBlankSprite(existingNames: rt.targets.map { $0.name })
        rt.addSprite(t)
        let reopened = try Project(sb3: try rt.exportSB3())
        XCTAssertEqual(reopened.targets.filter { !$0.isStage }.count, 2)
    }
}

