import SwiftUI
import LaTeXSwiftUI

/// Represents a single chat message, tracking text content and sender identity.
struct Message: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

/// The main view displaying problem, user input, chat messages, and streaming model responses.
struct ContentView: View {
    @EnvironmentObject var store: ProblemStore
    @ObservedObject var gemma = GemmaModel.shared

    @State private var currentProblem: Problem?
    @State private var userPrompt: String = ""
    @State private var isGenerating = false
    @State private var showSidebar = true
    @State private var messages: [Message] = []

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar with Problem Display
            if showSidebar {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(currentProblem != nil ? "Problem \(currentProblem!.id)" : "No Problem")
                            .font(.headline)
                        Spacer()
                        Button(action: { withAnimation { showSidebar.toggle() } }) {
                            Image(systemName: "chevron.left")
                        }
                    }
                    if let problem = currentProblem {
                        // Optional illustration and body for the problem
                        VStack(spacing: 12) {
                            if let figure = problem.figure {
                                HStack {
                                    Spacer()
                                    Image(figure.replacingOccurrences(of: ".png", with: ""))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 180)
                                    Spacer()
                                }
                            }
                            ScrollView {
                                VStack(spacing: 16) {
                                    if let imageName = problem.image {
                                        Image(imageName)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 200)
                                            .clipped()
                                            .cornerRadius(8)
                                    }
                                    Text(problem.body)
                                        .font(.custom("Avenir Next", size: 17))
                                        .fontWeight(.light)
                                        .lineSpacing(8)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                    Spacer()
                }
                .frame(width: 320)
                .padding()
                .background(Color(.systemGroupedBackground))
            } else {
                // Collapsed sidebar toggle
                VStack {
                    HStack {
                        Button(action: { withAnimation { showSidebar.toggle() } }) {
                            Image(systemName: "chevron.right").padding()
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .frame(width: 32)
                .background(Color(.systemGroupedBackground))
            }

            Divider()

            // MARK: - Chat interface and input
            VStack(spacing: 0) {
                // Chat message list with streaming updates
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                BubbleView(text: message.text, isUser: message.isUser)
                            }
                            Text("").id("BOTTOM")
                        }
                        .padding()
                        .onChange(of: gemma.streamingChunk) { newChunk in
                            if let last = messages.last, !last.isUser {
                                messages[messages.count - 1] = Message(text: newChunk, isUser: false)
                            } else {
                                messages.append(Message(text: newChunk, isUser: false))
                            }
                            withAnimation {
                                proxy.scrollTo("BOTTOM", anchor: .bottom)
                            }
                        }
                        .onChange(of: messages.count) { _ in
                            withAnimation {
                                proxy.scrollTo("BOTTOM", anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input bar for user queries
                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            Task { await gemma.initializeIfNeeded() }
        }
        .onOpenURL { url in handleDeepLink(url) }
        .onChange(of: gemma.isGenerating) { isGenerating in
            if !isGenerating, let lastIndex = messages.lastIndex(where: { !$0.isUser }) {
                messages[lastIndex] = Message(text: gemma.responseText, isUser: false)
            }
        }
    }

    /// The bottom input area where the user writes messages to continue the conversation.
    private var inputBar: some View {
        let maxUserInputLength = 300
        return VStack(spacing: 4) {
            HStack {
                TextField("To proceed effectively, please restrict your question to the solution or the techniques used.", text: $userPrompt)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1))
                    .font(.custom("Avenir Next", size: 17).weight(.light))
                    .disabled(isGenerating)
                    .opacity(isGenerating ? 0.6 : 1.0)

                Button(action: sendUserPrompt) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor((userPrompt.isEmpty || isGenerating || userPrompt.count > maxUserInputLength) ? .gray : .blue)
                        .opacity((userPrompt.isEmpty || isGenerating || userPrompt.count > maxUserInputLength) ? 0.5 : 1.0)
                        .padding(.leading, 6)
                        .padding(.trailing, 2)
                }
                .disabled(isGenerating || userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || userPrompt.count > maxUserInputLength)
            }
            HStack {
                Spacer()
                Text("\(userPrompt.count)/\(maxUserInputLength)")
                    .font(.caption)
                    .foregroundColor(userPrompt.count > maxUserInputLength ? .red : .gray)
                    .padding(.trailing, 12)
            }
        }
        .padding()
    }

