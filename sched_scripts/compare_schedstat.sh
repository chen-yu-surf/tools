#!/bin/bash
set -euo pipefail

# 检查参数
if [ $# -ne 1 ]; then
    echo "用法: $0 <时间间隔(秒)>"
    exit 1
fi
interval=$1

# 创建临时文件（使用当前目录，避免/tmp权限问题）
data1=$(mktemp ./schedstat_data1.XXXXXX)
data2=$(mktemp ./schedstat_data2.XXXXXX)

# 定义采集函数（用awk解析，避免bash子shell问题）
get_schedstat() {
    local output="$1"
    # 直接用awk解析/proc/schedstat，输出格式化数据
    awk '
    /^cpu[0-9]+$/ {          # 匹配CPU行（如cpu175）
        current_cpu = $0;
        current_domain = "";
        next;
    }
    /^domain[0-9]+/ {        # 匹配domain行（如domain0）
        current_domain = $1;  # 取第一个字段（domain0）
        next;
    }
    /^(not_idle|idle|new_idle)/ {  # 匹配属性行
        if (current_cpu != "" && current_domain != "") {
            # 确保有9个数值字段（$2到$10）
            if (NF == 10) {
                # 输出格式：CPU:Domain:属性 数值1 ... 数值9
                printf "%s:%s:%s %s %s %s %s %s %s %s %s %s\n",
                    current_cpu, current_domain, $1,
                    $2, $3, $4, $5, $6, $7, $8, $9, $10 >> "'"$output"'";
            }
        }
    }' /proc/schedstat
    # 检查文件是否生成
    if [ ! -s "$output" ]; then
        echo "错误：数据采集失败，文件 $output 为空"
        exit 1
    fi
}

# 第一次采集
echo "第一次获取数据..."
get_schedstat "$data1"

# 等待间隔
sleep "$interval"

# 第二次采集
echo "第二次获取数据..."
get_schedstat "$data2"

# 计算并打印结果
echo -e "\n符合条件的delta值结果（第2-9列有非零值）："
echo "CPU:Domain:属性 [lb_count, lb_llc, lb_numa, lb_llc_sg, lb_numa_sg, lb_llc_balance, lb_numa_balance, lb_llc_nr, lb_numa_nr]"

awk '
BEGIN { FS = " " }
# 读取第一次数据到数组a
NR == FNR {
    key = $1;
    for (i=2; i<=10; i++) a[key][i-1] = $i;
    next;
}
# 处理第二次数据，计算差值
{
    key = $1;
    if (key in a) {
        # 计算9列差值
        for (i=2; i<=10; i++) delta[i-1] = $i - a[key][i-1];
        # 检查第2-9列是否有非零值
        has_nonzero = 0;
        for (i=2; i<=9; i++) {
            if (delta[i] != 0) {
                has_nonzero = 1;
                break;
            }
        }
        # 打印结果
        if (has_nonzero) {
            printf "%s: [%d, %d, %d, %d, %d, %d, %d, %d, %d]\n",
                key, delta[1], delta[2], delta[3], delta[4], delta[5],
                delta[6], delta[7], delta[8], delta[9];
        }
    }
}' "$data1" "$data2"

# 清理临时文件
rm -f "$data1" "$data2"
echo -e "\n处理完成"
