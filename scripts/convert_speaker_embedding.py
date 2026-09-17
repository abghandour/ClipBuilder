import sys, torch, numpy as np, coremltools as ct
from speechbrain.inference.speaker import EncoderClassifier

torch.manual_seed(0)
enc = EncoderClassifier.from_hparams(source="speechbrain/spkrec-ecapa-voxceleb", savedir="pretrained",
                                     run_opts={"device": "cpu"})
enc.eval()
feats, norm, model = enc.mods.compute_features, enc.mods.mean_var_norm, enc.mods.embedding_model
print("fbank:", feats)
print("norm:", type(norm).__name__, "std_norm", getattr(norm, "std_norm", None), "norm_type", getattr(norm, "norm_type", None))

class Pipeline(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.feats, self.norm, self.model = feats, norm, model
    def forward(self, wav):                       # wav: [1, samples] float32, 16 kHz
        # SpeechBrain's InputNormalization (sentence mean, no std) and the
        # pooling mask both cast symbolic lengths to int, which the
        # converter cannot follow; whole-utterance input needs neither.
        f = self.feats(wav)
        f = f - f.mean(dim=1, keepdim=True)
        e = self.model(f)                         # [1, 1, 192]
        e = e.squeeze(1)
        return e / torch.clamp(e.norm(dim=-1, keepdim=True), min=1e-8)

pipe = Pipeline().eval()
wav = torch.randn(1, 48000) * 0.1
with torch.no_grad():
    ref = pipe(wav)
    ref2 = enc.encode_batch(wav).squeeze(1)
    ref2 = ref2 / ref2.norm(dim=-1, keepdim=True)
print("pipeline vs speechbrain cosine:", float((ref * ref2).sum()))

traced = torch.jit.trace(pipe, wav, strict=False)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="audio", shape=(1, ct.RangeDim(lower_bound=8000, upper_bound=16000 * 30, default=48000)), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "ECAPA-TDNN speaker embedding (SpeechBrain spkrec-ecapa-voxceleb, Apache-2.0): 16 kHz mono audio in, unit-length 192-d voice embedding out."
mlmodel.author = "SpeechBrain (converted for Clip Builder)"
mlmodel.license = "Apache-2.0"
mlmodel.save("SpeakerEmbedding.mlpackage")

for seconds in (1.0, 3.0, 7.5):
    x = torch.randn(1, int(16000 * seconds)) * 0.1
    with torch.no_grad():
        t = pipe(x)[0].numpy()
    c = mlmodel.predict({"audio": x.numpy()})["embedding"].reshape(-1)
    print(f"{seconds}s cosine torch vs coreml: {float(np.dot(t, c) / (np.linalg.norm(t) * np.linalg.norm(c))):.4f}")
