# 通过 UpdateDoctorMedical 单条写回，图片用 base64 内联

补全写回调用莲藕 `POST /api/doctorExt/UpdateDoctorMedical`（鉴权同查询接口：`nonce/timestamp/sign` query + header `sign:lo`，`code==1` 为成功）。该接口单条更新，必填 `AId`、`DoctorFileId`、`doctorName`，其余字段按需提交（请求体为 PascalCase）。

图片没有独立上传接口：`institutionBase` / `healthCommissionBase` 直接作为 base64 字符串字段写入，本项目将本地截图读为纯 base64（默认不带 `data:image/<mime>;base64,` 前缀；可在 config 设 `imageDataUri: true` 开启）后填入同一更新接口。因此"上传图片"与"补字段"复用同一 HTTP 调用，仅字段不同。

写回为高风险且默认指向生产 baseUrl，故 `supplement` 与 `upload-images` 默认 dry-run，必须显式 `--commit` 才真正调用接口，避免误写生产数据。
