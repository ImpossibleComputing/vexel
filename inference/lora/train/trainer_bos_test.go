package train

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"vexel/inference/pkg/tokenizer"
)

// writeTestTokenizer writes a minimal ByteLevel tokenizer.json fixture and loads
// it. The fixture maps every printable ASCII char (plus newline) to its own id so
// arbitrary template scaffolding encodes deterministically (one token per char),
// and registers <s> (id 1) as BOS with AddBOS=true. "<|begin_of_text|>" is mapped
// to the BOS id so the Llama-3 chat template's literal BOS marker decodes to BOS.
func writeTestTokenizer(t *testing.T) *tokenizer.Tokenizer {
	t.Helper()

	vocab := map[string]int{}
	id := 10
	for c := 33; c <= 126; c++ {
		vocab[string(rune(c))] = id
		id++
	}
	vocab["\n"] = id
	id++
	vocab["Ġ"] = id // presence of Ġ switches the tokenizer to ByteLevel mode
	id++

	const bosID = 1
	doc := map[string]any{
		"model": map[string]any{
			"vocab": vocab,
		},
		"added_tokens": []map[string]any{
			{"id": bosID, "content": "<s>"},
			{"id": 2, "content": "</s>"},
			// Llama-3's template emits this literal marker; map it to BOS so
			// Encode() turns it into the BOS token (not raw characters).
			{"id": bosID, "content": "<|begin_of_text|>"},
		},
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "tokenizer.json")
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}
	if err := os.WriteFile(path, b, 0644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	tok, err := tokenizer.Load(path)
	if err != nil {
		t.Fatalf("load fixture tokenizer: %v", err)
	}
	if !tok.AddBOS() {
		t.Fatalf("fixture tokenizer should AddBOS")
	}
	return tok
}

// TestTokenizeExampleFormatTextPrependsBOS asserts the FormatText training path
// prepends a single leading BOS for an AddBOS model, matching what inference does
// (scheduler.AddSequence). Without it, FormatText training data lacks the <bos>
// that inference always prepends — a train/inference mismatch.
func TestTokenizeExampleFormatTextPrependsBOS(t *testing.T) {
	tok := writeTestTokenizer(t)
	tr := &Trainer{tok: tok}

	tokens, promptLen, err := tr.tokenizeExample(Example{Format: FormatText, Text: "Hello"})
	if err != nil {
		t.Fatalf("tokenizeExample: %v", err)
	}
	if promptLen != 0 {
		t.Errorf("promptLen=%d, want 0 for FormatText", promptLen)
	}
	if len(tokens) < 2 {
		t.Fatalf("expected BOS + content tokens, got %v", tokens)
	}
	if int(tokens[0]) != tok.BOS() {
		t.Errorf("tokens[0]=%d, want BOS=%d", tokens[0], tok.BOS())
	}
	if int(tokens[1]) == tok.BOS() {
		t.Errorf("double BOS at start: %v", tokens)
	}
}

// TestTokenizeExamplePromptCompletionGemma2 covers a chat template with no BOS
// marker of its own (Gemma 2). The trainer must add exactly one leading BOS.
func TestTokenizeExamplePromptCompletionGemma2(t *testing.T) {
	tok := writeTestTokenizer(t)
	tr := &Trainer{tok: tok, config: TrainConfig{ModelPath: "gemma-2-2b.gguf"}}

	tokens, promptLen, err := tr.tokenizeExample(Example{
		Format:     FormatPromptCompletion,
		Prompt:     "Question",
		Completion: "Answer",
	})
	if err != nil {
		t.Fatalf("tokenizeExample: %v", err)
	}
	if promptLen < 2 {
		t.Fatalf("promptLen=%d, expected BOS + scaffolding", promptLen)
	}
	if int(tokens[0]) != tok.BOS() {
		t.Errorf("tokens[0]=%d, want BOS=%d", tokens[0], tok.BOS())
	}
	if int(tokens[1]) == tok.BOS() {
		t.Errorf("double BOS at start: %v", tokens[:promptLen])
	}
}

// TestTokenizeExamplePromptCompletionLlama3 covers a chat template that already
// emits its own BOS marker (Llama 3's <|begin_of_text|>). The trainer must NOT
// add a second BOS.
func TestTokenizeExamplePromptCompletionLlama3(t *testing.T) {
	tok := writeTestTokenizer(t)
	tr := &Trainer{tok: tok, config: TrainConfig{ModelPath: "Meta-Llama-3-8B.gguf"}}

	tokens, promptLen, err := tr.tokenizeExample(Example{
		Format:     FormatPromptCompletion,
		Prompt:     "Question",
		Completion: "Answer",
	})
	if err != nil {
		t.Fatalf("tokenizeExample: %v", err)
	}
	if promptLen < 2 {
		t.Fatalf("promptLen=%d, expected BOS + scaffolding", promptLen)
	}
	if int(tokens[0]) != tok.BOS() {
		t.Errorf("tokens[0]=%d, want BOS=%d (template marker)", tokens[0], tok.BOS())
	}
	if int(tokens[1]) == tok.BOS() {
		t.Errorf("double BOS: template already emits BOS and trainer added another: %v", tokens[:promptLen])
	}
}
