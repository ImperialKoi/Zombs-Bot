from __future__ import annotations
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from dataset import load_sessions, planned_splits
from ingest_recordings import (ANCHORS, ASSIGNMENTS, LOG, QUEUE, IngestError, KaggleSource, assign_split, emit_plan, init,
                               match_id_from_slug, plan_from, pull, queue_entries)

HAS_PIL = importlib.util.find_spec("PIL") is not None

# Stands in for zombs-extract: one JPEG per 1/fps seconds of each part, one JSON line per image.
FAKE_EXTRACTOR = '''
import json, sys
from pathlib import Path
from PIL import Image
recording, output = Path(sys.argv[1]), Path(sys.argv[2])
fps = float(sys.argv[sys.argv.index("--fps") + 1])
manifest = json.loads((recording / "recording.json").read_text())
(output / "images").mkdir(parents=True, exist_ok=True)
shade = int(manifest["matchID"][-2:], 16)
index = 0
for p, part in enumerate(manifest["parts"]):
    for i in range(int(part["durationSeconds"] * 30) + 1):
        if i % int(30 / fps) == 0:
            name = f"images/{index:06d}.jpg"
            Image.new("RGB", (part["width"], part["height"]), (index % 256, shade, 40)).save(output / name, quality=95)
            print(json.dumps({"image": name, "index": index, "part": p, "timestamp": part["startSeconds"] + i / 30,
                              "width": part["width"], "height": part["height"]}))
        index += 1
'''


def recording(folder: Path, match: str, mode: str, seconds: float = 6, video: bytes | None = None) -> Path:
    """A finished ZombsRecorder match folder; the fake extractor never decodes the video bytes."""
    folder = folder / match
    folder.mkdir(parents=True)
    video = video if video is not None else match.encode() * 1000
    (folder / "part-000.mov").write_bytes(video)
    (folder / "recording.json").write_text(json.dumps(dict(
        schema=1, matchID=match, mode=mode, teammates=[], recordedBy="friend", recorderVersion="0.1.0",
        createdAt=f"{match[:10]}T{match[11:19].replace('-', ':')}Z", endedAt="2026-10-06T23:59:59Z", endReason="hotkey",
        capture=dict(fps=30, codec="hevc", bitrate=4000000, topInsetPoints=87, scale=2),
        parts=[dict(file="part-000.mov", width=64, height=48, frames=int(seconds * 30), startSeconds=0, durationSeconds=seconds,
                    bytes=len(video), sha256=hashlib.sha256(video).hexdigest())], complete=True)))
    return folder


class FakeKaggle:
    def __init__(self, remote: Path):
        self.remote, self.deleted = remote, []

    def refs(self):
        return sorted(f"owner/zombs-rec-{p.name.lower()}" for p in self.remote.iterdir())

    def download(self, ref, destination):
        source = self.remote / ref.split("/")[1].removeprefix("zombs-rec-").upper()
        for file in source.iterdir():
            (destination / file.name).write_bytes(file.read_bytes())

    def delete(self, ref):
        self.deleted.append(ref)


