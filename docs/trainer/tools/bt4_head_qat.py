#!/usr/bin/env python3
"""Prepare/export the approved BT4 head-QAT stage; never launches training.

Uses our accepted production QAT arithmetic and named-tensor format, without
historical net, prefix or checkpoint paths. GPU/readback gates remain separate.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

import numpy as np

FT, FAC, HALFKA, THREAT, BUCKETS, L2, L3 = 1024, 768, 6144, 60144, 8, 16, 32
TRAIN = FAC + HALFKA + THREAT
GAIN = 0.9256841495771224
TARGET_DIVISOR = 800 / GAIN
BATCH_SIZE, BATCHES, LEARNING_RATE = 16384, 65536, 1e-5
HEAD = ("l1w", "l1b", "l2w", "l2b", "l3w", "l3b")
FROZEN = ("l0w", "l0b", "combw", "combb")
SHAPES = {
    "l0w": (TRAIN, FT), "l0b": (FT,), "l1w": (FT, BUCKETS * L2),
    "l1b": (BUCKETS * L2,), "l2w": (L2, BUCKETS * L3),
    "l2b": (BUCKETS * L3,), "l3w": (L3, BUCKETS), "l3b": (BUCKETS,),
    "psqtw": (TRAIN,), "psqtb": (1,), "combw": (2,), "combb": (1,),
}
HEADER = (b"ZQB9", HALFKA, FT, BUCKETS, 8, 1, L2, L3, THREAT, 400, 255, 64)
HEAD_START = 112 + HALFKA * FT * 2 + FT * 2
HEAD_END = HEAD_START + BUCKETS * L2 * FT + (128 + 4096 + 256 + 256 + 8) * 4
NET_BYTES = 74587732
OLD_NETS = {
    "c23ef305f8015c9d3e88765c8f43a082ce3cb0e4c8f25a568123df199301a932",
    "94da6682065a862dac0af63779ee39055553ba507a21ecd7b10bbe15dbab4a16",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bits_equal(a, b):
    return np.array_equal(np.asarray(a, dtype="<f4").ravel().view("<u4"),
                          np.asarray(b, dtype="<f4").ravel().view("<u4"))


def round_away(values):
    values = np.asarray(values, dtype=np.float64)
    return np.copysign(np.floor(np.abs(values) + 0.5), values)


def read_named(path, expected):
    """Memory-map tensors, reject missing/duplicate/unknown/truncated records."""
    path = Path(path)
    size, result = path.stat().st_size, {}
    with path.open("rb") as stream:
        while stream.tell() < size:
            label = stream.readline(128)
            require(label.endswith(b"\n"), "invalid tensor label")
            name = label[:-1].decode("ascii")
            require(name in expected and name not in result, f"unexpected tensor {name}")
            count_bytes = stream.read(8)
            require(len(count_bytes) == 8, "truncated tensor count")
            count = struct.unpack("<Q", count_bytes)[0]
            require(count == math.prod(SHAPES[name]), f"wrong shape for {name}")
            require(stream.tell() + count * 4 <= size, f"truncated tensor {name}")
            result[name] = np.memmap(path, dtype="<f4", mode="r", offset=stream.tell(), shape=SHAPES[name])
            stream.seek(count * 4, 1)
    require(set(result) == set(expected), "missing tensors")
    for name, tensor in result.items():
        flat = tensor.reshape(-1)
        for start in range(0, flat.size, 262144):
            require(np.isfinite(flat[start:start + 262144]).all(), f"nonfinite {name}")
    return result


def read_net(path):
    path = Path(path)
    require(path.stat().st_size == NET_BYTES, "wrong ZQB9 size")
    with path.open("rb") as stream:
        header = stream.read(112)
    require(struct.unpack_from("<4s8I3i", header) == HEADER, "wrong ZQB9 architecture/scales")
    layout = [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
              6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7]
    expected_map = bytes(layout[rank * 4 + min(file, 7 - file)] for rank in range(8) for file in range(8))
    require(header[48:] == expected_map, "wrong king-bucket map")
    result, offset = {}, 112
    for name, dtype, shape in [
        ("base", "<i2", (HALFKA, FT)), ("bias", "<i2", (FT,)),
        ("l1w", "i1", (BUCKETS * L2, FT)), ("l1b", "<f4", (128,)),
        ("l2w", "<f4", (256, L2)), ("l2b", "<f4", (256,)),
        ("l3w", "<f4", (BUCKETS, L3)), ("l3b", "<f4", (BUCKETS,)),
        ("threat", "i1", (THREAT, FT)), ("psqtw", "<f4", (HALFKA + THREAT,)),
        ("psqtb", "<f4", (1,)),
    ]:
        result[name] = np.memmap(path, dtype=dtype, mode="r", offset=offset, shape=shape)
        offset += math.prod(shape) * np.dtype(dtype).itemsize
    require(offset == NET_BYTES, "internal format size mismatch")
    for name, tensor in result.items():
        require(np.isfinite(tensor).all(), f"nonfinite exported {name}")
    return result


def head_bytes(weights):
    quant = round_away(weights["l1w"].T.astype(np.float64) * 64)
    require(np.isfinite(quant).all() and quant.min() >= -128 and quant.max() <= 127, "L1 i8 overflow")
    quant = quant.astype("i1")
    bound = 254 * np.abs(quant.astype(np.int64)).sum(axis=1)
    require(bound.max() < 2**24, "L1 exact f32 dot bound exceeded")
    pieces = [quant.tobytes()]
    for name in HEAD[1:]:
        tensor = weights[name].T if name.endswith("w") else weights[name]
        pieces.append(np.asarray(tensor, dtype="<f4").tobytes())
    packed = b"".join(pieces)
    require(len(packed) == HEAD_END - HEAD_START, "head packing size mismatch")
    return packed, int(bound.max())


def verify_averaged_export(weights, net, net_path):
    """Bind *all* new master tensors to their export before constructing QAT."""
    packed, bound = head_bytes(weights)
    with Path(net_path).open("rb") as stream:
        stream.seek(HEAD_START)
        require(stream.read(len(packed)) == packed, "averaged head/export mismatch")
    # The accepted full graph clamps its trainable combiner tightly around
    # unity; ZQB export omits it. QAT deliberately starts the deployed sum.
    require(np.all(weights["combw"] >= np.float32(.9999)) and np.all(weights["combw"] <= np.float32(1.0001))
            and np.all(np.abs(weights["combb"]) <= np.float32(.0001)), "full trainer combiner outside frozen narrow clamps")
    clipped = 0
    for start in range(0, HALFKA, 256):
        ids = np.arange(start, min(start + 256, HALFKA))
        merged = weights["l0w"][FAC + ids] + weights["l0w"][ids % FAC]
        quant = round_away(merged.astype(np.float64) * 255)
        require(quant.min() >= -32768 and quant.max() <= 32767, "FT i16 overflow")
        require(np.array_equal(quant.astype("<i2"), net["base"][ids]), "averaged HalfKA/export mismatch")
    for start in range(0, THREAT, 256):
        raw = weights["l0w"][FAC + HALFKA + start:FAC + HALFKA + min(start + 256, THREAT)]
        quant = round_away(raw.astype(np.float64) * 255)
        clipped += int((np.abs(quant) > 127).sum())
        require(np.array_equal(np.clip(quant, -127, 127).astype("i1"), net["threat"][start:start + len(raw)]), "averaged threat/export mismatch")
    bias = round_away(weights["l0b"].astype(np.float64) * 255)
    require(bias.min() >= -32768 and bias.max() <= 32767, "FT bias i16 overflow")
    require(np.array_equal(bias.astype("<i2"), net["bias"]), "averaged bias/export mismatch")
    psqt = weights["psqtw"]
    folded = np.concatenate((psqt[FAC:FAC + HALFKA] + psqt[np.arange(HALFKA) % FAC], psqt[FAC + HALFKA:]))
    require(bits_equal(folded, net["psqtw"]) and bits_equal(weights["psqtb"], net["psqtb"]), "averaged PSQT/export mismatch")
    return {"all_exported_master_tensors_match": True, "threat_weights_clipped": clipped,
            "max_l1_absolute_dot": bound, "full_master_combiner_weights": weights["combw"].tolist(),
            "full_master_combiner_bias": weights["combb"].tolist(),
            "full_master_combiner_max_weight_deviation": float(np.max(np.abs(weights["combw"] - 1))),
            "combiner_export_semantics": "full master narrow-clamp combiner omitted by ZQB export; QAT freezes exact unity plus zero bias"}


def check_target(path):
    target = json.loads(Path(path).read_text())
    for key, value in {"version": "bt4-common-cp-v1", "common_gain": GAIN,
                       "prepared_target_divisor": TARGET_DIVISOR, "game_result_weight": 0.1,
                       "output_cp_multiplier": 400, "runtime_scale_percent": 48}.items():
        require(target.get(key) == value, f"wrong common target {key}")
    require(len(target.get("tables", [])) == 42, "expected 42 source lookup tables")
    require(len({entry["id"] for entry in target["tables"]}) == 42, "duplicate lookup IDs")
    for entry in target["tables"]:
        require(len(entry["sha256"]) == 64 and all(c in "0123456789abcdef" for c in entry["sha256"]), "invalid lookup digest")
    return target


def write_tensor(stream, name, chunks):
    stream.write(name.encode("ascii") + b"\n" + struct.pack("<Q", math.prod(SHAPES[name])))
    written = 0
    for chunk in chunks:
        raw = np.asarray(chunk, dtype="<f4").tobytes()
        stream.write(raw)
        written += len(raw)
    require(written == math.prod(SHAPES[name]) * 4, f"written shape mismatch {name}")


def read_tsv(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        key, value = line.split("\t", 1)
        require(key not in result, f"duplicate state field {key}")
        result[key] = value
    return result


def verify_average_state(args):
    state = read_tsv(args.averaged_state)
    require(state.get("schema") == "zq_bt4_full_v1", "not a new full BT4 checkpoint")
    require(state.get("role") == "averaged-float-model-for-fresh-head-QAT;not-optimizer-resume", "QAT requires the scheduled average")
    require(state.get("readiness") == ("true" if getattr(args, "readiness", False) else "false"),
            "readiness and production model roles cannot mix")
    require(state.get("corpus-sha256") == sha(args.source_index), "QAT mixture differs from full training")
    require(state.get("contract-sha256") == sha(args.target_contract), "QAT targets differ from full training")
    require(state.get("export_scale") == "400", "wrong full-training output scale")
    expected_bits = int(np.float32(TARGET_DIVISOR).view("<u4"))
    require(int(state["data_target_divisor_f32_bits"], 0) == expected_bits, "full-training target divisor differs")
    for key in ("run-identity", "initial_sha256", "raw_tail_checksums_sha256"):
        require(len(state.get(key, "")) == 64 and all(c in "0123456789abcdef" for c in state[key]), f"invalid {key}")
    samples = [int(value) for value in state["average_samples"].split(",")]
    require(samples and samples == sorted(set(samples)) and min(samples) > int(state["main_sb"]), "invalid average endpoints")
    require(max(samples) == int(state["main_sb"]) + int(state["tail_sb"]), "average omits final endpoint")
    directory = args.averaged_state.resolve().parent
    require(args.averaged_weights.resolve() == directory / "weights.bin", "averaged master path differs from state directory")
    require(args.averaged_checksums.resolve() == directory / "CHECKSUMS.tsv", "average checksum path differs")
    covered = set()
    for line in args.averaged_checksums.read_text().splitlines():
        digest, size, name = line.split("\t")
        require(name not in covered and Path(name).name == name, "invalid average checksum filename")
        require((directory / name).stat().st_size == int(size), f"average size mismatch {name}")
        require(sha(directory / name) == digest, f"average checksum mismatch {name}")
        covered.add(name)
    require(covered == {"weights.bin", "state.tsv", "quantised.bin"}, "wrong averaged artifact set")
    require({item.name for item in directory.iterdir()} == covered | {"CHECKSUMS.tsv"}, "unexpected files in averaged directory")
    return state


def verify_validation(args):
    manifest = args.validation_manifest
    fixture = json.loads(manifest.read_text())
    require(fixture.get("schema") == "bt4-holdout-fixture-v1", "wrong holdout fixture schema")
    require(fixture.get("adapter_manifest_sha256") == sha(args.source_index), "holdout belongs to different mixture")
    require(fixture.get("target_contract_sha256") == sha(args.target_contract), "holdout targets differ")
    require(fixture.get("target_divisor") == TARGET_DIVISOR, "wrong holdout divisor")
    require(fixture.get("key_schema") == "bt4-stm-mirror-seven-u64le-sha256-v1" and fixture.get("holdout_bits") == 14,
            "wrong holdout key contract")
    require(fixture.get("record_bytes") == 32 and 0 < fixture.get("count", 0) <= 65536, "invalid holdout dimensions")
    files = {"validation_manifest": manifest}
    for kind in ("records", "metadata"):
        path = manifest.parent / fixture[kind + "_path"]
        require(sha(path) == fixture[kind + "_sha256"], f"holdout {kind} changed")
        files["validation_" + kind] = path
    require(files["validation_records"].stat().st_size == fixture["count"] * 32, "holdout byte count mismatch")
    return fixture, files


def prepare(args):
    check_target(args.target_contract)
    state = verify_average_state(args)
    fixture, validation_files = verify_validation(args)
    require(1 <= args.threads <= 8, "invalid preparation worker count")
    require(sha(args.net) not in OLD_NETS, "new averaged candidate required; old accepted net is comparator only")
    expected = set(SHAPES)
    weights, net = read_named(args.averaged_weights, expected), read_net(args.net)
    verified = verify_averaged_export(weights, net, args.net)
    inputs = {name: {"path": str(Path(path).resolve()), "sha256": sha(path)} for name, path in {
        "averaged_weights": args.averaged_weights, "averaged_state": args.averaged_state,
        "averaged_checksums": args.averaged_checksums, "pre_qat_net": args.net,
        "source_index": args.source_index, "target_contract": args.target_contract, **validation_files,
    }.items()}
    output = args.output_dir
    output.mkdir(exist_ok=False)
    with (output / "weights.bin").open("xb") as stream:
        def deployed_ft():
            yield np.zeros((FAC, FT), dtype="<f4")
            for name in ("base", "threat"):
                for start in range(0, len(net[name]), 256):
                    yield net[name][start:start + 256]
        write_tensor(stream, "l0w", deployed_ft())
        write_tensor(stream, "l0b", [net["bias"]])
        for name in HEAD:
            write_tensor(stream, name, [weights[name]])
        write_tensor(stream, "combw", [np.array([1, 1], dtype="<f4")])
        write_tensor(stream, "combb", [np.array([0], dtype="<f4")])
    psqt = np.concatenate((net["psqtw"], net["psqtb"]))
    scaled = round_away(psqt.astype(np.float64) * 2**20)
    # At most 32 HalfKA and 128 threat features, plus bias, in this graph.
    require(np.isfinite(scaled).all() and 160 * float(np.max(np.abs(scaled[:-1]))) + abs(float(scaled[-1])) < 2**63,
            "PSQT Q20 accumulation overflow")
    with (output / "psqt-q20.bin").open("xb") as stream:
        stream.write(scaled.astype("<i8").tobytes())
    readiness = getattr(args, "readiness", False)
    readiness_shuffle = getattr(args, "readiness_shuffle_records", None)
    require(readiness_shuffle is None or (readiness and readiness_shuffle >= BATCH_SIZE), "shuffle override is readiness-only")
    qat_data_identity = {"seed": state["seed"], "shuffle_records": str(readiness_shuffle or int(state["shuffle_records"]))}
    batches_per_sb = args.readiness_batches_per_sb if readiness else 4096
    superbatches = args.readiness_superbatches if readiness else 16
    require(not readiness or (0 < batches_per_sb * superbatches <= 256 and min(batches_per_sb, superbatches) > 0), "invalid readiness budget")
    receipt = {
        "schema": "zigqueen-bt4-head-qat-input-v1", "inputs": inputs,
        "mode": "readiness" if readiness else "production",
        "recipe": {"batch_size": BATCH_SIZE, "batches": batches_per_sb * superbatches, "presentations": batches_per_sb * superbatches * BATCH_SIZE,
                   "learning_rate": LEARNING_RATE, "target_divisor": TARGET_DIVISOR,
                   "game_result_weight": 0.1, "output_scale": 400, "fresh_optimizer_moments": True},
        "trainable": list(HEAD), "frozen": list(FROZEN), "master_export_check": verified,
        "output_sha256": {name: sha(output / name) for name in ("weights.bin", "psqt-q20.bin")},
        "full_training_identity": {key: state[key] for key in ("run-identity", "seed", "shuffle_records", "average_samples", "raw_tail_checksums_sha256")},
        "qat_data_identity": qat_data_identity,
        "production_ready": False,
        "pending": ["shared source-index admission and identity", "GPU forward/update/resume readiness",
                    "final CPU/GPU/reference and both-ISA runtime parity"],
    }
    (output / "preparation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    config = {
        "schema": "zq_bt4_head_qat_v1", "mode": receipt["mode"],
        "preparation": str((output / "preparation.json").resolve()),
        "preparation_sha256": sha(output / "preparation.json"),
        "weights": str((output / "weights.bin").resolve()), "weights_sha256": sha(output / "weights.bin"),
        "psqt": str((output / "psqt-q20.bin").resolve()), "psqt_sha256": sha(output / "psqt-q20.bin"),
        "source_index": str(args.source_index.resolve()), "source_index_sha256": sha(args.source_index),
        "target_contract": str(args.target_contract.resolve()), "target_contract_sha256": sha(args.target_contract),
        "validation_records": str(validation_files["validation_records"].resolve()),
        "validation_records_sha256": sha(validation_files["validation_records"]),
        "validation_count": fixture["count"],
        "run_identity": state["run-identity"], **qat_data_identity,
        "threads": args.threads, "batch_size": BATCH_SIZE, "batches_per_sb": batches_per_sb, "superbatches": superbatches,
        "target_divisor_f32_bits": int(np.float32(TARGET_DIVISOR).view("<u4")),
        "output_scale": 400,
    }
    (output / "qat-config.tsv").write_text("".join(f"{key}\t{value}\n" for key, value in config.items()))
    return receipt


def check_frozen(weights, net):
    require(bits_equal(weights["l0b"], net["bias"]), "frozen bias changed")
    require(not np.count_nonzero(weights["l0w"][:FAC].view("<u4")), "frozen factorizer changed")
    for name, offset in (("base", FAC), ("threat", FAC + HALFKA)):
        for start in range(0, len(net[name]), 256):
            require(bits_equal(weights["l0w"][offset + start:offset + start + len(net[name][start:start + 256])],
                               net[name][start:start + 256]), "frozen FT changed")
    require(bits_equal(weights["combw"], [1, 1]) and bits_equal(weights["combb"], [0]), "frozen combiner changed")


def export(args, *, readiness=False):
    receipt = json.loads(args.preparation.read_text())
    require(receipt["schema"] == "zigqueen-bt4-head-qat-input-v1", "wrong preparation schema")
    mode = "readiness" if readiness else "production"
    require(receipt.get("mode") == mode, "readiness preparation cannot be a production endpoint")
    for record in receipt["inputs"].values():
        require(sha(record["path"]) == record["sha256"], "prepared source changed")
    root = args.preparation.parent
    config = read_tsv(root / "qat-config.tsv")
    require(config["mode"] == receipt["mode"], "configuration mode differs from preparation")
    for name in ("source_index", "target_contract", "validation_records"):
        require(config[name] == receipt["inputs"][name]["path"] and config[name + "_sha256"] == receipt["inputs"][name]["sha256"],
                f"configuration {name} differs from preparation")
    for name, filename in (("weights", "weights.bin"), ("psqt", "psqt-q20.bin")):
        require(config[name + "_sha256"] == receipt["output_sha256"][filename], f"configuration {name} differs from preparation")
    for name, digest in receipt["output_sha256"].items():
        require(sha(root / name) == digest, "prepared tensor input changed")
    result = dict(line.split("\t", 1) for line in args.training_result.read_text().splitlines())
    require(result.get("status") == "complete" and result.get("mode") == mode, "not a complete production QAT endpoint")
    require(result.get("preparation_sha256") == sha(args.preparation), "QAT result belongs to different preparation")
    require(result.get("config_sha256") == sha(root / "qat-config.tsv"), "QAT run changed its frozen configuration")
    expected_batches = receipt["recipe"]["batches"] if readiness else BATCHES
    require(not readiness or 0 < expected_batches <= 256, "wrong readiness exposure")
    require(int(result["completed_batches"]) == expected_batches and int(result["presentations"]) == expected_batches * BATCH_SIZE, "wrong QAT exposure")
    require(result.get("named_after_sha256") == sha(args.named_after), "endpoint identity mismatch")
    before = read_named(root / "weights.bin", set(FROZEN + HEAD))
    after = read_named(args.named_after, set(FROZEN + HEAD))
    net_path = Path(receipt["inputs"]["pre_qat_net"]["path"])
    net = read_net(net_path)
    check_frozen(after, net)
    changed = [name for name in HEAD if not bits_equal(before[name], after[name])]
    require(len(changed) == 6, "expected all six trainable head tensors to change")
    head, bound = head_bytes(after)
    blob = net_path.read_bytes()
    packed = blob[:HEAD_START] + head + blob[HEAD_END:]
    with args.output.open("xb") as stream:
        stream.write(packed)
    report = {"schema": "zigqueen-bt4-head-qat-export-v1", "preparation_sha256": sha(args.preparation),
              "mode": mode, "production_endpoint": not readiness,
              "training_result_sha256": sha(args.training_result), "named_after_sha256": sha(args.named_after),
              "net_sha256": sha(args.output), "pre_qat_net_sha256": sha(net_path),
              "frozen_regions_byte_exact": True, "trainable_changed": changed,
              "max_l1_absolute_dot": bound, "output_scale": 400,
              "runtime_parity_pending": True, "accepted_baseline_update": False}
    args.output.with_suffix(args.output.suffix + ".json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    for name in ("averaged-weights", "averaged-state", "averaged-checksums", "net", "source-index", "target-contract", "validation-manifest", "output-dir"):
        prep.add_argument("--" + name, type=Path, required=True)
    prep.add_argument("--threads", type=int, required=True)
    prep.add_argument("--readiness-shuffle-records", type=int,
                      help="Exercise the production QAT shuffle window using a smaller full-trainer readiness average")
    prep.add_argument("--readiness", action="store_true")
    prep.add_argument("--readiness-batches-per-sb", type=int, default=2)
    prep.add_argument("--readiness-superbatches", type=int, default=2)
    out = sub.add_parser("export")
    for name in ("preparation", "named-after", "training-result", "output"):
        out.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args) if args.command == "prepare" else export(args), indent=2))


if __name__ == "__main__":
    main()
