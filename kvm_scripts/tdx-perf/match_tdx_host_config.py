keywords = [
    "CONFIG_EXPERT", "CONFIG_KVM", "CONFIG_KVM_SW_PROTECTED_VM",
    "CONFIG_KVM_INTEL", "CONFIG_X86_SGX_KVM", "CONFIG_X86_X2APIC",
    "CONFIG_HYPERVISOR_GUEST", "CONFIG_X86_SGX", "CONFIG_INTEL_TDX_HOST",
    "INTEL_TDX_GUEST", "TDX_GUEST_DRIVER"
]
special_case = "CONFIG_HYPERV is not set"

with open('config.txt', 'r') as file:
    content_lines = file.readlines()

content = ''.join(content_lines)

not_matched_lines = []

for keyword in keywords:
    if keyword != special_case.strip():
        found = False
        for line in content_lines:
            if (keyword + "=y" in line or keyword + "=m" in line):
                found = True
                break
        if not found:
            for line in content_lines:
                if keyword in line:
                    not_matched_lines.append(line.strip())
                    break
            else:
                not_matched_lines.append(f"{keyword}=y or {keyword}=m expected but not found")
    else:
        if special_case not in content:
            not_matched_lines.append(special_case)

if not not_matched_lines:
    print("Yes, matched")
else:
    print("Not matched lines:")
    for line in not_matched_lines:
        print(line)