class IngestLogicTests(unittest.TestCase):
    def test_split_fills_each_mode_first_then_hashes(self):
        assignments = {}
        for n in range(3):
            match = f"2026-10-06T19-0{n}-00Z-AAAAA{n}"
            assignments[match] = dict(mode="duo", split=assign_split(match, "duo", assignments))
        self.assertEqual([a["split"] for a in assignments.values()], ["train", "val", "test"])
        self.assertEqual(assign_split("2026-10-06T20-00-00Z-BBBBBB", "squad", assignments), "train")
        later = [assign_split(f"2026-10-07T00-00-{n:02d}Z-CCCCCC", "duo", assignments) for n in range(60)]
        self.assertEqual(later, [assign_split(f"2026-10-07T00-00-{n:02d}Z-CCCCCC", "duo", assignments) for n in range(60)])
        self.assertTrue({"train", "val", "test"} <= set(later) and later.count("train") > later.count("val"))

    def test_queue_uses_v2_anchor_rule_and_relative_times(self):
        rows = [dict(image=f"images/{i * 6:06d}.jpg", timestamp=100 + i * 0.2) for i in range(100)]
        entries = queue_entries("m", rows, 0)
        self.assertEqual([e["image"] for e in entries], [rows[round(i * 99 / 11)]["image"] for i in range(ANCHORS)])
        self.assertEqual(entries[0]["timeSeconds"], 0)
        self.assertAlmostEqual(entries[-1]["timeSeconds"], 19.8)
        self.assertEqual(len(queue_entries("m", rows, 50)), len({round(i * 99 / 11) for i in range(12)} | {round(i * 99 / 49) for i in range(50)}))
        self.assertEqual(len(queue_entries("m", rows[:5], 0)), 5)

    def test_slug_maps_back_to_match_id(self):
        self.assertEqual(match_id_from_slug("zombs-rec-2026-10-06t19-02-11z-4c1a9e"), "2026-10-06T19-02-11Z-4C1A9E")

    def test_plan_keeps_requested_modes_only(self):
        assignments = {"a": dict(mode="solo", split="train"), "b": dict(mode="duo", split="val"), "c": dict(mode="duo", split="train")}
        self.assertEqual(plan_from(assignments, {"duo"}), dict(modes=["duo"], splits=dict(train=["c"], val=["b"], test=[])))
        self.assertEqual(plan_from(assignments, {"duo", "solo"}, only={"a"})["splits"]["train"], ["a"])


