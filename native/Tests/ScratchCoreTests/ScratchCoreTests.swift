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
}
