# Next.js 交接：医生执业医院数据拉取与生成

本文说明如何把本仓库「机构端 SOAP + 莲藕 API → 报告 xlsx → MongoDB」能力接到 **Next.js** 网站使用。  
**不依赖**机构端桌面客户端；浏览器不能直连 SOAP，须经后端/Worker。

---

## 1. 目标与边界

### 要做什么

| 能力 | 说明 |
|------|------|
| 生成数据 | 全量拉取本院主执业 ∪ 多执业医生执业明细，拼莲藕档案三列，产出报告 |
| 落库 | 写入 MongoDB，供网站查询/展示 |
| 查询 | Next.js API 读 Mongo（或读生成好的文件），**不**在请求里同步跑全量 SOAP |

### 不要做什么

- 不要在浏览器 / Next.js Route Handler 里同步跑全量拉数（约 **10–25 分钟**）
- 不要把机构端账号、莲藕签名、Mongo 密码暴露给前端
- 本交接**不含**机构端 UI 采图、卫健委采图、`to_submit` 写回莲藕主线

---

## 2. 推荐架构

```text
[Next.js 前端]
    │  触发任务 / 查进度 / 查数据
    ▼
[Next.js API Routes 或独立 BFF]
    │  写 job 状态；禁止同步 SOAP
    ▼
[异步 Worker / 定时任务]  ← 复用本仓库 Python CLI
    │  ① build-practice-hospital-report
    │  ② export_practice_report_to_mongo.py
    ▼
[MongoDB hospital_admin]
    ▲
[Next.js API] 查询 practiceDetails / importReports / 聚合
```

建议形态（产品侧已改为 **hospital-admin 内自含**）：

1. **数据生成**：在 `hospital-admin` 内移植机构端 SOAP + 莲藕拉取与 join，由「获取数据」创建异步 job（同进程 fire-and-forget；后续可用 worker_threads 优化）。**不**再依赖本仓库 Python 作为运行时服务。  
2. **数据消费**：Next.js 读 Mongo `practiceDetails` / `importReports`  
3. **任务状态**：Mongo 集合 `practiceHospitalJobs`  
4. **本仓库**：仍可作为协议/字段口径的参考实现（`practice_table` / `practice_hospital_report` / 导库脚本），非网站运行时依赖。

---

## 3. 本仓库已有能力（直接复用）

### 3.1 环境

```powershell
cd doctor-detail-screenshot-capture
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
pip install openpyxl pymongo   # 报告与导库需要
```

配置文件：项目根 `config.json`（从 `config.json.example` 复制，**勿提交**）

| 配置 | 用途 |
|------|------|
| `loginUser` / `loginPassword` | 机构端 SOAP 登录 |
| `minkeRegApi.*` | 登录/医生服务 URL、ProductId、超时、workers |
| `doctorApi.*` | 莲藕 `GetDoctorMedicalPage` |

可选环境变量（项目根 `.env`，已 gitignore）：

```env
MONGO_URI=mongodb://USER:PASS@HOST:27017/hospital_admin?authSource=hospital_admin
```

### 3.2 生成报告（核心）

```powershell
# 全量：机构端 SOAP + 莲藕 API → xlsx（约 10–25 分钟）
.\.venv\Scripts\python.exe -m src.cli build-practice-hospital-report

# 已有机构端明细时只重拉莲藕三列
.\.venv\Scripts\python.exe -m src.cli build-practice-hospital-report --skip-institution-fetch
```

默认产出：

| 文件 | 含义 |
|------|------|
| `workspace/artifacts/医生执业医院.xlsx` | 机构端全量明细（中间结果） |
| `workspace/artifacts/医生执业医院信息_20260706.xlsx` | 四 sheet 报告（含莲藕档案列） |
| 运行时模板（本机） | `workspace/artifacts/医生执业医院信息.xlsx`（可含历史数据；生成时覆盖数据区） |
| **仓库内精简模板（可提交）** | `templates/医生执业医院信息.xlsx`（四 sheet + 互联网医院 A–G 名单，无明细数据） |

常用参数：

| 参数 | 说明 |
|------|------|
| `--output PATH` | 指定输出 xlsx |
| `--workers N` | 机构端并行预取线程（也可用 `minkeRegApi.practiceTableWorkers`） |
| `--skip-institution-fetch` | 跳过 SOAP 明细，用已有 `医生执业医院.xlsx` |

**数据口径（重要）**

