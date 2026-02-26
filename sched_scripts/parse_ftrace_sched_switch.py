import sys


def parse_ftrace_file(file_path, find_migrate=False):
    try:
        with open(file_path, 'r') as file:
            lines = file.readlines()

        process_records = {}
        for line in lines:
            if '==>' not in line:
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            cpu = parts[1].strip('[]')
            timestamp = float(parts[2].strip(':'))
            switch_info = line.split('==>')
            if len(switch_info) != 2:
                continue

            from_process_info = switch_info[0].strip().split()
            if len(from_process_info) < 3:
                continue
            from_process = from_process_info[-3]

            to_process_info = switch_info[1].strip().split()
            if len(to_process_info) < 2:
                continue
            to_process = to_process_info[0]

            if from_process not in process_records:
                process_records[from_process] = []
            process_records[from_process].append((timestamp, cpu, 'switchout'))

            if to_process not in process_records:
                process_records[to_process] = []
            process_records[to_process].append((timestamp, cpu, 'switchin'))

        for process, records in process_records.items():
            records.sort()
            if find_migrate:
                prev_cpu = None
                prev_record = None
                migrate_count = 0
                for record in records:
                    timestamp, cpu, event = record
                    if prev_cpu is not None and cpu != prev_cpu:
                        print(f"{process} CPU{prev_cpu} {prev_record[0]} {prev_record[2]}")
                        print(f"{process} CPU{cpu} {timestamp} {event}")
                        migrate_count += 1
                    prev_cpu = cpu
                    prev_record = record
                print(f"{process} CPU migration count: {migrate_count}")
            else:
                for timestamp, cpu, event in records:
                    print(f"{process} CPU{cpu} {timestamp} {event}")

    except FileNotFoundError:
        print(f"Error: File {file_path} not found.")
    except Exception as e:
        print(f"An unknown error occurred: {e}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <file_path> [--migrate_cpu]")
        sys.exit(1)

    file_path = sys.argv[1]
    find_migrate = '--migrate_cpu' in sys.argv

    parse_ftrace_file(file_path, find_migrate)
