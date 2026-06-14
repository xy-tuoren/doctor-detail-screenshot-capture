"""SOAP API for 医师电子化注册信息系统（机构版），与坐标自动化分离。"""



from .config import load_minke_reg_config, project_root

from .doctor_list import export_main_records, export_multi_records, fetch_doctor_unit_list

from .exporter import default_output_path, save_reg_workbook, save_reg_xlsx

from .session import login_minke_reg



__all__ = [

    "load_minke_reg_config",

    "project_root",

    "login_minke_reg",

    "export_main_records",

    "export_multi_records",

    "fetch_doctor_unit_list",

    "default_output_path",

    "save_reg_workbook",

    "save_reg_xlsx",

]

