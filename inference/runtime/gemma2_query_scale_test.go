package runtime

import (
	"math"
	"testing"

	"vexel/inference/backend/cpu"
	"vexel/inference/pkg/gguf"
)

// Gemma 2 query pre-attention scaling (query_pre_attn_scalar).
//
// The attention scores are scaled by 1/sqrt(d). For most architectures d is the
// head dimension, but Gemma 2 decouples it via query_pre_attn_scalar, which is an
// HF hparam absent from GGUF:
//
//	model         head_dim  query_pre_attn_scalar
//	gemma-2-2b    256       256   (== head_dim, scaling unchanged)
//	gemma-2-9b    256       256   (== head_dim, scaling unchanged)
//	gemma-2-27b   128       144   (!= head_dim, the only affected model)
//
// 27b is the only model whose scaling differs from the legacy 1/sqrt(head_dim),
// and there is no 27b GGUF fixture, so these unit tests guard the derivation and
// confirm 2b/9b suffer no regression.

// gemma2Model captures the hparams the derivation depends on.
type gemma2Model struct {
	name       string
	hiddenSize int
	numHeads   int
	headDim    int
	wantScalar int
}

var gemma2Models = []gemma2Model{
	{name: "gemma-2-2b", hiddenSize: 2304, numHeads: 8, headDim: 256, wantScalar: 256},
	{name: "gemma-2-9b", hiddenSize: 3584, numHeads: 16, headDim: 256, wantScalar: 256},
	{name: "gemma-2-27b", hiddenSize: 4608, numHeads: 32, headDim: 128, wantScalar: 144},
}

func TestGemma2QueryPreAttnScalarDerivation(t *testing.T) {
	for _, m := range gemma2Models {
		got := gemma2QueryPreAttnScalar(m.headDim, m.hiddenSize, m.numHeads)
		if got != m.wantScalar {
			t.Errorf("%s: gemma2QueryPreAttnScalar(headDim=%d, hidden=%d, heads=%d) = %d, want %d",
				m.name, m.headDim, m.hiddenSize, m.numHeads, got, m.wantScalar)
		}
	}
}

// Verify the scalar flows through the real GGUF config path. query_pre_attn_scalar
// is NOT a GGUF field, so it must be reconstructed from the other hparams.
func TestGemma2QueryPreAttnScalarFromGGUF(t *testing.T) {
	for _, m := range gemma2Models {
		g := gguf.ModelConfigValues{
			Architecture: "gemma2",
			HiddenSize:   m.hiddenSize,
			NumHeads:     m.numHeads,
			NumKVHeads:   m.numHeads / 2,
			HeadDim:      m.headDim,
			NumLayers:    1,
		}
		cfg := ModelConfigFromGGUF(g)
		if cfg.QueryPreAttnScalar != m.wantScalar {
			t.Errorf("%s: ModelConfigFromGGUF QueryPreAttnScalar = %d, want %d",
				m.name, cfg.QueryPreAttnScalar, m.wantScalar)
		}
		if got := cfg.EffectiveQueryPreAttnScalar(); got != m.wantScalar {
			t.Errorf("%s: EffectiveQueryPreAttnScalar = %d, want %d", m.name, got, m.wantScalar)
		}
	}
}

// Non-Gemma-2 architectures must leave QueryPreAttnScalar disabled (0) so the
// scaling falls back to the standard 1/sqrt(head_dim).
func TestQueryPreAttnScalarDisabledForLlama(t *testing.T) {
	g := gguf.ModelConfigValues{
		Architecture: "llama",
		HiddenSize:   4096,
		NumHeads:     32,
		NumKVHeads:   8,
		NumLayers:    1,
	}
	cfg := ModelConfigFromGGUF(g)
	if cfg.QueryPreAttnScalar != 0 {
		t.Errorf("llama QueryPreAttnScalar = %d, want 0 (disabled)", cfg.QueryPreAttnScalar)
	}
	if got, want := cfg.EffectiveQueryPreAttnScalar(), cfg.EffectiveHeadDim(); got != want {
		t.Errorf("llama EffectiveQueryPreAttnScalar = %d, want EffectiveHeadDim %d", got, want)
	}
}

// BlockRuntime.attentionScale is the value actually fed to SDPA. Confirm:
//   - gemma-2-2b/9b: scale is IDENTICAL to the legacy 1/sqrt(head_dim) (no regression).
//   - gemma-2-27b:   scale is 1/sqrt(144), distinct from the legacy 1/sqrt(128).
func TestGemma2AttentionScale(t *testing.T) {
	b := cpu.NewCPUBackend()

	for _, m := range gemma2Models {
		cfg := ModelConfig{
			HiddenSize:         m.hiddenSize,
			NumAttentionHeads:  m.numHeads,
			NumKeyValueHeads:   m.numHeads / 2,
			HeadDim:            m.headDim,
			NormType:           NormRMSNorm,
			MLPType:            MLPGeGLU,
			RMSNormEPS:         1e-6,
			RoPETheta:          10000.0,
			RoPENeox:           true,
			QueryPreAttnScalar: m.wantScalar,
		}
		block := NewBlockRuntime(b, cfg)

		got := block.attentionScale()
		want := float32(1.0 / math.Sqrt(float64(m.wantScalar)))
		if got != want {
			t.Errorf("%s: attentionScale() = %v, want 1/sqrt(%d) = %v", m.name, got, m.wantScalar, want)
		}

		legacy := float32(1.0 / math.Sqrt(float64(m.headDim)))
		unchanged := got == legacy
		if m.name == "gemma-2-27b" {
			if unchanged {
				t.Errorf("%s: attentionScale() must differ from legacy 1/sqrt(head_dim=%d)", m.name, m.headDim)
			}
		} else if !unchanged {
			t.Errorf("%s: attentionScale() = %v regressed vs legacy 1/sqrt(head_dim=%d) = %v",
				m.name, got, m.headDim, legacy)
		}
	}
}

// With QueryPreAttnScalar unset (0), attentionScale must fall back to 1/sqrt(head_dim).
func TestAttentionScaleFallsBackToHeadDim(t *testing.T) {
	b := cpu.NewCPUBackend()
	cfg := ModelConfig{
		HiddenSize:        4096,
		NumAttentionHeads: 32,
		NumKeyValueHeads:  8,
		NormType:          NormRMSNorm,
		MLPType:           MLPSwiGLU,
		RMSNormEPS:        1e-5,
		RoPETheta:         10000.0,
	}
	block := NewBlockRuntime(b, cfg)
	got := block.attentionScale()
	want := float32(1.0 / math.Sqrt(float64(cfg.EffectiveHeadDim())))
	if got != want {
		t.Errorf("attentionScale() = %v, want 1/sqrt(head_dim) = %v", got, want)
	}
}