    /// Handles the user's follow-up input and streams the assistant's response.
    private func sendUserPrompt() {
        Task {
            isGenerating = true
            messages.append(Message(text: userPrompt, isUser: true))
            messages.append(Message(text: "", isUser: false))
            let _ = await gemma.continueConversation(with: userPrompt)
            await MainActor.run {
                if let idx = messages.lastIndex(where: { !$0.isUser }) {
                    messages[idx] = Message(text: gemma.responseText, isUser: false)
                }
                userPrompt = ""
                isGenerating = false
            }
        }
    }

    /// Handles deep links (e.g., from iBooks) to load and solve a problem automatically.
    private func handleDeepLink(_ url: URL) {
        if url.scheme == "solveitsmart",
           url.host == "problem",
           let id = url.pathComponents.dropFirst().first,
           let problem = store.problem(withID: id) {
            currentProblem = problem
            Task {
                isGenerating = true
                await MainActor.run {
                    gemma.responseText = ""
                    gemma.streamingChunk = ""
                    messages.removeAll()
                    messages.append(Message(text: problem.body, isUser: true))
                    messages.append(Message(text: "", isUser: false))
                }
                await gemma.initializeIfNeeded()
                await gemma.resetChat()
                let response = await gemma.generateAndReturnSolution(
                    for: problem.body,
                    technique: problem.techniques.joined(separator: ", "),
                    figureDescription: problem.figureDescription,
                    finalAnswer: problem.finalAnswer,
                    solution: problem.solution
                )
                await MainActor.run {
                    if let idx = messages.lastIndex(where: { !$0.isUser }) {
                        messages[idx] = Message(text: response, isUser: false)
                    }
                    isGenerating = false
                }
            }
        }
    }
}

/// A chat bubble view that displays either the user's message or the assistant's response.
/// Includes a copy-to-clipboard button and a "Copied!" toast for assistant responses.
struct BubbleView: View {
    let text: String
    var isUser: Bool
    @State private var showCopiedToast = false

    var body: some View {
        HStack {
            if isUser { Spacer() }

            ZStack(alignment: .bottomTrailing) {
                // Display either typing indicator or formatted text
                VStack(alignment: .leading, spacing: 0) {
                    if text.isEmpty {
                        TypingIndicatorView()
                    } else {
                        MathAlignedText(fullText: text)
                    }
                }
                .padding(12)
                .background(isUser ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .foregroundColor(isUser ? .white : Color.primary)
                .cornerRadius(16)
                .lineSpacing(8)
                .shadow(color: isUser ? .clear : Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: .leading)
                .multilineTextAlignment(.leading)

                // Copy-to-clipboard for assistant responses
                if !isUser && !text.isEmpty {
                    VStack(spacing: 4) {
                        Button(action: {
                            UIPasteboard.general.string = text
                            showCopiedToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showCopiedToast = false
                            }
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                                .padding(6)
                                .background(Color.white.opacity(0.9))
                                .clipShape(Circle())
                                .shadow(radius: 1)
                        }

                        // Transient toast confirmation
                        if showCopiedToast {
                            Text("Copied!")
                                .font(.caption2)
                                .padding(6)
                                .background(Color.black.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(6)
                                .transition(.opacity)
                        }
                    }
                    .padding(8)
                }
            }

            if !isUser { Spacer() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Displays text with LaTeX-aware line rendering, preserving math formatting.
/// Breaks input into lines and processes each with inline equation rendering.
struct MathAlignedText: View {
    let fullText: String
    var spacing: CGFloat = 8

    var body: some View {
        let lines = fullText.components(separatedBy: .newlines)
        let sharedFont = Font.custom("Avenir Next", size: 17).weight(.light)

        VStack(alignment: .leading, spacing: spacing) {
            ForEach(lines, id: \.self) { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 8)
                } else {
                    LaTeX(line)
                        .blockMode(.alwaysInline)
                        .parsingMode(.onlyEquations)
                        .environment(\.font, sharedFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Visual indicator shown while the model is generating a response.
/// Mimics common "typing..." indicators using animated dots.
struct TypingIndicatorView: View {
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0.3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 8, height: 8)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .animation(
                        Animation.easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: scale
                    )
            }
        }
        .onAppear {
            scale = 1.0
            opacity = 1.0
        }
        .onDisappear {
            scale = 0.5
            opacity = 0.3
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}












