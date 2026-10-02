//
//  chord-eval: run the app's chord engines over audio files and write MIREX .lab files.
//
//  swift run -c release chord-eval --models ChordDetectionPOC/Models --out results TestSet/audio
//  python3 Tools/score.py --ref TestSet/labels results/*
//

import Foundation

let usage = """
usage: chord-eval [options] <audio file or folder>...

Writes <out>/<engine>/<name>.lab for every audio file and engine.

options:
  --engine <name>        templates | basicPitch | btc | all   (default: all)
  --models <dir>         folder with BTCChords.mlpackage, BTCKernels.bin, BasicPitch.mlpackage
                         (default: ChordDetectionPOC/Models)
  --out <dir>            output folder (default: results)
  --no-beats             fixed 0.5 s segments instead of the beat grid
  --per-beat <n>         segments per beat (default 2)
  --no-key               no key prior unless a <name>.key file is given
  --no-drum-removal      skip harmonic-percussive separation (templates engine)
  --no-slash             don't add bass notes (D/F#) to chords
  --bass-weight <x>      bass-root bonus for template engines (default 3, 0 = off)
  --stay <p>             probability of keeping the same chord per segment (default 0.85)
  --off-key <x>          off-key penalty, template engines (default 1.5)
  --btc-weight <x>       BTC emission weight (default 4)
  --btc-off-key <x>      off-key penalty, BTC (default 0.5)

A key can be supplied per song in <name>.key next to the audio, e.g. "A:min" or "Eb".
Without one, the key is estimated from the audio (like the app does when MusicUnderstanding fails).
"""

struct Arguments {
    var engines: [ChordEngineKind] = ChordEngineKind.allCases
    var models = URL(fileURLWithPath: "ChordDetectionPOC/Models")
    var out = URL(fileURLWithPath: "results")
    var options = ChordEngineOptions()
    var inputs: [URL] = []
}

func parseArguments() -> Arguments {
    var args = Arguments()
    var it = CommandLine.arguments.dropFirst().makeIterator()

    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value") }
        return v
    }
    func number(_ flag: String) -> Float {
        guard let v = Float(value(flag)) else { fail("\(flag) needs a number") }
        return v
    }

    while let arg = it.next() {
        switch arg {
        case "-h", "--help": print(usage); exit(0)
        case "--engine":
            let v = value(arg)
            if v == "all" { args.engines = ChordEngineKind.allCases }
            else if let kind = ChordEngineKind(rawValue: v) { args.engines = [kind] }
            else { fail("unknown engine \(v)") }
        case "--models": args.models = URL(fileURLWithPath: value(arg))
        case "--out": args.out = URL(fileURLWithPath: value(arg))
        case "--no-beats": args.options.useBeats = false
        case "--per-beat": args.options.config.segmentsPerBeat = max(1, Int(number(arg)))
        case "--no-key": args.options.estimateKeyWhenMissing = false
        case "--no-drum-removal": args.options.config.chroma.removeDrums = false
        case "--no-slash": args.options.config.detectSlashChords = false
        case "--bass-weight": args.options.config.bassWeight = number(arg)
        case "--stay": args.options.config.stayProbability = number(arg)
        case "--off-key": args.options.config.offKeyPenalty = number(arg)
        case "--btc-weight": args.options.config.btcEmissionWeight = number(arg)
        case "--btc-off-key": args.options.config.btcOffKeyPenalty = number(arg)
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)") }
            args.inputs.append(URL(fileURLWithPath: arg))
        }
    }
    if args.inputs.isEmpty { print(usage); exit(1) }
    args.options.modelDirectory = args.models
    return args
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "flac", "caf"]

func audioFiles(in inputs: [URL]) -> [URL] {
    var result: [URL] = []
    for url in inputs {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            fail("not found: \(url.path)")
        }
        if isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            result += items.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        } else {
            result.append(url)
        }
    }
    return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// "A:min", "Eb", "F#:maj", "C minor" -> key region.
func readKey(for audio: URL) -> [KeyRegion] {
    let url = audio.deletingPathExtension().appendingPathExtension("key")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let tonicPart = trimmed.split(whereSeparator: { $0 == ":" || $0 == " " }).first.map(String.init) ?? trimmed
    guard let tonic = NoteNaming.parseTonic(tonicPart) else {
        FileHandle.standardError.write(Data("warning: can't read key \"\(trimmed)\" in \(url.lastPathComponent)\n".utf8))
        return []
    }
    let lower = trimmed.lowercased()
    let isMinor = lower.contains("min") || (tonicPart.hasSuffix("m") && !lower.contains("maj"))
    return [KeyRegion(start: 0, tonic: NoteNaming.pitchClass(of: tonic), isMinor: isMinor)]
}

let args = parseArguments()
let files = audioFiles(in: args.inputs)
print("\(files.count) file(s), engines: \(args.engines.map(\.rawValue).joined(separator: ", "))")

for engine in args.engines {
    try FileManager.default.createDirectory(at: args.out.appendingPathComponent(engine.rawValue),
                                            withIntermediateDirectories: true)
}

for file in files {
    let name = file.deletingPathExtension().lastPathComponent
    let samples: [Float]
    do {
        samples = try AudioDecoder.loadMono(url: file, sampleRate: args.options.config.analysisSampleRate)
    } catch {
        print("  \(name): \(error.localizedDescription)")
        continue
    }
    let keys = readKey(for: file)

    for engine in args.engines {
        let started = Date()
        do {
            let analysis = try await ChordEngine.run(kind: engine, samples: samples, keys: keys, options: args.options)
            let out = args.out.appendingPathComponent(engine.rawValue).appendingPathComponent("\(name).lab")
            try analysis.labText.write(to: out, atomically: true, encoding: .utf8)
            let keyName = analysis.keys.isEmpty ? "none" : analysis.keys
                .map { NoteNaming.keyName(pitchClass: $0.tonic, isMinor: $0.isMinor) + ($0.start > 0 ? " @\(Int($0.start))s" : "") }
                .joined(separator: " -> ")
            let tempo = analysis.beats.map { "\($0.count) beats" } ?? "no beat grid"
            print(String(format: "  %@ [%@] %ld chords, key %@, %@, %.1fs",
                         name, engine.rawValue, analysis.segments.count, keyName, tempo, Date().timeIntervalSince(started)))
        } catch {
            print("  \(name) [\(engine.rawValue)]: \(error.localizedDescription)")
        }
    }
}
