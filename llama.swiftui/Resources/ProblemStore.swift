//
//  ProblemStore.swift
//  SolveItSmart
//
//  Created by Akif Acar on 11.07.2025.
//

import Foundation

struct Problem: Identifiable, Codable {
    let id: String
    let body: String
    let figure: String?
    let image: String?
    let techniques: [String]
    let figureDescription: String?
    let finalAnswer: String?
    let solution: String?
}

class ProblemStore: ObservableObject {
    @Published var problems: [Problem] = []

    init() {
        loadProblems()
    }

    func problem(withID id: String) -> Problem? {
        return problems.first { $0.id == id }
    }

    private func loadProblems() {
        if let url = Bundle.main.url(forResource: "problems", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let decoded = try? decoder.decode([Problem].self, from: data) {
                self.problems = decoded
            } else {
                print("❌ Failed to decode problems.json")
            }
        } else {
            print("❌ problems.json not found")
        }
    }
}