- 医生名单入口：SOAP `DoctorUnitGetListForOther` **st=1 ∪ st=8**（本院主执业 + 多执业含本院）
- 每人明细：会继续拉该医生其它注册行（含省外等），故「证书去重人数」可能略大于 UI 两表行数之和
- 莲藕三列：证书号优先 join；对不上则姓名唯一兜底；对不上则档案编号为空（**不是**机构端漏人）
- 不依赖桌面客户端；须能直连 `jgd.wsb002.cn`（避免 Clash fake-ip `198.18.x.x`）

### 3.3 导入 Mongo

```powershell
.\.venv\Scripts\python.exe scripts\export_practice_report_to_mongo.py `
  -x workspace/artifacts/医生执业医院信息_20260706.xlsx

# 若要先清空旧明细与批次（互联网医院主数据不动）
.\.venv\Scripts\python.exe scripts\export_practice_report_to_mongo.py `
  -x workspace/artifacts/医生执业医院信息_20260706.xlsx `
  --drop-existing
```

脚本会自动读项目根 `.env` 中的 `MONGO_URI`。

默认行为：**追加**新批次（新 `reportId`），不清空历史 `practiceDetails`。  
网站查「当前数据」务必按**最新** `importReports.importedAt` 过滤。

---

## 3.4 报告 xlsx「医生执业医院信息」与模板

`hospital-admin` 管线除写 Mongo 外，**应同步生成**与本仓库口径一致的报告文件（便于留档/对账）。  
Python 参考：`src/minke_reg/practice_hospital_report.py`（复制模板 → 重写各 sheet）。

### 产出文件名

| 场景 | 建议路径 |
|------|----------|
| 本仓库 CLI | `workspace/artifacts/医生执业医院信息_20260706.xlsx`（历史固定名，每次覆盖） |
| hospital-admin | 如 `data/exports/医生执业医院信息_YYYYMMDD_HHmmss.xlsx`，并在 `importReports.sourceXlsx` 记录路径 |

### 模板文件

| 项 | 说明 |
|----|------|
| 仓库模板 | **`templates/医生执业医院信息.xlsx`**（精简版，可进 Git） |
| 用法 | 生成时 `copy` 模板 → 写入「全量明细 / 医生执业医院数 / 医院重叠数」；**保留**「互联网医院重叠数」A–G 列名单，仅重算 H 列「执业医生数」 |
| 勿提交 | 含全量明细的大文件（数 MB）不要当模板提交 |

### 四 sheet 结构

#### Sheet「全量明细」（表头第 1 行，数据自第 2 行）

| 列 | 字段 |
|----|------|
| A–Q | 机构端：姓名、身份证号、执业证书编码、性别、医师类别、医师级别、执业范围、任职资格、审批日期、开始日期、结束日期、是否主执业机构、是否省外、执业医院、医院地址、省份、数据来源 |
| R–T | 莲藕：档案编号、档案状态（启用/停用）、所属团队 |

#### Sheet「医生执业医院数」

表头：医生档案、医生姓名、医生团队、档案状态、执业医院数、互联网执业医院数。  
（模板中可保留右侧分桶/合作统计占位文案，与 Python 报告一致。）

#### Sheet「互联网医院重叠数」（模板主数据）

| 列 | 含义 | 生成时 |
|----|------|--------|
| A 互联网医院名单 | 主数据 | **保留模板** |
| B 经营现状 | 主数据 | 保留 |
| C 网院属性 | 主数据 | 保留 |
| D 医院牌照类型 | 主数据 | 保留 |
| E 网院公司名称 | 主数据 | 保留 |
| F 实体医院 | 与明细「执业医院」对齐用 | 保留 |
| G 入驻平台 | 主数据 | 保留 |
| H 执业医生数 | 派生 | **按实体医院名聚合重算**（不落 Mongo 派生表也可现场算） |

精简模板已内置约 **56** 条互联网医院名单（A–G）。

#### Sheet「医院重叠数」

表头：执业医院、启用、停用、总计（按证书去重统计档案状态）。

### hospital-admin 实现要求（PR 验收）

1. 仓库内纳入 `templates/医生执业医院信息.xlsx`（或等价路径，并在文档标明）。  
2. Job 成功路径：join 完成后 **先写 xlsx（四 sheet）再写 Mongo**（或并行，但 `sourceXlsx` 必须有值）。  
3. 页面/API 可选提供「下载本次报告 xlsx」。  
4. 未实现 xlsx 时不得宣称与本仓库报告文件等价。

---

## 4. Mongo 数据模型（供 Next.js 查询）

数据库名：`hospital_admin`

### 4.1 `importReports`（导入批次，1 条/次）

| 字段 | 类型 | 说明 |
|------|------|------|
| `_id` | ObjectId | 即 `reportId` |
| `importedAt` | Date | 导入时间（UTC） |
| `sourceXlsx` | string | 来源文件路径 |
| `status` | string | `building` / `ready` |
| `summary` | object | 见下 |

`summary` 示例字段：

- `detailRows` / `doctors` / `hospitals`
- `lianouMatchedRows` / `lianouMissRows`
- `coopDoctors` / `nonCoopDoctors`（档案启用/停用）
- `internetHospitals`

### 4.2 `practiceDetails`（全量明细，每医生×每医院一行）

| 字段 | 说明 |
|------|------|
| `reportId` | 所属批次 |
| `importedAt` | 导入时间 |
| `doctorName` | 姓名 |
| `idCard` | 身份证 |
| `practicingCertCode` | 执业证书编码（已规范化） |
| `gender` / `medicalCategory` / `medicalLevel` / `practiceScope` / `qualificationTitle` | 基础信息 |
| `auditDate` / `startDate` / `endDate` | 审批/起止日期（Date 或 null） |
| `isMainPractice` / `isOutOfProvince` | 布尔 |
| `practiceHospital` / `hospitalAddress` / `province` / `dataSource` | 执业机构 |
| `doctorFileId` / `archiveStatus` / `team` | 莲藕档案三列；对不上时为空 |

查询最新批次明细：

```js
const latest = await db.collection("importReports")
  .find({ status: "ready" })
  .sort({ importedAt: -1 })
  .limit(1)
  .next();

