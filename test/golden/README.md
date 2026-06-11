# Golden reference tests

These tests (`golden_test.go`) validate the Go inference implementation against
reference activations captured from the **real TinyLlama-1.1B-Chat-v1.0** model with
PyTorch/Transformers. They cover the embedding lookup, RMSNorm, the Q projection, and
the full forward-pass logits.

## Layout

| Path | Tracked? | What it is |
| --- | --- | --- |
| `data/*.npy`, `data/metadata.json` | yes | Golden activations captured from TinyLlama-1.1B (committed). |
| `data/*.json` | yes | Human-readable summary stats per tensor. |
| `generate_golden.py` | yes | Regenerates `data/` from the model (needs `requirements.txt`). |
| `fetch_model.sh` | yes | Downloads the model fixture. |
| `../../models/tiny_model.safetensors` | **no** (git-ignored) | The weights the golden data was captured from. |

The model weights are multi-GB and intentionally git-ignored (root `.gitignore`:
`models/`, `*.safetensors`), so they are **not** present in a fresh checkout.

## Running the tests

Without the fixture, the golden tests **skip** (they do not fail), matching the
convention used by the other model-dependent tests in `inference/runtime`:

```bash
go test ./test/golden/        # SKIP: Model fixture not found ...
```

To run the full validation, download the fixture first:

```bash
make golden-model             # or: ./test/golden/fetch_model.sh
make test-golden              # or: go test ./test/golden/
```

`fetch_model.sh` places three files in `../../models` with the `tiny_*` names that
both the Go loader (`tiny_model.safetensors`) and `generate_golden.py`'s
`setup_local_model()` (`tiny_config.json`, `tiny_tokenizer.json`) expect.

## Regenerating the golden data

Only needed if the reference activations themselves must change (e.g. a different
input token or captured layer). This requires the Python dependencies and the model
fixture:

```bash
pip install -r requirements.txt
./fetch_model.sh
python generate_golden.py --model-dir ../../models --output-dir ./data
```

Keep the committed `data/` consistent with whatever weights produced it — the
tolerances in `golden_test.go` (`1e-5` for kernels, `1e-3` for the full forward pass)
assume the activations and weights match.
