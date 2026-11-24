// VoicePrompts.swift
// Short, casual sentences a student might dictate (messages, notes, homework, tech words),
// written the way they should come out: right capitals and punctuation. Used by the voice
// benchmark (all 30, spoken by macOS voices) and by Test my voice (the first 20, read by you).

import Foundation

enum VoicePrompts {
    static let all: [String] = [
        "Hey, are you coming to practice tomorrow after school?",
        "Can you send me the notes from chemistry class?",
        "I finished the SwiftUI layout, but the settings screen still crashes.",
        "Remind me to push my changes to GitHub before dinner.",
        "The intake jammed twice, so we need new rubber bands.",
        "Priya said the Onshape model is ready for review.",
        "For homework, read chapter 7 and answer the first ten questions.",
        "I need three things from the store: milk, eggs, and bread.",
        "Alex, do you want to work on the history project together?",
        "My essay is due Friday, and I haven't started the conclusion.",
        "Let's meet in the library after lunch.",
        "The drivetrain uses four motors and two gear ratios.",
        "Thanks for helping me with the math test. It really helped.",
        "Did anyone figure out problem 12 on the physics worksheet?",
        "Note to self: charge the batteries before the competition.",
        "I think the autonomous code works, but the turn is a little off.",
        "Can we move the meeting to Thursday instead?",
        "The new update fixed the bug where the app would freeze.",
        "Please bring your laptop, your charger, and a pencil.",
        "We scored 85 points in the last match, which is our best so far.",
        "Mom, can you pick me up at the front door?",
        "I'm going to study for the biology quiz tonight.",
        "Write a function that returns the average of a list of numbers.",
        "Priya and Alex are presenting first, and we go after them.",
        "Is the Python assignment due on Monday or Wednesday?",
        "Don't forget to commit the code and open a pull request.",
        "The sensor reads about 12 inches when the claw is closed.",
        "Honestly, I think we should redesign the whole arm.",
        "Text me when you get home, okay?",
        "First, sketch the part in Onshape, then export it for the 3D printer.",
    ]

    /// Test my voice: 20 prompts, read one at a time.
    static var forTest: [String] { Array(all.prefix(20)) }
}
