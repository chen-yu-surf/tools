import os
import re
import sys

def get_pids_by_name(task_name_substr):
    pids = []
    for pid in os.listdir('/proc'):
        if pid.isdigit():
            try:
                with open(f'/proc/{pid}/comm', 'r') as file:
                    comm = file.read().strip()
                    if task_name_substr in comm:
                        pids.append(pid)
            except IOError:
                continue
    return pids

def parse_numa_maps(pid):
    numa_node_allocations = {}
    try:
        with open(f"/proc/{pid}/numa_maps", 'r') as file:
            for line in file:
                match = re.findall(r'N(\d+)=(\d+)', line)
                if match:
                    for node, pages in match:
                        node = int(node)
                        pages = int(pages)
                        if node not in numa_node_allocations:
                            numa_node_allocations[node] = 0
                        numa_node_allocations[node] += pages
    except IOError:
        print(f"Cannot open /proc/{pid}/numa_maps")
        return None

    return numa_node_allocations

def get_running_cpu(pid):
    try:
        with open(f"/proc/{pid}/stat", 'r') as file:
            fields = file.read().split()
            cpu = fields[38]  # The 39th field is the last CPU the process ran on
            return int(cpu)
    except IOError:
        print(f"Cannot open /proc/{pid}/stat")
        return None

def main(task_name_substr):
    pids = get_pids_by_name(task_name_substr)
    if not pids:
        print(f"No tasks found with name containing '{task_name_substr}'")
        return

    for pid in pids:
        allocations = parse_numa_maps(pid)
        cpu = get_running_cpu(pid)

        if allocations is not None and cpu is not None:
            print(f"Task PID: {pid}, Running CPU: {cpu}")
            for node, pages in sorted(allocations.items()):
                print(f"  NUMA Node {node}: {pages} pages")
        else:
            print(f"Failed to retrieve information for PID {pid}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <task_name_substr>")
        sys.exit(1)

    task_name_substr = sys.argv[1]
    main(task_name_substr)

