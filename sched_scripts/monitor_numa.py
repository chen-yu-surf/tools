import time
import subprocess

def get_numa_metrics():
    """获取当前的NUMA指标"""
    result = subprocess.run(['cat', '/proc/vmstat'], stdout=subprocess.PIPE, text=True)
    metrics = {}
    
    for line in result.stdout.splitlines():
        if 'numa' in line:
            key, value = line.split()
            metrics[key] = int(value)
    
    return metrics

def print_delta(prev_metrics, curr_metrics):
    """打印两个采样之间的delta差值"""
    print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    for key in prev_metrics:
        delta = curr_metrics.get(key, 0) - prev_metrics.get(key, 0)
        print(f"{key}: {delta}")
    print()

def main():
    # 初始化前一次的指标为空字典
    prev_metrics = None
    
    while True:
        # 获取当前的NUMA指标
        curr_metrics = get_numa_metrics()
        
        # 如果有前一次的指标，则计算并打印delta
        if prev_metrics is not None:
            print_delta(prev_metrics, curr_metrics)
        
        # 更新前一次的指标为当前指标
        prev_metrics = curr_metrics
        
        # 每次循环后休眠5秒
        time.sleep(5)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Monitoring stopped by user.")
