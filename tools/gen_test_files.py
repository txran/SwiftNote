#!/usr/bin/env python3
"""SwiftNote M0 技术预研 · 测试文件生成器

生成 3 个测试文件（默认输出到脚本所在目录下的 testdata/）：
  1. small_1mb.json  约 1MB  合法 JSON  —— FR-05 格式化性能测试（阈值 ≤0.5s）
  2. big_50mb.json   约 50MB 合法 JSON  —— 大文件打开/滚动/跳转测试（阈值打开 ≤2s）
  3. huge_200mb.log  约 200MB 日志文本 —— FR-12 只读降级测试（不冻结、可滚动）

用法:
  python3 gen_test_files.py [输出目录]
生成后可随时删除，重跑脚本即可重新生成。
"""

import json
import os
import random
import string
import sys

random.seed(20261117)


def rand_word(n):
    return ''.join(random.choices(string.ascii_lowercase, k=n))


def make_entry(i):
    """模拟服务配置条目（内容为虚构测试数据）"""
    return {
        "serviceId": f"SVC-{i:06d}",
        "hostName": f"{rand_word(6)}-{i:04d}.example.internal",
        "port": random.choice([80, 443, 8080, 8443, 9090]),
        "timeoutMs": random.choice([3000, 5000, 10000, 30000, 60000]),
        "retryPolicy": {
            "maxRetries": random.randint(1, 5),
            "backoffMs": random.choice([100, 250, 500, 1000]),
        },
        "endpoints": [f"/api/{rand_word(5)}/{i}" for _ in range(random.randint(1, 3))],
        "enabled": random.choice([True, False]),
        "description": ''.join(random.choices(string.ascii_letters + ' ', k=random.randint(30, 90))),
    }


def report(path):
    size_mb = os.path.getsize(path) / 1024 / 1024
    print(f"  生成 {os.path.basename(path)}: {size_mb:.1f} MB")


def gen_json(path, target_mb):
    target = int(target_mb * 1024 * 1024)
    entries = []
    payload = {
        "schemaVersion": "1.0",
        "configType": "CBM-PROTOTYPE-TEST",
        "services": entries,
    }
    batch = max(1000, target // 500 // 4)
    while True:
        start = len(entries)
        for i in range(start, start + batch):
            entries.append(make_entry(i))
        data = json.dumps(payload, ensure_ascii=False, indent=2)
        if len(data.encode('utf-8')) >= target:
            break
    with open(path, 'w', encoding='utf-8') as f:
        f.write(data)
    report(path)


def gen_log(path, target_mb):
    target = target_mb * 1024 * 1024
    levels = ['INFO', 'WARN', 'ERROR', 'DEBUG']
    written = 0
    chunk = []
    with open(path, 'w', encoding='utf-8') as f:
        while written < target:
            lv = random.choice(levels)
            msg = ''.join(random.choices(string.ascii_letters + string.digits + ' ', k=random.randint(40, 110)))
            ts = (f"2026-11-17 {random.randint(0, 23):02d}:{random.randint(0, 59):02d}:"
                  f"{random.randint(0, 59):02d}.{random.randint(0, 999):03d}")
            line = f"{ts} [{lv:5s}] [thread-{random.randint(1, 32):02d}] CbmMessageParser - {msg}\n"
            chunk.append(line)
            written += len(line.encode('utf-8'))
            if len(chunk) >= 10000:
                f.write(''.join(chunk))
                chunk = []
        if chunk:
            f.write(''.join(chunk))
    report(path)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), 'testdata')
    os.makedirs(out_dir, exist_ok=True)
    print(f"输出目录: {out_dir}")
    print("[1/3] small_1mb.json（FR-05 格式化性能测试）")
    gen_json(os.path.join(out_dir, 'small_1mb.json'), 1)
    print("[2/3] big_50mb.json（大文件打开/滚动/跳转测试）")
    gen_json(os.path.join(out_dir, 'big_50mb.json'), 50)
    print("[3/3] huge_200mb.log（只读降级测试）")
    gen_log(os.path.join(out_dir, 'huge_200mb.log'), 200)
    print("完成。两个 JSON 均为合法 JSON，可直接用于格式化/校验测试。")


if __name__ == '__main__':
    main()
