# ADR-0007: 严格双字段匹配与精简 reconcile 产物

## Status

Superseded（匹配规则部分被 [ADR-0008](0008-cert-match-docmedical-operationtype.md) 取代：匹配键改为「姓名 + 执业证书编号」，不再用身份证号）。产物精简、`run-all` 入口等部分仍有效。

## Context

原先 `reconcile` 步骤产出多个中间 JSON（`doctors.json`、`export_index.json`、`reconcile_result.json`、`supplement_plan.json`、`capture_targets.json`），且匹配逻辑在莲藕无 `idCard` 时仍可能按身份证单字段尝试匹配，姓名不一致时仅作 note 而不进缺失名单。

业务要求：

- **必须**双字段同时匹配（**当前口径：莲藕 `doctorName` + `practicingCertCode` 与导出「姓名」+「执业证书编码」**，见 ADR-0008）
- **禁止**仅用姓名或仅身份证 fallback
- **莲藕无 `practicingCertCode`** → 直接进未匹配名单
- 默认只保留两个产物：`workspace/artifacts/to_submit.json` 与 `reconcile_report.xlsx`

## Decision

1. **匹配规则**（[`src/reconcile/matcher.py`](../../src/reconcile/matcher.py)）：以 ADR-0008 为准——姓名 + 执业证书编号双字段；任一字段缺失或不一致 → 未匹配名单。

2. **产物精简**：
   - 默认写入：`to_submit.json` + `reconcile_report.xlsx`（sheet：莲藕有机构端无 / 机构端有莲藕无）
   - `--debug` 时额外保存 `doctors.json`、`export_index.json`、`reconcile_result.json`

3. **下游命令**统一读 `to_submit.json`：
   - `submit`：遍历操作体数组
   - `capture-institution` / `capture-nhc`：按 `_capture` 元数据
   - `fill-images`：按图片字段填 base64

4. **`reconcile` 自包含**：未指定 `--doctors` / `--export-index` 时，内存拉 API + 解析最新导出，不强制落盘中间 JSON。

5. **`run-all`** 以 `reconcile` 为入口，不再单独跑 `fetch` / `parse-exports`。

## Consequences

- 莲藕 API 返回的 `practicingCertCode` 为空时，该医生进未匹配名单——符合规则，非实现缺陷
- 旧脚本若依赖 `supplement_plan.json` / `capture_targets.json`，需改用 `to_submit.json` 或加 `--debug`
