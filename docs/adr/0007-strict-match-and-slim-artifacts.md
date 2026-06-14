# ADR-0007: 严格双字段匹配与精简 reconcile 产物

## Status

Accepted

## Context

原先 `reconcile` 步骤产出多个中间 JSON（`doctors.json`、`export_index.json`、`reconcile_result.json`、`supplement_plan.json`、`capture_targets.json`），且匹配逻辑在莲藕无 `idCard` 时仍可能按身份证单字段尝试匹配，姓名不一致时仅作 note 而不进缺失名单。

业务要求：

- **必须**莲藕 `doctorName` + `idCard` 与导出「姓名」+「身份证号」同时匹配
- **禁止**仅用姓名 fallback
- **莲藕无 `idCard`** → 直接进缺失名单
- 默认只保留两个产物：`workspace/to_supplement.json` 与 `exports/缺失名单-{timestamp}.xlsx`

## Decision

1. **匹配规则**（[`src/reconcile/matcher.py`](../../src/reconcile/matcher.py)）：
   - 莲藕无 `idCard` → 缺失名单，不查导出
   - 导出无该身份证 → 缺失名单
   - 身份证有但姓名与导出不一致 → 缺失名单
   - 双匹配成功 → `to_supplement.json`

2. **产物精简**：
   - 默认写入：`to_supplement.json`（key=`{姓名}|{身份证}`）+ 缺失名单 xlsx（仅姓名、身份证，去重）
   - `--debug` 时额外保存 `doctors.json`、`export_index.json` 及旧格式 debug 文件

3. **下游命令**统一读 `to_supplement.json`：
   - `supplement`：遍历 `records[].fieldsToWrite`
   - `capture-institution` / `capture-nhc`：按 `needsCapture`
   - `upload-images`：按 `records[].missingFields` 找图片

4. **`reconcile` 自包含**：未指定 `--doctors` / `--export-index` 时，内存拉 API + 解析最新导出，不强制落盘中间 JSON。

5. **`run-all`** 以 `reconcile` 为入口，不再单独跑 `fetch` / `parse-exports`。

## Consequences

- 当前莲藕 API 不返回 `idCard` 时，`to_supplement.json` 为空、缺失名单很大——符合规则，非实现缺陷
- 待 API 返回身份证后，无需改匹配逻辑即可产生待补数据
- 旧脚本若依赖 `supplement_plan.json` / `capture_targets.json`，需改用 `to_supplement.json` 或加 `--debug`
