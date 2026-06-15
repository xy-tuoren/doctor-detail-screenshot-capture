# 写回经 UpdateDoctorMedical 单条更新，图片以 base64 字符串写入

补全与图片回填统一走莲藕 `POST /api/doctorExt/UpdateDoctorMedical`（单条更新，鉴权同查询接口：`nonce/timestamp/sign` query + header `sign:lo`，`code==1` 为成功）。请求体必填 `AId`、`DoctorFileId`、`doctorName`，其余字段可选。`institutionBase` / `healthCommissionBase` 接口侧就是普通字符串字段，没有独立上传接口；本项目约定**把本地截图读成 base64 字符串直接写入这两个字段**。因写回作用于生产系统且不可轻易回退，`supplement` 与 `upload-images` 默认 dry-run，必须显式加 `--commit` 才真正调用接口。
