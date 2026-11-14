"""Offline, standard-library analysis of the read-only RoArm USB timing test.

This program never opens a serial port and cannot command the robot.
Usage: python roarm_usb_timing_analyze.py RESULT_DIRECTORY [--overwrite]
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def quantile(values, probability):
    if not values:
        return None
    ordered = sorted(values)
    location = (len(ordered) - 1) * probability
    lower = int(location)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (location - lower)


def describe(values):
    return {
        "n": len(values),
        "p50_ms": quantile(values, 0.50),
        "p95_ms": quantile(values, 0.95),
        "p99_ms": quantile(values, 0.99),
        "max_ms": max(values) if values else None,
        "mean_ms": sum(values) / len(values) if values else None,
        "over_50ms": sum(value > 50.0 for value in values),
        "over_80ms": sum(value > 80.0 for value in values),
        "over_100ms": sum(value > 100.0 for value in values),
    }


def difference_ms(rows, later, earlier):
    values = []
    for row in rows:
        end, start = number(row.get(later)), number(row.get(earlier))
        if end is not None and start is not None:
            if end < start:
                raise ValueError(f"Negative {later}-{earlier} in {row['stage']} request {row['request_index']}")
            values.append(1000.0 * (end - start))
    return values


def intervals_ms(rows, field):
    stamps = [number(row.get(field)) for row in rows]
    stamps = [stamp for stamp in stamps if stamp is not None]
    if any(b <= a for a, b in zip(stamps, stamps[1:])):
        raise ValueError(f"Non-increasing {field}; inspect the acquisition file")
    return [1000.0 * (b - a) for a, b in zip(stamps, stamps[1:])]


def rate(intervals):
    return 1000.0 * len(intervals) / sum(intervals) if intervals else None


def stage_stats(stage, rows):
    successful = [row for row in rows if row["status"] == "ok"]
    send_intervals = intervals_ms(rows, "tx_start_s")
    reply_intervals = intervals_ms(successful, "rx_frame_s")
    counts = dict(Counter(row["status"] for row in rows))
    planned = int(stage["count"])
    if len(rows) > planned:
        raise ValueError(f"More samples than planned in {stage['name']}")
    values = {
        "request_interval": send_intervals,
        "reply_interval": reply_intervals,
        "host_rtt": difference_ms(successful, "rx_frame_s", "tx_start_s"),
        "parse_delay": difference_ms(successful, "parse_end_s", "rx_frame_s"),
        "write_overhead": difference_ms(rows, "write_end_s", "tx_start_s"),
        "dispatch_lateness": difference_ms(rows, "tx_start_s", "due_s"),
    }
    result = {
        "stage": stage["name"], "target_hz": float(stage["hz"]),
        "planned": planned, "attempted": len(rows), "success": len(successful),
        "unattempted": planned - len(rows), "non_ok": len(rows) - len(successful),
        "timeouts": counts.get("timeout", 0),
        "late_over_timeout": counts.get("late_over_timeout", 0),
        "status_counts": counts,
        "complete": len(rows) == planned and len(successful) == planned,
        "request_hz": rate(send_intervals), "reply_hz": rate(reply_intervals),
        "success_fraction_of_attempted": len(successful) / len(rows) if rows else None,
        "attempted_fraction_of_plan": len(rows) / planned if planned else None,
        "timing": {name: describe(samples) for name, samples in values.items()},
    }
    return result, values


def show(value, digits=3):
    return "未测" if value is None else f"{value:.{digits}f}"


def build_report(summary):
    configuration = summary["acquisition_configuration"]
    host_stack = configuration.get("host_stack") or "未记录的软件栈"
    lines = [
        "RoArm-M2-S USB 只读通信计时报告",
        f"分析生成时间（UTC）：{summary['analyzed_utc']}",
        f"采集状态：{summary['acquisition_state']}；采集错误：{summary['acquisition_error'] or '无记录'}",
        f"数据一致性与追溯警告：{'；'.join(summary['analysis_warnings']) if summary['analysis_warnings'] else '无'}",
        f"本次仅发送 T105 并读取 T1051，采集软件栈为 {host_stack}。未发送运动、上力或卸力命令。",
        f"主机循环范围：{configuration.get('host_loop') or 'T105 只读请求/回复循环；未测试运动控制执行'}",
        f"调度策略：{configuration.get('scheduling') or '未记录'}",
        "观察量是主机时间：RTT = 完整回复被主机观察到的时刻 - 主机开始写请求的时刻。",
        "采集、传输、主机调度和轮询的开销都可能包含在 RTT 内；其一半不能当作单程延迟。",
        "",
        "分阶段结果（请求与回复频率均按阶段内 (n-1)/(末时刻-首时刻) 计算）：",
    ]
    for stage in summary["stages"]:
        rtt = stage["timing"]["host_rtt"]
        interval = stage["timing"]["request_interval"]
        lines.extend([
            f"{stage['stage']}: 目标 {stage['target_hz']:g} Hz，计划 {stage['planned']}，实际尝试 {stage['attempted']}，成功 {stage['success']}，未尝试 {stage['unattempted']}，非成功 {stage['non_ok']}。",
            f"  请求频率 {show(stage['request_hz'])} Hz，成功回复频率 {show(stage['reply_hz'])} Hz。",
            f"  成功请求 RTT (n={rtt['n']})：P50/P95/P99/最大 = {show(rtt['p50_ms'])}/{show(rtt['p95_ms'])}/{show(rtt['p99_ms'])}/{show(rtt['max_ms'])} ms。",
            f"  RTT >50/>80/>100 ms：{rtt['over_50ms']}/{rtt['over_80ms']}/{rtt['over_100ms']}；分母为上述成功 RTT 数，超时另列。",
            f"  实际请求间隔 (n={interval['n']})：P50/P95/P99/最大 = {show(interval['p50_ms'])}/{show(interval['p95_ms'])}/{show(interval['p99_ms'])}/{show(interval['max_ms'])} ms。",
            f"  超时 {stage['timeouts']}，超时上限之后到达 {stage['late_over_timeout']}；状态计数 {json.dumps(stage['status_counts'], ensure_ascii=False)}。",
        ])
    pooled = summary["main_20hz_pooled"]
    rtt = pooled["timing"]["host_rtt"]
    lines.extend([
        "",
        f"20 Hz 主测合并：计划 {pooled['planned']}，尝试 {pooled['attempted']}，成功 {pooled['success']}。",
        f"阶段内间隔加权有效请求频率 {show(pooled['request_hz'])} Hz，回复频率 {show(pooled['reply_hz'])} Hz；排除阶段之间的间隔。",
        f"成功 RTT 的 P50/P95/P99/最大 = {show(rtt['p50_ms'])}/{show(rtt['p95_ms'])}/{show(rtt['p99_ms'])}/{show(rtt['max_ms'])} ms；n={rtt['n']}。",
        "",
        "结论与边界：",
        summary["interpretation"],
        "论文的 50 ms 是仿真中主机命令/编码器更新方案；本次只对静态只读通信层提供实测依据。",
        "没有测试 T102 命令发送、机械运动跟踪、保持力矩、完整 MATLAB 控制回路、神经网络推理并行负载或 100 Hz 母线功率采集。",
        "论文 10–15 ms 是两个独立方向的仿真通信抖动设定；本次 RTT 不能验证该单程延迟设定，也不能证明两方向独立。",
        "原厂回复没有请求序号、设备采样时间或可验证的新鲜性标志。单个未完成请求和停止晚到回复可减少混配，但不能证明每条编码器数据都是新采集。",
        "超时与其他失败只按观测状态报告，不能换算成物理链路丢包率；未尝试阶段也不能计为零失败或已通过。",
        "每阶段均从上一次实际请求起点至少等待一个目标周期，未做补发追赶。主机开销会使实际频率低于目标频率；50 ms 以上的发送间隔本身不等同于通信失败。",
        "所有分位数用线性插值（位置 (n-1)p），不将这些样本解释为相互独立的机械臂性能重复。",
        "数据身份、完整统计与字段定义见 summary.json；分阶段平表见 stage_summary.csv。",
    ])
    return "\n".join(lines) + "\n"


def analyze(directory):
    def read_json(name):
        return json.loads((directory / name).read_text(encoding="utf-8-sig"))
    metadata, status = read_json("metadata.json"), read_json("status.json")
    if status.get("state") not in {"complete", "failed", "stopped", "aborted"}:
        raise ValueError("Acquisition is not terminal; do not analyze or plot while timing is running")
    sample_path = directory / "samples.csv"
    if sample_path.exists():
        with sample_path.open(encoding="utf-8-sig", newline="") as handle:
            rows = list(csv.DictReader(handle))
    elif status.get("state") == "complete":
        raise ValueError("Acquisition says complete but samples.csv is missing")
    else:
        rows = []  # A failure before the first attempt is not a completed test.
    required = {"stage", "request_index", "target_hz", "tx_start_s", "rx_frame_s", "status"}
    if rows and not required.issubset(rows[0]):
        raise ValueError(f"Missing CSV columns: {sorted(required - set(rows[0]))}")
    known_stages = {stage["name"] for stage in metadata["stages"]}
    if any(row["stage"] not in known_stages for row in rows):
        raise ValueError("Unexpected stage name in samples.csv")
    stage_summaries, value_sets = [], []
    for planned in metadata["stages"]:
        subset = [row for row in rows if row["stage"] == planned["name"]]
        indices = [int(row["request_index"]) for row in subset]
        if indices != list(range(1, len(indices) + 1)):
            raise ValueError(f"Duplicate/missing/out-of-order request index in {planned['name']}")
        for row in subset:
            if number(row["target_hz"]) != float(planned["hz"]):
                raise ValueError(f"Target-frequency disagreement in {planned['name']}")
            if row["status"] == "ok" and any(number(row.get(key)) is None for key in ("tx_start_s", "write_end_s", "rx_frame_s", "parse_end_s")):
                raise ValueError("An ok sample lacks required timing values")
        stage, values = stage_stats(planned, subset)
        stage_summaries.append(stage)
        value_sets.append(values)
    main_pairs = [(stage, values) for stage, values in zip(stage_summaries, value_sets) if stage["stage"].startswith("main_20hz_")]
    pooled_values = {key: [value for _, sample_set in main_pairs for value in sample_set[key]] for key in value_sets[0]}
    pooled = {key: sum(stage[key] for stage, _ in main_pairs) for key in ("planned", "attempted", "success", "unattempted", "non_ok", "timeouts", "late_over_timeout")}
    pooled.update({"timing": {key: describe(values) for key, values in pooled_values.items()}, "request_hz": rate(pooled_values["request_interval"]), "reply_hz": rate(pooled_values["reply_interval"])})
    if not main_pairs or pooled["attempted"] < pooled["planned"]:
        interpretation = "20 Hz 主测未全部完成；只能报告已经观测的只读链路结果，不能判定论文 50 ms 完整控制回路满足要求。"
    elif pooled["non_ok"]:
        interpretation = "20 Hz 主测出现非成功请求；应结合失败记录评价通信裕量，不能判定完整控制回路满足要求。"
    elif pooled["timing"]["host_rtt"]["over_50ms"]:
        interpretation = "20 Hz 主测回复完成，但存在成功 RTT 超过 50 ms 的请求；本次不能支持每个 50 ms 周期都收到反馈的保证。"
    else:
        interpretation = "名义 20 Hz 主测全部回复，已观测的成功 RTT 均未超过 50 ms；这只说明本次静态只读往返延迟在 50 ms 内，不能据此把目标调度频率当作已实现的控制频率。"
    interpretation += f" 合并实际请求频率为 {show(pooled['request_hz'])} Hz（目标 20 Hz），实际请求间隔均值为 {show(pooled['timing']['request_interval']['mean_ms'])} ms；主机调度开销与设备处理不能从本测试中单独辨识。"
    identities = {}
    for name in ("metadata.json", "status.json", "samples.csv", "executed_script.ps1", "executed_script.m", "serial.jsonl", "session.mat", "acquisition_summary.json"):
        path = directory / name
        if path.exists():
            identities[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}
    warnings = []
    if status.get("samples") is not None and int(status["samples"]) != len(rows):
        warnings.append("status.json samples count does not match CSV; investigate")
    if status.get("state") == "complete" and not all(stage["complete"] for stage in stage_summaries):
        warnings.append("Acquisition says complete, but planned stage counts/success do not agree")
    claimed_hash = metadata.get("script_sha256")
    snapshot_hashes = [identities[name]["sha256"] for name in ("executed_script.ps1", "executed_script.m") if name in identities]
    if claimed_hash and snapshot_hashes and str(claimed_hash).lower() not in snapshot_hashes:
        warnings.append("metadata.script_sha256 does not match an executed-script snapshot")
    return {
        "schema": "roarm_readonly_usb_timing_analysis_v1",
        "analyzed_utc": datetime.now(timezone.utc).isoformat(),
        "analysis_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "input_directory": str(directory), "source_identity": identities,
        "acquisition_state": status.get("state"), "acquisition_error": status.get("error"),
        "acquisition_configuration": {key: metadata.get(key) for key in ("schema", "host_stack", "host_loop", "scheduling", "poll_sleep_ms", "request_timeout_s", "feedback_age_contract_s", "powershell_version", "matlab_version", "os", "baud", "timing_scope", "script_sha256")},
        "motion_commands_sent": metadata.get("motion_commands_sent"),
        "analysis_warnings": warnings, "stages": stage_summaries,
        "main_20hz_pooled": pooled, "interpretation": interpretation,
        "definitions": {
            "host_rtt": "rx_frame_s - tx_start_s; successful replies only",
            "request_interval": "successive attempted tx_start_s differences within each stage",
            "reply_interval": "successive successful rx_frame_s differences within each stage",
            "parse_delay": "parse_end_s - rx_frame_s; successful replies only",
            "write_overhead": "write_end_s - tx_start_s wherever both are available",
            "dispatch_lateness": "tx_start_s - due_s wherever both are available",
            "rate": "(n-1)/(last-first) per stage, or number of within-stage intervals divided by their combined duration when pooled",
            "threshold_counts": "strictly greater than threshold; denominator is timing.n; timeout/non-ok counts reported separately",
            "quantile": "linear interpolation at zero-based position (n-1)*p",
        },
        "limits": [
            f"Read-only static host-observed link timing with {metadata.get('host_stack') or 'an unrecorded host stack'}, not the full motion controller.",
            "No motion/command execution, servo-loop timing, power sampling or 100-Hz acquisition tested.",
            "Firmware has no request ID, device timestamp, or independently verified fresh sample flag.",
            "RTT cannot establish one-way delay or independence of the simulation's two 10-15 ms delay directions.",
            "Timeout observations do not measure physical packet-loss probability.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    directory = args.directory.resolve(strict=True)
    outputs = [directory / name for name in ("summary.json", "stage_summary.csv", "report.txt")]
    if not args.overwrite and any(path.exists() for path in outputs):
        parser.error("Analysis outputs already exist; inspect them or explicitly use --overwrite (raw inputs are never changed)")
    summary = analyze(directory)
    flat = []
    for stage in summary["stages"]:
        row = {key: value for key, value in stage.items() if key not in {"timing", "status_counts"}}
        for metric, stats in stage["timing"].items():
            row.update({f"{metric}_{key}": value for key, value in stats.items()})
        row["status_counts_json"] = json.dumps(stage["status_counts"], ensure_ascii=False)
        flat.append(row)
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=list(flat[0]))
    writer.writeheader()
    writer.writerows(flat)
    outputs[0].write_text(json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    outputs[1].write_text(buffer.getvalue(), encoding="utf-8-sig", newline="")
    outputs[2].write_text(build_report(summary), encoding="utf-8")
    print(json.dumps({"output_directory": str(directory), "acquisition_state": summary["acquisition_state"], "main_planned": summary["main_20hz_pooled"]["planned"], "main_attempted": summary["main_20hz_pooled"]["attempted"], "main_success": summary["main_20hz_pooled"]["success"], "interpretation": summary["interpretation"], "analysis_warnings": summary["analysis_warnings"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
