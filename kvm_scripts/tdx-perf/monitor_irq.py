import time
import sys

def read_interrupts():
    cal_counts = None
    loc_counts = None
    with open('/proc/interrupts', 'r') as f:
        for line in f:
            if line.startswith(' CAL:'):
                parts = line.split()
                cal_counts = [int(part) for part in parts[1:] if part.isdigit()]
            elif line.startswith(' LOC:'):
                parts = line.split()
                loc_counts = [int(part) for part in parts[1:] if part.isdigit()]
    return cal_counts, loc_counts

def calculate_delta(initial, final):
    return [f - i for i, f in zip(initial, final)]

def main(interval):
    # Read initial interrupt counts
    initial_cal, initial_loc = read_interrupts()
    if initial_cal is None or initial_loc is None:
        print("Could not find 'CAL' or 'LOC' line in /proc/interrupts")
        return

    # Wait for the specified interval
    time.sleep(interval)

    # Read final interrupt counts
    final_cal, final_loc = read_interrupts()
    if final_cal is None or final_loc is None:
        print("Could not find 'CAL' or 'LOC' line in /proc/interrupts")
        return

    # Calculate and print the delta
    delta_cal = calculate_delta(initial_cal, final_cal)
    delta_loc = calculate_delta(initial_loc, final_loc)
    print("Interrupt deltas (CAL):")
    print(delta_cal)
    print("Interrupt deltas (LOC):")
    print(delta_loc)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 monitor_irq.py <interval_in_seconds>")
        sys.exit(1)

    try:
        interval = int(sys.argv[1])
    except ValueError:
        print("Please provide a valid integer for the interval.")
        sys.exit(1)

    main(interval)
