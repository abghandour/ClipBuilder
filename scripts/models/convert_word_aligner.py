"""Convert the Apache-2.0 Portuguese wav2vec2 CTC model to the fixed-window
Core ML model behind Settings > Transcription > Word timing > Precise
(docs/Word-Alignment-Plan.md).

    uv run --python 3.12 --with torch==2.5.1 --with coremltools==8.3.0 \
        --with transformers==4.46.3 --with "numpy<2.2" python convert_word_aligner.py

Writes PortugueseAligner.mlpackage and vocab.json to the current directory.
Zip them with a NOTICE.txt as PortugueseAligner-<version>.zip; the app pins
the archive's SHA-256 in WordAlignerModel.archiveSHA256, and a rebuilt
archive will not match byte for byte, so bump the version with the hash.
"""
import json, sys, torch, numpy as np, coremltools as ct, coremltools.optimize.coreml as cto
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
name='jonatasgrosman/wav2vec2-large-xlsr-53-portuguese'; SECONDS=20
proc=Wav2Vec2Processor.from_pretrained(name); model=Wav2Vec2ForCTC.from_pretrained(name).eval()
vocab=proc.tokenizer.get_vocab()
json.dump({"vocab":vocab,"blank":proc.tokenizer.pad_token_id,"sample_rate":16000,"window_seconds":SECONDS,"source":name,"license":"apache-2.0"},open('vocab.json','w'),ensure_ascii=False,indent=1)
class Wrap(torch.nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    def forward(s,x): return torch.log_softmax(s.m(x).logits,-1)
w=Wrap(model).eval(); x=torch.zeros(1,SECONDS*16000)
traced=torch.jit.trace(w,x,strict=False)
ml=ct.convert(traced,inputs=[ct.TensorType(name='audio',shape=x.shape)],outputs=[ct.TensorType(name='emission')],
  minimum_deployment_target=ct.target.macOS15,compute_precision=ct.precision.FLOAT16,skip_model_load=True)
q=cto.linear_quantize_weights(ml,cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode='linear_symmetric',dtype='int8')))
q.short_description='Portuguese word aligner (wav2vec2 XLSR-53 CTC, 8-bit weights)'; q.license='Apache-2.0'; q.author=name
q.save('PortugueseAligner.mlpackage'); print('saved')