@unittest.skipUnless(HAS_PIL, "the audit and contact sheets need Pillow (.venv)")
class IngestPipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.corpus, self.raw, self.local, self.remote = (self.root / n for n in ("corpus", "raw", "local", "remote"))
        for folder in (self.local, self.remote):
            folder.mkdir()
        extractor = self.root / "fake_extract.py"
        extractor.write_text(FAKE_EXTRACTOR)
        self.extractor = [sys.executable, str(extractor)]

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self) -> tuple[Path, Path]:
        """Three Solo sessions in ZombsAssistant's format with a frozen plan."""
        from PIL import Image
        seed = self.root / "seed"
        for n, split in enumerate(("train", "val", "test")):
            match = seed / f"2026-10-04T00-0{n}-00Z-00000{n}"
            (match / "images").mkdir(parents=True)
            Image.new("RGB", (64, 48), (n * 50, 0, 0)).save(match / "images" / "000000.jpg")
            (match / "session.json").write_text(json.dumps(dict(matchID=match.name, mode="solo")))
            (match / "frames.jsonl").write_text(json.dumps(dict(image="images/000000.jpg", matchID=match.name, mode="solo",
                                                                timestamp=1.0, width=64, height=48)) + "\n")
            for log in ("observations.jsonl", "decisions.jsonl"):
                (match / log).write_text("")
        plan = self.root / "seed-plan.json"
        plan.write_text(json.dumps(dict(modes=["solo"], splits=dict(train=["2026-10-04T00-00-00Z-000000"],
                                                                     val=["2026-10-04T00-01-00Z-000001"], test=["2026-10-04T00-02-00Z-000002"]))))
        return seed, plan

    def pull(self, **options):
        return pull(self.corpus, raw=self.raw, extractor=self.extractor, source=options.pop("source", FakeKaggle(self.remote)),
                    local=self.local, **options)

    def test_seeded_corpus_ingests_local_and_kaggle_matches(self):
        seed, plan = self.seed()
        init(self.corpus, seed, plan)
        self.assertTrue((self.corpus / "2026-10-04T00-01-00Z-000001").is_symlink())
        duo, squad = "2026-10-06T19-02-11Z-4C1A9E", "2026-10-06T20-00-00Z-ABCDEF"
        recording(self.local, duo, "duo")
        recording(self.remote, squad, "squad", seconds=4)
        summary = self.pull()
        self.assertEqual(summary["problems"], {})
        self.assertEqual([m["matchID"] for m in summary["ingested"]], [duo, squad])

        sessions = {s["matchID"]: s for s in load_sessions(self.corpus)}
        self.assertEqual(len(sessions), 5)
        self.assertEqual(len(sessions[duo]["frames"]), 31)  # 0 s to 6 s inclusive at 5 FPS
        self.assertEqual(sessions[duo]["source"], "zombs-recorder")
        self.assertEqual({r["mode"] for r in sessions[squad]["frames"]}, {"squad"})
        self.assertTrue(json.loads((self.corpus / "audits" / f"{duo}.json").read_text())["passed"])
        self.assertTrue((self.corpus / "contact-sheets" / f"{squad}.jpg").exists())

        record = json.loads((self.corpus / ASSIGNMENTS).read_text())
        self.assertEqual(record["assignments"]["2026-10-04T00-01-00Z-000001"]["split"], "val")
        self.assertEqual((record["assignments"][duo]["split"], record["assignments"][squad]["split"]), ("train", "train"))
        queue = json.loads((self.corpus / QUEUE).read_text())["frames"]
        self.assertEqual(len(queue), 2 * ANCHORS)
        log = json.loads((self.corpus / LOG).read_text())["matches"]
        self.assertEqual((log[duo]["source"], log[squad]["kaggleRef"]), ("local", "owner/zombs-rec-2026-10-06t20-00-00z-abcdef"))

        again = self.pull()
        self.assertEqual((again["ingested"], sorted(again["skipped"])), ([], [duo, squad]))
        self.assertEqual(json.loads((self.corpus / QUEUE).read_text())["frames"], queue)

    def test_bad_hash_is_skipped_until_fixed(self):
        init(self.corpus)
        match = "2026-10-06T19-02-11Z-4C1A9E"
        folder = recording(self.remote, match, "duo")
        good = (folder / "part-000.mov").read_bytes()
        (folder / "part-000.mov").write_bytes(b"truncated")
        summary = self.pull()
        self.assertIn("SHA-256", summary["problems"][match])
        self.assertFalse((self.corpus / match).exists())
        self.assertEqual(json.loads((self.corpus / ASSIGNMENTS).read_text())["assignments"], {})
        (folder / "part-000.mov").write_bytes(good)
        for stale in self.raw.iterdir():  # The bad copy stays in raw; a fixed re-upload replaces it.
            import shutil
            shutil.rmtree(stale)
        self.assertEqual([m["matchID"] for m in self.pull()["ingested"]], [match])
        self.assertNotIn(match, json.loads((self.corpus / LOG).read_text())["problems"])

    def test_three_matches_make_an_exportable_plan(self):
        init(self.corpus)
        matches = [f"2026-10-06T19-0{n}-00Z-00000{n}" for n in range(3)]
        for match in matches:
            recording(self.remote, match, "duo")
        self.pull()
        plan = emit_plan(self.corpus, {"duo"}, self.root / "plan.json")
        self.assertEqual(plan["splits"], dict(train=[matches[0]], val=[matches[1]], test=[matches[2]]))
        splits = planned_splits(load_sessions(self.corpus), json.loads((self.root / "plan.json").read_text()), {"duo"})
        self.assertEqual({name: [s["matchID"] for s in group] for name, group in splits.items()}, plan["splits"])

    def test_teammates_recording_the_same_game_share_a_split(self):
        init(self.corpus)
        mine, friend, later = "2026-10-06T17-04-10Z-212F9A", "2026-10-06T17-04-11Z-644390", "2026-10-06T17-30-00Z-0A0B0C"
        for folder, match, start in [(self.local, mine, "2026-10-06T17:04:10Z"), (self.remote, friend, "2026-10-06T17:04:12Z"),
                                     (self.remote, later, "2026-10-06T17:30:00Z")]:
            path = recording(folder, match, "duo")
            manifest = json.loads((path / "recording.json").read_text())
            manifest["createdAt"] = start
            (path / "recording.json").write_text(json.dumps(manifest))
        self.pull()
        assignments = json.loads((self.corpus / ASSIGNMENTS).read_text())["assignments"]
        self.assertEqual(assignments[friend]["split"], assignments[mine]["split"])
        self.assertEqual(assignments[friend]["sameGameAs"], mine)
        self.assertEqual((assignments[mine]["split"], assignments[later]["split"]), ("train", "val"))
        self.assertNotIn("sameGameAs", assignments[later])

    def test_interrupted_registration_is_repaired_without_duplicates(self):
        init(self.corpus)
        match = "2026-10-06T19-02-11Z-4C1A9E"
        recording(self.remote, match, "solo")
        self.pull()
        record = json.loads((self.corpus / ASSIGNMENTS).read_text())
        del record["assignments"][match]  # As if the run stopped after queueing, before freezing the split.
        (self.corpus / ASSIGNMENTS).write_text(json.dumps(record))
        summary = self.pull()
        self.assertEqual([m["matchID"] for m in summary["ingested"]], [match])
        self.assertEqual(len(json.loads((self.corpus / QUEUE).read_text())["frames"]), ANCHORS)
        self.assertEqual(json.loads((self.corpus / ASSIGNMENTS).read_text())["assignments"][match]["split"], "train")

    def test_video_and_remote_retention(self):
        init(self.corpus)
        with self.assertRaises(IngestError):
            self.pull(keep_video=False, delete_remote=True)
        match = "2026-10-06T19-02-11Z-4C1A9E"
        recording(self.remote, match, "squad")
        source = FakeKaggle(self.remote)
        self.pull(source=source, keep_video=False)
        self.assertFalse((self.raw / match / "part-000.mov").exists())
        self.assertTrue((self.raw / match / "recording.json").exists())
        local_only = "2026-10-06T21-00-00Z-FEDCBA"
        recording(self.local, local_only, "squad")
        self.pull(source=None, keep_video=False)  # No Kaggle copy, so the only video stays.
        self.assertTrue((self.raw / local_only / "part-000.mov").exists())
        other = "2026-10-06T22-00-00Z-012345"
        recording(self.remote, other, "squad")
        self.pull(source=source, keep_video=True, delete_remote=True)
        self.assertEqual(source.deleted, [f"owner/zombs-rec-{other.lower()}"])
        self.assertTrue((self.raw / other / "part-000.mov").exists())

    def test_download_falls_back_to_single_files(self):
        remote = recording(self.remote, "2026-10-07T16-53-23Z-F91B95", "duo")

        class Api:  # The zipped download 404s, as Kaggle did for one ready dataset.
            def dataset_download_files(self, ref, path, unzip, quiet):
                (Path(path) / "partial.zip").write_bytes(b"x")
                raise RuntimeError("404 Client Error: Not Found")

            def dataset_list_files(self, ref):
                return type("Listing", (), {"files": [type("File", (), {"name": p.name})() for p in remote.iterdir()]})()

            def dataset_download_file(self, ref, name, path, quiet):
                (Path(path) / name).write_bytes((remote / name).read_bytes())

        target = self.root / "download"
        target.mkdir()
        KaggleSource(api=Api(), owner="owner").download("owner/zombs-rec-x", target)
        self.assertEqual(sorted(p.name for p in target.iterdir()), ["part-000.mov", "recording.json"])

    def test_prune_video_keeps_frames_and_unarchived_video(self):
        from ingest_recordings import prune_video
        init(self.corpus)
        archived, local_only = "2026-10-06T19-02-11Z-4C1A9E", "2026-10-06T21-00-00Z-FEDCBA"
        recording(self.remote, archived, "duo")
        recording(self.local, local_only, "duo")
        self.pull(keep_video=True)
        summary = prune_video(self.corpus, {archived: f"owner/zombs-rec-{archived.lower()}"})
        self.assertEqual((summary["deleted"], summary["kept"]), ([archived], [local_only]))
        self.assertFalse((self.raw / archived / "part-000.mov").exists())
        self.assertTrue((self.raw / archived / "recording.json").exists())
        self.assertTrue((self.raw / local_only / "part-000.mov").exists())
        self.assertEqual(len(load_sessions(self.corpus)), 2)  # Frames stay.
        self.assertFalse(json.loads((self.corpus / LOG).read_text())["matches"][archived]["videoKept"])
        self.assertEqual(prune_video(self.corpus, None, everything=True)["deleted"], [local_only])

    def test_init_refuses_reuse_and_unplanned_seed(self):
        seed, plan = self.seed()
        init(self.corpus, seed, plan)
        with self.assertRaises(IngestError):
            init(self.corpus, seed, plan)
        plan.write_text(json.dumps(dict(modes=["solo"], splits=dict(train=[], val=[], test=[]))))
        with self.assertRaises(IngestError):
            init(self.root / "other", seed, plan)


if __name__ == "__main__":
    unittest.main()
