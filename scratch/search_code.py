import os

target = "MINIMUM_CONTEXT_LENGTH"
search_dir = r"c:\Users\admin\Pictures\Hermes-USB-Portable\src\hermes-agent"

for root, dirs, files in os.walk(search_dir):
    for file in files:
        if file.endswith(".py"):
            path = os.path.join(root, file)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    content = f.read()
                if target in content:
                    lines = content.splitlines()
                    for idx, line in enumerate(lines):
                        if target in line:
                            print(f"{path}:{idx+1}: {line}")
            except Exception as e:
                pass
