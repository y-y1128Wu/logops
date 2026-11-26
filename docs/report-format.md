# LogOps 报表格式规范说明 (v1.0)

本规范严格依照《接口冻结值（表1）》制定，用于定义 `analyze.sh` 生成的两个输出文件（`summary.csv` 和 `report.md`）的数据格式，供组内其他模块（如网页看板、自动测试）对接使用。

## 1. summary.csv 规范
- **文件路径**：`out/summary.csv`
- **编码格式**：UTF-8 **带 BOM**（确保 Windows Excel 直接打开不乱码）
- **表头要求**：必须严格固定为三列 `section,item,value`
- **数据行要求**：每行按逗号分隔，不包含多余空格。

**示例格式：**
```csv
section,item,value
总览,总请求数,5
总览,独立IP数,3
总览,5xx错误数,1