const rows = await db.collection("practiceDetails")
  .find({ reportId: latest._id })
  .limit(50)
  .toArray();
```

### 4.3 `internetHospitals`（互联网医院主数据，upsert）

字段含：`internetHospitalName`、`operationStatus`、`hospitalAttribute`、`licenseType`、`networkCompany`、`entityHospital`、`platform`、`active` 等。  
「执业医生数」等派生指标**不落库**，用聚合按需算。

---

## 5. 建议的 Next.js API 设计

以下为交接约定，路径可按项目调整。鉴权（Session/JWT）由网站统一加。

### 5.1 查询类（同步，读 Mongo）

#### `GET /api/practice-hospitals/reports/latest`

返回最新就绪批次元数据。

```json
{
  "reportId": "…",
  "importedAt": "2026-07-20T…",
  "status": "ready",
  "summary": {
    "detailRows": 20219,
    "doctors": 3486,
    "hospitals": 4814,
    "lianouMatchedRows": 20126,
    "lianouMissRows": 93,
    "coopDoctors": 2980,
    "nonCoopDoctors": 418
  }
}
```

#### `GET /api/practice-hospitals/details`

| Query | 说明 |
|-------|------|
| `reportId` | 可选，默认 latest |
| `page` / `pageSize` | 分页 |
| `cert` | 执业证书编码 |
| `name` | 姓名（模糊需自己建索引策略） |
| `hospital` | 执业医院 |
| `archiveStatus` | `启用` / `停用` |
| `hasFileId` | `true`/`false` 是否已匹配莲藕 |

#### `GET /api/practice-hospitals/doctors/:cert`

某证书下全部执业医院行（同一 `reportId`）。

#### `GET /api/practice-hospitals/stats/hospital-overlap`（可选）

对最新 `reportId` 做 aggregation：按 `practiceHospital` 统计医生数（证书去重）、启用/停用等。  
派生逻辑对齐本仓库报告 sheet「医院重叠数」，不必落库。

### 5.2 生成类（异步，触发 Worker）

#### `POST /api/practice-hospitals/jobs`

触发一次全量生成 + 导入。

请求体示例：

```json
{
  "dropExisting": false,
  "skipInstitutionFetch": false
}
```

响应（立即返回）：

```json
{
  "jobId": "…",
  "status": "queued"
}
```

Worker 伪流程（本仓库已实现）：

1. 网站 `POST /jobs` 写入 Mongo 集合 `practiceHospitalJobs`（`status=queued`）  
2. 数据机常驻本仓库 Worker，领取任务并将 job 置为 `running`  
3. 执行：`python -m src.cli build-practice-hospital-report`  
4. 成功后执行：`python scripts/export_practice_report_to_mongo.py -x <产出xlsx> [--drop-existing]`  
5. 写回 job `succeeded` + 新 `reportId`；失败写 `failed` + `error`

```powershell
# 数据机（本仓库根目录）常驻轮询；网站点「获取数据」后才会被领取
.\.venv\Scripts\python.exe scripts\practice_hospital_job_worker.py

