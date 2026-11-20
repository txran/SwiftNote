#!/usr/bin/env python3
"""生成 SwiftNote 冒烟测试用的小样例文件（多标签 / 三格式高亮）。

用法：
    python3 tools/gen_samples.py            # 默认生成 12 个 bulk JSON
    python3 tools/gen_samples.py 40         # 生成 40 个，用于验证末行溢出计数
"""
import json
import os
import sys

BASE = os.path.join(os.path.dirname(__file__), "testdata", "samples")
BULK = int(sys.argv[1]) if len(sys.argv) > 1 else 12


def write(name: str, content: str) -> None:
    with open(os.path.join(BASE, name), "w", encoding="utf-8") as f:
        f.write(content)


def main() -> None:
    os.makedirs(BASE, exist_ok=True)

    for name in ["message-parser.json", "cbm-types.json", "gateway-config.json"]:
        write(name, json.dumps({
            "version": 1,
            "messageName": "CbmMessage",
            "parserEnabled": True,
            "timeoutMs": 3000,
            "fields": [
                {"fieldName": "header", "fieldType": "string", "length": 8, "required": True},
                {"fieldName": "payload", "fieldType": "bytes", "length": None, "required": False},
            ],
            "remark": "网关超时配置示例",
        }, ensure_ascii=False, indent=2))

    write("message-template.xml", """<?xml version="1.0" encoding="UTF-8"?>
<!-- CBM 消息解析配置
     支持多行注释与属性 -->
<message name="CbmOrderEvent" version="2.1">
    <field name="header" type="string" length="8" required="true"/>
    <field name="payload" type="bytes" required="false">
        <description><![CDATA[原始报文，长度自适应
可跨行]]></description>
    </field>
</message>
""")

    write("parser.properties", """# CBM 解析参数
gateway.timeout=3000
gateway.retryCount: 2
# 续行示例
parser.rules = header,payload,\\
  trailer
[advanced]
cacheEnabled = true
""")

    for i in range(BULK):
        write(f"bulk-{i:02d}.json", json.dumps({
            "version": i + 1,
            "messageName": f"CbmMessage{i}",
            "parserEnabled": i % 2 == 0,
            "timeoutMs": 1000 + i * 100,
            "remark": f"批量标签测试 #{i}",
        }, ensure_ascii=False, indent=2))

    print(f"已生成样例到 {BASE}（bulk {BULK} 个）")


if __name__ == "__main__":
    main()
