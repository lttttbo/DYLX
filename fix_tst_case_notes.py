#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
检查并修正 .tst 文件中指定 TEST.NAME 后缀的测试用例说明：

  1. .FI
     - 用例类别：故障注入测试
     - 用例来源：基于理论和经验的错误预测

  2. .R
     - 用例类别：基于需求的测试
     - 用例来源：
       * “需求分析”保持不变
       * “需求分析、有效等价类”修正为“需求分析、等价类生成与分析”
       * 已修正的“需求分析、等价类生成与分析”保持不变
       * 其他内容统一修正为“需求分析”

  3. .IN.RA.L / .IN.RA.H
     - 用例类别：接口测试
     - 用例来源：边界值分析

  4. .IN.NEC
     - 用例类别：接口测试
     - 用例来源：等价类生成与分析

默认仅检查，不修改文件；增加 --write 才会实际写入。
实际写入时默认为每个被修改文件创建备份。
"""

from __future__ import annotations

import argparse
import codecs
import os
import re
import shutil
import stat
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import DefaultDict, Dict, Iterable, List, Optional, Sequence, Tuple


FIELD_CATEGORY = "用例类别"
FIELD_SOURCE = "用例来源"
TARGET_FIELDS: Sequence[str] = (FIELD_CATEGORY, FIELD_SOURCE)

CASE_FI = "FI"
CASE_R = "R"
CASE_IN_RA = "IN_RA"
CASE_IN_NEC = "IN_NEC"
CASE_KIND_ORDER: Sequence[str] = (CASE_FI, CASE_R, CASE_IN_RA, CASE_IN_NEC)
CASE_KIND_LABELS: Dict[str, str] = {
    CASE_FI: ".FI",
    CASE_R: ".R",
    CASE_IN_RA: ".IN.RA.L/.IN.RA.H",
    CASE_IN_NEC: ".IN.NEC",
}

R_SOURCE_REQUIREMENT = "需求分析"
R_SOURCE_OLD_EQUIVALENCE = "需求分析、有效等价类"
R_SOURCE_NEW_EQUIVALENCE = "需求分析、等价类生成与分析"

FIXED_TARGETS: Dict[str, Dict[str, str]] = {
    CASE_FI: {
        FIELD_CATEGORY: "故障注入测试",
        FIELD_SOURCE: "基于理论和经验的错误预测",
    },
    CASE_R: {
        FIELD_CATEGORY: "基于需求的测试",
    },
    CASE_IN_RA: {
        FIELD_CATEGORY: "接口测试",
        FIELD_SOURCE: "边界值分析",
    },
    CASE_IN_NEC: {
        FIELD_CATEGORY: "接口测试",
        FIELD_SOURCE: "等价类生成与分析",
    },
}


def classify_case_name(case_name: str) -> Optional[str]:
    """根据 TEST.NAME 的末尾后缀识别需要处理的用例类型。"""
    upper_name = case_name.strip().upper()
    if upper_name.endswith(".FI"):
        return CASE_FI
    if upper_name.endswith(".IN.RA.L") or upper_name.endswith(".IN.RA.H"):
        return CASE_IN_RA
    if upper_name.endswith(".IN.NEC"):
        return CASE_IN_NEC
    if upper_name.endswith(".R"):
        return CASE_R
    return None


def target_value_for(case_kind: str, field_name: str, current_value: str) -> str:
    """根据用例类型、字段和当前值计算目标值。"""
    current_value = current_value.strip()

    if case_kind == CASE_R and field_name == FIELD_SOURCE:
        # 保证脚本幂等：已经修正后的来源再次运行时必须保持不变。
        if current_value in (R_SOURCE_REQUIREMENT, R_SOURCE_NEW_EQUIVALENCE):
            return current_value
        if current_value == R_SOURCE_OLD_EQUIVALENCE:
            return R_SOURCE_NEW_EQUIVALENCE
        return R_SOURCE_REQUIREMENT

    try:
        return FIXED_TARGETS[case_kind][field_name]
    except KeyError as exc:
        raise ValueError(
            f"未定义的字段修正规则：case_kind={case_kind!r}, field_name={field_name!r}"
        ) from exc

TEST_NEW_RE = re.compile(r"^[ \t]*TEST\.NEW[ \t]*$")
TEST_END_RE = re.compile(r"^[ \t]*TEST\.END[ \t]*$")
TEST_NAME_RE = re.compile(
    r"^[ \t]*TEST\.NAME[ \t]*(?::|：)?[ \t]*(?P<value>.*?)[ \t]*$"
)
TEST_NOTES_RE = re.compile(r"^[ \t]*TEST\.NOTES[ \t]*(?::|：)?[ \t]*$")
TEST_END_NOTES_RE = re.compile(
    r"^[ \t]*TEST\.END_NOTES[ \t]*(?::|：)?[ \t]*$"
)

# 用于判断“字段名下一行”究竟是字段值，还是下一个说明条目。
KNOWN_NOTE_LABELS = (
    "测试目的",
    "用例类别",
    "预置条件",
    "测试步骤",
    "用例来源",
    "追溯 ID",
    "追溯ID",
    "等价列表",
    "通过准则",
    "备注",
    "测试方法",
    "测试类型",
    "需求编号",
    "输入条件",
    "期望结果",
)
KNOWN_NOTE_FIELD_RE = re.compile(
    r"^[ \t]*(?:"
    + "|".join(re.escape(label) for label in KNOWN_NOTE_LABELS)
    + r")[ \t]*(?::|：)"
)
KNOWN_NOTE_LABEL_ONLY_RE = re.compile(
    r"^[ \t]*(?:"
    + "|".join(re.escape(label) for label in KNOWN_NOTE_LABELS)
    + r")[ \t]*$"
)
GENERIC_NOTE_FIELD_RE = re.compile(
    r"^[ \t]*[\u3400-\u9fffA-Za-z_][^:：\r\n，。；、]{0,30}(?::|：)"
)


@dataclass(frozen=True)
class DecodedFile:
    text: str
    encoding: str
    bom: bytes = b""

    def encode(self, text: str) -> bytes:
        return self.bom + text.encode(self.encoding)


@dataclass(frozen=True)
class FieldLineMatch:
    indent: str
    label: str
    between: str
    colon: str
    after_colon: str
    value: str
    trailing: str


@dataclass
class Finding:
    kind: str
    path: Path
    line: int
    case_name: str = ""
    field_name: str = ""
    old_value: str = ""
    target_value: str = ""
    detail: str = ""


@dataclass
class FileResult:
    path: Path
    case_counts: Dict[str, int] = field(default_factory=dict)
    changed: bool = False
    written: bool = False
    edit_count: int = 0
    findings: List[Finding] = field(default_factory=list)
    output_bytes: Optional[bytes] = None


@dataclass
class Summary:
    files_scanned: int = 0
    case_counts: Dict[str, int] = field(default_factory=dict)
    files_needing_changes: int = 0
    files_written: int = 0
    edits: int = 0
    empty_values: int = 0
    missing_fields: int = 0
    mismatches: int = 0
    structural_anomalies: int = 0
    errors: int = 0


def split_body_eol(line: str) -> Tuple[str, str]:
    """拆分一行的正文和原始换行符。"""
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n") or line.endswith("\r"):
        return line[:-1], line[-1:]
    return line, ""


def decode_bytes(data: bytes) -> DecodedFile:
    """自动识别常见的 tst 文件编码，并保留 BOM。"""
    if data.startswith(codecs.BOM_UTF8):
        return DecodedFile(
            data[len(codecs.BOM_UTF8) :].decode("utf-8"),
            "utf-8",
            codecs.BOM_UTF8,
        )
    if data.startswith(codecs.BOM_UTF16_LE):
        return DecodedFile(
            data[len(codecs.BOM_UTF16_LE) :].decode("utf-16-le"),
            "utf-16-le",
            codecs.BOM_UTF16_LE,
        )
    if data.startswith(codecs.BOM_UTF16_BE):
        return DecodedFile(
            data[len(codecs.BOM_UTF16_BE) :].decode("utf-16-be"),
            "utf-16-be",
            codecs.BOM_UTF16_BE,
        )

    last_error: Optional[UnicodeDecodeError] = None
    for encoding in ("utf-8", "gb18030"):
        try:
            return DecodedFile(data.decode(encoding), encoding)
        except UnicodeDecodeError as exc:
            last_error = exc

    assert last_error is not None
    raise last_error


def parse_field_line(line: str, field_name: str) -> Optional[FieldLineMatch]:
    """
    识别以下形式（兼容半角/全角冒号，以及缺少冒号的轻微格式异常）：
      用例类别：故障注入测试
      用例类别: 故障注入测试
      用例类别：
      用例类别
      用例类别  故障注入测试
    """
    body, _ = split_body_eol(line)
    match = re.match(
        rf"^(?P<indent>[ \t]*)(?P<label>{re.escape(field_name)})(?P<tail>.*)$",
        body,
    )
    if not match:
        return None

    tail = match.group("tail")
    # 防止把“用例类别说明：...”误认为目标字段。
    if tail and tail[0] not in " \t:：":
        return None

    tail_match = re.match(
        r"^(?P<between>[ \t]*)(?P<colon>[:：]?)(?P<after>[ \t]*)"
        r"(?P<value>.*?)(?P<trailing>[ \t]*)$",
        tail,
    )
    if not tail_match:
        return None

    return FieldLineMatch(
        indent=match.group("indent"),
        label=match.group("label"),
        between=tail_match.group("between"),
        colon=tail_match.group("colon"),
        after_colon=tail_match.group("after"),
        value=tail_match.group("value"),
        trailing=tail_match.group("trailing"),
    )


def is_note_boundary(line: str) -> bool:
    body, _ = split_body_eol(line)
    stripped = body.strip()
    if not stripped:
        return False
    if stripped.startswith("TEST.") or stripped.startswith("--"):
        return True
    return bool(
        KNOWN_NOTE_FIELD_RE.match(body)
        or KNOWN_NOTE_LABEL_ONLY_RE.match(body)
        or GENERIC_NOTE_FIELD_RE.match(body)
    )


def choose_eol(lines: Sequence[str], near_index: int) -> str:
    """为新增行选择与原文件一致的换行符。"""
    if 0 <= near_index < len(lines):
        _, eol = split_body_eol(lines[near_index])
        if eol:
            return eol
    for index in range(min(near_index - 1, len(lines) - 1), -1, -1):
        _, eol = split_body_eol(lines[index])
        if eol:
            return eol
    return os.linesep


def find_case_blocks(lines: Sequence[str]) -> Tuple[List[Tuple[int, int]], List[int]]:
    """返回 TEST.NEW 到精确 TEST.END 之间的测试用例块。"""
    blocks: List[Tuple[int, int]] = []
    unclosed_starts: List[int] = []
    start: Optional[int] = None

    for index, line in enumerate(lines):
        body, _ = split_body_eol(line)
        if TEST_NEW_RE.match(body):
            if start is not None:
                unclosed_starts.append(start)
            start = index
            continue
        if start is not None and TEST_END_RE.match(body):
            blocks.append((start, index))
            start = None

    if start is not None:
        unclosed_starts.append(start)
    return blocks, unclosed_starts


def extract_case_name(
    lines: Sequence[str], start: int, end: int
) -> Tuple[Optional[str], Optional[int]]:
    for index in range(start, end + 1):
        body, _ = split_body_eol(lines[index])
        match = TEST_NAME_RE.match(body)
        if not match:
            continue

        inline_value = match.group("value").strip()
        if inline_value:
            return inline_value.strip('"\''), index

        # 兼容：TEST.NAME: 后，名称另起一行。
        for next_index in range(index + 1, end + 1):
            next_body, _ = split_body_eol(lines[next_index])
            next_value = next_body.strip()
            if not next_value:
                continue
            if next_value.startswith("TEST.") or next_value.startswith("--"):
                return None, index
            return next_value.strip('"\''), next_index
        return None, index

    return None, None


def find_notes_range(
    lines: Sequence[str], start: int, end: int
) -> Tuple[Optional[int], Optional[int]]:
    notes_start: Optional[int] = None
    for index in range(start, end + 1):
        body, _ = split_body_eol(lines[index])
        if notes_start is None:
            if TEST_NOTES_RE.match(body):
                notes_start = index
            continue
        if TEST_END_NOTES_RE.match(body):
            return notes_start, index
    return notes_start, None


def build_inline_replacement(
    original_line: str, match: FieldLineMatch, target_value: str
) -> str:
    _, eol = split_body_eol(original_line)
    if match.colon:
        prefix = (
            match.indent
            + match.label
            + match.between
            + match.colon
            + match.after_colon
        )
    else:
        # 原字段缺少冒号时，顺便规范为全角冒号。
        prefix = match.indent + match.label + "："
    return prefix + target_value + match.trailing + eol


def build_separate_value_replacement(original_line: str, target_value: str) -> str:
    body, eol = split_body_eol(original_line)
    leading = re.match(r"^[ \t]*", body).group(0)  # type: ignore[union-attr]
    trailing = re.search(r"[ \t]*$", body).group(0)  # type: ignore[union-attr]
    return leading + target_value + trailing + eol


def find_next_separate_value_line(
    lines: Sequence[str], field_line_index: int, notes_end: int
) -> Optional[int]:
    for index in range(field_line_index + 1, notes_end):
        body, _ = split_body_eol(lines[index])
        if not body.strip():
            continue
        if is_note_boundary(lines[index]):
            return None
        return index
    return None


def analyze_file(path: Path) -> FileResult:
    result = FileResult(path=path)

    try:
        raw = path.read_bytes()
        decoded = decode_bytes(raw)
    except (OSError, UnicodeError) as exc:
        result.findings.append(
            Finding(
                kind="ERROR",
                path=path,
                line=1,
                detail=f"读取或解码失败：{exc}",
            )
        )
        return result

    lines = decoded.text.splitlines(keepends=True)
    # 空文件 splitlines() 返回空列表；保持后续逻辑安全。
    if not lines and decoded.text:
        lines = [decoded.text]

    replacements: Dict[int, str] = {}
    insertions: DefaultDict[int, List[str]] = defaultdict(list)

    case_blocks, unclosed_starts = find_case_blocks(lines)
    for start_index in unclosed_starts:
        result.findings.append(
            Finding(
                kind="STRUCTURE",
                path=path,
                line=start_index + 1,
                detail="发现 TEST.NEW，但未找到对应的精确 TEST.END；该块未自动修改。",
            )
        )

    for case_start, case_end in case_blocks:
        case_name, name_line = extract_case_name(lines, case_start, case_end)
        if not case_name:
            result.findings.append(
                Finding(
                    kind="STRUCTURE",
                    path=path,
                    line=(name_line if name_line is not None else case_start) + 1,
                    detail=(
                        "测试用例块中 TEST.NAME 缺失或为空；无法判断是否属于 "
                        ".FI、.R、.IN.RA.L/.IN.RA.H 或 .IN.NEC 用例。"
                    ),
                )
            )
            continue

        case_kind = classify_case_name(case_name)
        if case_kind is None:
            continue

        result.case_counts[case_kind] = result.case_counts.get(case_kind, 0) + 1
        case_kind_label = CASE_KIND_LABELS[case_kind]

        notes_start, notes_end = find_notes_range(lines, case_start, case_end)
        if notes_start is None or notes_end is None:
            result.findings.append(
                Finding(
                    kind="STRUCTURE",
                    path=path,
                    line=(name_line if name_line is not None else case_start) + 1,
                    case_name=case_name,
                    detail=(
                        f"{case_kind_label} 用例缺少完整的 "
                        "TEST.NOTES / TEST.END_NOTES 区域；未自动修改。"
                    ),
                )
            )
            continue

        for field_name in TARGET_FIELDS:
            occurrences: List[Tuple[int, FieldLineMatch]] = []
            for index in range(notes_start + 1, notes_end):
                match = parse_field_line(lines[index], field_name)
                if match is not None:
                    occurrences.append((index, match))

            if not occurrences:
                target_value = target_value_for(case_kind, field_name, "")
                eol = choose_eol(lines, notes_end)
                insertions[notes_end].append(f"{field_name}：{target_value}{eol}")
                result.findings.append(
                    Finding(
                        kind="MISSING",
                        path=path,
                        line=notes_end + 1,
                        case_name=case_name,
                        field_name=field_name,
                        target_value=target_value,
                        detail="字段不存在；补充位置为 TEST.END_NOTES 前。",
                    )
                )
                continue

            if len(occurrences) > 1:
                for duplicate_index, _ in occurrences[1:]:
                    result.findings.append(
                        Finding(
                            kind="DUPLICATE",
                            path=path,
                            line=duplicate_index + 1,
                            case_name=case_name,
                            field_name=field_name,
                            detail=(
                                "同一 TEST.NOTES 区域存在重复字段；"
                                "各处将按照当前用例类型的规则逐项检查。"
                            ),
                        )
                    )

            for field_index, match in occurrences:
                inline_value = match.value.strip()
                if inline_value:
                    target_value = target_value_for(
                        case_kind, field_name, inline_value
                    )
                    if inline_value != target_value:
                        replacements[field_index] = build_inline_replacement(
                            lines[field_index], match, target_value
                        )
                        result.findings.append(
                            Finding(
                                kind="MISMATCH",
                                path=path,
                                line=field_index + 1,
                                case_name=case_name,
                                field_name=field_name,
                                old_value=inline_value,
                                target_value=target_value,
                            )
                        )
                    continue

                value_line_index = find_next_separate_value_line(
                    lines, field_index, notes_end
                )
                if value_line_index is not None:
                    value_body, _ = split_body_eol(lines[value_line_index])
                    separate_value = value_body.strip()
                    target_value = target_value_for(
                        case_kind, field_name, separate_value
                    )
                    if separate_value != target_value:
                        replacements[value_line_index] = (
                            build_separate_value_replacement(
                                lines[value_line_index], target_value
                            )
                        )
                        result.findings.append(
                            Finding(
                                kind="MISMATCH",
                                path=path,
                                line=value_line_index + 1,
                                case_name=case_name,
                                field_name=field_name,
                                old_value=separate_value,
                                target_value=target_value,
                                detail=(
                                    f"字段名位于第 {field_index + 1} 行，值另起一行。"
                                ),
                            )
                        )
                    continue

                # 字段存在但没有可识别的值：记录精确字段行，并直接补为同一行值。
                target_value = target_value_for(case_kind, field_name, "")
                replacements[field_index] = build_inline_replacement(
                    lines[field_index], match, target_value
                )
                result.findings.append(
                    Finding(
                        kind="EMPTY",
                        path=path,
                        line=field_index + 1,
                        case_name=case_name,
                        field_name=field_name,
                        target_value=target_value,
                        detail="字段值为空。",
                    )
                )

    if replacements or insertions:
        output_lines: List[str] = []
        for index, original_line in enumerate(lines):
            if index in insertions:
                output_lines.extend(insertions[index])
            output_lines.append(replacements.get(index, original_line))

        output_text = "".join(output_lines)
        result.output_bytes = decoded.encode(output_text)
        result.changed = result.output_bytes != raw
        result.edit_count = len(replacements) + sum(
            len(items) for items in insertions.values()
        )

    return result

def iter_tst_files(root: Path, recursive: bool) -> Iterable[Path]:
    if root.is_file():
        if root.suffix.lower() == ".tst":
            yield root
        return

    iterator = root.rglob("*") if recursive else root.iterdir()
    for path in iterator:
        if path.is_file() and path.suffix.lower() == ".tst":
            yield path


def unique_backup_path(path: Path, suffix: str) -> Path:
    candidate = path.with_name(path.name + suffix)
    if not candidate.exists():
        return candidate
    counter = 1
    while True:
        candidate = path.with_name(path.name + suffix + f".{counter}")
        if not candidate.exists():
            return candidate
        counter += 1


def atomic_write(path: Path, data: bytes) -> None:
    """在同一目录创建临时文件后原子替换，并尽量保留权限。"""
    original_mode = stat.S_IMODE(path.stat().st_mode)
    temp_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=str(path.parent), prefix=path.name + ".", suffix=".tmp", delete=False
        ) as temp_file:
            temp_name = temp_file.name
            temp_file.write(data)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.chmod(temp_name, original_mode)
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def format_finding(
    finding: Finding, write_mode: bool, write_succeeded: bool = False
) -> str:
    location = f"{finding.path}:{finding.line}"
    case_part = f" | TEST.NAME={finding.case_name}" if finding.case_name else ""
    field_part = f" | 字段={finding.field_name}" if finding.field_name else ""
    if not write_mode:
        action = "将修正"
    elif write_succeeded:
        action = "已修正"
    else:
        action = "未写入"

    if finding.kind == "MISMATCH":
        detail_part = f" | {finding.detail}" if finding.detail else ""
        return (
            f"[值不符合] {location}{case_part}{field_part}"
            f" | 原值={finding.old_value!r} | 目标值={finding.target_value!r}"
            f" | {action}{detail_part}"
        )
    if finding.kind == "EMPTY":
        return (
            f"[空值异常] {location}{case_part}{field_part}"
            f" | 目标值={finding.target_value!r} | {action} | {finding.detail}"
        )
    if finding.kind == "MISSING":
        return (
            f"[字段缺失] {location}{case_part}{field_part}"
            f" | 目标值={finding.target_value!r} | {action} | {finding.detail}"
        )
    if finding.kind == "DUPLICATE":
        return f"[重复字段] {location}{case_part}{field_part} | {finding.detail}"
    if finding.kind == "STRUCTURE":
        return f"[结构异常] {location}{case_part} | {finding.detail}"
    if finding.kind == "ERROR":
        return f"[处理失败] {location} | {finding.detail}"
    return f"[{finding.kind}] {location}{case_part}{field_part} | {finding.detail}"


def update_summary(summary: Summary, result: FileResult) -> None:
    summary.files_scanned += 1
    for case_kind, count in result.case_counts.items():
        summary.case_counts[case_kind] = summary.case_counts.get(case_kind, 0) + count
    summary.edits += result.edit_count
    if result.changed:
        summary.files_needing_changes += 1

    for finding in result.findings:
        if finding.kind == "EMPTY":
            summary.empty_values += 1
        elif finding.kind == "MISSING":
            summary.missing_fields += 1
        elif finding.kind == "MISMATCH":
            summary.mismatches += 1
        elif finding.kind in ("STRUCTURE", "DUPLICATE"):
            summary.structural_anomalies += 1
        elif finding.kind == "ERROR":
            summary.errors += 1


def build_report(
    root: Path,
    write_mode: bool,
    results: Sequence[FileResult],
    summary: Summary,
) -> str:
    mode_text = "实际修改" if write_mode else "仅检查（未写入）"
    report_lines = [
        "TST 用例类别与用例来源检查报告",
        f"生成时间：{datetime.now().astimezone().isoformat(timespec='seconds')}",
        f"检查路径：{root}",
        f"运行模式：{mode_text}",
        "",
    ]

    finding_count = 0
    for result in results:
        for finding in result.findings:
            report_lines.append(
                format_finding(finding, write_mode, result.written)
            )
            finding_count += 1

    if finding_count == 0:
        report_lines.append("未发现需要修正或提示的问题。")

    report_lines.extend(["", "汇总：", f"  扫描 .tst 文件：{summary.files_scanned}"])
    for case_kind in CASE_KIND_ORDER:
        report_lines.append(
            f"  扫描 {CASE_KIND_LABELS[case_kind]} 用例："
            f"{summary.case_counts.get(case_kind, 0)}"
        )
    report_lines.extend(
        [
            f"  需要修改的文件：{summary.files_needing_changes}",
            f"  实际写入的文件：{summary.files_written}",
            f"  规划/完成的编辑：{summary.edits}",
            f"  值不符合：{summary.mismatches}",
            f"  空值异常：{summary.empty_values}",
            f"  字段缺失：{summary.missing_fields}",
            f"  结构或重复字段异常：{summary.structural_anomalies}",
            f"  处理失败：{summary.errors}",
        ]
    )
    return "\n".join(report_lines) + "\n"

def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "递归检查 .tst 文件中 TEST.NAME 以 .FI、.R、.IN.RA.L、"
            ".IN.RA.H 或 .IN.NEC 结尾的用例，并按规则修正用例类别和"
            "用例来源。默认仅检查。"
        )
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="待检查的目录或单个 .tst 文件，默认当前目录",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="实际修改文件；不指定时仅输出检查结果",
    )
    parser.add_argument(
        "--no-recursive",
        action="store_true",
        help="只检查指定目录的第一层，不递归子目录",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="实际写入时不创建备份（默认创建 .bak、.bak.1 等）",
    )
    parser.add_argument(
        "--backup-suffix",
        default=".bak",
        help="备份文件后缀，默认 .bak",
    )
    parser.add_argument(
        "--report",
        help="报告文件路径；默认写入检查目录下的 tst_case_notes_check_report.txt",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    root = Path(args.path).expanduser().resolve()

    if not root.exists():
        print(f"错误：路径不存在：{root}", file=sys.stderr)
        return 2
    if root.is_file() and root.suffix.lower() != ".tst":
        print(f"错误：指定文件不是 .tst 文件：{root}", file=sys.stderr)
        return 2

    files = sorted(
        iter_tst_files(root, recursive=not args.no_recursive),
        key=lambda path: str(path).lower(),
    )

    results: List[FileResult] = []
    summary = Summary()

    for path in files:
        result = analyze_file(path)
        update_summary(summary, result)

        if args.write and result.changed and result.output_bytes is not None:
            try:
                if not args.no_backup:
                    backup_path = unique_backup_path(path, args.backup_suffix)
                    shutil.copy2(path, backup_path)
                atomic_write(path, result.output_bytes)
                result.written = True
                summary.files_written += 1
            except OSError as exc:
                result.findings.append(
                    Finding(
                        kind="ERROR",
                        path=path,
                        line=1,
                        detail=f"写入失败：{exc}",
                    )
                )
                summary.errors += 1

        results.append(result)

    if args.report:
        report_path = Path(args.report).expanduser().resolve()
    else:
        report_base = root if root.is_dir() else root.parent
        report_path = report_base / "tst_case_notes_check_report.txt"

    report_text = build_report(root, args.write, results, summary)

    # 控制台逐项提示，包含文件和原始行号。
    printed = False
    for result in results:
        for finding in result.findings:
            print(format_finding(finding, args.write, result.written))
            printed = True
    if not printed:
        print("未发现需要修正或提示的问题。")

    try:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        with report_path.open("w", encoding="utf-8", newline="\n") as report_file:
            report_file.write(report_text)
    except OSError as exc:
        print(f"警告：报告文件写入失败：{report_path}：{exc}", file=sys.stderr)
        summary.errors += 1

    print()
    print(f"扫描文件：{summary.files_scanned}")
    for case_kind in CASE_KIND_ORDER:
        print(
            f"{CASE_KIND_LABELS[case_kind]} 用例："
            f"{summary.case_counts.get(case_kind, 0)}"
        )
    print(f"需要修改的文件：{summary.files_needing_changes}")
    print(f"实际写入的文件：{summary.files_written}")
    print(f"编辑数量：{summary.edits}")
    print(
        "空值/缺失/结构异常："
        f"{summary.empty_values}/{summary.missing_fields}/"
        f"{summary.structural_anomalies}"
    )
    print(f"报告文件：{report_path}")

    return 1 if summary.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
