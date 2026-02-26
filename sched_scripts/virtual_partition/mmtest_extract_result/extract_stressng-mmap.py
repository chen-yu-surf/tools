import os
import re
import sys

def extract_throughput_values(directory):
    # Regular expression to match the file pattern
    file_pattern = re.compile(r'stressng-\d+-\d+\.log')
    # Regular expression to extract the throughput value
    mmap_pattern = re.compile(r'mmap\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)')

    # List to store throughput values
    throughput_values = []

    # Iterate over all files in the directory
    for filename in os.listdir(directory):
        if file_pattern.match(filename):
            file_path = os.path.join(directory, filename)
            with open(file_path, 'r') as file:
                for line in file:
                    match = mmap_pattern.search(line)
                    if match:
                        throughput_value = match.group(5)
                        throughput_values.append(f"Throughput {throughput_value}")
                        break  # Stop after finding the first match in the file

    # Print all throughput values
    for throughput_value in throughput_values:
        print(throughput_value)

if __name__ == "__main__":
    # Check if the directory path is provided as a command-line argument
    if len(sys.argv) != 2:
        print("Usage: python extract_throughput.py <directory_path>")
        sys.exit(1)

    # Get the directory path from the command-line argument
    user_directory = sys.argv[1]
    extract_throughput_values(user_directory)
