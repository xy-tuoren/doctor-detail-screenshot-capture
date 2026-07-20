# 机构端导出列到莲藕字段的映射规则

一个医生只会出现在主执业导出或多执业导出之一（互斥），在哪张表被匹配到就决定其执业类型与日期来源。映射规则：

- 在**主执业导出**命中：`recordDate`（备案日期）← `审核日期`；`recordExpireDate` 不补（主执业导出无结束日期，见 ADR-0003）。
- 在**多执业导出**命中：`recordDate`（备案日期）← `开始日期`；`recordExpireDate`（备案到期日期）← `结束日期`。
- 科室：`professionalList` ← 「执业范围」（`,`/`，` → `;`）+ 「医师类别」→ `professionalType`。
- 执业类型：`medicalInstitutionType` ← 主执业导出命中=1，多执业导出命中=2。
- 图片字段：`healthCommissionBase`、`institutionBase` 由截图脚本填入 base64，不从导出表映射。
- **匹配键**：`doctorName` + `practicingCertCode` 与导出「姓名」+「执业证书编码」双字段（见 ADR-0008）；身份证号仅用于报告展示与采图定位，不作为匹配键，不写入 `UpdateDoctorMedical`。

只写回 `updateField` 点名缺失、且导出该行确有值的字段；导出无值则跳过（dropped，不算缺失）。其中"主执业用审核日期充当备案日期"属于业务约定、在代码里看不出缘由，故在此显式记录，避免后人误改。
