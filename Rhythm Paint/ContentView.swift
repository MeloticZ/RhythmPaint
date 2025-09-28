//
//  ContentView.swift
//  Rhythm Paint
//
//  Created by Korgo on 9/23/25.
//

import SwiftUI
import UIKit
import Combine

import AudioKit
import SoundpipeAudioKit

class TonePlayer: ObservableObject {
    let engine = AudioEngine()
    let mixer = Mixer()

    init() {
        engine.output = mixer
        do {
            try engine.start()
        } catch {
            Log("AudioKit did not start! \(error)")
        }
    }
    
    func play(frequency: Float, duration: TimeInterval) {
        debugPrint("Playing tone ", frequency)
        let osc = Oscillator()
        let ramp: Float = 0.03
        osc.frequency = frequency
        osc.amplitude     = 0          // start silent
        
        osc.$amplitude.ramp(to: 1.0, duration: ramp)
        
        mixer.addInput(osc)
        osc.start()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            osc.$amplitude.ramp(to: 0.0, duration: ramp)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(ramp)) {   // wait for fade-out
                osc.stop()
                self.mixer.removeInput(osc)
            }
        }
    }
}


final class MutableVariables: ObservableObject {
    // hack but it works
    @Published var appleBreaker: Int = 1
    var lastRun: Date = .now
    var position: CGFloat = 0
    var eventUUIDMapping: [Int: UUID] = [:]
}

struct Line {
    let value: Int
    let y: CGFloat
    init(value: Int, y: CGFloat) {
        self.value = value
        self.y = y
    }
}

class Point {
    let x: CGFloat
    let y: CGFloat
    var played: Bool
    var cg: CGPoint { CGPoint(x: x, y: y) }
    
    init(x: CGFloat, y: CGFloat, played: Bool = false) {
        self.x = x
        self.y = y
        self.played = played
    }
    
    convenience init(cgPoint: CGPoint, played: Bool = false) {
        self.init(x: cgPoint.x, y: cgPoint.y, played: played)
    }
    
    func markAsPlayed() {
        played = true
    }
}

class Sketch {
    var points: [Point] = []
    var startPosition: CGFloat = CGFloat.infinity
    var endPosition: CGFloat = -1
    
    func addPoint(_ point: CGPoint) {
        points.append(Point(cgPoint: point))
        if (point.x < startPosition) {
            startPosition = point.x
        }
        if (point.x > endPosition) {
            endPosition = point.x
        }
    }
    
    init() {
        points = []
    }
    convenience init(point: Point) {
        self.init()
        self.points = [point]
    }
}

class SketchManager {
    var sketches: [UUID: Sketch]
    
    init () {
        sketches = [:]
    }
    
    func addPoint(withID id: UUID, point: CGPoint) {
        if (checkIfSketchExists(withID: id)) {
            sketches[id]?.addPoint(point)
            return
        }
        
        addSketch(withID: id, point: point)
    }
    
    func checkIfSketchExists(withID id: UUID) -> Bool {
        sketches.keys.contains(id)
    }
    
    func addSketch(withID id: UUID, sketch: Sketch) {
        sketches[id] = sketch
    }
    func addSketch(withID id: UUID, point: CGPoint) {
        sketches[id] = Sketch(point: Point(cgPoint: point))
    }
    func addSketch(withID id: UUID, point: Point) {
        sketches[id] = Sketch(point: point)
    }
    func getSketch(withID id: UUID) -> Sketch? {
        sketches[id]
    }
    func getAllSketches() -> [Sketch] {
        Array(sketches.values)
    }
    func removeSketch(withID id: UUID) -> Sketch? {
        let item = getSketch(withID: id)
        sketches.removeValue(forKey: id)
        return item
    }
    func batchRemoveWithOffset(by offset: CGFloat) {
        sketches = sketches.filter { $0.value.endPosition > CGFloat(offset) }
    }
}

class IdentificationManager: ObservableObject {
    var identification: [AnyHashable: UUID]
    
    init () {
        identification = [:]
    }
    
    func getID(withID id: AnyHashable) -> UUID {
        if (identification[id] == nil) {
            return rotate(withID: id)
        }
        return identification[id]!
    }
    
    @discardableResult
    func rotate(withID id: AnyHashable) -> UUID {
        let newID = UUID()
        identification[id] = newID
        return newID
    }
}

func hitTest(p1: Point, p2: Point, offset: CGFloat, context: GraphicsContext) -> CGFloat? {
        // Transform to screen-space (account for scrolling offset)
        let prevX = p1.x - offset
        let currX = p2.x - offset

        // Check if the segment crosses screen X = 0 from left to right
        if (prevX <= 0 && currX >= 0) || (prevX >= 0 && currX <= 0) {
            let dx = currX - prevX
            if dx != 0 {
                // Parametric t where x(t) == 0
                let t = -prevX / dx
                let yHit = p1.y + t * (p2.y - p1.y)

                return yHit
            }
        }
    return nil
}


