# CoNo — Copyright (C) 2026 AIB Inc. — GPL-3.0-or-later
# SwiftF0 (lars76/swift-f0, MIT) 모델의 pitch 출력을 double → float 로 바꾼다.
# 이유: ONNX Runtime ObjC API 는 double 텐서를 읽지 못한다 ("unsupported tensor element type").
# 사용: uv run --with onnx python3 scripts/convert_swiftf0.py <원본 model.onnx> CoNo/Resources/swift_f0.onnx
import hashlib
import sys

import onnx
from onnx import TensorProto, helper

# lars76/swift-f0 @ 2ed0c83 의 swift_f0/model.onnx
EXPECTED_MD5 = "4ba011fd2164a135a3f214bc86f3626f"

src, dst = sys.argv[1], sys.argv[2]
digest = hashlib.md5(open(src, "rb").read()).hexdigest()
if digest != EXPECTED_MD5:
    sys.exit(f"원본 해시 불일치: {digest} (기대값 {EXPECTED_MD5})")

model = onnx.load(src)
graph = model.graph
pitch = next(o for o in graph.output if o.name == "pitch")
if pitch.type.tensor_type.elem_type != TensorProto.DOUBLE:
    sys.exit("pitch 출력이 이미 double 이 아니다 — 변환 불필요")

# 기존 출력 텐서 이름을 내부용으로 바꾸고, 그 뒤에 Cast 를 붙여 원래 이름으로 내보낸다
internal = "pitch_f64"
for node in graph.node:
    node.output[:] = [internal if name == "pitch" else name for name in node.output]
    node.input[:] = [internal if name == "pitch" else name for name in node.input]
graph.node.append(helper.make_node("Cast", [internal], ["pitch"], to=TensorProto.FLOAT, name="pitch_to_float"))
pitch.type.tensor_type.elem_type = TensorProto.FLOAT

onnx.checker.check_model(model)
onnx.save(model, dst)
print(f"OK: {dst} (md5 {hashlib.md5(open(dst, 'rb').read()).hexdigest()})")
