# ADR-0008: 证书号匹配、docMedicalList 逐医院、operationType 中间数据

## Status

Accepted（取代 [ADR-0007](0007-strict-match-and-slim-artifacts.md) 的「身份证双字段匹配」与 `to_supplement.json` / `to_create.json` 产物约定）

## Context

最新接口与业务调整：

- 莲藕查询接口 `GetDoctorMedicalPage` 返回的缺失信息已变为**按医院维度**的 `docMedicalList[]`（每项含 `aId` / `hospital` / `updateField`），不再是医生维度的单个 `updateField`。
- 业务要求匹配键由身份证改为**执业证书编号 `practicingCertCode` + 姓名**。
- 机构端导出已改为 SOAP 接口产出的 `.xlsx`，落在 `exports/reg-api/`（旧 UI 导出 `.xls` 在 `exports/`）。
- 每位我方管理的医生都应在 `docMedicalList` 中有一条「莲藕健康医院」记录；缺则新增、有则更新。

## Decision

1. **匹配规则**（[`src/reconcile/matcher.py`](../../src/reconcile/matcher.py)）：
   - 莲藕无 `practicingCertCode` → **莲藕有机构端无**核对名单（不回退身份证/姓名）。
   - 导出无该证书号 → **莲藕有机构端无**核对名单。
   - 证书号命中但姓名与导出不一致 → **莲藕有机构端无**核对名单。
   - 双匹配成功 → 进入中间数据生成。
   - 机构端导出有、莲藕无对应证书号 → **机构端有莲藕无**核对名单（仅统计）。

2. **导出读取**（[`src/institution_export/parser.py`](../../src/institution_export/parser.py)）：
   - 同时查找 `exports/` 与 `exports/reg-api/` 下的 `主执业导出-*.xlsx|xls`、`多执业导出-*.xlsx|xls`，取最新。
   - `.xlsx` 用 openpyxl 读取，`.xls`（OOXML 伪装）沿用内置 zip/xml 读取。
   - 索引键改为**执业证书编码**（main: dict、multi: list）；姓名用于第二字段校验，身份证随行保留供图片采集。

3. **中间数据 `to_submit.json`**（[`src/reconcile/submit_payload.py`](../../src/reconcile/submit_payload.py)）：
   - 缺「莲藕健康医院」→ `operationType=0` 新增，带齐新增接口字段。
   - docMedicalList 每个已存在医院（含莲藕健康医院）`updateField` 非空 → `operationType=1` 更新，仅必填 5 项 + 点名且可提供的字段。
   - 字段命名对齐接口文档（`operationType/aId/doctorFileId/iDCard/qualificationCertCode/practicingCertCode/...`）；图片字段空占位。

4. **提交**（[`src/lianou/writeback.py`](../../src/lianou/writeback.py)）：
   - body 透传 `operationType`；更新校验 `aId`、新增校验 `doctorFileId`。
   - 新增操作即便选填字段为空也带齐；更新操作丢弃空值。

5. **管线步骤化**（[`src/cli/pipeline_cmds.py`](../../src/cli/pipeline_cmds.py)）：
   `export-reg`（可选）→ `fetch` → `reconcile` → `capture-institution` → `capture-nhc` → `fill-images` → `submit`。
   每步可单独运行；`run-all` 默认从 `reconcile` 起串跑（`--with-export` 才含导出），提交默认 dry-run、`--commit` 才真写回。

## Consequences

- 主执业导出的「所在科室」当前为空，故 `departmentName` 多数为空；省/市/医院等级导出不提供，新增时以空值提交。
- 同一医生多医院会产生多条操作（1 条新增 + N 条更新）；图片按医生去重采集后回填到该医生的所有操作。
- 接口体使用 camelCase（`aId/doctorFileId/iDCard`）；若服务端只认 PascalCase，提交步骤会暴露失败再调整。
- 旧产物 `to_supplement.json` / `to_create.json` / `缺失名单.xlsx` 被 `workspace/to_submit.json` + `workspace/核对名单-莲藕有机构端无-*.xlsx` + `workspace/核对名单-机构端有莲藕无-*.xlsx` 取代；旧脚本需迁移。