let audioFreqMin: Double = 27.5
let audioFreqMax: Double = 4186.0
func valueToFrequency(_ value: Double) -> Double {
    return audioFreqMin * pow(audioFreqMax / audioFreqMin, value)
}


struct ContentView: View {
    private let screenHeight = UIScreen.main.bounds.height
    private let lineGap: CGFloat = 50.0
    private let deltaSpeed: CGFloat = 75.0
    @StateObject private var player = TonePlayer()
    @StateObject private var variables = MutableVariables()
    @StateObject private var identities = IdentificationManager()
    @State private var currentStrokes = SketchManager()
    @State private var allStrokes = SketchManager()
    private var lines: [Line] {
        var result: [Line] = []
        var lineIndex: Int = 0
        
        while true {
            if lineIndex == 0 {
                result.append(Line(value: 0, y: screenHeight / 2))
                lineIndex += 1
                continue
            }
            
            result.append(Line(value: lineIndex, y: screenHeight / 2 + CGFloat(lineIndex) * lineGap))
            result.append(Line(value: lineIndex, y: screenHeight / 2 - CGFloat(lineIndex) * lineGap))
            if screenHeight / 2 + CGFloat(lineIndex) * lineGap >= screenHeight {
                break
            }
            lineIndex += 1
        }
        return result
    }
    
    
    
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let timeDelta = timeline.date.timeIntervalSince(variables.lastRun)
                let delta = timeDelta * deltaSpeed
                var currentHits = Set<CGFloat>()
                variables.lastRun = timeline.date
                variables.position += delta
                
                allStrokes.batchRemoveWithOffset(by: variables.position)
                
                for line in lines {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: line.y))
                    path.addLine(to: CGPoint(x: size.width, y: line.y))
                    context.stroke(path, with: .color(.primary.opacity(0.3)), lineWidth: 1)
                }
                
                for sketch in currentStrokes.getAllSketches() {
                    var path = Path()
                    var previous: Point = .init(x: .infinity, y: 0)
                    for (index, point) in sketch.points.enumerated() {
                        path.addLine(to: CGPoint(x: point.x - variables.position, y: point.y))
                        // Collision Test on X=0
                        if index > 0 {
                            if let yPos = hitTest(p1: previous, p2: point, offset: variables.position, context: context) {
                                currentHits.insert(yPos)
                            }
                        }
                        previous = point
                    }
                    context.stroke(path, with: .color(.primary), lineWidth: 8)
                }
                
                for sketch in allStrokes.getAllSketches() {
                    var path = Path()
                    var previous: Point = .init(x: .infinity, y: 0)
                    for (index, point) in sketch.points.enumerated() {
                        path.addLine(to: CGPoint(x: point.x - variables.position, y: point.y))
                        // Collision Test on X=0
                        if index > 0 {
                            if let yPos = hitTest(p1: previous, p2: point, offset: variables.position, context: context) {
                                currentHits.insert(yPos)
                            }
                        }
                        previous = point
                    }
                    context.stroke(path, with: .color(.primary), lineWidth: 8)
                }
                
                for currentHit in currentHits {
                    let markerSize: CGFloat = 12
                    let markerRect = CGRect(
                        x: -markerSize / 2,
                        y: currentHit - markerSize / 2,
                        width: markerSize,
                        height: markerSize
                    )
                    context.fill(Path(ellipseIn: markerRect), with: .color(.accentColor))
                    player.play(frequency: Float(valueToFrequency((screenHeight-currentHit) / screenHeight)), duration: timeDelta)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .gesture(
                SpatialEventGesture(coordinateSpace: .global)
                    .onChanged { events in
                        for event in events {
                            
                            if (event.phase == .active) {
                                let key = identities.getID(withID: AnyHashable(event.id.hashValue))
                                currentStrokes.addPoint(withID: key, point: CGPoint(x: event.location.x + variables.position, y: event.location.y))
                            } else {
                                let key = identities.getID(withID: AnyHashable(event.id.hashValue))
                                allStrokes.addSketch(withID: key, sketch: currentStrokes.removeSketch(withID: key)!)
                                allStrokes.addPoint(withID: key, point: CGPoint(x: event.location.x + variables.position, y: event.location.y))
                                identities.rotate(withID: AnyHashable(event.id.hashValue))
                            }
                            
                        }
                    }
                
                    .onEnded { events in
                        for event in events {
                            let key = identities.getID(withID: AnyHashable(event.id.hashValue))
                            allStrokes.addSketch(withID: key, sketch: currentStrokes.removeSketch(withID: key)!)
                            allStrokes.addPoint(withID: key, point: CGPoint(x: event.location.x + variables.position, y: event.location.y))
                            identities.rotate(withID: AnyHashable(event.id.hashValue))
                        }
                    }
            )
        }
    }
}
    

#Preview {
    ContentView()
}
