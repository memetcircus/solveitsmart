import Foundation
import llama

@MainActor
class GemmaModel: ObservableObject {
    static let shared = GemmaModel(modelPath: Bundle.main.path(
        forResource: "google_gemma-3n-E2B-it-Q4_K_M",
        ofType: "gguf",
        inDirectory: "models")!)
    
    var context: LlamaContext?
    private let modelPath: String
    private let maxPromptLength = 1855
    
    @Published var responseText: String = ""
    @Published var streamingChunk: String = ""
    @Published var isReady: Bool = false
    @Published var isGenerating: Bool = false
    private var firstAssistantResponse: String? = nil
    private var firstAssistantSummary: String? = nil
    private var selectedTechnique: String? = nil
    
    private var chatHistory: [(role: String, content: String)] = []
    
    private init(modelPath: String) {
        self.modelPath = modelPath
    }
    
    func initializeIfNeeded() async {
        guard context == nil else { return }
        
        do {
            self.context = try LlamaContext.create_context(path: modelPath)
            self.isReady = true
            print("✅ GemmaModel context initialized")
        } catch {
            print("❌ Failed to initialize LlamaContext: \(error)")
            self.context = nil
            self.isReady = false
        }
    }
    
    func resetChat() async {
        chatHistory = []
        responseText = ""
        streamingChunk = ""
        firstAssistantResponse = nil
        firstAssistantSummary = nil
    }
    
    func estimateTokenCount(for text: String) -> Int {
        return text.count / 4
    }
    
    /// This function is called when the user follows up with an input message after the initial problem solution.
    ///
    /// It first checks for empty inputs, stop-intent messages (e.g., "thank you"), and length limits.
    /// Then, the user message is appended to the chat history, and a condensed prompt is constructed
    /// using the assistant's original response (summarized using `summarizeAssistantResponse`) and the new user input.
    ///
    /// The final prompt strictly constrains the assistant to avoid solving the problem again or introducing new techniques.
    /// Instead, the assistant is asked to continue the conversation only within the scope of the original solution.
    ///
    /// A token-limited history window is maintained to ensure the prompt stays within the model's context length.
    /// The response is streamed in real-time and appended to the UI and `chatHistory`.
    func continueConversation(with userMessage: String) async -> String {
        printChatHistoryDump(label: "Debug: Before continueConversation")
        
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("⚠️ Ignored empty user message.")
            return "Please enter a message."
        }
        
        let lowercasedInput = userMessage.lowercased()
        let stopPhrases = ["stop", "enough", "thank you", "yes that's enough", "that's fine"]
        if stopPhrases.contains(where: { lowercasedInput.contains($0) }) {
            print("🛑 Detected stop intent in input.")
            return await handleSystemMessages(msg: "🛑 Okay, I'll stop here.")
        }
        
        let maxUserInputLength = 500
        if userMessage.count > maxUserInputLength {
            return "⚠️ Your message is too long. Please shorten it and try again."
        }
        
        await initializeIfNeeded()
        
        print("📥 User input: '\(userMessage)'")
        print("📏 Input length: \(userMessage.count)")
        print("🔢 Estimated user tokens: \(userMessage.split(separator: " ").count + 4)")
        
        guard let context else {
            return "❌ Model context could not be created."
        }
        
        // Append user's message to chat history
        chatHistory.append((role: "user", content: userMessage))
        
        // Estimate tokens dynamically
        let maxTokens = 2048
        let tokenBudget = maxTokens - 300
        var totalTokens = 0
        var selectedHistory: [(role: String, content: String)] = []
        
        for message in chatHistory.reversed() {
            let contentTokenEstimate = message.content.split(separator: " ").count + 4
            
            if totalTokens + contentTokenEstimate > tokenBudget {
                break
            }
            selectedHistory.insert(message, at: 0)
            totalTokens += contentTokenEstimate
        }
        
        let fullPrompt = await buildMinimalPrompt(from: selectedHistory, newUserInput: userMessage)
        
        if debugPromptMetrics(fullPrompt, label: "ContinueConversation Prompt") > maxPromptLength {
            print("❌ Prompt too long (\(fullPrompt.count) chars).")
            return await handleSystemMessages(msg:"⚠️ Sorry cant process that. Please ask another question.")
        }
        
        print("===PROMPT START===\n\(fullPrompt)\n===PROMPT END===")
        print("🧾 Prompt length: \(fullPrompt.count)")
        
        await context.clear()
        await context.resetState()
        await context.completion_init(text: fullPrompt)
        
        var response = ""
        let maxLoops = 1000
        var loopCount = 0
        
        await MainActor.run {
            self.streamingChunk = ""
            self.isGenerating = true
        }
        
        while await !context.is_done, loopCount < maxLoops {
            let chunk = await context.completion_loop()
            response += chunk
            loopCount += 1
            
            if loopCount >= maxLoops {
                print("⚠️ Max loop count reached")
                
            }
            await MainActor.run {
                self.streamingChunk = response
            }
        }
        
        print("✅ Response completed in \(loopCount) loops.")
        print("💬 Response preview:\n\(response)")
        
