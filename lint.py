#!/usr/bin/env python3
import os
import re
import sys
import yaml


def parse_duration_seconds(value) -> float | None:
    """
    解析 docker compose duration 字符串，返回秒数。
    支持常见单位：h、m、s、ms、us、ns。
    """
    if not isinstance(value, str):
        return None

    text = value.strip()
    if not text:
        return None

    matches = re.findall(r'(\d+(?:\.\d+)?)(h|ms|us|ns|m|s)', text)
    if not matches:
        return None

    rebuilt = ''.join(f'{number}{unit}' for number, unit in matches)
    if rebuilt != text:
        return None

    total_seconds = 0.0
    unit_scale = {
        'h': 3600,
        'm': 60,
        's': 1,
        'ms': 1e-3,
        'us': 1e-6,
        'ns': 1e-9,
    }

    for number, unit in matches:
        total_seconds += float(number) * unit_scale[unit]

    return total_seconds


def is_stateless(conf: dict) -> bool:
    """
    判断服务是否为无状态：
    - stop_grace_period 为 20s
    - 或 deploy.replicas > 2
    - 或 deploy.update_config.order 为 start-first
    """
    sgp = conf.get('stop_grace_period')
    if isinstance(sgp, str) and sgp.endswith('s') and sgp[:-1] == '20':
        return True
    replicas = conf.get('deploy', {}) .get('replicas')
    if isinstance(replicas, int) and replicas > 2:
        return True
    order = conf.get('deploy', {}).get('update_config', {}).get('order')
    if order == 'start-first':
        return True
    return False


def validate_service(name: str, conf: dict):
    """
    根据服务类型（无状态/有状态）校验必需字段及取值规范，
    返回 (is_stateless, error_list)
    """
    errors = []
    stateless = is_stateless(conf)
    upd = conf.get('deploy', {}).get('update_config', {})

    if stateless:
        # 无状态服务规范
        if conf.get('stop_grace_period') != '20s':
            errors.append("stop_grace_period 应为 '20s'")
        if upd.get('order') != 'start-first':
            errors.append("deploy.update_config.order 应为 'start-first'")
        if upd.get('delay') != '5s':
            errors.append("deploy.update_config.delay 应为 '5s'")
    else:
        # 有状态服务规范
        stop_grace_period = parse_duration_seconds(conf.get('stop_grace_period'))
        if stop_grace_period is None or stop_grace_period < 60:
            errors.append("stop_grace_period 应大于等于 '60s'")
        if upd.get('order') != 'stop-first':
            errors.append("deploy.update_config.order 应为 'stop-first'")
        if upd.get('delay') != '60s':
            errors.append("deploy.update_config.delay 应为 '60s'")
        replicas = conf.get('deploy', {}).get('replicas')
        if replicas not in (None, 1):
            errors.append("deploy.replicas 应不存在或等于 1")

    return stateless, errors


def process_file(path: str):
    print(f"\n→ 检查文件: {path}")
    data = yaml.safe_load(open(path)) or {}
    services = data.get('services')
    if not isinstance(services, dict):
        print("  ⚠️ 未发现 services 节点或格式不正确，跳过")
        return

    has_error = False
    for svc_name, svc_conf in services.items():
        stateless, errs = validate_service(svc_name, svc_conf or {})
        svc_type = '无状态' if stateless else '有状态'
        print(f"  服务 '{svc_name}' 被检测为 {svc_type}")
        if errs:
            has_error = True
            print("    ❌ 配置不符合规范：")
            for e in errs:
                print(f"      - {e}")

def main(root='./stage4'):
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            if fn in ('docker-compose.yml', 'docker.compose.yml'):
                process_file(os.path.join(dirpath, fn))


if __name__ == '__main__':
    root_dir = sys.argv[1] if len(sys.argv) > 1 else './stage4'
    main(root_dir)
