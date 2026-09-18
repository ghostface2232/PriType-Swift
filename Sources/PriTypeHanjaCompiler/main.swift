import Foundation
import PriTypeCore

// Compiles libhangul's hanja.txt into the memory-mapped dictionary PriType ships.
//
//   swift run PriTypeHanjaCompiler [source] [output]
//
// Defaults: Tools/hanja/hanja.txt → Sources/PriTypeCore/Resources/hanja.dat.
// HanjaDictionaryTests fails when the committed output is out of date.

let arguments = CommandLine.arguments.dropFirst()
let source = arguments.first ?? "Tools/hanja/hanja.txt"
let output = arguments.dropFirst().first ?? "Sources/PriTypeCore/Resources/hanja.dat"

do {
    let text = try String(contentsOfFile: source, encoding: .utf8)
    let data = try HanjaDictionary.compile(source: text)
    let dictionary = try HanjaDictionary(data: data)
    try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    print("Wrote \(output): \(dictionary.count) keys, \(data.count) bytes")
} catch {
    FileHandle.standardError.write(Data("PriTypeHanjaCompiler: \(error)\n".utf8))
    exit(1)
}
