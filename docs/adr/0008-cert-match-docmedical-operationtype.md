# ADR-0008: 证书号匹配、docMedicalList 逐医院、operationType 中间数据

## Status

Accepted（取代 [ADR-0007](0007-strict-match-and-slim-artifacts.md) 的「身份证双字段匹配」与 `to_supplement.json` / `to_create.json` 产物约定）

## Context

最新接口与业务调整：

- 莲藕查询接口 `GetDoctorMedicalPage` 返回的缺失信息已变为**按医院维度**的 `docMedicalList[]`（每项含 `aId` / `hospital` / `updateField`），不再是医生维度的单个 `updateField`。
- 业务要求匹配键由身份证改为**执业证书编号 `practicingCertCode` + 姓名**。
- 机构端导出目录：`exports/ui/`（客户端 UI 手动导出，多为 `.xls`）、`exports/reg-api/`（SOAP 接口 `.xlsx`）。
- 每位我方管理的医生都应在 `docMedicalList` 中有一条「莲藕健康医院」记录；缺则新增、有则更新。

## Decision

1. **匹配规则**（[`src/reconcile/matcher.py`](../../src/reconcile/matcher.py)）：
   - 莲藕无 `practicingCertCode` → **莲藕有机构端无**核对名单（不回退身份证/姓名）。
   - 导出无该证书号 → **莲藕有机构端无**核对名单。
   - 证书号命中但姓名与导出不一致 → **莲藕有机构端无**核对名单。
   - 双匹配成功 → 进入中间数据生成。
   - 机构端导出有、莲藕无对应证书号 → **机构端有莲藕无**核对名单（仅统计）。

2. **导出读取**（[`src/institution_export/parser.py`](../../src/institution_export/parser.py)）：
   - 在 `exports/ui/`（客户端 UI 导出）与 `exports/reg-api/`（SOAP 导出）下查找 `主执业导出-*.xlsx|xls`、`多执业导出-*.xlsx|xls`，取修改时间最新；兼容仍放在 `exports/` 根目录的旧文件。
   - `.xlsx` 用 openpyxl 读取，`.xls`（OOXML 伪装）沿用内置 zip/xml 读取。
   - 索引键改为**执业证书编码**（main: dict、multi: list）；姓名用于第二字段校验，身份证随行保留供图片采集。

3. **中间数据 `to_submit.json`**（[`src/reconcile/submit_payload.py`](../../src/reconcile/submit_payload.py)、[`src/reconcile/to_supplement.py`](../../src/reconcile/to_supplement.py)）：
   - 缺「莲藕健康医院」→ `operationType=0` 新增，`updateField` 对象带齐新增业务字段。
   - docMedicalList 每个已存在医院（含莲藕健康医院）查询接口 `updateField` 非空 → `operationType=1` 更新，带 `aId`；`updateField` 仅为**本次实际要提交的键值对**（点名 + 导出可映射），非查询接口 `docMedicalList` 原结构。
   - 顶层：身份五件套 + `operationType` / `aId`；`updateField`：业务字段对象层；`_capture` / `_op`：本地采图与调试，不提交。
   - `postable_body` 提交前展平顶层 + `updateField`；更新丢弃空值，新增保留空占位。

4. **提交**（[`src/lianou/writeback.py`](../../src/lianou/writeback.py)）：
   - body 透传 `operationType`；更新校验 `aId`、新增校验 `doctorFileId`。
   - 新增操作即便选填字段为空也带齐；更新操作丢弃 `updateField` 内空值。
   - `submit --include-images` 或 `fill-images --commit` 提交图片 base64。

5. **管线步骤化**（[`src/cli/pipeline_cmds.py`](../../src/cli/pipeline_cmds.py)）：
   `export-reg`（可选）→ `fetch`（可选）→ `reconcile` → `capture-institution` → `capture-nhc` → `fill-images` → `submit`。
   每步可单独运行；`run-all` 默认从 `reconcile` 起串跑（`--with-export` 才含 SOAP 导出），`submit` / `fill-images` 默认 dry-run、`--commit` 才真写回。

6. **字段映射**（[`src/reconcile/field_mapping.py`](../../src/reconcile/field_mapping.py)）：
   - `departmentName` ← 导出「执业范围」；主执业 `recordDate` ← 「审核日期」；多执业 `recordDate`/`recordExpireDate` ← 「开始/结束日期」。
   - 省/市/等级导出无列时默认广东省、广州市、`hospitalLevel=10`。

## Consequences

- `departmentName` 来自导出「执业范围」，非「所在科室」列；主执业导出该列常为空时科室仍可能由执业范围提供。
- 省/市/医院等级导出不提供时，新增与点名更新使用业务默认值（广东省、广州市、二级）。
- 同一医生多医院会产生多条操作（1 条新增 + N 条更新）；图片按医生去重采集后回填到该医生的所有相关操作。
- 接口体使用 camelCase（`aId/doctorFileId/iDCard`）；若服务端只认 PascalCase，提交步骤会暴露失败再调整。
- 旧产物 `to_supplement.json` / `to_create.json` / 分散的核对名单 xlsx 被 `workspace/to_submit.json` + `workspace/reconcile_report.xlsx`（双 sheet）取代；旧脚本需迁移。
