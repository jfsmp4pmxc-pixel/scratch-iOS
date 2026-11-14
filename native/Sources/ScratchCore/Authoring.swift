import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

func md5Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    var h: UInt64 = 1469598103934665603
    for b in data { h = (h ^ UInt64(b)) &* 1099511628211 }
    return String(format: "%016llx%016llx", h, h ^ 0x9e3779b97f4a7c15)
    #endif
}

private let blankStageSVG = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="360" viewBox="0 0 480 360"><rect width="480" height="360" fill="#ffffff"/></svg>"#.utf8)

private let defaultSpriteSVG = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80" viewBox="0 0 80 80"><circle cx="40" cy="40" r="38" fill="#4C97FF" stroke="#3373CC" stroke-width="4"/><circle cx="28" cy="32" r="6" fill="#ffffff"/><circle cx="52" cy="32" r="6" fill="#ffffff"/><path d="M24 52 Q40 66 56 52" fill="none" stroke="#ffffff" stroke-width="4" stroke-linecap="round"/></svg>"#.utf8)

public extension Project {

    /// Dự án trống: một sân khấu trắng và một sprite hình tròn.
    static func blank() -> Project {
        let sid = md5Hex(blankStageSVG)
        let pid = md5Hex(defaultSpriteSVG)

        let backdrop: [String: Any] = ["name": "backdrop1", "assetId": sid, "md5ext": sid + ".svg", "dataFormat": "svg",
                                       "bitmapResolution": 1, "rotationCenterX": 240, "rotationCenterY": 180]
        var stage: [String: Any] = ["isStage": true, "name": "Stage", "variables": [String: Any](), "lists": [String: Any](),
                                    "broadcasts": ["b1": "message1"], "blocks": [String: Any](), "comments": [String: Any](),
                                    "currentCostume": 0, "sounds": [Any](), "volume": 100, "layerOrder": 0]
        stage["costumes"] = [backdrop]

        let costume: [String: Any] = ["name": "costume1", "assetId": pid, "md5ext": pid + ".svg", "dataFormat": "svg",
                                      "bitmapResolution": 1, "rotationCenterX": 40, "rotationCenterY": 40]
        var sprite: [String: Any] = ["isStage": false, "name": "Sprite1", "variables": [String: Any](), "lists": [String: Any](),
                                     "broadcasts": [String: Any](), "blocks": [String: Any](), "comments": [String: Any](),
                                     "currentCostume": 0, "sounds": [Any](), "volume": 100, "layerOrder": 1,
                                     "visible": true, "x": 0, "y": 0, "size": 100, "direction": 90,
                                     "draggable": false, "rotationStyle": "all around"]
        sprite["costumes"] = [costume]

        let meta: [String: Any] = ["semver": "3.0.0", "vm": "0.2.0", "agent": "ScratchNative"]
        let root: [String: Any] = ["targets": [stage, sprite], "monitors": [Any](), "extensions": [Any](), "meta": meta]
        let assets: [String: Data] = [sid + ".svg": blankStageSVG, pid + ".svg": defaultSpriteSVG]
        do {
            let json = try JSONSerialization.data(withJSONObject: root, options: [])
            return try Project(projectJSON: json, assets: assets)
        } catch {
            fatalError("Không tạo được dự án trống: \(error)")
        }
    }

    /// Tạo sprite mới từ dữ liệu ảnh (png/jpg/svg). Chưa được thêm vào Runtime.
    func makeSprite(name: String, existingNames: [String], assetData: Data, dataFormat: String,
                    centerX: Double, centerY: Double, bitmapResolution: Double) -> Target {
        let id = md5Hex(assetData)
        let md5ext = id + "." + dataFormat
        assets[md5ext] = assetData
        var unique = name
        var n = 2
        while existingNames.contains(unique) { unique = "\(name)\(n)"; n += 1 }
        let t = Target(isStage: false, name: unique)
        let json: [String: Any] = ["name": "costume1", "assetId": id, "md5ext": md5ext, "dataFormat": dataFormat,
                                   "bitmapResolution": bitmapResolution, "rotationCenterX": centerX, "rotationCenterY": centerY]
        t.costumes = [Costume(json: json)]
        t.blocksDirty = true
        return t
    }

    func makeBlankSprite(existingNames: [String]) -> Target {
        return makeSprite(name: "Sprite", existingNames: existingNames, assetData: defaultSpriteSVG, dataFormat: "svg",
                          centerX: 40, centerY: 40, bitmapResolution: 1)
    }
}
