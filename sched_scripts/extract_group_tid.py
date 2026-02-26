import re
import sys

def parse_perf_c2c_report(input_text):
    tid_pattern = re.compile(r'\s+\d+\s+(\d+):[a-zA-Z_]+\s+')
    cache_line_tid_sets = []
    current_tids = set()
    start_marker = "=================================================\n      Shared Cache Line Distribution Pareto\n================================================="
    lines = input_text.split('\n')
    target_block = []
    in_target_block = False
    
    for line in lines:
        current_line_trimmed = line.strip()
        if not in_target_block:
            temp_line = '\n'.join(target_block[-2:] + [line]) if len(target_block)>=2 else line
            if start_marker in temp_line:
                in_target_block = True
                target_block = []
            else:
                target_block.append(line)
            continue
        if current_line_trimmed.startswith('=================================================') and len(target_block) > 0:
            break
        if in_target_block:
            target_block.append(line)
    
    for line in target_block:
        if line.strip().startswith('----------------------------------------------------------------------'):
            if current_tids:
                cache_line_tid_sets.append(current_tids.copy())
                current_tids.clear()
            continue
        match = tid_pattern.search(line)
        if match:
            tid = match.group(1)
            current_tids.add(tid)
    if current_tids:
        cache_line_tid_sets.append(current_tids)
    
    final_groups = []
    for tid_set in cache_line_tid_sets:
        groups_to_merge = []
        for idx, group in enumerate(final_groups):
            if not group.isdisjoint(tid_set):
                groups_to_merge.append(idx)
        new_group = tid_set.copy()
        for idx in sorted(groups_to_merge, reverse=True):
            new_group.update(final_groups.pop(idx))
        final_groups.append(new_group)
    
    print("===== Final Thread Groups (Threads in the same group may share data, no sharing between groups) =====")
    for group_idx, tid_group in enumerate(final_groups, start=1):
        sorted_tids = sorted(list(tid_group), key=lambda x: int(x))
        print(f"g{group_idx}: {{{', '.join(sorted_tids)}}}")
    
    return final_groups

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 script.py <perf_c2c_report_file>")
        sys.exit(1)
    file_path = sys.argv[1]
    with open(file_path, "r", encoding="utf-8") as f:
        perf_output = f.read()
    parse_perf_c2c_report(perf_output)
