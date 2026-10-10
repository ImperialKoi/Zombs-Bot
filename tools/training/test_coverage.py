import json
import tempfile
import unittest
from pathlib import Path

from scene_coverage import audit_coverage, review_evidence, sha256
from annotate import is_reviewed, prepare_review


class CoverageTests(unittest.TestCase):
    def test_annotator_cannot_save_empty_frame_without_explicit_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "image.jpg"
            image.write_bytes(b"fixture")
            data = {"reviewed": True, "objects": []}
            with self.assertRaises(ValueError):
                prepare_review(data, image)
            data["review"] = {"reviewer": "fixture", "notes": "Empty menu inspected",
                              "sceneObjectsReviewed": True, "negative": True,
                              "negativeReason": "No target-class world objects visible"}
            saved = prepare_review(data, image)
            self.assertEqual(saved["review"]["imageSHA256"], sha256(image))
            annotation = Path(tmp) / "annotation.json"
            annotation.write_text(json.dumps(saved))
            frame = {"image_path": image, "annotation_path": annotation}
            self.assertTrue(is_reviewed(frame))
            image.write_bytes(b"changed image")
            self.assertFalse(is_reviewed(frame))

    def test_negative_requires_source_bound_scene_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "image.jpg"
            image.write_bytes(b"fixture")
            annotation = {"reviewed": True, "objects": [], "review": {
                "reviewer": "fixture", "date": "2026-10-04", "method": "visual",
                "notes": "Empty menu reviewed", "sceneObjectsReviewed": True,
                "negative": True, "imageSHA256": sha256(image)}}
            with self.assertRaises(ValueError):
                review_evidence(annotation, image)
            annotation["review"]["negativeReason"] = "Inspected full frame: no target-class world objects"
            review_evidence(annotation, image)
            annotation["review"]["sceneObjectsReviewed"] = False
            with self.assertRaises(ValueError):
                review_evidence(annotation, image)
            annotation["review"]["sceneObjectsReviewed"] = True
            image.write_bytes(b"replacement")
            with self.assertRaises(ValueError):
                review_evidence(annotation, image)

    def test_split_coverage_does_not_count_unreviewed_or_unaudited_negatives(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue = root / "queue.json"
            plan = root / "plan.json"
            rows = []
            for n in range(3):
                match = root / "recordings" / str(n)
                (match / "images").mkdir(parents=True)
                (match / "annotations").mkdir()
                image = match / "images/0.jpg"
                image.write_bytes(b"fixture")
                (match / "session.json").write_text(json.dumps({"matchID": str(n), "mode": "solo"}))
                (match / "frames.jsonl").write_text(json.dumps({"image": "images/0.jpg"}) + "\n")
                rows.append({"matchID": str(n), "image": "images/0.jpg"})
                if n == 0:
                    obj = {"label": "rock", "polygon": [[0, 0], [1, 0], [0, 1]]}
                    annotation = {"reviewed": True, "objects": [obj, obj], "review": {
                        "reviewer": "fixture", "date": "2026-10-04", "method": "visual", "notes": "two rocks",
                        "sceneObjectsReviewed": True, "negative": False, "imageSHA256": sha256(image)}}
                    (match / "annotations/0.json").write_text(json.dumps(annotation))
                elif n == 1:
                    (match / "annotations/0.json").write_text(json.dumps({"reviewed": True, "objects": []}))
            queue.write_text(json.dumps({"frames": rows}))
            plan.write_text(json.dumps({"modes": ["solo"], "splits": {"train": ["0"], "val": ["1"], "test": ["2"]}}))
            lock = root / "lock.json"
            lock.write_text(json.dumps({str(plan): sha256(plan)}))
            result = audit_coverage(root / "recordings", queue, plan, lock)
            self.assertEqual(result["totals"]["reviewed"], 1)
            self.assertEqual(result["totals"]["pending"], 2)
            self.assertEqual(result["totals"]["invalid"], 1)
            self.assertEqual(result["totals"]["negativeFrames"], 0)
            self.assertEqual(result["splits"]["train"]["classes"]["rock"], {"instances": 2, "frames": 1})
            self.assertIn("rock", result["missingReviewedClassesBySplit"]["val"])
            self.assertFalse(result["queueComplete"])
            plan.write_text(plan.read_text() + "\n")
            self.assertEqual(audit_coverage(root / "recordings", queue, plan, lock)["changedLockedFiles"], [str(plan)])
            rows.append(rows[0])
            queue.write_text(json.dumps({"frames": rows}))
            with self.assertRaises(ValueError):
                audit_coverage(root / "recordings", queue, plan)


if __name__ == "__main__":
    unittest.main()