# 或任务计划：有单处理一单
.\.venv\Scripts\python.exe scripts\practice_hospital_job_worker.py --once
```

Worker 读写字段：`status` / `phase`（`claimed`→`building_report`→`importing_mongo`→`done`）/ `dropExisting` / `skipInstitutionFetch` / `reportId` / `error`。

#### `GET /api/practice-hospitals/jobs/:jobId`

返回进度/状态（queued / running / succeeded / failed）。  
全量无细粒度进度时，可展示 `phase` 文案。

**禁止**：在 `POST` 的 Route Handler 内 `await` 跑完整 CLI。网站按钮只建任务；真正拉数依赖数据机 Worker。

---

## 6. Next.js 侧依赖与环境变量

```env
# 仅给 Next.js 查询用（只读账号更佳）
MONGODB_URI=mongodb://...@.../hospital_admin?authSource=hospital_admin
MONGODB_DB=hospital_admin

# 触发任务用（可选：调用内网 Worker webhook）
PRACTICE_JOB_WEBHOOK_URL=https://worker.internal/run-practice-report
PRACTICE_JOB_WEBHOOK_SECRET=...
```

Worker 机器另需：

- 本仓库 `config.json`（机构端 + 莲藕）
- `MONGO_URI`（可写）
- 出站访问 `jgd.wsb002.cn` 与莲藕 `doctorApi.baseUrl`
- Python `.venv` 与依赖

包建议：`mongodb` 或 `mongoose`（Next.js）；Worker 继续用本仓库 Python。

---

## 7. 与「机构端桌面应用」的关系

| 项目 | 说明 |
|------|------|
| 本数据链路 | **不需要**安装/启动桌面客户端 |
| 客户端用途 | UI 采图、人工点选导出；与本报告链路独立 |
| 服务地址 | 与客户端 `exe.config` 中 DocUnit/Login ASMX 相同 |
| 本机缓存 | 客户端有 `TempGarbageData`；本仓库列表用空 `aMd5Str`，不读该缓存 |

---

## 8. 验收清单（交接自测）

1. 本仓库或 hospital-admin Job 成功产出「医生执业医院信息」四 sheet xlsx（基于 `templates/医生执业医院信息.xlsx`）  
2. Mongo：`importReports.status=ready`，且 `sourceXlsx` 指向该文件；`practiceDetails` 有明细  
3. Next.js `GET .../reports/latest` 返回新 `importedAt`  
4. `details` 分页可查；按证书能查到多医院行  
5. 档案编号为空的行：机构端字段仍在，属莲藕未匹配，不算生成失败  
6. 全量任务走异步（HTTP 立即返回）；长任务勿部署在短超时 Serverless  
7. 互联网医院 sheet：A–G 与模板名单一致，H 列执业医生数已按本批明细重算  

---

## 9. 关键代码索引

| 路径 | 说明 |
|------|------|
| `src/cli/pipeline_cmds.py` → `build-practice-hospital-report` | 报告 CLI 入口 |
| `src/minke_reg/practice_table.py` | 机构端 SOAP 明细 |
| `src/minke_reg/practice_hospital_report.py` | 拼报告、莲藕 join |
| `src/minke_reg/session.py` / `soap.py` | 登录与 SOAP 客户端 |
| `scripts/export_practice_report_to_mongo.py` | xlsx → Mongo |
| `AGENTS.md` | 项目总说明与术语 |
| `docs/nextjs-practice-hospital-api-handoff.md` | 本文 |

---

## 10. 联系与注意事项

- `config.json`、`.env`、Mongo 密码勿进 Git、勿进前端 bundle  
- 机构端账号是否允许服务器侧长期自动化，需业务/合规确认  
- 机器指纹（登录 S2/S3）绑部署机；换机需回归登录  
- 文档日期口径以仓库代码为准；若 CLI 参数变更，以 `python -m src.cli build-practice-hospital-report -h` 为准  
