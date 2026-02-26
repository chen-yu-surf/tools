import time
import subprocess

def get_numa_metrics_from_vmstat():
    result = subprocess.run(['cat', '/proc/vmstat'], stdout=subprocess.PIPE, text=True)
    metrics = {}

    for line in result.stdout.splitlines():
        if 'numa' in line:
            key, value = line.split()
            metrics[key] = int(value)

    return metrics

def get_numa_metrics_from_memory_stat():
    try:
        with open('/sys/fs/cgroup/mytest/memory.stat', 'r') as file:
            lines = file.readlines()
    except FileNotFoundError:
        print("/sys/fs/cgroup/mytest/memory.stat not found.")
        return {}
    
    metrics = {}
    for line in lines:
        if 'numa' in line:
            key, value = line.split()
            metrics[key] = int(value)
    return metrics

def print_delta(prev_metrics, curr_metrics):
    for key in prev_metrics:
        delta = curr_metrics.get(key, 0) - prev_metrics.get(key, 0)
        print(f"{key}: {delta}")
    print()

def main():
    initial_vmstat_metrics = get_numa_metrics_from_vmstat()
    initial_memory_stat_metrics = get_numa_metrics_from_memory_stat()
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        final_vmstat_metrics = get_numa_metrics_from_vmstat()
        final_memory_stat_metrics = get_numa_metrics_from_memory_stat()
        
        print("\nDelta values for /proc/vmstat:")
        print_delta(initial_vmstat_metrics, final_vmstat_metrics)
        
        print("Delta values for /sys/fs/cgroup/mytest/memory.stat:")
        print_delta(initial_memory_stat_metrics, final_memory_stat_metrics)
        
        print("Monitoring stopped by user.")

if __name__ == "__main__":
    main()
