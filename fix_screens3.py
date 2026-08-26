import os

files = [
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_metadata_screen.dart",
]

with open(files[0], 'r', encoding='utf-8') as f:
    c = f.read()

c = c.replace("[].catchError((_) => <Map<String, dynamic>>[]);", "<Map<String, dynamic>>[];")

with open(files[0], 'w', encoding='utf-8') as f:
    f.write(c)

print("Fixed catchError")
