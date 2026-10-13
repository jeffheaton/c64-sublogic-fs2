// fs2disk: writes the disk image the web build is deployed with (`DeployDisk`): only the sectors
// the port reads, with nothing a modified copy added. `make web-disk` runs it.
//
//     fs2disk <your .d64> <output .d64>

import C64Kit
import Foundation
import FS2Data

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: fs2disk <your .d64> <output .d64>\n".utf8))
    exit(2)
}
do {
    let source = try D64Image(contentsOf: URL(fileURLWithPath: arguments[1]))
    let image = try DeployDisk.image(from: source)
    // The result must pass the port's own disk check.
    _ = try GameData(d64: D64Image(data: image))
    try Data(image).write(to: URL(fileURLWithPath: arguments[2]))
    print("\(arguments[2]): \(image.count) bytes (the port's \(SubLogicDisk.blockCount) blocks, scrubbed)")
} catch {
    FileHandle.standardError.write(Data("fs2disk: \(error)\n".utf8))
    exit(1)
}
