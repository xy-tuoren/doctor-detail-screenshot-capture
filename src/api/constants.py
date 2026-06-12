API_PATH = "/api/doctorExt/GetDoctorMedicalPage"

HOSPITAL_LEVEL_LABELS = {
    1: "一级",
    2: "一级甲",
    10: "二级",
    11: "二级甲",
    12: "二级乙",
    13: "二级丙",
    20: "三级",
    21: "三级甲",
    22: "三级乙",
    23: "三级丙",
    91: "未定级",
    92: "未查到",
}

MEDICAL_INSTITUTION_TYPE_LABELS = {
    1: "第一执业",
    2: "多点执业",
}

DEFAULT_API_CONFIG = {
    "baseUrl": "http://imax.lianouyiyuan.com",
    "nonce": "1486837976",
    "timestamp": "1597991281",
    "sign": "09149C743CDEEB7FB8E688701AD0349F013AF2FB",
    "headerSign": "lo",
    "pageSize": 100,
    "outputDir": "exports",
    "requestTimeoutSeconds": 60,
    "retryCount": 3,
    "retryDelaySeconds": 2,
}
