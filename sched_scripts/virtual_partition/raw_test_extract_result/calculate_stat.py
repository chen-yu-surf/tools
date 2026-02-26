import sys
import numpy as np

def calculate_statistics(data):
    values = [float(x[1]) for x in data]
    mean_val = np.mean(values)
    median_val = np.median(values)
    std_dev = np.std(values)
    
    std_dev_percentage_mean = (std_dev / mean_val) * 100
    std_dev_percentage_median = (std_dev / median_val) * 100
    
    return mean_val, median_val, std_dev_percentage_mean, std_dev_percentage_median

def process_file(file_path):
    with open(file_path, mode='r') as file:
        lines = file.readlines()
        
    grouped_data = []
    current_group = []
    for line in lines:
        test_name, value = line.strip().split(',')
        if not current_group or current_group[0][0] == test_name:
            current_group.append((test_name, value))
        else:
            grouped_data.append(current_group)
            current_group = [(test_name, value)]
    if current_group:
        grouped_data.append(current_group)
    
    print("test,mean,median,stdev1%,stdev2%")
    
    for group in grouped_data:
        if len(group) != 3:
            print(f"Warning: {group[0][0]} does not have exactly 3 entries.")
            continue
        
        mean_val, median_val, std_dev_percentage_mean, std_dev_percentage_median = calculate_statistics(group)
        print(f"{group[0][0]},{mean_val:.2f},{median_val:.2f},{std_dev_percentage_mean:.2f}%,{std_dev_percentage_median:.2f}%")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <path_to_input_file>")
        sys.exit(1)
    
    file_path = sys.argv[1]
    process_file(file_path)