        await MainActor.run {
            let cleanedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
            self.responseText = cleanedResponse.isEmpty || cleanedResponse == "```"
            ? "⚠️ Sorry, I couldn't process that — the input may be too large or too complex."
            : response
            self.streamingChunk = ""
            self.isGenerating = false
        }
        
        if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           chatHistory.last?.content != response {
            chatHistory.append((role: "assistant", content: response))
        }
        
        return response
    }
    
    func handleSystemMessages(msg: String) async -> String {
        await MainActor.run {
            self.responseText = msg
            self.streamingChunk = ""
            self.isGenerating = false
        }
        return msg
    }
    
    /// This function is called first when a problem is opened via a deep link (e.g., from iBooks).
    /// It constructs a comprehensive solution prompt using the provided problem, the designated solving technique,
    /// any associated figure description, the expected final answer, and the original solution text.
    ///
    /// The prompt is sent to the Gemma model to generate a full solution in 3–6 clearly numbered steps,
    /// preserving all original reasoning and numeric integrity. Double dollar signs ($$...$$) are enforced
    /// for all math rendering. The final answer is explicitly inserted at the end.
    ///
    /// This function also resets model state, initiates token streaming for real-time UI updates,
    /// and saves the user + assistant exchanges into `chatHistory` for future referencing.
    func generateAndReturnSolution(for problem: String, technique: String, figureDescription: String?, finalAnswer: String?, solution: String?) async -> String {
        
        await initializeIfNeeded()
        
        guard let context else {
            return "❌ Model context could not be created."
        }
        
        
        self.selectedTechnique = technique
        
        let prompt1 = """
        Solve the problem using the Polya-style technique: \(technique). Problem: \(problem) \(figureDescription != nil ? "Figure: \(figureDescription!)" : "") Provided Solution: \(solution ?? "") Rewrite the reasoning in 3–6 new steps, preserving original logic, numbers, and guesses. Ensure each numbered step starts on a **new line** (e.g.,1. ..,2. ..,etc.). Avoid simplification, invention, repetition, meta phrases. Use only double dollar signs for math expressions (e.g., $$2^5 = 32$$). Never use a single dollar sign "$". Finish with the final answer: \(finalAnswer ?? "") Do not write anything after this final answer. 
        """
        
        let prompt = """
        Solve the problem using the Polya-style technique: \(technique). Problem: \(problem) \(figureDescription != nil ? "Figure: \(figureDescription!)" : "") Provided Solution: \(solution ?? "") Rewrite the reasoning clearly in **no more than 8 steps**, preserving all original logic, numbers, and guesses. Do not break down or expand algebraic expressions unless absolutely necessary. Do not explain how to solve equations or do arithmetic. Use new lines for each step (e.g., 1. ..., 2. ...). Use only double dollar signs for math expressions (e.g., $$2^5 = 32$$). Never use a single dollar sign "$". Finish with the final answer: \(finalAnswer ?? "") and nothing else.
        """
        
        
        if debugPromptMetrics(prompt, label: "GenerateSolution Prompt") > maxPromptLength {
            print("❌ Prompt too long (\(prompt.count) chars).")
            return await handleSystemMessages(msg: "⚠️ Prompt is too long! Choose another problem to analyze")
        }
        
        await forceResetForNewProblem()
        await context.completion_init(text: prompt)
        
        var fullText = ""
        let maxLoops = 1000
        var loopCount = 0
        
        await MainActor.run {
            self.streamingChunk = ""
            self.isGenerating = true
        }
        
        while await !context.is_done, loopCount < maxLoops {
            let chunk = await context.completion_loop()
            fullText += chunk
            loopCount += 1
            
            await MainActor.run {
                self.streamingChunk = fullText
            }
        }
        
        print("📥 Final model response (\(fullText.count) chars)")
        print("\nThe final model response is \(fullText)")
        
        
        await MainActor.run {
            self.responseText = fullText
            self.streamingChunk = ""
            self.isGenerating = false
        }
        
        chatHistory.append((role: "user", content: problem))
        chatHistory.append((role: "assistant", content: fullText))
        
        return fullText
    }
    
    /// Utility function to print a debug summary of the chat history.
    func printChatHistoryDump(label: String = "📚 Chat History") {
        print("\(label) ---")
        for (i, msg) in chatHistory.enumerated() {
            let tokenEstimate = estimateTokenCount(for: msg.content)
            let preview = msg.content.replacingOccurrences(of: "\n", with: " ").prefix(200)
            print("🔹[\(i)] \(msg.role.capitalized) (\(tokenEstimate) tokens): \(preview)")
        }
        print("\(label) --- End")
    }
    
    /// Logs prompt details for debugging and returns its character count.
    func debugPromptMetrics(_ prompt: String, label: String = "Prompt") -> Int {
        let tokenEstimate = estimateTokenCount(for: prompt)
        print("=== \(label) ===")
        print(prompt)
        print("=== END ===")
        print("🧾 \(label) length: \(prompt.count) chars")
        print("🔢 Estimated tokens: \(tokenEstimate)")
        
        return prompt.count
        
    }
    
    /// Sanitizes the model output to plain text while preserving math blocks.
    /// Cleans formatting artifacts and removes control/invisible characters.
    func sanitizeToPlainText(_ text: String) -> String {
        var plain = text
        var mathSnippets: [String] = []
        
        // Match $$...$$
        let mathBlockRegex = try! NSRegularExpression(pattern: "\\$\\$.*?\\$\\$", options: [.dotMatchesLineSeparators])
        let matches = mathBlockRegex.matches(in: plain, options: [], range: NSRange(plain.startIndex..., in: plain))
        
        // Replace from back to front
        var tokenized = plain as NSString
        for (i, match) in matches.enumerated().reversed() {
            let snippet = tokenized.substring(with: match.range)
            let token = "MATH_BLOCK_\(i)"  // <<< Tokenlar düz olsun
            mathSnippets.insert(snippet, at: 0)
            tokenized = tokenized.replacingCharacters(in: match.range, with: token) as NSString
        }
        plain = String(tokenized)
        
        // Clean markdown
        let markdownChars = ["*", "`", "#", "~"]
        markdownChars.forEach { plain = plain.replacingOccurrences(of: $0, with: "") }
        
        // Remove invisible/control characters
        let invisibleCharacters: [Character] = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]
        plain.removeAll(where: { invisibleCharacters.contains($0) })
        plain.removeAll(where: { $0.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains) })
        
        // Replace newlines and reduce whitespace
        plain = plain.replacingOccurrences(of: "\n", with: " ")
        plain = plain.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        // Restore math snippets
        for (i, snippet) in mathSnippets.enumerated() {
            plain = plain.replacingOccurrences(of: "MATH_BLOCK_\(i)", with: snippet)  // <<< Düz tokenla değiştir
        }
        
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Hard resets the model and clears chat state, useful when switching to a new problem.
    func forceResetForNewProblem() async {
        await initializeIfNeeded()
        
        chatHistory = []
        responseText = ""
        streamingChunk = ""
        firstAssistantResponse = nil
        firstAssistantSummary = nil
        
        if let context = context {
            await context.clear()
            await context.resetState()
            print("🔁 Context and history forcibly reset for new problem.")
        } else {
            print("⚠️ Tried to reset context, but it was nil.")
        }
    }
    
    /// Provides a summarization of the assistant's initial response in 5–7 concise sentences.
    func summarizeAssistantResponse(_ input: String) async -> String {
        
        let prompt = "Summarize the following explanation in 5–7 plain sentences. Use only double dollar signs for math expressions like $$3 × 0.6 = 1.8$$. For prices, write as \"3.5 dollars\", never \"$3.5\". Do not use single dollar signs \"$...$\" under any condition. Be concise and preserve all numeric accuracy. End with a final sentence stating the answer clearly. Explanation to summarize: \(sanitizeToPlainText(input))"
        
        return await withCheckedContinuation { continuation in
            callModel(with: prompt) { summary in
                continuation.resume(returning: summary)
            }
        }
    }
    
    /// Builds a compressed prompt based on the assistant's summary and the user's follow-up question.
    func buildMinimalPrompt(from history: [(role: String, content: String)], newUserInput: String) async -> String {
        
        // Use cached assistant summary if available, otherwise generate
        if firstAssistantSummary == nil {
            if let firstAssistant = history.first(where: { $0.role == "assistant" })?.content {
                firstAssistantResponse = firstAssistant
                firstAssistantSummary = await summarizeAssistantResponse(firstAssistant)
            }
        }
        let assistantSummary = firstAssistantSummary ?? "No summary available."
        
        let techniqueLine = selectedTechnique != nil ? "- \(selectedTechnique!)" : ""
        
        
        return """
Continue the conversation focused only on the new user message. Be brief, clear, and to the point. Use a single-column format. Use only $$...$$ for math, never $...$. Do NOT use a single dollar sign ($) for math or currency. Do not solve the problem again or attempt any alternative solution, even if explicitly requested. Do not introduce new techniques. Do not use or mention techniques that were not used in the assistant summary. The assistant summary uses the Polya's technique(s): \"\(techniqueLine)\". Do not repeat reasoning or sentences. Answer only based on the assistant summary. If the question is unrelated to the summary, reply: "This question is outside the scope of this problem. Please ask about the solution or technique used." Assistant (summary):\(sanitizeToPlainText(assistantSummary)) User (new): \(sanitizeToPlainText(newUserInput)). Assistant:
"""
        
    }
    
    /// Internal utility to call the model with a one-shot prompt (non-streaming).
    func callModel(with prompt: String, completion: @escaping (String) -> Void) {
        Task {
            guard let context = self.context else {
                completion("❌ Model not ready.")
                return
            }
            
            await context.clear()
            await context.resetState()
            await context.completion_init(text: prompt)
            
            var fullResponse = ""
            let maxLoops = 1000
            var loopCount = 0
            
            while await !context.is_done, loopCount < maxLoops {
                let chunk = await context.completion_loop()
                fullResponse += chunk
                loopCount += 1
            }
            
            completion(fullResponse.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}





