# 医生数据采集与补全（Doctor Data Capture & Completion）

本项目围绕"医生执业相关数据的采集、核对与补全"展开：从内部业务系统拉取我方管理的医生名单及其缺失字段，与机构端注册数据核对，补全可补的字段，并采集机构端与卫健委两类公示截图。

## Language

### 数据来源（Data Sources）

**莲藕系统**：
我方内部业务系统（imax，`GetDoctorMedicalPage` 接口）。是"我方管理哪些医生、各医生缺哪些字段"的权威来源，也是需要被补全/写回的目标系统。
_Avoid_: 系统（单独使用时含义不清）、内部系统、imax（仅在指接口实现时使用）

**机构端**：
医师电子化注册信息系统（机构版）桌面客户端及其导出数据。是"审核日期、开始/结束日期、执业范围"等注册信息的权威来源。其导出名单用于与莲藕系统名单核对。
_Avoid_: 民科、实际系统、注册库

**主执业导出 / 多执业导出**：
机构端导出的两张名单。主执业导出含"审核日期"，无开始/结束日期；多执业导出含"开始日期/结束日期"，无审核日期。**一个医生只会出现在其中一张**（两张互斥）。
_Avoid_: 第一执业表、多点执业表（指文件时统一用此二名）

**第一执业 / 多点执业**：
医生执业类型，对应莲藕字段 `medicalInstitutionType`（1 / 2）。本项目中该类型由"医生在主执业还是多执业导出里被匹配到"确定，而非作为查表的输入。
_Avoid_: 主执业/多执业（这两个词专指上面的导出文件，不指类型）

**卫健委**：
国家卫健委医师执业注册信息公示平台（`zgcx.nhc.gov.cn`）。公开查询平台，用于采集卫健委公示截图。
_Avoid_: 公示平台、国网

### 核对与名单（Reconciliation & Rosters）

**核对（对比）**：
以莲藕系统名单为基准，用莲藕的 `doctorName` + `practicingCertCode`（执业证书编号）与机构端导出的「姓名」+「执业证书编码」**双字段同时匹配**。莲藕无 `practicingCertCode`、导出无该证书号、或姓名与导出不一致 → **莲藕有机构端无**核对名单。双匹配成功 → 按 `docMedicalList` 逐医院生成 **to_submit.json** 操作体。机构端导出有而莲藕没有对应证书号 → **机构端有莲藕无**核对名单（仅统计，不新增整名医生）。禁止仅用姓名匹配，证书号为空一律进莲藕有机构端无名单。
_Avoid_: 比对、匹配

**中间数据（to_submit.json）**：
核对后对每个「双匹配成功」的医生，遍历其 `docMedicalList` 生成 **UpdateDoctorMedical 请求体数组**，每项带 `operationType`：
- docMedicalList 中**缺「莲藕健康医院」** → 一条 **新增**（`operationType=0`），携带新增接口需要的全部字段（必填 5 项 + 机构类型/医院/科室/日期 + 图片空占位）。
- docMedicalList 中**每个已存在医院**（含莲藕健康医院）若 `updateField` 非空 → 一条 **更新**（`operationType=1`，带 `aId`），只含必填 5 项 + `updateField` 点名且我方可提供的字段；图片字段空占位供后续脚本写入 base64。

**莲藕健康医院**：
本院在 `docMedicalList` 中的医院名（固定字符串 `莲藕健康医院`）。每位我方管理的医生都应有一条本院记录，缺则新增、有则按其 `updateField` 更新。

**未匹配名单**（合并为单文件 `workspace/reconcile_report.xlsx`，每次核对覆盖）：
一个 xlsx、两个 sheet，**三列：姓名、执业证书编号、身份证**（身份证**展示**优先莲藕 API `idCard`，为空时用机构端导出「身份证号」补充，不参与匹配）：
- sheet `莲藕有机构端无`：莲藕 API 有该医生，但机构端导出无法按「执业证书编号+姓名」双字段匹配（含证书号为空、导出无此证号、姓名不一致）。
- sheet `机构端有莲藕无`：机构端导出有该医生，但莲藕 API 无对应执业证书编号。

**管线中间产物（`workspace/`）**：
每次 `reconcile` 默认只落 **3 个主文件**（固定名、覆盖写）：
| 文件 | 说明 |
|------|------|
| `to_submit.json` | 提交操作体（新增/修改），后续采图、回填、提交均读此文件 |
| `reconcile_report.xlsx` | 核对名单（上表两个 sheet） |
| `reconcile_summary.json` | 核对摘要（条数统计、导出来源路径） |

子目录（不 clutter 根目录）：
| 路径 | 说明 |
|------|------|
| `cache/doctors_api_cache.json` | 莲藕 API 全量缓存（24h 复用） |
| `tmp/capture-config-*.json` | 机构端采图临时配置 |
| `tmp/nhc-failures.log` | 卫健委采图失败日志 |
| `debug/` | 仅 `--debug`：`doctors.json`、`export_index.json`、`reconcile_result.json` |

机构端 SOAP 原始导出（输入）在 `exports/reg-api/`；截图在 `captures/`。

**缺失字段**：
莲藕系统接口为每位医生返回的、标记其缺少哪些数据的字段（接口字段 `updateField`）。指示该医生需要补全什么。
_Avoid_: updateField（仅指接口字段实现时使用）

### 采集产物（Capture Artifacts）

**机构端图片**：
从机构端客户端详情窗采集的执业信息截图。对应莲藕系统的 `institutionBase`（机构端图片 base64）字段。
_Avoid_: captures、详情截图

**卫健委图片**：
从卫健委公示平台采集的医师信息截图，与机构端图片同存于 `captures/` 下（`captures/卫健委/`）。对应莲藕系统的 `healthCommissionBase`（卫健委图片 base64）字段。
_Avoid_: screenshots、batch-doctor-query
