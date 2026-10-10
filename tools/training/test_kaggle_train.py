import ast
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from kaggle_train import kernel_source, slug, stage_bundle
from train import check_provenance, sha256


class KaggleTrainTests(unittest.TestCase):
    def test_bundle_uploads_train_and_val_but_never_test_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "dataset"
            for split in ("train", "val", "test"):
                for kind, suffix in (("images", ".jpg"), ("labels", ".txt")):
                    (root / kind / split).mkdir(parents=True)
                    (root / kind / split / f"{split}-frame{suffix}").write_text(split)
            (root / "split-report.json").write_text("{}")
            stage_bundle(root / "dataset.yaml", Path(tmp) / "bundle.zip")
            names = set(zipfile.ZipFile(Path(tmp) / "bundle.zip").namelist())
        self.assertEqual(names, {"dataset/images/train/train-frame.jpg", "dataset/labels/train/train-frame.txt",
                                 "dataset/images/val/val-frame.jpg", "dataset/labels/val/val-frame.txt",
                                 "dataset/split-report.json", "code/train.py", "code/dataset.py"})

    def test_kernel_embeds_config(self):
        config = dict(epochs=100, size=960, batch=4, nominalBatch=4, ultralytics="8.4.173")
        tree = ast.parse(kernel_source(config))
        assigned = next(node for node in tree.body if isinstance(node, ast.Assign) and node.targets[0].id == "CONFIG")
        self.assertEqual(json.loads(ast.literal_eval(assigned.value.args[0])), config)

    def test_weights_must_match_the_dataset_and_their_training_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            report, weights = Path(tmp) / "split-report.json", Path(tmp) / "run" / "best.pt"
            report.write_text('{"frames": 3}')
            weights.parent.mkdir()
            weights.write_bytes(b"checkpoint")
            record = dict(splitReportSHA256=sha256(report), bestCheckpointSHA256=sha256(weights), size=960)
            (weights.parent / "training.json").write_text(json.dumps(record))
            self.assertEqual(check_provenance(weights, report)["size"], 960)
            weights.write_bytes(b"other checkpoint")
            with self.assertRaises(SystemExit): check_provenance(weights, report)
            weights.write_bytes(b"checkpoint")
            report.write_text('{"frames": 4}')
            with self.assertRaises(SystemExit): check_provenance(weights, report)

    def test_slugs_are_kaggle_safe(self):
        self.assertEqual(slug("zombs-train-Solo_Pilot 2026.10.05"), "zombs-train-solo-pilot-2026-10-05")
        self.assertLessEqual(len(slug("zombs-" + "x" * 80)), 50)


if __name__ == "__main__":
    unittest.main()
