DEFAULT_LOGIN_SERVICE_URL = (

    "https://jgd.wsb002.cn/LoginUnitService/LoginService.asmx"

)

from src.institution_export.paths import EXPORT_REG_API_DIR

DEFAULT_DOC_UNIT_SERVICE_URL = (

    "https://jgd.wsb002.cn/Unit.DoctorReg.WSL/MKDocUnitService.asmx"

)

DEFAULT_PRODUCT_ID = "8fad1b8d-2020-48d1-824b-5b3b261ee089"



NS_LOGIN = "http://www.minke.cn/LoginService/"

NS_DOCTOR_UNIT = "http://www.minke.cn/doctor/unit/"



EMPTY_GUID = "00000000-0000-0000-0000-000000000000"



MAIN_ROW_TAGS = frozenset({"vDoctor_RegMain", "tDoctor_RegMain"})

MULTI_ROW_TAGS = frozenset(

    {"tDoctor_RegMain_Muti", "tDoctor_RegMuti", "vDoctor_RegMain_Muti"}

)



DEFAULT_MINKE_REG_CONFIG = {

    "loginServiceUrl": DEFAULT_LOGIN_SERVICE_URL,

    "docUnitServiceUrl": DEFAULT_DOC_UNIT_SERVICE_URL,

    "productId": DEFAULT_PRODUCT_ID,

    "outputDir": f"exports/{EXPORT_REG_API_DIR}",

    "requestTimeoutSeconds": 120,

    "mainSearchType": 1,

    "multiSearchType": 8,

    "forceRefreshMd5": "",

    "useDoctorUnitGetListForOther": False,

    "detailFetchWorkers": 48,

    "detailFetchRetries": 2,

    "detailReuseConnection": True,

}

