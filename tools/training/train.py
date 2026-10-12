"""Training recipe and Core ML export for annotated ZombsRoyale data.

Training runs on a Kaggle GPU: kaggle_train.py uploads the train/val splits and this file, and
the kernel calls fit(). This machine only exports the downloaded checkpoint to raw YOLO11-seg
Core ML outputs: train.py DATASET OUTPUT --weights best.pt
"""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
from pathlib import Path
from dataset import LABELS, tree_hash

# Exported input height; the width is the training size. 960 x 768 holds any game area wider than 5:4 at the
# training scale and runs entirely on the Neural Engine: 9-11 ms on an M1 against 21-23 ms for 960 x 960, whose
# 18,900 anchors exceed the Neural Engine's 16,384 and put the head on the GPU beside the game. Its detections
# match the square export's at the same thresholds (97-99.7% per class over 511 frames). 960 x 512 is faster
# (6-7 ms) but lowers confidences, since training letterboxes to 960 x 960. Multiples of 128 run fastest.
INPUT_HEIGHT = 768


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_trainable(report: dict) -> str:
    """Return the dataset scope; release candidates need the full reviewed-frame minimum."""
    scope = report.get("scope", "release")
    if scope != "pilot" and report["frames"] < 2000:
        raise SystemExit("At least 2,000 reviewed frames are required before training the release candidate.")
    return scope


def fit(dataset: Path, output: Path, epochs: int = 100, size: int = 960, device="0", batch: int = 4,
        nominal_batch: int = 64) -> Path:
    """Fine-tune YOLO11n-seg; returns the checkpoint chosen on validation, with training.json beside it."""
    import torch
    import ultralytics
    from ultralytics import YOLO
    report_file = dataset.parent / "split-report.json"
    require_trainable(json.loads(report_file.read_text()))
    output.mkdir(parents=True, exist_ok=True)
    model = YOLO("yolo11n-seg.pt")
    base = Path(model.ckpt_path)
    model.train(data=str(dataset.resolve()), epochs=epochs, imgsz=size, device=device, batch=batch,
                project=str((output / "runs").resolve()), name="zombs", exist_ok=False, seed=42, deterministic=True,
                nbs=nominal_batch, fliplr=0.0, flipud=0.0, mosaic=0.0)
    best = output / "best.pt"
    shutil.copy2(model.trainer.best, best)
    provenance = dict(splitReportSHA256=sha256(report_file), baseWeightsSHA256=sha256(base), epochs=epochs,
                      size=size, batch=batch, nominalBatch=nominal_batch, device=str(model.trainer.device),
                      accelerator=torch.cuda.get_device_name(0) if torch.cuda.is_available() else str(device),
                      torch=torch.__version__, ultralytics=ultralytics.__version__,
                      bestCheckpointSHA256=sha256(best))
    (output / "training.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return best


def check_runtime_layout(package: Path, size: int, height: int | None = None) -> None:
    """Refuse an export whose input or raw outputs differ from what Detector.swift decodes."""
    import coremltools as ct
    spec = ct.models.MLModel(str(package.resolve()), skip_model_load=True).get_spec()
    images = [(i.type.imageType.width, i.type.imageType.height) for i in spec.description.input
              if i.type.WhichOneof("Type") == "imageType"]
    shapes = [list(o.type.multiArrayType.shape) for o in spec.description.output]
    if (images != [(size, height or size)] or not any(len(s) == 3 and s[1] == 4 + len(LABELS) + 32 for s in shapes)
            or not any(len(s) == 4 and s[1] == 32 for s in shapes)):
        raise RuntimeError(f"Core ML layout does not match the runtime decoder: inputs {images}, outputs {shapes}")


def check_provenance(weights: Path, report_file: Path) -> dict:
    """The checkpoint must come from fit() on exactly this dataset export."""
    provenance = json.loads((weights.parent / "training.json").read_text())
    if provenance.get("splitReportSHA256") != sha256(report_file):
        raise SystemExit("These weights were trained on a different dataset export")
    if provenance.get("bestCheckpointSHA256") != sha256(weights):
        raise SystemExit("Checkpoint bytes differ from its training record")
    return provenance


def export(weights: Path, dataset: Path, output: Path, height: int = INPUT_HEIGHT) -> None:
    """Export a fitted checkpoint to the runtime's fixed-shape raw Core ML layout with its manifest."""
    from ultralytics import YOLO
    report_file = dataset.parent / "split-report.json"
    report = json.loads(report_file.read_text())
    scope = require_trainable(report)
    provenance = check_provenance(weights, report_file)
    destination = output / "zombs.mlpackage"
    if destination.exists():
        raise FileExistsError("Use a new output folder; existing model artifacts are preserved")
    trained = YOLO(str(weights))
    if [trained.names[i] for i in range(len(trained.names))] != LABELS:
        raise RuntimeError("Export class order differs from runtime taxonomy")
    size = provenance["size"]
    if height % 32 or not 160 <= height <= size:
        raise SystemExit(f"Input height must be a multiple of 32 between 160 and the training size {size}")
    output.mkdir(parents=True, exist_ok=True)
    shutil.move(trained.export(format="coreml", imgsz=[height, size], half=True, nms=False, dynamic=False), destination)
    check_runtime_layout(destination, size, height)
    shutil.copy2(weights.parent / "training.json", output / "training.json")
    manifest = dict(modelFile=destination.name, modelSHA256=tree_hash(destination), inputSize=size, inputHeight=height,
                    labels=LABELS, detectorThreshold=0.5, maskThreshold=0.5, scope=scope,
                    trainingFrames=sum(m["frames"] for m in report["splits"]["train"]),
                    trainedOn={name: [m["matchID"] for m in report["splits"][name]] for name in ("train", "val")},
                    splitReportSHA256=provenance["splitReportSHA256"])
    (output / "model.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Exported model. Run evaluate.py on the untouched test split and complete supervised acceptance.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--weights", type=Path, required=True,
                        help="best.pt downloaded from the Kaggle run, with its training.json beside it")
    parser.add_argument("--height", type=int, default=INPUT_HEIGHT,
                        help=f"model input height (default {INPUT_HEIGHT}); the width is the training size")
    args = parser.parse_args()
    export(args.weights, args.dataset, args.output, args.height)


if __name__ == "__main__":
    main()
