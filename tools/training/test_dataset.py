import json
import tempfile
import unittest
from pathlib import Path
from dataset import MODES, export_dataset, planned_splits, split_sessions, tree_hash, validate_annotation


class DatasetTests(unittest.TestCase):
    def test_solo_pilot_requires_separate_matches(self):
        sessions = [dict(matchID=f"solo-{n}", mode="solo") for n in range(4)]
        splits = split_sessions(sessions, modes={"solo"})
        self.assertEqual(sorted(len(group) for group in splits.values()), [1,1,2])
        with self.assertRaises(ValueError): split_sessions(sessions)
        with self.assertRaises(ValueError): split_sessions(sessions, modes=set())

    def test_frozen_plan_rejects_leakage_and_missing_annotations(self):
        sessions = [dict(matchID=str(n), mode="solo") for n in range(4)]
        plan = dict(modes=["solo"], splits=dict(train=["0","1"], val=["2"], test=["3"]))
        self.assertEqual([s["matchID"] for s in planned_splits(sessions,plan,{"solo"})["train"]], ["0","1"])
        with self.assertRaises(ValueError): planned_splits(sessions[:3],plan,{"solo"})
        plan["splits"]["test"]=["1","3"]
        with self.assertRaises(ValueError): planned_splits(sessions,plan,{"solo"})

    def test_split_keeps_matches_and_modes_separate(self):
        sessions = [dict(matchID=f"{mode}-{n}", mode=mode) for mode in MODES for n in range(7)]
        splits = split_sessions(sessions)
        ids = [s["matchID"] for group in splits.values() for s in group]
        self.assertEqual(len(ids), len(set(ids)))
        for group in splits.values(): self.assertEqual({s["mode"] for s in group}, MODES)
        self.assertEqual(splits, split_sessions(sessions))

    def test_insufficient_matches_fails(self):
        with self.assertRaises(ValueError): split_sessions([dict(matchID="one", mode="solo")])

    def test_invalid_polygons_fail(self):
        for polygon in [[[0, 0], [0, 0], [0, 0]], [[0, 0], [1, 0], [float("nan"), 1]], [[0, 0], [2, 0], [1, 1]]]:
            with self.assertRaises(ValueError): validate_annotation(dict(reviewed=True, objects=[dict(label="player", polygon=polygon)]))
        validate_annotation(dict(reviewed=True, objects=[]))

    def test_hash_includes_filename_and_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "a").write_bytes(b"first")
            before = tree_hash(root); (root / "a").write_bytes(b"second")
            self.assertNotEqual(before, tree_hash(root))
            before = tree_hash(root); (root / "a").rename(root / "b")
            self.assertNotEqual(before, tree_hash(root))

    def test_dataset_export_and_reject_stale_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "recordings"; output = Path(tmp) / "dataset"
            for mode in MODES:
                for n in range(3):
                    match = root / f"{mode}-{n}"
                    (match / "images").mkdir(parents=True); (match / "annotations").mkdir()
                    (match / "session.json").write_text(json.dumps(dict(matchID=match.name, mode=mode)))
                    (match / "images" / "0.jpg").write_bytes(b"fixture-image")
                    (match / "frames.jsonl").write_text(json.dumps(dict(image="images/0.jpg")) + "\n")
                    (match / "annotations" / "0.json").write_text(json.dumps(dict(reviewed=True, objects=[dict(label="player", polygon=[[0,0],[1,0],[1,1],[0,1]])])))
            report = export_dataset(root, output)
            self.assertEqual(report["frames"], 9)
            self.assertEqual(len(list(output.glob("labels/*/*.txt"))), 9)
            with self.assertRaises(ValueError): export_dataset(root, output)

    def test_snapshot_may_train_on_a_mode_missing_from_held_out_splits(self):
        sessions = [dict(matchID="s0", mode="solo"), dict(matchID="s1", mode="solo"), dict(matchID="s2", mode="solo"),
                    dict(matchID="d0", mode="duo")]
        plan = dict(modes=["duo", "solo"], splits=dict(train=["s0", "d0"], val=["s1"], test=["s2"]))
        with self.assertRaises(ValueError): planned_splits(sessions, plan, {"solo", "duo"})
        splits = planned_splits(sessions, plan, {"solo", "duo"}, require_all=False, every_mode_everywhere=False)
        self.assertEqual([s["matchID"] for s in splits["train"]], ["s0", "d0"])
        plan["splits"] = dict(train=["s0"], val=["s1", "d0"], test=["s2"])  # A mode must still be trained on.
        with self.assertRaises(ValueError): planned_splits(sessions, plan, {"solo", "duo"}, require_all=False, every_mode_everywhere=False)

    def test_all_mode_snapshot_is_still_a_pilot(self):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            root, plan = Path(tmp) / "recordings", Path(tmp) / "plan.json"
            splits = dict(train=[], val=[], test=[])
            for mode in sorted(MODES):
                for split in splits:
                    match = root / f"{mode}-{split}"
                    (match / "images").mkdir(parents=True); (match / "annotations").mkdir()
                    (match / "session.json").write_text(json.dumps(dict(matchID=match.name, mode=mode)))
                    (match / "frames.jsonl").write_text(json.dumps(dict(image="images/0.jpg")) + "\n")
                    (match / "images" / "0.jpg").write_bytes(match.name.encode())
                    review = dict(reviewer="fixture", date="2026-10-07", method="visual", notes="tree", sceneObjectsReviewed=True,
                                  negative=False, imageSHA256=hashlib.sha256(match.name.encode()).hexdigest())
                    tree = dict(label="tree", polygon=[[0, 0], [1, 0], [1, 1]])
                    (match / "annotations" / "0.json").write_text(json.dumps(dict(reviewed=True, objects=[tree], review=review)))
                    splits[split].append(match.name)
            plan.write_text(json.dumps(dict(modes=sorted(MODES), splits=splits)))
            report = export_dataset(root, Path(tmp) / "snapshot", None, plan, reviewed_snapshot=True)
            self.assertEqual((report["frames"], report["scope"], report["modes"]), (9, "pilot", sorted(MODES)))

    def test_reviewed_snapshot_exports_only_source_bound_reviews(self):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            root, plan = Path(tmp) / "recordings", Path(tmp) / "plan.json"
            plan.write_text(json.dumps(dict(modes=["solo"], splits=dict(train=["m0", "m3"], val=["m1"], test=["m2"]))))
            for n in range(4):
                match = root / f"m{n}"
                (match / "images").mkdir(parents=True); (match / "annotations").mkdir()
                (match / "session.json").write_text(json.dumps(dict(matchID=match.name, mode="solo")))
                (match / "frames.jsonl").write_text("".join(json.dumps(dict(image=f"images/{i}.jpg")) + "\n" for i in range(2)))
                for i in range(2):
                    (match / "images" / f"{i}.jpg").write_bytes(f"{n}-{i}".encode())
                if n == 3: continue  # A planned training match nobody has reviewed yet.
                review = dict(reviewer="fixture", date="2026-10-05", method="visual", notes="rock",
                              sceneObjectsReviewed=True, negative=False,
                              imageSHA256=hashlib.sha256(f"{n}-0".encode()).hexdigest())
                rock = dict(label="rock", polygon=[[0, 0], [1, 0], [1, 1]])
                (match / "annotations" / "0.json").write_text(json.dumps(dict(reviewed=True, objects=[rock], review=review)))
                (match / "annotations" / "1.json").write_text(json.dumps(dict(reviewed=True, objects=[rock], review=review)))
            with self.assertRaises(ValueError): export_dataset(root, Path(tmp) / "strict", ["solo"], plan)
            with self.assertRaises(ValueError): export_dataset(root, Path(tmp) / "unplanned", ["solo"], None, reviewed_snapshot=True)
            output = Path(tmp) / "snapshot"
            report = export_dataset(root, output, ["solo"], plan, reviewed_snapshot=True)
            self.assertEqual((report["frames"], report["scope"]), (3, "pilot"))
            self.assertEqual(report["unreviewedPlannedMatches"], dict(train=["m3"], val=[], test=[]))
            # Frame 1 reuses frame 0's image hash, so its review is not bound to its own image.
            self.assertEqual(sorted(p["matchID"] for p in report["pendingAnnotationFiles"]), ["m0", "m1", "m2"])
            manifest = [json.loads(line) for line in (output / "exported-frames.jsonl").read_text().splitlines()]
            self.assertEqual([(m["split"], m["matchID"], m["image"]) for m in manifest],
                             [("train", "m0", "images/0.jpg"), ("val", "m1", "images/0.jpg"), ("test", "m2", "images/0.jpg")])
            self.assertEqual(manifest[0]["annotationSHA256"],
                             hashlib.sha256((root / "m0" / "annotations" / "0.json").read_bytes()).hexdigest())


if __name__ == "__main__": unittest.main()
